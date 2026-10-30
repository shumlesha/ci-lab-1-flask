#requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$contextName = 'kind-cicd-lab4'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolsDir = Join-Path $repoRoot '.tools/lab4'
$env:PATH = "$toolsDir;$env:PATH"

& kubectl --context $contextName apply -f (Join-Path $repoRoot 'k8s/namespace.yaml')
if ($LASTEXITCODE -ne 0) { throw 'Cannot create the staging namespace.' }

$existing = & kubectl --context $contextName -n staging get secret lab4-app --ignore-not-found -o name
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the lab4-app Secret.' }
if ($existing) {
    Write-Host 'Secret lab4-app already exists; its password was not changed.'
    return
}

$password = [Convert]::ToHexString(
    [Security.Cryptography.RandomNumberGenerator]::GetBytes(24)
).ToLowerInvariant()
$secret = @{
    apiVersion = 'v1'
    kind = 'Secret'
    metadata = @{ name = 'lab4-app'; namespace = 'staging' }
    type = 'Opaque'
    stringData = @{
        POSTGRES_PASSWORD = $password
        DATABASE_URL = "postgresql://lab4:${password}@postgres:5432/lab4"
        REDIS_URL = 'redis://redis:6379/0'
    }
}
try {
    $secret | ConvertTo-Json -Depth 8 |
        & kubectl --context $contextName create -f -
    if ($LASTEXITCODE -ne 0) { throw 'Secret creation failed.' }
} finally {
    $secret = $null
    $password = $null
}
Write-Host 'The application and PostgreSQL share Secret lab4-app.'
