[CmdletBinding()]
param(
    [string]$Region       = "us-east-1",
    [string]$ChartVersion = "8.0.22",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"
$OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Namespace  = "newrelic"
$Release    = "newrelic-bundle"
$SecretName = "newrelic-license"
$Root       = Split-Path -Parent $PSScriptRoot
$ValuesFile = Join-Path $Root "k8s\newrelic\values.yaml"

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
    param([Parameter(Mandatory)][string]$Name, [string]$Source, [switch]$Secure)
    $cliArgs = @("ssm", "get-parameter", "--name", $Name,
                 "--query", "Parameter.Value", "--output", "text", "--region", $Region)
    if ($Secure) { $cliArgs += "--with-decryption" }
    $value = (Invoke-Probe -Exe "aws" -ProbeArgs $cliArgs) -join "`n"
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "SSM: parâmetro '$Name' ausente ou vazio.`n    Quem publica: $Source"
    }
    return $value.Trim()
}


Write-Step "Pré-requisitos"

$helm = Invoke-Probe -Exe "helm" -ProbeArgs @("version", "--short")
if (-not $helm) {
    throw @"
helm não encontrado no PATH.

    Esta máquina não tem winget/choco/scoop, então a instalação é manual — baixe o zip oficial,
    confira o SHA256 e ponha o binário no PATH:

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    `$ver = "v3.21.4"; `$zip = "helm-`$ver-windows-amd64.zip"
    Invoke-WebRequest "https://get.helm.sh/`$zip"           -OutFile "`$env:TEMP\`$zip"        -UseBasicParsing
    Invoke-WebRequest "https://get.helm.sh/`$zip.sha256sum" -OutFile "`$env:TEMP\`$zip.sha256" -UseBasicParsing
    `$exp = ((Get-Content "`$env:TEMP\`$zip.sha256" -Raw).Trim() -split '\s+')[0]
    if (`$exp -ne (Get-FileHash "`$env:TEMP\`$zip" -Algorithm SHA256).Hash.ToLower()) { throw "SHA256 não confere" }
    Expand-Archive "`$env:TEMP\`$zip" -DestinationPath "`$env:TEMP\helm-x" -Force
    New-Item -ItemType Directory -Force "`$env:LOCALAPPDATA\Programs\helm" | Out-Null
    Copy-Item "`$env:TEMP\helm-x\windows-amd64\helm.exe" "`$env:LOCALAPPDATA\Programs\helm\"
    `$env:PATH = "`$env:LOCALAPPDATA\Programs\helm;`$env:PATH"

    Invoke-WebRequest e não o curl do Git Bash: o IWR usa o repositório de certificados do Windows,
    onde a raiz do antivírus está confiada; o curl do Git traz CA bundle próprio e leva x509.
"@
}
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
          "    Rode: aws eks update-kubeconfig --name $cluster --region $Region`n" +
          "    (obrigatório a cada recriação: o endpoint muda, o ARN do contexto não — e o erro" +
          " que aparece é 'no such host', que engana.)"
}
Write-Note "contexto: $context"


if ($Uninstall) {
    Write-Step "Removendo o release"
    Invoke-Probe -Exe "helm" -ProbeArgs @("uninstall", $Release, "-n", $Namespace) | Out-Null
    Invoke-Probe -Exe "kubectl" -ProbeArgs @("delete", "namespace", $Namespace, "--wait=false") | Out-Null
    Write-Host "`n  Release '$Release' e namespace '$Namespace' removidos." -ForegroundColor Green
    return
}


Write-Step "Namespace e license key (do SSM)"

$licenseKey = Get-SsmValue "/fase4/newrelic/license-key" -Secure `
    -Source "bootstrap manual do dono; nenhum Terraform cria este parâmetro"

$nsYaml = & kubectl create namespace $Namespace --dry-run=client -o yaml
$nsYaml | & kubectl apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao criar/atualizar o namespace '$Namespace'" }

# Por stdin: --set aparece na process list, e um values com segredo seria outra copia da chave em disco.
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($licenseKey))
$secretYaml = @(
    "apiVersion: v1",
    "kind: Secret",
    "metadata:",
    "  name: $SecretName",
    "  namespace: $Namespace",
    "type: Opaque",
    "data:",
    "  licenseKey: $b64"
) -join "`n"
$secretYaml | & kubectl apply -f - | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Falha ao aplicar o Secret '$SecretName'" }
Write-Note "namespace/$Namespace e secret/$SecretName (1 chave)"


Write-Step "Instalando o chart nri-bundle $ChartVersion"

Invoke-Checked -Exe "helm" -CArgs @("repo", "add", "newrelic", "https://helm-charts.newrelic.com",
                                    "--force-update") | Out-Null
Invoke-Checked -Exe "helm" -CArgs @("repo", "update", "newrelic") | Out-Null

Invoke-Checked -Exe "helm" -CArgs @(
    "upgrade", "--install", $Release, "newrelic/nri-bundle",
    "--version", $ChartVersion,
    "-n", $Namespace,
    "-f", $ValuesFile,
    "--set", "global.cluster=$cluster",
    "--wait", "--timeout", "10m"
)


Write-Step "Componentes"
Invoke-Checked -Exe "kubectl" -CArgs @("-n", $Namespace, "get", "daemonset,deployment,pods", "-o", "wide")

$logging = Invoke-Probe -Exe "kubectl" -ProbeArgs @(
    "-n", $Namespace, "get", "daemonset", "-o", "jsonpath={.items[*].metadata.name}")
if ($logging -match "logging|fluent") {
    Write-Alert "há um DaemonSet de logging no namespace: '$logging'."
    Write-Alert "os logs da aplicação vão chegar DUPLICADOS ao New Relic. Confira o values.yaml."
} else {
    Write-Note "nenhum DaemonSet de logging — sem duplicação de log da aplicação"
}


Write-Step "Memória por nó (requests — é o que o agendador enxerga)"

function ConvertTo-Mi {
    param([string]$v)
    if (-not $v) { return 0.0 }
    switch -regex ($v) {
        '^(\d+(\.\d+)?)Mi$' { return [double]$matches[1] }
        '^(\d+(\.\d+)?)Gi$' { return [double]$matches[1] * 1024 }
        '^(\d+(\.\d+)?)Ki$' { return [double]$matches[1] / 1024 }
        # M e G do Kubernetes sao decimais; o 1MB do PowerShell e binario.
        '^(\d+(\.\d+)?)M$'  { return [double]$matches[1] * 1000000 / 1048576 }
        '^(\d+(\.\d+)?)G$'  { return [double]$matches[1] * 1000000000 / 1048576 }
        '^(\d+)$'           { return [double]$matches[1] / 1048576 }
        default             { return 0.0 }
    }
}

$nodes = (Invoke-Checked -Exe "kubectl" -CArgs @("get", "nodes", "-o", "jsonpath={.items[*].metadata.name}")) -split '\s+'
$totalFree = 0.0

foreach ($node in ($nodes | Where-Object { $_ })) {
    $allocMi = ConvertTo-Mi (Invoke-Checked -Exe "kubectl" -CArgs @(
        "get", "node", $node, "-o", "jsonpath={.status.allocatable.memory}"))

    $spec = Invoke-Checked -Exe "kubectl" -CArgs @(
        "get", "pods", "--all-namespaces", "--field-selector", "spec.nodeName=$node,status.phase=Running",
        "-o", "jsonpath={range .items[*]}{.metadata.namespace}{'|'}{range .spec.containers[*]}{.resources.requests.memory}{','}{end}{'\n'}{end}")

    $requestedMi = 0.0; $pods = 0; $nrMi = 0.0
    foreach ($line in ($spec -split "`n" | Where-Object { $_ -match '\|' })) {
        $ns, $rest = $line -split '\|', 2
        $podMi = 0.0
        foreach ($m in ($rest -split ',' | Where-Object { $_ })) { $podMi += ConvertTo-Mi $m }
        $requestedMi += $podMi
        $pods++
        if ($ns -eq $Namespace) { $nrMi += $podMi }
    }

    $freeMi = $allocMi - $requestedMi
    $totalFree += $freeMi

    Write-Host ("`n  {0}" -f $node)
    Write-Note ("allocatable ............... {0,7:N0} Mi" -f $allocMi)
    Write-Note ("requests ({1,2} pods) ....... {0,7:N0} Mi   (dos quais New Relic: {2:N0} Mi)" -f $requestedMi, $pods, $nrMi)
    Write-Note ("livre para os servicos .... {0,7:N0} Mi" -f $freeMi)
}

Write-Host ""
Write-Host ("  Livre no cluster para os servicos: {0:N0} Mi (some os requests de cada replica para conferir o teto do HPA)." -f $totalFree) -ForegroundColor Yellow

Write-Host "`n  Verificacao no painel do New Relic:" -ForegroundColor Green
Write-Host @"

    FROM K8sNodeSample       SELECT uniqueCount(nodeName) WHERE clusterName = '$cluster' SINCE 10 minutes ago
    FROM K8sPodSample        SELECT count(*) WHERE clusterName = '$cluster' FACET namespaceName SINCE 10 minutes ago
    FROM InfrastructureEvent SELECT count(*) WHERE category = 'kubernetes' SINCE 30 minutes ago

  E o que NAO pode acontecer (log duplicado) — so 'logs.APM' pode aparecer:

    FROM Log SELECT count(*) FACET newrelic.source SINCE 30 minutes ago
"@
