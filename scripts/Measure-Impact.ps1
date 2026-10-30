#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LogPath,
    [Parameter(Mandatory)][DateTimeOffset]$FromUtc,
    [Parameter(Mandatory)][DateTimeOffset]$ToUtc,
    [string]$CanaryVersion = 'broken'
)
$ErrorActionPreference = 'Stop'
if ($ToUtc -le $FromUtc) { throw 'ToUtc must be later than FromUtc.' }
$items = @(
    Get-Content -LiteralPath $LogPath | Where-Object { $_.Trim() } |
        ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object {
            $time = [DateTimeOffset]$_.time
            $time -ge $FromUtc -and $time -lt $ToUtc
        }
)
if ($items.Count -eq 0) { throw 'No load-generator records in the chosen time interval.' }
$canary = @($items | Where-Object version -EQ $CanaryVersion)
$errors = @($items | Where-Object { $_.status -ge 500 -and $_.status -lt 600 })
$transport = @($items | Where-Object status -EQ 0)
$duration = ($ToUtc - $FromUtc).TotalSeconds
[pscustomobject]@{
    from_utc = $FromUtc.ToUniversalTime().ToString('o')
    to_utc = $ToUtc.ToUniversalTime().ToString('o')
    duration_seconds = [Math]::Round($duration, 3)
    total_attempts = $items.Count
    attempts_per_second = [Math]::Round($items.Count / $duration, 3)
    canary_responses = $canary.Count
    canary_fraction = [Math]::Round($canary.Count / $items.Count, 4)
    http_5xx_responses = $errors.Count
    http_5xx_fraction_of_attempts = [Math]::Round($errors.Count / $items.Count, 4)
    transport_errors = $transport.Count
    unique_users = 'Not measured; one synthetic load generator was used.'
} | ConvertTo-Json
