[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string]$StateKey = "infra-k8s/terraform.tfstate"
)

$ErrorActionPreference = "Stop"

$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Sem credenciais validas. Abra a sessao do Learner Lab primeiro." }

$bucket = "fiap-fase4-tfstate-$($identity.Account)"
Write-Host "Conta $($identity.Account) · bucket alvo: $bucket" -ForegroundColor Cyan

$existente = aws s3api list-buckets --query "Buckets[?Name=='$bucket'].Name" --output text
if ($existente -eq $bucket) {
    Write-Host "Bucket ja existe — nada a criar." -ForegroundColor Green
}
else {
    # us-east-1 NAO aceita LocationConstraint: a API rejeita.
    if ($Region -eq "us-east-1") {
        $null = aws s3api create-bucket --bucket $bucket --region $Region
    }
    else {
        $null = aws s3api create-bucket --bucket $bucket --region $Region --create-bucket-configuration "LocationConstraint=$Region"
    }
    if ($LASTEXITCODE -ne 0) { throw "Falha ao criar o bucket $bucket." }

    $null = aws s3api put-bucket-versioning --bucket $bucket --versioning-configuration "Status=Enabled"

    $null = aws s3api put-public-access-block --bucket $bucket `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

    Write-Host "Bucket criado, versionado e fechado para acesso publico." -ForegroundColor Green
}

$null = aws s3api put-bucket-tagging --bucket $bucket --tagging "TagSet=[{Key=Project,Value=fiap-fase4},{Key=ManagedBy,Value=bootstrap-backend}]"
if ($LASTEXITCODE -ne 0) { throw "Falha ao taguear o bucket $bucket." }
Write-Host "Tags do bucket: Project=fiap-fase4, ManagedBy=bootstrap-backend." -ForegroundColor Green

$backendPath = Join-Path (Split-Path $PSScriptRoot -Parent) "backend.hcl"
@"
bucket       = "$bucket"
key          = "$StateKey"
region       = "$Region"
use_lockfile = true
encrypt      = true
"@ | Out-File -FilePath $backendPath -Encoding utf8

Write-Host "backend.hcl escrito em $backendPath" -ForegroundColor Green
Write-Host ""
Write-Host "Proximo passo:  terraform init `"-backend-config=backend.hcl`"" -ForegroundColor Cyan
Write-Host "No GitHub, cadastre a variable TF_STATE_BUCKET = $bucket nos repos de infra." -ForegroundColor Cyan
