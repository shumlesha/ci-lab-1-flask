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
$kind = Join-Path $toolDir 'kind.exe'
$kubectl = Join-Path $toolDir 'kubectl.exe'
$clusterName = 'cicd-lab4'
$context = 'kind-cicd-lab4'
$registryName = 'kind-registry'
foreach ($file in @($kind, $kubectl, (Join-Path $repoRoot 'k8s/kind-cluster.yaml'))) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Не найден $file. Сначала запустите Install-Lab4Tools.ps1." }
}
function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    $output = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Команда $Executable $($Arguments -join ' ') завершилась с кодом $LASTEXITCODE." }
    $output
}
function Invoke-Kubectl([string[]]$Arguments) {
    Invoke-Checked $kubectl (@('--context', $context) + $Arguments)
}
if ((Invoke-Checked 'docker' @('info', '--format', '{{.OSType}}')) -ne 'linux') {
    throw 'Docker Desktop должен быть запущен в режиме Linux containers.'
}
$registryId = Invoke-Checked 'docker' @('container', 'ls', '--all', '--filter', "name=^/$registryName$", '--format', '{{.ID}}')
if ($registryId) {
    $registry = @(Invoke-Checked 'docker' @('inspect', $registryName) | Out-String | ConvertFrom-Json -AsHashtable)[0]
    $bindings = @()
    $portBindings = $registry['HostConfig']['PortBindings']
    if ($portBindings -and $portBindings.ContainsKey('5000/tcp')) { $bindings = @($portBindings['5000/tcp']) }
    if ($bindings.Count -ne 1 -or $null -eq $bindings[0] -or
        $bindings[0]['HostIp'] -ne '127.0.0.1' -or $bindings[0]['HostPort'] -ne '5001') {
        throw 'Конфликт: kind-registry уже существует, но не использует только 127.0.0.1:5001 -> 5000/tcp. Контейнер не изменён.'
    }
    if (-not $registry['Config']['Labels'] -or $registry['Config']['Labels']['io.lab4.cluster'] -ne $clusterName) {
        throw 'Конфликт: kind-registry не помечен как созданный ЛР4. Он не изменён; сначала проверьте назначение этого контейнера.'
    }
    if ($registry['Config']['Image'] -ne 'registry:2') { throw 'Конфликт: kind-registry использует образ, отличный от registry:2.' }
}
$clusterExists = $clusterName -in @(Invoke-Checked $kind @('get', 'clusters'))
if ($clusterExists) {
    Invoke-Checked $kind @('export', 'kubeconfig', '--name', $clusterName)
    $markerJson = Invoke-Kubectl @('get', 'configmap', 'local-registry-hosting', '-n', 'kube-public', '--ignore-not-found', '-o', 'json')
    if (-not $markerJson) { throw 'Конфликт: cicd-lab4 уже существует без маркера ЛР4. Кластер не изменён и не удалён.' }
    $marker = $markerJson | Out-String | ConvertFrom-Json -AsHashtable
    if (-not $marker['metadata']['labels'] -or $marker['metadata']['labels']['app.kubernetes.io/part-of'] -ne $clusterName) {
        throw 'Конфликт: существующий cicd-lab4 не помечен как стенд ЛР4. Автоматические изменения остановлены.'
    }
}
if (-not $registryId) {
    Invoke-Checked 'docker' @('run', '-d', '--restart=always', '--name', $registryName,
        '--label', "io.lab4.cluster=$clusterName", '--network', 'bridge',
        '-p', '127.0.0.1:5001:5000', 'registry:2')
}
elseif (-not $registry['State']['Running']) {
    Invoke-Checked 'docker' @('start', $registryName)
}
if (-not $clusterExists) {
    Invoke-Checked $kind @('create', 'cluster', '--name', $clusterName,
        '--config', (Join-Path $repoRoot 'k8s/kind-cluster.yaml'), '--wait', '180s')
}
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('lab4-cluster-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $tempDir, $reportDir | Out-Null
try {
    $configMapFile = Join-Path $tempDir 'local-registry-hosting.yaml'
    @'
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
  labels:
    app.kubernetes.io/part-of: cicd-lab4
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
'@ | Set-Content -LiteralPath $configMapFile -Encoding utf8NoBOM
    Invoke-Kubectl @('apply', '-f', $configMapFile)
    $networks = Invoke-Checked 'docker' @('inspect', '--format', '{{json .NetworkSettings.Networks}}', $registryName) |
        ConvertFrom-Json -AsHashtable
    if (-not $networks.ContainsKey('kind')) {
        Invoke-Checked 'docker' @('network', 'connect', 'kind', $registryName)
    }
    $hostsFile = Join-Path $tempDir 'hosts.toml'
    '[host."http://kind-registry:5000"]' | Set-Content -LiteralPath $hostsFile -Encoding utf8NoBOM
    $registryDir = '/etc/containerd/certs.d/localhost:5001'
    $nodes = @(Invoke-Checked $kind @('get', 'nodes', '--name', $clusterName))
    if ($nodes.Count -eq 0) { throw 'kind не вернул ни одного узла cicd-lab4.' }
    foreach ($nodeName in $nodes) {
        Invoke-Checked 'docker' @('exec', $nodeName, 'mkdir', '-p', $registryDir)
        Invoke-Checked 'docker' @('cp', $hostsFile, "${nodeName}:${registryDir}/hosts.toml")
    }
    Invoke-Kubectl @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s')
    $nodeReport = Invoke-Kubectl @('get', 'nodes', '-o', 'wide')
    $nodeReport | Set-Content -LiteralPath (Join-Path $reportDir 'cluster-nodes.txt') -Encoding utf8
    $nodeReport | Write-Output
    Write-Host 'Стенд готов: context kind-cicd-lab4; image names localhost:5001/имя:тег.'
    Write-Host 'Следующий шаг: .\scripts\lab4\Install-Lab4Platform.ps1'
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
