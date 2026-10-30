#requires -Version 7.0
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if (-not $IsWindows) { throw 'Этот установщик предназначен для Windows и PowerShell 7.' }
if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64') {
    throw 'Этот набор содержит Windows AMD64. Для ARM64 нужны другие бинарные файлы.'
}
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolDir = Join-Path $repoRoot '.tools/lab4'
$reportDir = Join-Path $repoRoot 'reports/lab4'
$tempDir = Join-Path ([IO.Path]::GetTempPath()) ('lab4-tools-' + [guid]::NewGuid())
New-Item -ItemType Directory -Force -Path $toolDir, $reportDir, $tempDir | Out-Null
$env:PATH = $toolDir + [IO.Path]::PathSeparator + $env:PATH

function Invoke-Checked([string]$Executable, [string[]]$Arguments) {
    $output = & $Executable @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Команда $Executable завершилась с кодом $LASTEXITCODE." }
    $output
}
function Receive-Verified([string]$Url, [string]$ChecksumUrl, [string]$Asset,
                          [string]$Destination, [string]$PublishedHash = '') {
    $download = Join-Path $tempDir $Asset
    $checksumFile = Join-Path $tempDir ($Asset + '.checksums.txt')
    Write-Host "Загрузка $Asset ..."
    Invoke-WebRequest -Uri $Url -OutFile $download -TimeoutSec 300
    Invoke-WebRequest -Uri $ChecksumUrl -OutFile $checksumFile -TimeoutSec 60
    $checksumText = Get-Content -LiteralPath $checksumFile -Raw
    $pattern = '(?im)^([0-9a-f]{64})\s+\*?(?:\./)?' + [regex]::Escape($Asset) + '\s*$'
    $match = [regex]::Match($checksumText, $pattern)
    if (-not $match.Success) {
        $match = [regex]::Match($checksumText, '(?i)\A\s*([0-9a-f]{64})\s*\z')
    }
    if (-not $match.Success) { throw "В checksum-файле не найден SHA256 для $Asset." }
    $expected = $match.Groups[1].Value
    if ($PublishedHash -and $expected -ne $PublishedHash) {
        throw "Опубликованный SHA256 для $Asset изменился. Установка остановлена." 
    }
    if ((Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash -ne $expected) {
        throw "SHA256 не совпал для $Asset. Файл не будет установлен или запущен."
    }
    Copy-Item -LiteralPath $download -Destination $Destination -Force
    Add-Content -LiteralPath (Join-Path $reportDir 'download-checksums.txt') -Encoding utf8 `
        -Value "$expected  $Asset"
}

try {
    Set-Content -LiteralPath (Join-Path $reportDir 'download-checksums.txt') -Encoding utf8 `
        -Value ('Verified at: ' + [DateTime]::UtcNow.ToString('O'))
    $kindRelease = 'https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0'
    Receive-Verified -Url "$kindRelease/kind-windows-amd64" `
        -ChecksumUrl "$kindRelease/kind-windows-amd64.sha256sum" `
        -Asset 'kind-windows-amd64' -Destination (Join-Path $toolDir 'kind.exe')
    $kubectlRelease = 'https://dl.k8s.io/release/v1.37.0/bin/windows/amd64'
    Receive-Verified -Url "$kubectlRelease/kubectl.exe" `
        -ChecksumUrl "$kubectlRelease/kubectl.exe.sha256" `
        -Asset 'kubectl.exe' -Destination (Join-Path $toolDir 'kubectl.exe')
    $helmAsset = 'helm-v3.22.1-windows-amd64.zip'
    $helmZip = Join-Path $tempDir 'helm-verified.zip'
    Receive-Verified -Url "https://get.helm.sh/$helmAsset" `
        -ChecksumUrl "https://get.helm.sh/$helmAsset.sha256sum" `
        -Asset $helmAsset -Destination $helmZip `
        -PublishedHash '32ce9f4509b81782c9740898c43946e1f97c4d93ec5d10222c9b6eeec21ea043'
    Expand-Archive -LiteralPath $helmZip -DestinationPath (Join-Path $tempDir 'helm')
    Copy-Item -LiteralPath (Join-Path $tempDir 'helm/windows-amd64/helm.exe') `
        -Destination (Join-Path $toolDir 'helm.exe') -Force
    $argoRelease = 'https://github.com/argoproj/argo-rollouts/releases/download/v1.10.1'
    Receive-Verified -Url "$argoRelease/kubectl-argo-rollouts-windows-amd64" `
        -ChecksumUrl "$argoRelease/argo-rollouts-checksums.txt" `
        -Asset 'kubectl-argo-rollouts-windows-amd64' `
        -Destination (Join-Path $toolDir 'kubectl-argo-rollouts.exe') `
        -PublishedHash 'ad8da0c9f1e9a67292c0019a906ef7e54157d598df90fa0b59839bc039a624b7'
    $versions = @(
        'Checked at: ' + [DateTime]::UtcNow.ToString('O')
        'PowerShell: ' + $PSVersionTable.PSVersion
        'Tool directory: ' + $toolDir
        (Invoke-Checked (Join-Path $toolDir 'kind.exe') @('version'))
        (Invoke-Checked (Join-Path $toolDir 'kubectl.exe') @('version', '--client', '--output=yaml'))
        (Invoke-Checked (Join-Path $toolDir 'helm.exe') @('version', '--short'))
        (Invoke-Checked (Join-Path $toolDir 'kubectl-argo-rollouts.exe') @('version', '--short'))
    )
    $versions | Set-Content -LiteralPath (Join-Path $reportDir 'tool-versions.txt') -Encoding utf8
    $versions | Write-Output
    Write-Host 'Инструменты проверены. .tools/lab4 стоит первым в PATH этого окна PowerShell.'
    Write-Host 'Следующий шаг: .\scripts\lab4\New-Lab4Cluster.ps1'
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
