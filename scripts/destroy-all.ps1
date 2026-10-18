[CmdletBinding()]
param(
    [string]$Region = "us-east-1",
    [switch]$Force,
    [switch]$SkipAudit,
    [switch]$AuditOnly
)

# 'Continue', nao 'Stop': no PS 5.1 o stderr de executavel nativo vira NativeCommandError.
$ErrorActionPreference = "Continue"
$script:Failed = $false

$PersistentApiName = "fiap-fase4-api"

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
        "Target groups"       = @("elbv2", "describe-target-groups", "--query", "TargetGroups[].TargetGroupName")
        "VPCs nao-default"    = @("ec2", "describe-vpcs", "--filters", "Name=isDefault,Values=false", "--query", "Vpcs[].VpcId")
        "EIPs"                = @("ec2", "describe-addresses", "--query", "Addresses[].PublicIp")
        "ENIs disponiveis"    = @("ec2", "describe-network-interfaces", "--filters", "Name=status,Values=available", "--query", "NetworkInterfaces[].NetworkInterfaceId")
        "EBS volumes"         = @("ec2", "describe-volumes", "--query", "Volumes[].VolumeId")
        "ECR repos"           = @("ecr", "describe-repositories", "--query", "repositories[].repositoryName")
        "API Gateways"        = @("apigatewayv2", "get-apis", "--query", "Items[?Name!='$PersistentApiName'].Name")
        "VPC Links"           = @("apigatewayv2", "get-vpc-links", "--query", "Items[].Name")
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

    Write-Head "Persistente por desenho (G18): fica de pe entre sessoes"
    $persistent = [ordered]@{
        "API Gateway"         = @("apigatewayv2", "get-apis", "--query", "Items[?Name=='$PersistentApiName'].Name")
        "Log group de acesso" = @("logs", "describe-log-groups", "--log-group-name-prefix", "/aws/apigateway/$PersistentApiName", "--query", "logGroups[].logGroupName")
    }
    foreach ($name in $persistent.Keys) {
        $value = Get-AwsValue $persistent[$name]
        if (-not $script:LastAwsOk) {
            Write-Fail "$name : CONSULTA FALHOU (credencial expirada?) - resultado NAO confiavel"
        }
        elseif ([string]::IsNullOrWhiteSpace($value) -or $value -eq "None") {
            Write-Host "  [--]   $name : nao existe (o root persistent/ do auth ainda nao foi aplicado nesta conta)" -ForegroundColor DarkGray
        }
        else {
            Write-Ok "$name : $value  (persistente por desenho, G18 - nao e sobra)"
        }
    }

    Write-Head "SSM (o que deve sobreviver)"
    $params = Get-AwsValue @("ssm", "get-parameters-by-path", "--path", "/fase4", "--recursive", "--query", "Parameters[].Name")
    if ($params) {
        ($params -split "\s+") | Where-Object { $_ } | Sort-Object | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
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

$edgeRoots = @(
    [pscustomobject]@{ Path = "fiap-fase4-auth-serverless\session"; Label = "VPC Link + integracao + rotas do API Gateway" }
)
$infraRoots = @(
    [pscustomobject]@{ Path = "fiap-fase4-os-service\terraform"; Label = "RDS + target group + regra no ALB + fila de respostas da saga" }
    [pscustomobject]@{ Path = "fiap-fase4-billing-service\terraform"; Label = "target group + regra no ALB" }
    [pscustomobject]@{ Path = "fiap-fase4-execution-service\terraform"; Label = "target group + regra no ALB + fila de comandos" }
    [pscustomobject]@{ Path = "fiap-fase4-infra-k8s"; Label = "VPC + EKS + NAT + ECR + ALB + SNS" }
)

function Invoke-TerraformDestroy {
    param([Parameter(Mandatory)]$Target)

    Write-Head "destroy: $($Target.Path)  ($($Target.Label))"
    $dir = Join-Path $root $Target.Path
    $backend = Join-Path $dir "backend.hcl"

    if (-not (Test-Path $backend)) {
        Write-Warn2 "$($Target.Path)\backend.hcl ausente — nada aplicado a partir desta maquina; pulando."
        Write-Host "         Se ha state no bucket (aplicado pelo CI), crie o backend.hcl a partir do backend.hcl.example e rode de novo; a auditoria acusa a sobra." -ForegroundColor DarkGray
        return
    }

    $bucket = ((Get-Content $backend | Select-String '^\s*bucket') -replace '.*=\s*"?([^"]+)"?.*', '$1').Trim()
    $key = ((Get-Content $backend | Select-String '^\s*key') -replace '.*=\s*"?([^"]+)"?.*', '$1').Trim()
    if ($bucket -and $key) {
        $lock = Get-AwsValue @("s3api", "head-object", "--bucket", $bucket, "--key", "$key.tflock", "--query", "LastModified")
        if ($lock) {
            Write-Fail "existe um LOCK no state ($key.tflock, de $lock) — um apply do CI esta rodando. Espere ele terminar e rode de novo."
            return
        }
    }

    Push-Location $dir
    try {
        $init = Invoke-Native -Exe "terraform" -NativeArgs @("init", "-input=false", "-reconfigure", "-lockfile=readonly", "-backend-config=backend.hcl", "-no-color")
        if ($init.ExitCode -ne 0) {
            Write-Fail "terraform init falhou em $($Target.Path)"
            $init.Lines | Where-Object { $_ -match "Error" } | Select-Object -First 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
            return
        }

        $r = Invoke-Native -Exe "terraform" -NativeArgs @("destroy", "-no-color", "-auto-approve")
        $done = $r.Lines | Where-Object { $_ -match "Destroy complete" } | Select-Object -Last 1
        if ($r.ExitCode -eq 0 -and $done) { Write-Ok $done.Trim() }
        elseif ($r.ExitCode -eq 0) { Write-Ok "nada a destruir (state vazio)" }
        else {
            Write-Fail "destroy falhou em $($Target.Path)"
            $r.Lines | Where-Object { $_ -match "^Error|Error:" } | Select-Object -First 4 | ForEach-Object { Write-Host "         $_" -ForegroundColor DarkGray }
        }
    }
    finally { Pop-Location }
}

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
    Write-Host "  Vai destruir TODA a infraestrutura de sessao da Fase 4 nesta conta, nesta ordem:" -ForegroundColor Yellow
    foreach ($t in $edgeRoots) { Write-Host "    - $($t.Path)  ($($t.Label))" -ForegroundColor Yellow }
    Write-Host "    - limpeza do cluster (TargetGroupBindings com o controller vivo, helm uninstall)" -ForegroundColor Yellow
    foreach ($t in $infraRoots) { Write-Host "    - $($t.Path)  ($($t.Label))" -ForegroundColor Yellow }
    Write-Host "  Sobrevivem: o root persistent/ do auth (API $PersistentApiName, G18), o bucket de state e o bootstrap do SSM." -ForegroundColor DarkGray
    Write-Host ""
    $answer = Read-Host "  Digite DESTRUIR para confirmar"
    if ($answer -ne "DESTRUIR") { Write-Host "  Abortado." -ForegroundColor Yellow; exit 0 }
}

Write-Head "Variaveis do Terraform"
if ($env:TF_VAR_cluster_role_name -or (Test-Path (Join-Path $root "fiap-fase4-infra-k8s\terraform.tfvars"))) {
    Write-Ok "cluster_role_name vem do ambiente ou do terraform.tfvars"
}
else {
    $env:TF_VAR_cluster_role_name = Get-AwsValue @("iam", "list-roles", "--query", "Roles[?contains(RoleName,'LabEksClusterRole')].RoleName|[0]")
    if ([string]::IsNullOrWhiteSpace($env:TF_VAR_cluster_role_name) -or $env:TF_VAR_cluster_role_name -eq "None") {
        Write-Host "  [FAIL] LabEksClusterRole nao encontrada: o destroy le os data sources e precisa do nome real. Nada foi destruido." -ForegroundColor Red
        exit 1
    }
    Write-Ok "cluster_role_name descoberto: $($env:TF_VAR_cluster_role_name)"
}

Write-Head "Cluster: contexto do kubectl"
$clusterName = Get-AwsValue @("ssm", "get-parameter", "--name", "/fase4/eks/cluster-name", "--query", "Parameter.Value")
$clusterStatus = $null
if ($clusterName) {
    $clusterStatus = Get-AwsValue @("eks", "describe-cluster", "--name", $clusterName, "--query", "cluster.status")
}

if (-not $clusterStatus) {
    Write-Ok "nenhum cluster da Fase 4 de pe — nada a limpar dentro dele"
}
else {
    $context = ""
    if (Get-Command kubectl -ErrorAction SilentlyContinue) {
        $context = (Invoke-Native -Exe "kubectl" -NativeArgs @("config", "current-context")).Text.Trim()
    }
    if ($context -notlike "*$clusterName*") {
        Write-Host "  [FAIL] o kubectl aponta para '$context', nao para o cluster '$clusterName'. Nada foi destruido." -ForegroundColor Red
        Write-Host "         Rode: aws eks update-kubeconfig --name $clusterName --region $Region  e repita." -ForegroundColor DarkGray
        exit 1
    }
    Write-Ok "contexto: $context"
}

foreach ($t in $edgeRoots) { Invoke-TerraformDestroy -Target $t }

Write-Head "Cluster: Services LoadBalancer, TargetGroupBindings e charts"
if (-not $clusterStatus) {
    Write-Ok "sem cluster — nada a limpar"
}
else {
    $kube = Invoke-Native -Exe "kubectl" -NativeArgs @("get", "svc", "-A", "--no-headers", "--request-timeout=25s")
    if ($kube.ExitCode -ne 0) {
        Write-Warn2 "kubectl nao alcancou o cluster — sem limpeza interna (a auditoria confere ELB e target groups no fim)"
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

        $crd = Invoke-Native -Exe "kubectl" -NativeArgs @("get", "crd", "targetgroupbindings.elbv2.k8s.aws", "--request-timeout=25s")
        if ($crd.ExitCode -ne 0) {
            Write-Ok "sem CRD de TargetGroupBinding (controller nao instalado)"
        }
        else {
            # Antes do helm uninstall: e o controller vivo que remove as regras de SG criadas para cada binding.
            $tgb = Invoke-Native -Exe "kubectl" -NativeArgs @("delete", "targetgroupbindings.elbv2.k8s.aws", "--all", "-A", "--timeout=180s")
            if ($tgb.ExitCode -eq 0) { Write-Ok "TargetGroupBindings removidos" }
            else { Write-Fail "nao consegui remover os TargetGroupBindings — regra de SG orfa pode travar o destroy da VPC" }
        }

        if (-not (Get-Command helm -ErrorAction SilentlyContinue)) {
            Write-Fail "helm fora do PATH — charts nao desinstalados (o destroy do cluster os leva junto)"
        }
        else {
            $charts = @(
                [pscustomobject]@{ Release = "newrelic-bundle"; Namespace = "newrelic" }
                [pscustomobject]@{ Release = "aws-load-balancer-controller"; Namespace = "kube-system" }
            )
            foreach ($chart in $charts) {
                $status = Invoke-Native -Exe "helm" -NativeArgs @("status", $chart.Release, "-n", $chart.Namespace)
                if ($status.ExitCode -ne 0) { Write-Ok "$($chart.Release): nao instalado"; continue }
                $un = Invoke-Native -Exe "helm" -NativeArgs @("uninstall", $chart.Release, "-n", $chart.Namespace, "--wait", "--timeout", "5m")
                if ($un.ExitCode -eq 0) { Write-Ok "$($chart.Release) desinstalado" }
                else { Write-Fail "helm uninstall $($chart.Release) falhou" }
            }
        }
    }
}

foreach ($t in $infraRoots) { Invoke-TerraformDestroy -Target $t }

if ($SkipAudit) {
    Write-Host "`n  -SkipAudit: a auditoria NAO rodou. Confira a conta a mao antes de dormir." -ForegroundColor Yellow
    exit ($(if ($script:Failed) { 1 } else { 0 }))
}

Invoke-AuditAndExit
