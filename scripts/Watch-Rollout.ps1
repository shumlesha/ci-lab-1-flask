#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Name = 'ci-lab-flask',
    [string]$Namespace = 'staging',
    [string]$Context = 'kind-cicd-lab4',
    [ValidateRange(10, 3600)][int]$TimeoutSeconds = 600,
    [ValidateRange(1, 30)][int]$PollSeconds = 2,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$RunName = ('rollout-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$reportDir = Join-Path $repoRoot "reports/lab4/$RunName"
if (Test-Path -LiteralPath $reportDir) { throw 'Evidence directory already exists. Choose a new -RunName.' }
$null = New-Item -ItemType Directory -Path $reportDir -Force
$logPath = Join-Path $reportDir 'observer.log'
function Write-Log([string]$Message) {
    $line = "{0} {1}" -f [DateTimeOffset]::UtcNow.ToString('o'), $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    Write-Host $line
}
function Read-Kube([string[]]$Arguments) {
    $raw = & kubectl --context $Context -n $Namespace --request-timeout=10s @Arguments -o json 2>> (Join-Path $reportDir 'kubectl-stderr.log')
    if ($LASTEXITCODE -ne 0) { throw "kubectl failed (exit $LASTEXITCODE); see kubectl-stderr.log." }
    return ($raw -join "`n" | ConvertFrom-Json -Depth 100)
}
function Save-Json([string]$FileName, $Value) {
    $Value | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $reportDir $FileName) -Encoding utf8
}
function Send-Notice([string]$Message) {
    if (-not $env:TELEGRAM_BOT_TOKEN -or -not $env:TELEGRAM_CHAT_ID) {
        Write-Log 'Telegram credentials are absent; the result is recorded locally.'
        return 'not_configured'
    }
    try {
        $body = @{ chat_id = $env:TELEGRAM_CHAT_ID; text = $Message } | ConvertTo-Json -Compress
        $uri = 'https://api.telegram.org/bot' + $env:TELEGRAM_BOT_TOKEN + '/sendMessage'
        $response = Invoke-RestMethod -Uri $uri -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 15 -ErrorAction Stop -Verbose:$false -Debug:$false
        if ($response.ok -ne $true) { throw 'Telegram rejected the message.' }
        Write-Log 'Telegram notification sent.'
        return 'sent'
    } catch {
        Write-Log 'Telegram delivery failed. Check the credentials, /start and network; deployment evidence is preserved.'
        return 'failed'
    }
}
try {
    $initial = Read-Kube -Arguments @('get', 'rollout', $Name)
    $uid = [string]$initial.metadata.uid
    $generation = [long]$initial.metadata.generation
    $started = [DateTimeOffset]::UtcNow
    $deadline = $started.AddSeconds($TimeoutSeconds)
    Save-Json 'initial-rollout.json' $initial
    Write-Log "Observing $Namespace/$Name; target generation=$generation; context=$Context."
    $index = 0
    $outcome = $null
    $failedName = $null
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $rollout = Read-Kube -Arguments @('get', 'rollout', $Name)
        if ($rollout.metadata.uid -ne $uid -or [long]$rollout.metadata.generation -ne $generation) {
            throw 'Rollout was replaced or its specification changed during observation. Start a new observation.'
        }
        Save-Json ('rollout-{0:D4}.json' -f $index) $rollout
        $index++
        $observed = 0L
        $fresh = [long]::TryParse([string]$rollout.status.observedGeneration, [ref]$observed) -and $observed -ge $generation
        $phase = [string]$rollout.status.phase
        Write-Log "phase=$phase; observedGeneration=$observed; step=$($rollout.status.currentStepIndex); abort=$($rollout.status.abort)"
        if ($fresh -and $phase -eq 'Healthy' -and -not $rollout.status.abort -and
            $rollout.status.stableRS -and $rollout.status.stableRS -eq $rollout.status.currentPodHash) {
            $outcome = 'Healthy'
            break
        }
        if ($fresh -and $rollout.status.abort -eq $true -and $phase -eq 'Degraded') {
            $runs = Read-Kube -Arguments @('get', 'analysisruns', '-l', "app=$Name")
            $revision = [string]$rollout.metadata.annotations.'rollout.argoproj.io/revision'
            $currentHash = [string]$rollout.status.currentPodHash
            $stableHash = [string]$rollout.status.stableRS
            $failed = @($runs.items | Where-Object {
                $_.status.phase -eq 'Failed' -and $revision -and
                $_.metadata.annotations.'rollout.argoproj.io/revision' -eq $revision -and
                $_.metadata.labels.'rollouts-pod-template-hash' -eq $currentHash -and
                @($_.metadata.ownerReferences | Where-Object { $_.kind -eq 'Rollout' -and $_.uid -eq $uid }).Count -gt 0
            } | Sort-Object { $_.metadata.creationTimestamp } -Descending)
            $pods = Read-Kube -Arguments @('get', 'pods', '-l', "app=$Name")
            $slices = Read-Kube -Arguments @('get', 'endpointslices', '-l', "kubernetes.io/service-name=$Name")
            Save-Json 'abort-check.json' @{ rollout = $rollout; analysisRuns = $runs; pods = $pods; endpointSlices = $slices }
            $readyEndpoints = @($slices.items.endpoints | Where-Object { $_.conditions.ready -eq $true -and $_.conditions.terminating -ne $true })
            $onlyStable = $readyEndpoints.Count -gt 0 -and $stableHash -and $stableHash -ne $currentHash
            foreach ($endpoint in $readyEndpoints) {
                $matching = @($pods.items | Where-Object { $_.metadata.uid -eq $endpoint.targetRef.uid })
                if ($endpoint.targetRef.kind -ne 'Pod' -or $matching.Count -ne 1 -or
                    $matching[0].metadata.labels.'rollouts-pod-template-hash' -ne $stableHash -or
                    $matching[0].metadata.deletionTimestamp) { $onlyStable = $false }
            }
            if ($failed.Count -gt 0 -and $onlyStable) {
                $failedName = $failed[0].metadata.name
                $outcome = 'VerifiedAnalysisAbort'
                break
            }
            Write-Log 'Abort detected; waiting for matching Failed AnalysisRun and exclusively stable ready endpoints.'
        }
        Start-Sleep -Seconds $PollSeconds
    }
    if (-not $outcome) { throw 'Observation timed out; automatic rollback has NOT been confirmed.' }
    $confirmed = [DateTimeOffset]::UtcNow
    Save-Json 'final-rollout.json' $rollout
    $allRuns = Read-Kube -Arguments @('get', 'analysisruns', '-l', "app=$Name")
    Save-Json 'analysisruns.json' $allRuns
    $yaml = & kubectl --context $Context -n $Namespace --request-timeout=10s get analysisruns -l "app=$Name" -o yaml 2>> (Join-Path $reportDir 'kubectl-stderr.log')
    if ($LASTEXITCODE -ne 0) { throw 'Could not save AnalysisRun YAML.' }
    $yaml | Set-Content (Join-Path $reportDir 'analysisruns.yaml') -Encoding utf8
    $message = if ($outcome -eq 'Healthy') {
        "ЛР4: $Namespace/$Name успешно развёрнут. generation=$generation; stableRS=$($rollout.status.stableRS)."
    } else {
        "ЛР4: подтверждён возврат обслуживания $Namespace/$Name после Failed AnalysisRun $failedName. Rollout abort=true, Degraded; все готовые endpoints ведут на stableRS=$($rollout.status.stableRS)."
    }
    Write-Log "$outcome; FailedAnalysisRun=$failedName; stableRS=$($rollout.status.stableRS)."
    $notification = Send-Notice $message
    Save-Json 'result.json' @{ outcome = $outcome; generation = $generation; failedAnalysisRun = $failedName; stableRS = $rollout.status.stableRS; startedUtc = $started; confirmedUtc = $confirmed; finishedUtc = [DateTimeOffset]::UtcNow; notification = $notification }
    Write-Host "Evidence: $reportDir"
    if ($outcome -eq 'Healthy') { exit 0 }
    exit 2
} catch {
    Write-Log "Observer stopped: $($_.Exception.Message) No new rollback claim is made."
    Save-Json 'observer-error.json' @{ outcome = 'Unconfirmed'; message = $_.Exception.Message; timestampUtc = [DateTimeOffset]::UtcNow }
    exit 1
}
