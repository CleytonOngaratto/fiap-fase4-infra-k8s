[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string[]]$CandidateRoles = @("LabEksClusterRole", "LabRole")
)

$ErrorActionPreference = "Continue"
$script:Failed = $false

function Write-Head($text) { Write-Host "`n=== $text ===" -ForegroundColor Cyan }
function Write-Ok($text) { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Write-Warn2($text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Write-Fail($text) { Write-Host "  [FAIL] $text" -ForegroundColor Red; $script:Failed = $true }

Write-Head "1. Sessao AWS"
$identity = aws sts get-caller-identity --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $null -eq $identity) {
    Write-Fail "Sem credenciais validas. A sessao do Learner Lab dura ~4h: abra o lab, copie o bloco 'AWS Details' para ~/.aws/credentials e rode de novo."
    exit 1
}
Write-Ok "Conta $($identity.Account) · $($identity.Arn)"

Write-Head "2. Roles do cluster e dos nos (descoberta)"

$roleNames = @()
# Path=='/' exclui os service-linked roles do EKS, que sobrevivem ao destroy e seriam escolhidos por engano.
$listed = aws iam list-roles --query "Roles[?Path=='/'].RoleName" --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $listed) {
    $roleNames = @($listed | Where-Object { $_ -match "LabEksClusterRole" -or $_ -eq "LabRole" })
    Write-Ok "list-roles permitido — $($roleNames.Count) role(s) candidato(s)"
}
else {
    Write-Warn2 "iam:ListRoles negado — caindo para sondagem nome a nome"
    foreach ($candidate in $CandidateRoles) {
        $null = aws iam get-role --role-name $candidate --output json
        if ($LASTEXITCODE -eq 0) { $roleNames += $candidate }
    }
}

if ($roleNames.Count -eq 0) {
    Write-Fail "Nenhum role de EKS encontrado. Sem isso o cluster nao sobe (e nao podemos criar roles)."
    exit 1
}

$clusterRole = $null
$labRole = $null

foreach ($name in $roleNames) {
    $doc = aws iam get-role --role-name $name --query "Role.AssumeRolePolicyDocument" --output json
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "$name — sem permissao de leitura"; continue }

    $policies = aws iam list-attached-role-policies --role-name $name --query "AttachedPolicies[].PolicyName" --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { $policies = @() }

    $trustsEks = $doc -match "eks\.amazonaws\.com"
    $trustsEc2 = $doc -match "ec2\.amazonaws\.com"

    Write-Host "  - $name -> confia em eks: $trustsEks · em ec2: $trustsEc2"
    Write-Host "      policies: $($policies -join ', ')" -ForegroundColor DarkGray

    if ($name -eq "LabRole") { $labRole = @{ TrustsEc2 = $trustsEc2; Policies = $policies } }
    elseif ($trustsEks -and $null -eq $clusterRole) { $clusterRole = $name }
}

Write-Head "3. Validacao dos papeis"
if ($clusterRole) { Write-Ok "cluster_role_name = $clusterRole   <- terraform.tfvars e variable CLUSTER_ROLE_NAME" }
else { Write-Fail "Nenhuma LabEksClusterRole confia em eks.amazonaws.com — o control plane nao pode ser criado." }

if (-not $labRole) {
    Write-Fail "LabRole nao encontrada — e a role dos nos (o Terraform a le por data source)."
}
elseif (-not $labRole.TrustsEc2) {
    Write-Fail "LabRole nao confia em ec2.amazonaws.com — o NODE GROUP nao pode ser criado (o cluster subiria e falharia 10 min depois)."
}
else {
    Write-Ok "LabRole confia em ec2.amazonaws.com (role dos nos)"
    foreach ($needed in @("AmazonEKSWorkerNodePolicy", "AmazonEC2ContainerRegistryReadOnly")) {
        if ($labRole.Policies -contains $needed) { Write-Ok "  $needed" }
        else { Write-Fail "  $needed AUSENTE na LabRole — os nos nao entram no cluster ou nao baixam imagem do ECR." }
    }
    if ($labRole.Policies -notcontains "AmazonEKS_CNI_Policy") {
        Write-Host "  [INFO] AmazonEKS_CNI_Policy nao anexada: no lab, as acoes do VPC CNI vem das VocLabPolicy." -ForegroundColor DarkGray
    }
}

Write-Head "4. SSM Parameter Store (contrato F8)"

$null = aws ssm put-parameter --name "/fase4/preflight" --value "ok" --type String --overwrite --region $Region
if ($LASTEXITCODE -eq 0) {
    $null = aws ssm get-parameter --name "/fase4/preflight" --region $Region
    if ($LASTEXITCODE -eq 0) { Write-Ok "put/get funcionam — contrato F8 viavel" } else { Write-Fail "PutParameter passou mas GetParameter falhou." }
    $null = aws ssm delete-parameter --name "/fase4/preflight" --region $Region
}
else {
    Write-Fail "ssm:PutParameter negado. O contrato F8 (integracao dos 5 repos) precisa ser redesenhado ANTES do apply."
}

Write-Head "5. Limites da conta (informativo)"

$vcpu = aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query "Quota.Value" --output text --region $Region
if ($LASTEXITCODE -eq 0) { Write-Ok "Cota de vCPU on-demand: $vcpu (o lab documenta teto de 32)" }
else { Write-Warn2 "service-quotas indisponivel — assuma o teto documentado: 9 instancias / 32 vCPU" }

$eips = aws ec2 describe-addresses --query "length(Addresses)" --output text --region $Region
if ($LASTEXITCODE -eq 0) { Write-Ok "EIPs alocados: $eips (o NAT precisa de 1; limite padrao 5)" }

Write-Host ""
Write-Host "  LEMBRETE: 20+ instancias EC2 simultaneas DESATIVAM a conta do lab e apagam tudo." -ForegroundColor Yellow
Write-Host "  node_max_size esta em 3 por isso. Nao suba sem contar o que ja existe na conta." -ForegroundColor Yellow

Write-Host ""
if ($script:Failed) {
    Write-Host "PREFLIGHT REPROVADO — resolva os [FAIL] acima antes do apply." -ForegroundColor Red
    exit 1
}
Write-Host "PREFLIGHT OK — pode seguir para terraform init/plan/apply." -ForegroundColor Green
