[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Org,
    [string]$Profile = "default",
    [string]$ClusterRoleName,
    [string]$StateBucket,
    [string[]]$Repos = @(
        "fiap-fase4-infra-k8s",
        "fiap-fase4-os-service",
        "fiap-fase4-billing-service",
        "fiap-fase4-execution-service",
        "fiap-fase4-auth-serverless"
    )
)

$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$null = gh auth status
if ($LASTEXITCODE -ne 0) { throw "gh nao autenticado. Rode: gh auth login" }

$keyId = aws configure get aws_access_key_id --profile $Profile
$secret = aws configure get aws_secret_access_key --profile $Profile
$token = aws configure get aws_session_token --profile $Profile

if (-not $keyId -or -not $secret -or -not $token) {
    throw "Credenciais incompletas no perfil '$Profile'. O Learner Lab exige os TRES valores (a sessao e temporaria, precisa do session token)."
}

$identity = aws sts get-caller-identity --profile $Profile --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "As credenciais do perfil '$Profile' nao sao validas (sessao expirada?)." }
Write-Host "Credencial valida — conta $($identity.Account)" -ForegroundColor Green

$secrets = [ordered]@{
    AWS_ACCESS_KEY_ID     = $keyId
    AWS_SECRET_ACCESS_KEY = $secret
    AWS_SESSION_TOKEN     = $token
}

foreach ($repo in $Repos) {
    $target = "$Org/$repo"
    Write-Host "-> $target" -ForegroundColor Cyan
    foreach ($name in $secrets.Keys) {
        # Por stdin: com -b o valor aparece na lista de processos. O gh corta o \r\n que o pipe do PS 5.1 acrescenta.
        $secrets[$name] | gh secret set $name -R $target
        if ($LASTEXITCODE -ne 0) { Write-Warning "Falha ao gravar $name em $target (o repo ja existe no GitHub?)" }
    }

    if ($ClusterRoleName) { gh variable set CLUSTER_ROLE_NAME -R $target -b $ClusterRoleName }
    if ($StateBucket) { gh variable set TF_STATE_BUCKET   -R $target -b $StateBucket }
}

Write-Host ""
Write-Host "Secrets atualizados. Valem enquanto a sessao do lab estiver ativa (~4h)." -ForegroundColor Green
if (-not $ClusterRoleName -or -not $StateBucket) {
    Write-Host "Dica: na primeira execucao passe -ClusterRoleName (do preflight) e -StateBucket (do bootstrap)," -ForegroundColor Yellow
    Write-Host "      senao o workflow de Terraform falha." -ForegroundColor Yellow
}
