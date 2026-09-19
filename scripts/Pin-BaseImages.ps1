[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path -Parent $PSScriptRoot
$dockerfile = Join-Path $root 'Dockerfile'
$baselineFile = Join-Path $root 'Dockerfile.singlestage'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$mainText = [IO.File]::ReadAllText($dockerfile)
$baselineText = [IO.File]::ReadAllText($baselineFile)
$resolved = @{}

foreach ($variable in @('PYTHON_BUILD_IMAGE', 'PYTHON_RUNTIME_IMAGE')) {
    $pattern = '(?m)^ARG ' + [regex]::Escape($variable) + '=([^\r\n]+)'
    $match = [regex]::Match($mainText, $pattern)
    if (-not $match.Success) { throw "Missing ARG $variable in Dockerfile." }
    $tag = ($match.Groups[1].Value -split '@', 2)[0]
    Write-Host "Pulling $tag for linux/amd64..."
    & docker pull --platform linux/amd64 $tag
    if ($LASTEXITCODE -ne 0) { throw "docker pull failed: $tag" }
    $json = & docker image inspect --format '{{json .RepoDigests}}' $tag
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect $tag" }
    $digests = @($json | ConvertFrom-Json)
    $candidate = $digests | Where-Object {
        $_ -match '(^|/)python@sha256:[0-9a-f]{64}$'
    } | Select-Object -First 1
    if (-not $candidate) { throw "No Python registry digest found for $tag" }
    $digest = ($candidate -split '@', 2)[1]
    $resolved[$variable] = "$tag@$digest"
}


foreach ($variable in @('PYTHON_BUILD_IMAGE', 'PYTHON_RUNTIME_IMAGE')) {
    $pattern = '(?m)^ARG ' + [regex]::Escape($variable) + '=[^\r\n]+'
    $mainText = [regex]::Replace($mainText, $pattern, "ARG $variable=$($resolved[$variable])")
}
$baselineText = [regex]::Replace(
    $baselineText,
    '(?m)^ARG PYTHON_BUILD_IMAGE=[^\r\n]+',
    "ARG PYTHON_BUILD_IMAGE=$($resolved['PYTHON_BUILD_IMAGE'])"
)
[IO.File]::WriteAllText($dockerfile, $mainText.Replace("`r`n", "`n"), $utf8)
[IO.File]::WriteAllText($baselineFile, $baselineText.Replace("`r`n", "`n"), $utf8)
Write-Host 'Pinned both stages and the comparison base. Review git diff before committing.'
