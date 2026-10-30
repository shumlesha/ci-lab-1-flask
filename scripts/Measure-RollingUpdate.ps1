#requires -Version 7.0
[CmdletBinding()]
param(
    [string]$Name = 'ci-lab-flask',
    [string]$Namespace = 'staging',
    [string]$Context = 'kind-cicd-lab4',
    [ValidateRange(10, 1800)][int]$DurationSeconds = 180,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$RunName = ('rolling-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$reportDir = Join-Path $repoRoot "reports/lab4/$RunName"
if (Test-Path -LiteralPath $reportDir) { throw 'Evidence directory already exists. Choose a new -RunName.' }
$null = New-Item -ItemType Directory -Path $reportDir -Force
$csvPath = Join-Path $reportDir 'rolling-samples.csv'
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
try {
    $initial = Read-Kube -Arguments @('get', 'deployment', $Name)
    $uid = [string]$initial.metadata.uid
    $initialGeneration = [long]$initial.metadata.generation
    $desired = [int]$initial.spec.replicas
    $strategy = $initial.spec.strategy.rollingUpdate
    if ($initial.spec.strategy.type -ne 'RollingUpdate' -or
        [string]$strategy.maxUnavailable -notmatch '^\d+$' -or [string]$strategy.maxSurge -notmatch '^\d+$') {
        throw 'This lab observer expects RollingUpdate with integer maxUnavailable and maxSurge.'
    }
    $floor = $desired - [int]$strategy.maxUnavailable
    $ceiling = $desired + [int]$strategy.maxSurge
    if ([long]$initial.status.observedGeneration -lt $initialGeneration -or
        [int]$initial.status.updatedReplicas -ne $desired -or [int]$initial.status.availableReplicas -lt $desired) {
        throw 'Wait for the initial Deployment to become fully ready before starting this observer.'
    }
    Save-Json 'initial-deployment.json' $initial
    Write-Log "Ready. Now run set image in another terminal. Available floor=$floor; desired ReplicaSet ceiling=$ceiling."
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $targetGeneration = $null
    $samples = 0
    $lowAvailability = 0
    $highDesired = 0
    $complete = $false
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        $sampleClock = [Diagnostics.Stopwatch]::StartNew()
        $deployment = Read-Kube -Arguments @('get', 'deployment', $Name)
        if ($deployment.metadata.uid -ne $uid) { throw 'The Deployment was replaced during observation.' }
        $generation = [long]$deployment.metadata.generation
        if ($generation -gt $initialGeneration -and $null -eq $targetGeneration) {
            $targetGeneration = $generation
            Write-Log "Update detected: generation=$generation."
        }
        if ($null -ne $targetGeneration -and $generation -ne $targetGeneration) { throw 'A second specification change was detected; repeat the experiment separately.' }
        if ([int]$deployment.spec.replicas -ne $desired) { throw 'Replica count changed; this experiment expects fixed replicas.' }
        $rsList = Read-Kube -Arguments @('get', 'replicasets', '-l', "app=$Name")
        $rs = @($rsList.items | Where-Object { @($_.metadata.ownerReferences | Where-Object { $_.uid -eq $uid -and $_.kind -eq 'Deployment' }).Count -gt 0 })
        $rsUids = @($rs.metadata.uid)
        $podList = Read-Kube -Arguments @('get', 'pods', '-l', "app=$Name")
        $pods = @($podList.items | Where-Object { @($_.metadata.ownerReferences | Where-Object { $_.uid -in $rsUids }).Count -gt 0 })
        $active = @($pods | Where-Object { -not $_.metadata.deletionTimestamp -and $_.status.phase -notin @('Succeeded', 'Failed') })
        $terminating = @($pods | Where-Object { $_.metadata.deletionTimestamp })
        $rsDesired = [int](($rs | Measure-Object -Property { [int]$_.spec.replicas } -Sum).Sum)
        $available = [int]$deployment.status.availableReplicas
        if ($available -lt $floor) { $lowAvailability++ }
        if ($rsDesired -gt $ceiling) { $highDesired++ }
        $row = [pscustomobject][ordered]@{
            timestamp_utc = [DateTimeOffset]::UtcNow.ToString('o')
            elapsed_seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 3)
            generation = $generation; observed_generation = [long]$deployment.status.observedGeneration
            desired_replicas = $desired; available_replicas = $available
            updated_replicas = [int]$deployment.status.updatedReplicas
            replicasets_desired_total = $rsDesired
            pods_running_nonterminating = @($active | Where-Object { $_.status.phase -eq 'Running' }).Count
            pods_nonterminating = $active.Count; pods_terminating = $terminating.Count
            min_available = $floor; max_replicasets_desired = $ceiling
            replica_set_sizes = (($rs | ForEach-Object { "$($_.metadata.name):$($_.spec.replicas)" }) -join '; ')
        }
        $row | Export-Csv -LiteralPath $csvPath -Append -NoTypeInformation -Encoding utf8
        Save-Json ('snapshot-{0:D4}.json' -f $samples) @{ deployment = $deployment; replicaSets = $rs; pods = $pods }
        $samples++
        Write-Log "generation=$generation; available=$available; updated=$($row.updated_replicas); RS desired=$rsDesired; active=$($active.Count); terminating=$($terminating.Count)"
        if ($null -ne $targetGeneration -and [long]$deployment.status.observedGeneration -ge $targetGeneration -and
            $row.updated_replicas -eq $desired -and $available -ge $desired -and $rsDesired -eq $desired) {
            $complete = $true
            break
        }
        Start-Sleep -Milliseconds ([Math]::Max(0, 1000 - [int]$sampleClock.ElapsedMilliseconds))
    }
    Save-Json 'result.json' @{ completed = $complete; initialGeneration = $initialGeneration; targetGeneration = $targetGeneration; samples = $samples; minAvailable = $floor; maxReplicaSetsDesired = $ceiling; samplesBelowAvailabilityFloor = $lowAvailability; samplesAboveReplicaSetCeiling = $highDesired; elapsedSeconds = $clock.Elapsed.TotalSeconds }
    if (-not $complete) { throw 'Time limit reached before an observed update completed. Inspect the captured samples.' }
    Write-Log "Rolling Update completed. Samples below availability floor=$lowAvailability; above RS ceiling=$highDesired."
    Write-Log 'Samples are observations at intervals; API reads are not atomic. Inspect any outliers and the Pod/ReplicaSet snapshots.'
    Write-Host "Evidence: $reportDir"
    exit 0
} catch {
    Write-Log "Observer stopped: $($_.Exception.Message)"
    Save-Json 'observer-error.json' @{ completed = $false; message = $_.Exception.Message; timestampUtc = [DateTimeOffset]::UtcNow }
    exit 1
}
