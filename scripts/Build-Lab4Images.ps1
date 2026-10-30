#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Published')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Published')]
    [ValidatePattern('^ghcr\.io/[^\s]+@sha256:[0-9a-f]{64}$')]
    [string]$StableRef,

    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [switch]$BuildStableLocally
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$reportDir = Join-Path $repoRoot 'reports/lab4/images'
New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
$imageName = 'localhost:5001/ci-lab-flask'

function Invoke-Docker {
    param([string[]]$Arguments)
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker failed during '$($Arguments[0])'; see the preceding output."
    }
}

Push-Location $repoRoot
try {
    Invoke-RestMethod 'http://127.0.0.1:5001/v2/' -TimeoutSec 10 | Out-Null
    if ($PSCmdlet.ParameterSetName -eq 'Published') {
        Invoke-Docker @('pull', '--platform', 'linux/amd64', $StableRef)
        Invoke-Docker @('tag', $StableRef, "${imageName}:stable")
        "Stable source: $StableRef" | Set-Content (Join-Path $reportDir 'source.txt')
    } else {
        Invoke-Docker @('build', '--platform', 'linux/amd64',
            '--build-arg', 'APP_VERSION=stable', '--build-arg', 'CHAOS_MODE=false',
            '-t', "${imageName}:stable", '.')
        'Stable source: local build; this does not prove CI publication.' |
            Set-Content (Join-Path $reportDir 'source.txt')
    }


    $smoke = @'
from app import create_app
app = create_app()
client = app.test_client()
assert client.get('/health').get_json() == {'status': 'ok'}
assert client.get('/demo').status_code == 200
assert client.get('/demo').get_json()['version'] == 'stable'
assert client.get('/metrics').status_code == 200
assert b'http_requests_total' in client.get('/metrics').data
print('Stable image Lab 4 contract: PASS')
'@
    Invoke-Docker @('run', '--rm', "${imageName}:stable", 'python', '-c', $smoke)
    Invoke-Docker @('push', "${imageName}:stable")

    Invoke-Docker @('build', '--platform', 'linux/amd64',
        '--build-arg', 'APP_VERSION=v2', '--build-arg', 'CHAOS_MODE=false',
        '-t', "${imageName}:v2", '.')
    Invoke-Docker @('push', "${imageName}:v2")
    Invoke-Docker @('build', '--platform', 'linux/amd64',
        '--build-arg', 'APP_VERSION=broken', '--build-arg', 'CHAOS_MODE=true',
        '-t', "${imageName}:broken", '.')
    Invoke-Docker @('push', "${imageName}:broken")

    $inventory = & docker image inspect "${imageName}:stable" "${imageName}:v2" "${imageName}:broken"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the three published images.' }
    $inventory | Set-Content (Join-Path $reportDir 'image-inspect.json') -Encoding utf8
    $sourceCommit = & git rev-parse HEAD
    if ($LASTEXITCODE -eq 0) { $sourceCommit | Set-Content (Join-Path $reportDir 'source-commit.txt') }
    Write-Host 'Images stable, v2 and broken are available in localhost:5001.'
    Write-Host "Image identity evidence: $reportDir"
} finally {
    Pop-Location
}
