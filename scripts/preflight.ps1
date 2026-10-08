[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [string[]]$CandidateRoles = @("LabEksClusterRole", "LabEksNodeRole", "LabRole")
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

Write-Head "2. Roles de EKS (descoberta)"

$roleNames = @()
# Path=='/' exclui os service-linked roles do EKS, que sobrevivem ao destroy e seriam escolhidos por engano.
$listed = aws iam list-roles --query "Roles[?Path=='/'].RoleName" --output json | ConvertFrom-Json
if ($LASTEXITCODE -eq 0 -and $listed) {
    $roleNames = @($listed | Where-Object { $_ -match "Eks" -or $_ -eq "LabRole" })
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
$nodeRole = $null

# LabEks primeiro: a LabRole tambem confia nos dois principals e seria escolhida antes.
$roleNames = @($roleNames | Sort-Object { $_ -notmatch "LabEks" })

foreach ($name in $roleNames) {
    $doc = aws iam get-role --role-name $name --query "Role.AssumeRolePolicyDocument" --output json
    if ($LASTEXITCODE -ne 0) { Write-Warn2 "$name — sem permissao de leitura"; continue }

    $policies = aws iam list-attached-role-policies --role-name $name --query "AttachedPolicies[].PolicyName" --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { $policies = @() }

    $trustsEks = $doc -match "eks\.amazonaws\.com"
    $trustsEc2 = $doc -match "ec2\.amazonaws\.com"

    $roles = @()
    if ($trustsEks) { $roles += "CLUSTER" }
    if ($trustsEc2) { $roles += "NODE" }
    $label = if ($roles.Count -gt 0) { $roles -join "+" } else { "nenhum (nao serve para EKS)" }

    Write-Host "  - $name -> $label"
    Write-Host "      policies: $($policies -join ', ')" -ForegroundColor DarkGray

    if ($trustsEks -and $null -eq $clusterRole) { $clusterRole = $name }
    if ($trustsEc2 -and $null -eq $nodeRole) { $nodeRole = @{ Name = $name; Policies = $policies } }
}

Write-Head "3. Validacao dos papeis"
if ($clusterRole) { Write-Ok "cluster_role_name = $clusterRole   <- para o terraform.tfvars" }
else { Write-Fail "Nenhum role confia em eks.amazonaws.com — o control plane nao pode ser criado." }

if ($nodeRole) {
    Write-Ok "node_role_name = $($nodeRole.Name)   <- para o terraform.tfvars"
    foreach ($needed in @("AmazonEKSWorkerNodePolicy", "AmazonEKS_CNI_Policy")) {
        if ($nodeRole.Policies -contains $needed) { Write-Ok "  $needed" }
        else { Write-Fail "  $needed AUSENTE no role de node — os nos nao entram no cluster." }
    }
    if ($nodeRole.Policies -contains "AmazonEC2ContainerRegistryReadOnly") {
        Write-Ok "  AmazonEC2ContainerRegistryReadOnly"
    }
    else {
        Write-Warn2 "  AmazonEC2ContainerRegistryReadOnly ausente — pull do ECR privado vai falhar ao implantar a aplicacao (ImagePullBackOff)."
    }
}
else {
    Write-Fail "Nenhum role confia em ec2.amazonaws.com — o NODE GROUP nao pode ser criado (o cluster subiria e falharia 10 min depois)."
}

Write-Head "4. SSM Parameter Store (contrato F8)"

$null = aws ssm put-parameter --name "/fase4/preflight" --value "ok" --type String --overwrite --region $Region
if ($LASTEXITCODE -eq 0) {
    $null = aws ssm get-parameter --name "/fase4/preflight" --region $Region
    if ($LASTEXITCODE -eq 0) { Write-Ok "put/get funcionam — contrato F8 viavel" } else { Write-Fail "PutParameter passou mas GetParameter falhou." }
    $null = aws ssm delete-parameter --name "/fase4/preflight" --region $Region
}
else {
    Write-Fail "ssm:PutParameter negado. O contrato F8 (integracao dos 4 repos) precisa ser redesenhado ANTES do apply."
}

Write-Head "5. Limites da conta (informativo)"

$vcpu = aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query "Quota.Value" --output text --region $Region
if ($LASTEXITCODE -eq 0) { Write-Ok "Cota de vCPU on-demand: $vcpu (o lab documenta teto de 32)" }
else { Write-Warn2 "service-quotas indisponivel — assuma o teto documentado: 9 instancias / 32 vCPU" }

$eips = aws ec2 describe-addresses --query "length(Addresses)" --output text --region $Region
if ($LASTEXITCODE -eq 0) { Write-Ok "EIPs alocados: $eips (o NAT precisa de 1; limite padrao 5)" }

Write-Host ""
Write-Host "  LEMBRETE: 20+ instancias EC2 simultaneas DESATIVAM a conta do lab e apagam tudo." -ForegroundColor Yellow
Write-Host "  node_max_size esta em 4 por isso. Nao suba sem contar o que ja existe na conta." -ForegroundColor Yellow

Write-Host ""
if ($script:Failed) {
    Write-Host "PREFLIGHT REPROVADO — resolva os [FAIL] acima antes do apply." -ForegroundColor Red
    exit 1
}
Write-Host "PREFLIGHT OK — pode seguir para terraform init/plan/apply." -ForegroundColor Green
