[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = '0.72.0'
$expectedHash = 'ed3cf122060f61818fe1f735fd97557954e16e10bc8b058af9852271cf2e91b3'
$root = Split-Path -Parent $PSScriptRoot
$destination = Join-Path $root ".tools\trivy\$version"
$zip = Join-Path ([IO.Path]::GetTempPath()) ("trivy-" + [guid]::NewGuid() + '.zip')
$uri = "https://github.com/aquasecurity/trivy/releases/download/v$version/trivy_${version}_windows-64bit.zip"

if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'This installer requires 64-bit Windows.'
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $zip
    $actualHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        throw "SHA256 mismatch. Expected $expectedHash; got $actualHash. File not executed."
    }
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $destination -Force
    $exe = Join-Path $destination 'trivy.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        throw 'trivy.exe was not found in the verified archive.'
    }
    & $exe --version
    if ($LASTEXITCODE -ne 0) { throw 'The installed Trivy binary did not run.' }
    Write-Host "Installed: $exe"
    Write-Host 'For this PowerShell session, add the directory above to $env:PATH.'
} finally {
    if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
}
