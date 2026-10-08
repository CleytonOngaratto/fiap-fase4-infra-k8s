[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$Namespace = "car-workshop",
    [switch]$Force,
    [switch]$SkipAudit,
    [switch]$AuditOnly
)

# 'Continue', nao 'Stop': no PS 5.1 o stderr de executavel nativo vira NativeCommandError.
$ErrorActionPreference = "Continue"
$script:Failed = $false

function Write-Head($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Write-Ok($t) { Write-Host "  [OK]   $t" -ForegroundColor Green }
function Write-Warn2($t) { Write-Host "  [WARN] $t" -ForegroundColor Yellow }
function Write-Fail($t) { Write-Host "  [FAIL] $t" -ForegroundColor Red; $script:Failed = $true }

function Invoke-Native {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$NativeArgs)
    $ErrorActionPreference = "Continue"
    $out = & $Exe @NativeArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = @($out); Text = ($out -join "`n") }
}

# Consulta que falhou nao pode virar "vazio": com token expirado toda chamada devolve $null.
function Get-AwsValue {
    param([Parameter(Mandatory)][string[]]$Query)
    $r = Invoke-Native -Exe "aws" -NativeArgs ($Query + @("--region", $Region, "--output", "text"))
    $script:LastAwsOk = ($r.ExitCode -eq 0)
    if ($r.ExitCode -ne 0) { return $null }
    return ($r.Text -replace "`r", "").Trim()
}

function Invoke-AuditAndExit {
    Write-Head "Auditoria da conta (o passo que faltou em 2026-09-02)"

    # Sem espaco dentro das queries: o PS 5.1 mexe nas aspas de argumento de executavel nativo.
    $checks = [ordered]@{
        "EKS clusters"        = @("eks", "list-clusters", "--query", "clusters")
        "EC2 nao-encerradas"  = @("ec2", "describe-instances", "--filters", "Name=instance-state-name,Values=running,pending,stopping,stopped,shutting-down", "--query", "Reservations[].Instances[].InstanceId")
        "NAT Gateways"        = @("ec2", "describe-nat-gateways", "--filter", "Name=state,Values=available,pending,deleting", "--query", "NatGateways[].NatGatewayId")
        "RDS"                 = @("rds", "describe-db-instances", "--query", "DBInstances[].DBInstanceIdentifier")
        "RDS snapshots"       = @("rds", "describe-db-snapshots", "--snapshot-type", "manual", "--query", "DBSnapshots[].DBSnapshotIdentifier")
        "ELB classic"         = @("elb", "describe-load-balancers", "--query", "LoadBalancerDescriptions[].LoadBalancerName")
        "ELB v2"              = @("elbv2", "describe-load-balancers", "--query", "LoadBalancers[].LoadBalancerName")
        "VPCs nao-default"    = @("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=false", "--query", "Vpcs[].VpcId")
        "EIPs"                = @("ec2", "describe-addresses", "--query", "Addresses[].PublicIp")
        "ENIs disponiveis"    = @("ec2", "describe-network-interfaces", "--filters", "Name=status,Values=available", "--query", "NetworkInterfaces[].NetworkInterfaceId")
        "EBS volumes"         = @("ec2", "describe-volumes", "--query", "Volumes[].VolumeId")
        "ECR repos"           = @("ecr", "describe-repositories", "--query", "repositories[].repositoryName")
        "API Gateways"        = @("apigatewayv2", "get-apis", "--query", "Items[].Name")
        "Lambdas fiap-*"      = @("lambda", "list-functions", "--query", "Functions[?starts_with(FunctionName,'fiap')].FunctionName")
        "SGs nao-default"     = @("ec2", "describe-security-groups", "--query", "SecurityGroups[?GroupName!='default'].GroupName")
        "SNS topicos"         = @("sns", "list-topics", "--query", "Topics[?!ends_with(TopicArn,':RedshiftSNS')].TopicArn")
        "SQS filas"           = @("sqs", "list-queues", "--query", "QueueUrls")
        "DynamoDB tabelas"    = @("dynamodb", "list-tables", "--query", "TableNames")
        "Launch templates"    = @("ec2", "describe-launch-templates", "--query", "LaunchTemplates[].LaunchTemplateName")
    }

    $leftovers = @()
    foreach ($name in $checks.Keys) {
        $value = Get-AwsValue $checks[$name]
        if (-not $script:LastAwsOk) {
            Write-Fail "$name : CONSULTA FALHOU (credencial expirada?) - resultado NAO confiavel"
            $leftovers += $name
            continue
        }
        if ([string]::IsNullOrWhiteSpace($value) -or $value -eq "None") {
            Write-Ok "$name : vazio"
        }
        else {
            Write-Fail "$name : $value"
            $leftovers += $name
        }
    }

    Write-Head "SSM (o que deve sobreviver)"
    $params = Get-AwsValue @("ssm", "get-parameters-by-path", "--path", "/fase4", "--recursive", "--query", "Parameters[].Name")
    if ($params) {
        ($params -split "\s+") | Where-Object { $_ } | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($params -match "/fase4/eks/lb-dns") {
            Write-Warn2 "/fase4/eks/lb-dns sobreviveu (esperado: e do cd.yml, nenhum Terraform o apaga) e agora aponta para um ELB morto."
            Write-Host "         Rode o workflow_dispatch do cd.yml no repo app ANTES do proximo apply do auth-serverless." -ForegroundColor Yellow
        }
    }

    Write-Host ""
    if ($leftovers.Count -gt 0) {
        Write-Host "SOBROU COISA NA CONTA: $($leftovers -join ', ')" -ForegroundColor Red
        Write-Host "Isso continua faturando. Resolva agora — foi assim que a sessao de 2026-09-02 custou US$ 7." -ForegroundColor Red
        exit 1
    }
    if ($script:Failed) {
        Write-Host "A conta esta limpa, mas algum passo reportou falha — leia os [FAIL] acima." -ForegroundColor Yellow
        exit 1
    }
    Write-Host "CONTA ZERADA E CONFERIDA — pode fechar o laboratorio." -ForegroundColor Green
    exit 0
}

$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent

$repos = @(
    [pscustomobject]@{ Name = "fiap-fase4-auth-serverless"; Label = "Lambda + API Gateway" }
    [pscustomobject]@{ Name = "fiap-fase4-infra-k8s"; Label = "VPC + EKS + NAT + ECR" }
)

if ($AuditOnly -and $SkipAudit) {
    Write-Host "  -AuditOnly e -SkipAudit sao contraditorios: use um ou outro." -ForegroundColor Red
    exit 2
}

Write-Head "Sessao AWS"
$identity = Get-AwsValue @("sts", "get-caller-identity", "--query", "[Account,Arn]")
if (-not $identity) {
    Write-Host "  Sem credenciais validas. A sessao do Learner Lab dura ~4h." -ForegroundColor Red
    Write-Host "  Abra o lab, cole o bloco 'AWS Details' em ~/.aws/credentials e rode de novo." -ForegroundColor Red
    exit 1
}
Write-Ok $identity

if ($AuditOnly) {
    Write-Host "  -AuditOnly: nada sera destruido; so a auditoria (somente leitura)." -ForegroundColor DarkGray
    Invoke-AuditAndExit
}

if (-not $Force) {
    Write-Host ""
    Write-Host "  Vai destruir TODA a infraestrutura da Fase 4 nesta conta:" -ForegroundColor Yellow
    foreach ($r in $repos) { Write-Host "    - $($r.Name)  ($($r.Label))" -ForegroundColor Yellow }
    Write-Host "  Os parametros de bootstrap do SSM e o bucket de state sobrevivem (nenhum Terraform os cria)." -ForegroundColor DarkGray
    Write-Host ""
    $answer = Read-Host "  Digite DESTRUIR para confirmar"
    if ($answer -ne "DESTRUIR") { Write-Host "  Abortado." -ForegroundColor Yellow; exit 0 }
}

Write-Head "Services LoadBalancer (a ENI deles trava a VPC)"
$kube = Invoke-Native -Exe "kubectl" -NativeArgs @("get", "svc", "-A", "--no-headers", "--request-timeout=25s")
if ($kube.ExitCode -ne 0) {
    Write-Warn2 "kubectl nao alcancou o cluster — sem Service para remover (a auditoria confere ELB no fim)"
}
else {
    $lbs = @($kube.Lines | Where-Object { $_ -match "LoadBalancer" })
    if ($lbs.Count -eq 0) { Write-Ok "nenhum Service LoadBalancer" }
    foreach ($line in $lbs) {
        $parts = ($line -split "\s+") | Where-Object { $_ }
        $ns = $parts[0]; $name = $parts[1]
        $del = Invoke-Native -Exe "kubectl" -NativeArgs @("-n", $ns, "delete", "svc", $name, "--timeout=180s")
        if ($del.ExitCode -eq 0) { Write-Ok "svc $ns/$name removido" }
        else { Write-Fail "nao consegui remover svc $ns/$name — o destroy da VPC vai travar na ENI" }
    }
}

foreach ($repo in $repos) {
    Write-Head "destroy: $($repo.Name)  ($($repo.Label))"
    $dir = Join-Path $root $repo.Name

    if (-not (Test-Path (Join-Path $dir "backend.hcl"))) {
        Write-Fail "$($repo.Name)/backend.hcl ausente — sem ele o terraform nao abre o state remoto. Crie a partir do backend.hcl.example e rode de novo."
        continue
    }

    $bucket = ((Get-Content (Join-Path $dir "backend.hcl") | Select-String '^\s*bucket') -replace '.*=\s*"?([^"]+)"?.*', '$1').Trim()
    $key = ((Get-Content (Join-Path $dir "backend.hcl") | Select-String '^\s*key') -replace '.*=\s*"?([^"]+)"?.*', '$1').Trim()
    if ($bucket -and $key) {
        $lock = Get-AwsValue @("s3api", "head-object", "--bucket", $bucket, "--key", "$key.tflock", "--query", "LastModified")
        if ($lock) {
            Write-Fail "existe um LOCK no state ($key.tflock, de $lock) — um apply do CI esta rodando. Espere ele terminar e rode de novo."
            continue
        }
    }

    Push-Location $dir
    try {
        $r = Invoke-Native -Exe "terraform" -NativeArgs @("destroy", "-no-color", "-auto-approve")
        $done = $r.Lines | Where-Object { $_ -match "Destroy complete" } | Select-Object -Last 1
        if ($r.ExitCode -eq 0 -and $done) { Write-Ok $done.Trim() }
        elseif ($r.ExitCode -eq 0) { Write-Ok "nada a destruir (state vazio)" }
        else {
            Write-Fail "destroy falhou em $($repo.Name)"
            $r.Lines | Where-Object { $_ -match "^Error|Error:" } | Select-Object -First 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        }
    }
    finally { Pop-Location }
}

if ($SkipAudit) {
    Write-Host "`n  -SkipAudit: a auditoria NAO rodou. Confira a conta a mao antes de dormir." -ForegroundColor Yellow
    exit ($(if ($script:Failed) { 1 } else { 0 }))
}

Invoke-AuditAndExit
