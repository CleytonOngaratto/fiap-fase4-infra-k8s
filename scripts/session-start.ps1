[CmdletBinding()]
param([string]$Region = "us-east-1")

Write-Host @"

RETOMADA DE SESSAO — FIAP Fase 4
================================
Ordem de deploy: plataforma (infra-k8s) -> infra de cada servico -> deploy dos servicos -> borda (auth-serverless)
Tempo ate a plataforma de pe: ~30 min

  1. Abrir o lab e colar o bloco 'AWS Details' em ~/.aws/credentials            (~1 min)
  2. w32tm /resync num PowerShell de administrador: o certificado do webhook
     do LB Controller nasce com a hora local, e o relogio desta maquina adianta  (~10 s)
  3. .\scripts\preflight.ps1                                                    (~10 s)
  4. .\scripts\refresh-gh-secrets.ps1 -Org <org> -ClusterRoleName <do preflight> -StateBucket <bucket>
  5. Plataforma: merge na main que mude .tf, ou workflow_dispatch 'apply'        (~20 min)
  6. aws eks update-kubeconfig --name fiap-fase4-eks --region $Region
  7. .\scripts\install-lb-controller.ps1 e .\scripts\install-newrelic-k8s.ps1    (~5 min)
  8. Infra de cada servico: terraform/ do os, do billing e do execution
  9. Deploy dos servicos: o pipeline de cada repositorio
 10. Borda: auth-serverless (root session/; o persistent/ continua de pe)

FIM DA SESSAO — .\scripts\destroy-all.ps1: destroi na ordem inversa e audita a conta item por item.

"@ -ForegroundColor Cyan

$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Sessao do lab NAO esta ativa. Comece pelo passo 1." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Sessao ativa — conta $($identity.Account)" -ForegroundColor Green

$clusters = aws eks list-clusters --region $Region --query "clusters" --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $clusters.Count -gt 0) {
    Write-Host "[!] Ja existe cluster EKS na conta: $($clusters -join ', ')" -ForegroundColor Yellow
    Write-Host "    Se for da sessao anterior, ele esta faturando desde entao. Confira antes de aplicar de novo." -ForegroundColor Yellow
}
else {
    Write-Host "[OK] Nenhum cluster EKS de pe — comecando do zero, como esperado." -ForegroundColor Green
}

$bootstrap = '^/fase4/(jwt|app|newrelic|mercadopago|apigw)/'
$params = aws ssm get-parameters-by-path --path /fase4 --recursive --region $Region --query "Parameters[].Name" --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0) {
    $stale = @($params | Where-Object { $_ -and $_ -notmatch $bootstrap })
    if ($stale.Count -gt 0) {
        Write-Host "[!] $($stale.Count) parametro(s) /fase4 fora do bootstrap, de uma sessao anterior:" -ForegroundColor Yellow
        $stale | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
        Write-Host "    O destroy apaga os que o Terraform criou; se sobrou algum, um destroy nao terminou." -ForegroundColor Yellow
    }
    else {
        Write-Host "[OK] SSM /fase4: so os parametros de bootstrap" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "LEMBRETE: o painel de budget do lab atrasa 8-12h. Nao use como sinal de seguranca." -ForegroundColor Yellow
