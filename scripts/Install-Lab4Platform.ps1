#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Запустите этот сценарий в Windows PowerShell 7.' }
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolDir = Join-Path $repoRoot '.tools/lab4'
$reportDir = Join-Path $repoRoot 'reports/lab4'
$env:PATH = $toolDir + [IO.Path]::PathSeparator + $env:PATH
$kubectl = Join-Path $toolDir 'kubectl.exe'
$helm = Join-Path $toolDir 'helm.exe'
$context = 'kind-cicd-lab4'
$valuesFile = Join-Path $repoRoot 'k8s/monitoring-values.yaml'
foreach ($file in @($kubectl, $helm, $valuesFile)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Не найден $file. Проверьте комплект и Install-Lab4Tools.ps1." }
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    $output = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Команда $Executable $($Arguments -join ' ') завершилась с кодом $LASTEXITCODE." }
    $output
}
function Invoke-Kubectl([string[]]$Arguments) {
    Invoke-Checked $kubectl (@('--context', $context) + $Arguments)
}
$marker = Invoke-Kubectl @('get', 'configmap', 'local-registry-hosting', '-n', 'kube-public', '-o', 'json') |
    Out-String | ConvertFrom-Json -AsHashtable
if (-not $marker['metadata']['labels'] -or $marker['metadata']['labels']['app.kubernetes.io/part-of'] -ne 'cicd-lab4') {
    throw 'Контекст не подтверждён как стенд ЛР4. Сначала запустите New-Lab4Cluster.ps1.'
}
Invoke-Kubectl @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s')
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null

Write-Host 'Установка Prometheus Operator и Prometheus (chart 92.10.1) ...'
Invoke-Checked $helm @('repo', 'add', 'prometheus-community',
    'https://prometheus-community.github.io/helm-charts', '--force-update')
Invoke-Checked $helm @('repo', 'update', 'prometheus-community')
Invoke-Checked $helm @('upgrade', '--install', 'monitoring', 'prometheus-community/kube-prometheus-stack',
    '--kube-context', $context, '--namespace', 'monitoring', '--create-namespace',
    '--version', '92.10.1', '--values', $valuesFile, '--wait', '--timeout', '15m', '--history-max', '5')
Invoke-Kubectl @('wait', '--for=condition=Established', 'crd/podmonitors.monitoring.coreos.com', '--timeout=120s')

Write-Host 'Установка Argo Rollouts v1.10.1 ...'
$namespace = Invoke-Kubectl @('get', 'namespace', 'argo-rollouts', '--ignore-not-found', '-o', 'name')
if (-not $namespace) { Invoke-Kubectl @('create', 'namespace', 'argo-rollouts') }
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('lab4-platform-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tempDir | Out-Null
try {
    $installFile = Join-Path $tempDir 'argo-rollouts-v1.10.1-install.yaml'
    Invoke-WebRequest -Uri 'https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1/install.yaml' `
        -OutFile $installFile -TimeoutSec 180
    $expected = '149148429a6f8258b789003ffb9bc6698a526d611ecb1b185624217cf51bae7f'
    if ((Get-FileHash -LiteralPath $installFile -Algorithm SHA256).Hash -ne $expected) {
        throw 'SHA256 install.yaml Argo Rollouts не совпал с release v1.10.1. Применение остановлено.'
    }

    Invoke-Kubectl @('apply', '--server-side', '-n', 'argo-rollouts', '-f', $installFile)
    Invoke-Kubectl @('wait', '--for=condition=Established', 'crd/rollouts.argoproj.io',
        'crd/analysistemplates.argoproj.io', 'crd/analysisruns.argoproj.io', '--timeout=120s')
    Invoke-Kubectl @('rollout', 'status', 'deployment/argo-rollouts', '-n', 'argo-rollouts', '--timeout=300s')
    $platformReport = @(
        'Checked at: ' + [DateTime]::UtcNow.ToString('O')
        'Context: ' + $context
        (Invoke-Checked $helm @('list', '--kube-context', $context, '-n', 'monitoring', '-o', 'yaml'))
        (Invoke-Kubectl @('get', 'deployment', 'argo-rollouts', '-n', 'argo-rollouts', '-o', 'wide'))
        (Invoke-Kubectl @('get', 'pods', '-n', 'monitoring', '-o', 'wide'))
        (Invoke-Kubectl @('get', 'services', '-n', 'monitoring'))
    )
    $platformReport | Set-Content -LiteralPath (Join-Path $reportDir 'platform-versions.txt') -Encoding utf8
    $platformReport | Write-Output
    Write-Host 'Платформа установлена. Далее применяйте ресурсы проекта по руководству ЛР4.'
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
