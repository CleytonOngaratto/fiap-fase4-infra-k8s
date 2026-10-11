[CmdletBinding()]
param(
    [string]$Region              = "us-east-1",
    [string]$ChartVersion        = "3.5.0",
    [int]$MaxClockSkewSeconds    = 30,
    [switch]$SkipClockCheck,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Namespace  = "kube-system"
$Release    = "aws-load-balancer-controller"
$Selector   = "app.kubernetes.io/name=aws-load-balancer-controller"
$Root       = Split-Path -Parent $PSScriptRoot
$ValuesFile = Join-Path $Root "k8s\aws-load-balancer-controller\values.yaml"

function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Note { param([string]$Message) Write-Host "    $Message" -ForegroundColor DarkGray }
function Write-Alert { param([string]$Message) Write-Host "    [aviso] $Message" -ForegroundColor Yellow }

# PS 5.1: stderr de executavel nativo vira NativeCommandError; o 'Continue' local evita derrubar a sondagem.
function Invoke-Probe {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$ProbeArgs)
    $ErrorActionPreference = "Continue"
    $out = & $Exe @ProbeArgs 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return $out
}

function Invoke-Checked {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$CArgs)
    $out = & $Exe @CArgs
    if ($LASTEXITCODE -ne 0) { throw "$Exe $($CArgs -join ' ') falhou (exit $LASTEXITCODE)" }
    return $out
}

function Get-SsmValue {
    param([Parameter(Mandatory)][string]$Name, [string]$Source)
    $cliArgs = @("ssm", "get-parameter", "--name", $Name,
                 "--query", "Parameter.Value", "--output", "text", "--region", $Region)
    $value = (Invoke-Probe -Exe "aws" -ProbeArgs $cliArgs) -join "`n"
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "SSM: parâmetro '$Name' ausente ou vazio.`n    Quem publica: $Source"
    }
    return $value.Trim()
}

function Get-AwsClockSkewSeconds {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $request = [System.Net.WebRequest]::Create("https://sts.$Region.amazonaws.com/")
    $request.Method = "HEAD"
    $request.Timeout = 10000
    try { $response = $request.GetResponse() }
    catch [System.Net.WebException] { $response = $_.Exception.Response }
    if (-not $response) { return $null }
    try {
        $awsNow = [DateTimeOffset]::ParseExact($response.Headers["Date"], "r", [Globalization.CultureInfo]::InvariantCulture)
    }
    finally { $response.Close() }
    return [int][math]::Round(([DateTimeOffset]::UtcNow - $awsNow).TotalSeconds)
}


Write-Step "Pré-requisitos"

$helm = Invoke-Probe -Exe "helm" -ProbeArgs @("version", "--short")
if (-not $helm) { throw "helm não encontrado no PATH (versão em uso no projeto: v3.21.4, em %LOCALAPPDATA%\Programs\helm)." }
Write-Note "helm: $helm"

if (-not (Test-Path $ValuesFile)) { throw "values não encontrado: $ValuesFile" }

$who = Invoke-Probe -Exe "aws" -ProbeArgs @("sts", "get-caller-identity", "--query", "Arn", "--output", "text")
if (-not $who) {
    throw "Credenciais da AWS inválidas ou expiradas (a sessão do Learner Lab dura ~4h).`n" +
          "    Recole o 'AWS Details' do painel em ~/.aws/credentials."
}
Write-Note "identidade: $who"

$cluster = Get-SsmValue "/fase4/eks/cluster-name" -Source "terraform apply deste repositório"

$context = Invoke-Probe -Exe "kubectl" -ProbeArgs @("config", "current-context")
if ([string]::IsNullOrWhiteSpace($context) -or $context -notlike "*$cluster*") {
    throw "O contexto do kubectl ('$context') não é o cluster do contrato ('$cluster').`n" +
          "    Rode: aws eks update-kubeconfig --name $cluster --region $Region"
}
Write-Note "contexto: $context"


if ($Uninstall) {
    Write-Step "Removendo o release"
    $bindings = Invoke-Probe -Exe "kubectl" -ProbeArgs @("get", "targetgroupbindings.elbv2.k8s.aws", "-A", "--no-headers")
    if ($bindings) {
        throw "Ainda há TargetGroupBindings no cluster. Apague-os antes, com o controller vivo:`n" +
              "    é ele que remove as regras de security group que criou para cada um."
    }
    Invoke-Checked -Exe "helm" -CArgs @("uninstall", $Release, "-n", $Namespace, "--wait") | Out-Null
    Write-Host "`n  Release '$Release' removido." -ForegroundColor Green
    return
}


Write-Step "Relógio local × AWS (o certificado do webhook nasce com a hora local)"

if ($SkipClockCheck) {
    Write-Alert "checagem do relógio pulada a pedido (-SkipClockCheck)."
}
else {
    $skew = Get-AwsClockSkewSeconds
    if ($null -eq $skew) {
        throw "Não consegui ler a hora da AWS (cabeçalho Date do STS).`n" +
              "    Rode w32tm /resync num PowerShell de administrador e repita com -SkipClockCheck."
    }
    if ([math]::Abs($skew) -gt $MaxClockSkewSeconds) {
        throw "O relógio local está $skew s fora da hora da AWS (limite: $MaxClockSkewSeconds s).`n" +
              "    O certificado do webhook nasceria fora da validade e o API server o recusaria (x509).`n" +
              "    Rode w32tm /resync num PowerShell de administrador e repita."
    }
    Write-Note "diferença: $skew s (limite: $MaxClockSkewSeconds s)"
}


Write-Step "Instalando o chart aws-load-balancer-controller $ChartVersion"

$vpcId = Get-SsmValue "/fase4/vpc/id" -Source "terraform apply deste repositório"

Invoke-Checked -Exe "helm" -CArgs @("repo", "add", "eks", "https://aws.github.io/eks-charts",
                                    "--force-update") | Out-Null
Invoke-Checked -Exe "helm" -CArgs @("repo", "update", "eks") | Out-Null

Invoke-Checked -Exe "helm" -CArgs @(
    "upgrade", "--install", $Release, "eks/aws-load-balancer-controller",
    "--version", $ChartVersion,
    "-n", $Namespace,
    "-f", $ValuesFile,
    "--set", "clusterName=$cluster",
    "--set", "region=$Region",
    "--set", "vpcId=$vpcId",
    "--wait", "--timeout", "5m"
)


Write-Step "Rollout e permissões"

Invoke-Checked -Exe "kubectl" -CArgs @("-n", $Namespace, "rollout", "status", "deployment/$Release", "--timeout=180s") | Out-Null
Invoke-Checked -Exe "kubectl" -CArgs @("-n", $Namespace, "get", "deployment,pods", "-l", $Selector, "-o", "wide")

$logs = Invoke-Probe -Exe "kubectl" -ProbeArgs @("-n", $Namespace, "logs", "-l", $Selector, "--tail=-1", "--prefix")
$denied = @($logs | Select-String -Pattern "AccessDenied|UnauthorizedOperation|not authorized|explicit deny")
if ($denied.Count -gt 0) {
    $denied | Select-Object -First 5 | ForEach-Object { Write-Alert $_.Line }
    throw "O controller registrou $($denied.Count) erro(s) de permissão da AWS."
}
Write-Note "nenhum erro de permissão da AWS no log dos pods do controller"

Write-Host "`n  Controller pronto, só para TargetGroupBinding (sem Ingress, sem webhook de Service)." -ForegroundColor Green
