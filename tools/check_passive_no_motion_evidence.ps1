param(
  [Parameter(Mandatory = $true)]
  [string]$SummaryJsonPath,
  [Parameter(Mandatory = $true)]
  [string]$ExpectedFirmwareSha256,
  [Parameter(Mandatory = $true)]
  [string]$FirmwareSourceCommit,
  [Parameter(Mandatory = $true)]
  [string]$RunnerSourceCommit,
  [int]$MinDurationSeconds = 600,
  [int]$MinPowerVbusMv = 4400,
  [double]$MaxChipTempC = 70.0,
  [int]$MaxDisplayFrameUs = 50000,
  [switch]$RequireObservedTurn,
  [switch]$RequireCameraHostVision,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$ExpectedFirmwareSha256 = $ExpectedFirmwareSha256.Trim().ToLowerInvariant()
$FirmwareSourceCommit = $FirmwareSourceCommit.Trim().ToLowerInvariant()
$RunnerSourceCommit = $RunnerSourceCommit.Trim().ToLowerInvariant()
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($ExpectedFirmwareSha256 -notmatch "^[0-9a-f]{64}$") { throw "ExpectedFirmwareSha256 must be a full SHA-256." }
if ($FirmwareSourceCommit -notmatch "^[0-9a-f]{40}$") { throw "FirmwareSourceCommit must be a full Git commit SHA." }
if ($RunnerSourceCommit -notmatch "^[0-9a-f]{40}$") { throw "RunnerSourceCommit must be a full Git commit SHA." }

$checks = New-Object System.Collections.Generic.List[object]

function Add-Check {
  param([string]$Id, [bool]$Passed, [string]$Detail)
  $script:checks.Add([ordered]@{
      id = $Id
      status = $(if ($Passed) { "pass" } else { "fail" })
      detail = $Detail
    })
}

function Read-JsonWithRetry {
  param([string]$Path, [int]$Attempts = 6, [int]$DelayMilliseconds = 100)
  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch {
      if ($attempt -eq $Attempts) { throw }
      Start-Sleep -Milliseconds $DelayMilliseconds
    }
  }
}

function Get-PropertyValue {
  param($Object, [string]$Name, $DefaultValue = $null)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return $property.Value
}

function Get-IntValue {
  param($Object, [string]$Name, [int64]$DefaultValue = 0)
  $value = Get-PropertyValue $Object $Name $null
  if ($null -eq $value) { return $DefaultValue }
  try { return [int64]$value } catch { return $DefaultValue }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-JsonBoolean {
  param($Object, [string]$Name, [bool]$Expected)
  $property = if ($null -ne $Object) { $Object.PSObject.Properties[$Name] } else { $null }
  return $null -ne $property -and $property.Value -is [bool] -and $property.Value -eq $Expected
}

function Test-MotionBreach {
  param($Sample)
  foreach ($field in @(
      "motionRequested", "motionAutonomous", "motionEnabled", "servoPowerAllowed",
      "servoRailEnabled", "servoTorqueEnabled", "powerMotionRequested", "powerMotionAllowed",
      "powerServoRailAllowed", "motionActuatorReady", "cameraGazeMotionOutput"
    )) {
    $property = if ($null -ne $Sample) { $Sample.PSObject.Properties[$field] } else { $null }
    if ($null -eq $property -or $property.Value -isnot [bool] -or $property.Value) { return $true }
  }
  return $false
}

$summary = $null
$run = $null
$polls = $null
$seal = $null
$candidate = $null
$hostRuntime = $null
$preflight = $null
$evidenceRoot = ""

if (-not (Test-Path -LiteralPath $SummaryJsonPath -PathType Leaf)) {
  Add-Check "summary-json" $false "Missing summary: $SummaryJsonPath"
} else {
  $SummaryJsonPath = (Resolve-Path -LiteralPath $SummaryJsonPath).Path
  $evidenceRoot = Split-Path -Parent $SummaryJsonPath
  try {
    $summary = Read-JsonWithRetry $SummaryJsonPath
    $run = Read-JsonWithRetry (Join-Path $evidenceRoot "run.json")
    $polls = Read-JsonWithRetry (Join-Path $evidenceRoot "polls.json")
    $seal = Read-JsonWithRetry (Join-Path $evidenceRoot "seal.json")
    $candidate = Read-JsonWithRetry (Join-Path $evidenceRoot "candidate-manifest.json")
    $hostRuntime = Read-JsonWithRetry (Join-Path $evidenceRoot "host-runtime-manifest.json")
    $preflight = Read-JsonWithRetry (Join-Path $evidenceRoot "preflight.json")
    Add-Check "packet-json" $true "Parsed summary, run, polls, seal, candidate, and host runtime JSON."
  } catch {
    Add-Check "packet-json" $false "Packet JSON is missing or invalid after bounded retries."
  }
}

if ($null -ne $summary -and $null -ne $run -and $null -ne $polls -and $null -ne $seal -and
    $null -ne $candidate -and $null -ne $hostRuntime -and $null -ne $preflight) {
  Add-Check "summary-schema" ($summary.schema -ceq "stackchan.passive-no-motion-summary.v1") "schema=$($summary.schema)"
  Add-Check "run-schema" ($run.schema -ceq "stackchan.passive-no-motion-run.v1") "schema=$($run.schema)"
  Add-Check "polls-schema" ($polls.schema -ceq "stackchan.passive-no-motion-polls.v1") "schema=$($polls.schema)"
  Add-Check "seal-schema" ($seal.schema -ceq "stackchan.passive-no-motion-seal.v1") "schema=$($seal.schema)"
  $runIds = @(@([string]$summary.runId, [string]$run.runId, [string]$polls.runId, [string]$seal.runId) |
      Sort-Object -Unique)
  Add-Check "run-id" ($runIds.Count -eq 1 -and $runIds[0] -match "^[0-9a-f]{32}$") "runIds=$($runIds -join ',')"

  $requiredPacketFiles = @(
    "run.json", "polls.json", "summary.json", "preflight.json", "runner.ps1", "checker.ps1",
    "candidate-manifest.json", "host-runtime-manifest.json"
  )
  $sealedFilesValid = $true
  foreach ($name in $requiredPacketFiles) {
    $path = Join-Path $evidenceRoot $name
    $declared = [string](Get-PropertyValue $seal.files $name "")
    $valid = (Test-Path -LiteralPath $path -PathType Leaf) -and
      $declared -match "^[0-9a-f]{64}$" -and (Get-Sha256 $path) -ceq $declared
    Add-Check ("sealed-" + $name) $valid "declared=$declared"
    if (-not $valid) { $sealedFilesValid = $false }
  }
  $safetyStopPath = Join-Path $evidenceRoot "safety-stop.json"
  $safetyStopDeclared = [string](Get-PropertyValue $seal.files "safety-stop.json" "")
  $safetyStopPacket = $null
  $safetyStopEvidenceValid = $false
  if ($null -eq $summary.safetyStop) {
    $safetyStopEvidenceValid = -not (Test-Path -LiteralPath $safetyStopPath) -and
      [string]::IsNullOrWhiteSpace($safetyStopDeclared)
  } elseif ((Test-Path -LiteralPath $safetyStopPath -PathType Leaf) -and
      $safetyStopDeclared -match "^[0-9a-f]{64}$" -and (Get-Sha256 $safetyStopPath) -ceq $safetyStopDeclared) {
    try {
      $safetyStopPacket = Read-JsonWithRetry $safetyStopPath
      $safetyStopEvidenceValid = [string]$safetyStopPacket.runId -ceq [string]$summary.runId -and
        (Test-JsonBoolean $safetyStopPacket.result "stopRequestTransportOk" $true) -and
        (Test-JsonBoolean $safetyStopPacket.result "stopRequestAccepted" $true) -and
        (Test-JsonBoolean $safetyStopPacket.result "postStopDebugAvailable" $true) -and
        (Test-JsonBoolean $safetyStopPacket.result "verifiedOff" $true) -and
        $null -ne $safetyStopPacket.result.postStopDebug
    } catch { $safetyStopEvidenceValid = $false }
  }
  Add-Check "safety-stop-evidence" $safetyStopEvidenceValid "no breach requires no stop file; a breach requires a sealed accepted stop and complete post-stop debug snapshot"
  Add-Check "seal-summary-status" ([string]$seal.summaryStatus -ceq [string]$summary.status) "seal=$($seal.summaryStatus) summary=$($summary.status)"

  Add-Check "firmware-source" ([string]$run.firmwareSourceCommit -ceq $FirmwareSourceCommit -and
    [string]$summary.firmwareSourceCommit -ceq $FirmwareSourceCommit -and
    [string]$candidate.sourceCommit -ceq $FirmwareSourceCommit -and
    [string]$hostRuntime.sourceCommit -ceq $FirmwareSourceCommit) "expected=$FirmwareSourceCommit"
  Add-Check "firmware-sha" ([string]$run.expectedFirmwareSha256 -ceq $ExpectedFirmwareSha256 -and
    [string]$summary.installedFirmwareSha256 -ceq $ExpectedFirmwareSha256 -and
    [string]$candidate.firmwareSha256 -ceq $ExpectedFirmwareSha256) "expected=$ExpectedFirmwareSha256"
  Add-Check "candidate-installed" (Test-JsonBoolean $candidate.installation "confirmed" $true) "confirmed=$($candidate.installation.confirmed)"
  Add-Check "runner-source" ([string]$run.runnerSourceCommit -ceq $RunnerSourceCommit -and
    [string]$summary.runnerSourceCommit -ceq $RunnerSourceCommit -and
    [string]$summary.runnerSourceCommitEnd -ceq $RunnerSourceCommit) "expected=$RunnerSourceCommit"
  $expectedRunnerBlob = ((& git rev-parse "$RunnerSourceCommit`:tools/run_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()
  $expectedCheckerBlob = ((& git rev-parse "$RunnerSourceCommit`:tools/check_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()
  $packetRunnerBlob = ((& git hash-object --path=tools/run_passive_no_motion_evidence.ps1 (Join-Path $evidenceRoot "runner.ps1")) -join "").Trim().ToLowerInvariant()
  $packetCheckerBlob = ((& git hash-object --path=tools/check_passive_no_motion_evidence.ps1 (Join-Path $evidenceRoot "checker.ps1")) -join "").Trim().ToLowerInvariant()
  Add-Check "runner-git-blobs" ($expectedRunnerBlob -match "^[0-9a-f]{40}$" -and
    $expectedCheckerBlob -match "^[0-9a-f]{40}$" -and $packetRunnerBlob -ceq $expectedRunnerBlob -and
    $packetCheckerBlob -ceq $expectedCheckerBlob -and [string]$run.runnerSourceBlob -ceq $expectedRunnerBlob -and
    [string]$run.checkerSourceBlob -ceq $expectedCheckerBlob) "runner=$packetRunnerBlob checker=$packetCheckerBlob"
  Add-Check "runner-clean" ((Test-JsonBoolean $run "runnerSourceDirty" $false) -and
    (Test-JsonBoolean $summary "runnerSourceDirty" $false) -and
    (Test-JsonBoolean $summary "runnerSourceDirtyEnd" $false)) "start=$($summary.runnerSourceDirty) end=$($summary.runnerSourceDirtyEnd)"
  Add-Check "host-runtime-binding" ($hostRuntime.schema -ceq "stackchan.pc-brain-runtime.v1" -and
    (Test-JsonBoolean $hostRuntime "sourceWorktreeClean" $true) -and [int]$hostRuntime.bridgePid -eq [int]$run.hostRuntimePid -and
    [int]$summary.hostRuntimePid -eq [int]$run.hostRuntimePid) "pid=$($run.hostRuntimePid) sourceClean=$($hostRuntime.sourceWorktreeClean)"
  $hostProcessStartedAt = try { [DateTime]::Parse([string]$run.hostProcessStartedAt).ToUniversalTime() } catch { [DateTime]::MaxValue }
  $hostRuntimeGeneratedAt = try { [DateTime]::Parse([string]$hostRuntime.generatedAt).ToUniversalTime() } catch { [DateTime]::MinValue }
  $hostTimeDeltaSeconds = ($hostRuntimeGeneratedAt - $hostProcessStartedAt).TotalSeconds
  Add-Check "host-runtime-provenance" ([System.IO.Path]::GetFullPath([string]$run.qualificationRoot) -ceq
    [System.IO.Path]::GetFullPath($RepoRoot) -and [System.IO.Path]::GetFullPath([string]$hostRuntime.sourceRoot) -ceq
    [System.IO.Path]::GetFullPath([string]$run.qualificationRoot) -and
    [string]$run.hostRuntimeGeneratedAt -ceq $hostRuntimeGeneratedAt.ToString("o") -and
    $hostTimeDeltaSeconds -ge 0 -and $hostTimeDeltaSeconds -le 120 -and
    [string]$run.hostCommandLineSha256 -match "^[0-9a-f]{64}$") "root=$($run.qualificationRoot) processToManifestSeconds=$hostTimeDeltaSeconds"
  Add-Check "control-policy" ([string]$run.controlPolicy -ceq "emergency_stop_only" -and
    [string]$summary.controlPolicy -ceq "emergency_stop_only") "run=$($run.controlPolicy) summary=$($summary.controlPolicy)"
  Add-Check "ordinary-methods" (@($run.ordinaryRobotMethods).Count -eq 1 -and
    [string]$run.ordinaryRobotMethods[0] -ceq "GET /debug" -and
    @($summary.ordinaryRobotMethods).Count -eq 1 -and
    [string]$summary.ordinaryRobotMethods[0] -ceq "GET /debug") "ordinary robot method must be exactly GET /debug"

  $externalFirmwarePath = [string]$seal.externalBindings.candidateFirmwarePath
  $externalSourcePath = [string]$seal.externalBindings.candidateSourcePath
  $externalFirmwareValid = (Test-Path -LiteralPath $externalFirmwarePath -PathType Leaf) -and
    (Get-Sha256 $externalFirmwarePath) -ceq $ExpectedFirmwareSha256 -and
    [string]$seal.externalBindings.candidateFirmwareSha256 -ceq $ExpectedFirmwareSha256
  $externalSourceHash = [string]$seal.externalBindings.candidateSourceSha256
  $externalSourceValid = (Test-Path -LiteralPath $externalSourcePath -PathType Leaf) -and
    $externalSourceHash -match "^[0-9a-f]{64}$" -and (Get-Sha256 $externalSourcePath) -ceq $externalSourceHash -and
    [string]$candidate.sourceArchiveSha256 -ceq $externalSourceHash
  Add-Check "external-firmware" $externalFirmwareValid "path=$externalFirmwarePath"
  Add-Check "external-source" $externalSourceValid "path=$externalSourcePath"

  $records = @($polls.records)
  $sequenceValid = $records.Count -gt 0
  $timeValid = $true
  $elapsedValid = $true
  $maxPollGapMs = 0
  $previousTime = $null
  $previousElapsedMs = $null
  for ($index = 0; $index -lt $records.Count; $index++) {
    if ((Get-IntValue $records[$index] "sequence" -1) -ne $index) { $sequenceValid = $false }
    try {
      $timestamp = [DateTime]::Parse([string]$records[$index].generatedAt).ToUniversalTime()
      if ($null -ne $previousTime -and $timestamp -lt $previousTime) { $timeValid = $false }
      $previousTime = $timestamp
    } catch { $timeValid = $false }
    $elapsedMs = Get-IntValue $records[$index] "elapsedMs" -1
    if ($elapsedMs -lt 0 -or ($null -ne $previousElapsedMs -and $elapsedMs -lt $previousElapsedMs)) {
      $elapsedValid = $false
    }
    if ($null -ne $previousElapsedMs) { $maxPollGapMs = [math]::Max($maxPollGapMs, $elapsedMs - $previousElapsedMs) }
    $previousElapsedMs = $elapsedMs
  }
  Add-Check "poll-sequence" $sequenceValid "records=$($records.Count)"
  Add-Check "poll-time-order" $timeValid "timestamps must be parseable and nondecreasing"
  Add-Check "poll-monotonic" ($elapsedValid -and $maxPollGapMs -le 8000) "maxGapMs=$maxPollGapMs limit=8000"
  $preflightMatches = $records.Count -gt 0 -and [string]$preflight.runId -ceq [string]$run.runId -and
    (($preflight.sample | ConvertTo-Json -Depth 14 -Compress) -ceq
      ($records[0] | ConvertTo-Json -Depth 14 -Compress))
  Add-Check "preflight-record" $preflightMatches "preflight runId/sample must exactly match polls.records[0]"

  $qualificationPollContract = if ($MinDurationSeconds -ge 600) {
    [int]$run.pollMilliseconds -eq 2000 -and [int]$run.pollTimeoutSeconds -eq 4
  } else {
    [int]$run.pollMilliseconds -ge 50 -and [int]$run.pollMilliseconds -le 2000 -and
      [int]$run.pollTimeoutSeconds -ge 1 -and [int]$run.pollTimeoutSeconds -le 4
  }
  Add-Check "poll-contract" $qualificationPollContract "pollMs=$($run.pollMilliseconds) timeoutS=$($run.pollTimeoutSeconds) qualification=$($MinDurationSeconds -ge 600)"

  $okRecords = @($records | Where-Object { $_.ok -eq $true })
  $failedRecords = @($records | Where-Object { $_.ok -ne $true })
  $failedRatio = if ($records.Count -gt 0) { $failedRecords.Count / [double]$records.Count } else { 1.0 }
  $failedPolicyPassed = if ($records.Count -lt 100) { $failedRecords.Count -eq 0 } else { $failedRatio -le 0.01 }
  $maxFailureStreak = 0
  $failureStreak = 0
  foreach ($record in $records) {
    if ($record.ok -eq $true) { $failureStreak = 0 } else {
      $failureStreak += 1
      $maxFailureStreak = [math]::Max($maxFailureStreak, $failureStreak)
    }
  }
  Add-Check "poll-counts" ($records.Count -eq [int]$summary.records -and $okRecords.Count -eq [int]$summary.okPolls -and
    $failedRecords.Count -eq [int]$summary.failedPolls) "packet=$($records.Count) ok=$($okRecords.Count) failed=$($failedRecords.Count)"
  Add-Check "failed-poll-policy" ($failedPolicyPassed -and $maxFailureStreak -le 1) "ratio=$failedRatio streak=$maxFailureStreak"
  $failedContinuity = @($failedRecords | Where-Object {
      -not (Test-JsonBoolean $_ "socketPresent" $true) -or
      -not (Test-JsonBoolean $_ "hostOperational" $true) -or
      -not (Test-JsonBoolean $_ "hostRuntimePidAlive" $true) -or
      (Get-IntValue $_ "bridgePid" 0) -ne [int]$run.hostRuntimePid
    }).Count -eq 0
  Add-Check "failed-poll-continuity" $failedContinuity "isolated debug failures must retain socket, host, and PID evidence"

  $bindingPassed = $okRecords.Count -gt 0 -and @($okRecords | Where-Object {
      -not (Test-JsonBoolean $_ "debugResponseTruncated" $false) -or
      [string]$_.controlPolicy -cne "emergency_stop_only" -or
      [string]$_.firmwareSha256 -cne $ExpectedFirmwareSha256 -or
      -not (Test-JsonBoolean $_ "appConfirmed" $true) -or
      (Get-IntValue $_ "bridgePid" 0) -ne [int]$run.hostRuntimePid
    }).Count -eq 0
  Add-Check "per-poll-binding" $bindingPassed "okPolls=$($okRecords.Count)"

  $motionBreaches = @($okRecords | Where-Object { Test-MotionBreach $_ }).Count
  Add-Check "no-motion-authority" ($motionBreaches -eq 0 -and $null -eq $summary.safetyStop) "breaches=$motionBreaches safetyStop=$($null -ne $summary.safetyStop)"
  foreach ($counter in @("motionEnableRequests", "motionSessionRefreshes", "motionLastWriteMs", "servoRailEnableEntries", "powerMotionGrants")) {
    $counterPassed = $okRecords.Count -gt 0 -and @($okRecords | Where-Object { (Get-IntValue $_ $counter -1) -ne 0 }).Count -eq 0
    Add-Check ("zero-" + $counter) $counterPassed "all successful polls must report zero"
  }

  foreach ($field in @(
      "networkConnected", "bridgeReady", "bridgeUplinkReady", "socketPresent", "hostRuntimePidAlive",
      "wakeReady", "speakerReady", "hostOperational", "hostSpeechReady",
      "hostSttHealthy", "hostVoiceConfigured"
    )) {
    $readyPassed = $okRecords.Count -gt 0 -and @($okRecords | Where-Object {
        -not (Test-JsonBoolean $_ $field $true)
      }).Count -eq 0
    Add-Check ("ready-" + $field) $readyPassed "all successful polls must be ready"
  }
  $micReadyPassed = $okRecords.Count -gt 0 -and @($okRecords | Where-Object {
      if (Test-JsonBoolean $_ "micReady" $true) { return $false }
      $transient = (Test-JsonBoolean $_ "wakeAudioPauseRequested" $true) -or
        (Test-JsonBoolean $_ "wakeAudioPaused" $true) -or
        (Test-JsonBoolean $_ "audioStreamActive" $true) -or
        (Test-JsonBoolean $_ "speakerRunning" $true) -or
        ([string]$_.wakeCuePhase -notin @("", "idle", "unknown"))
      return -not $transient
    }).Count -eq 0
  Add-Check "ready-mic-lifecycle" $micReadyPassed "mic must be ready except during an explicit cue/capture/playback transition"

  $resetReasons = @($okRecords | ForEach-Object { [string]$_.resetReason } | Sort-Object -Unique)
  $bootCounts = @($okRecords | ForEach-Object { [int64]$_.bootCount } | Sort-Object -Unique)
  $uptimeRegressions = 0
  for ($index = 1; $index -lt $okRecords.Count; $index++) {
    if ([int64]$okRecords[$index].uptimeMs -lt [int64]$okRecords[$index - 1].uptimeMs) { $uptimeRegressions += 1 }
  }
  Add-Check "clean-reset" ($resetReasons.Count -eq 1 -and $resetReasons[0] -in @("software", "poweron", "power-on")) "reasons=$($resetReasons -join ',')"
  Add-Check "stable-boot" ($bootCounts.Count -eq 1 -and $uptimeRegressions -eq 0) "bootCounts=$($bootCounts -join ',') uptimeRegressions=$uptimeRegressions"

  $first = $okRecords | Select-Object -First 1
  $last = $okRecords | Select-Object -Last 1
  $coverageMs = if ($null -ne $first -and $null -ne $last) {
    [int64]$last.elapsedMs - [int64]$first.elapsedMs
  } else { 0 }
  $pollMilliseconds = [int]$run.pollMilliseconds
  $minimumCoverageMs = [math]::Max(0, ($MinDurationSeconds * 1000) - [math]::Max(2000, 2 * $pollMilliseconds))
  $minimumOkPolls = [math]::Max(1, [math]::Floor(($MinDurationSeconds * 1000 / [double]$pollMilliseconds) * 0.8))
  Add-Check "duration" ([int]$summary.durationSeconds -ge $MinDurationSeconds -and
    [int64]$summary.elapsedDurationMs -ge ($MinDurationSeconds * 1000) -and
    $coverageMs -ge $minimumCoverageMs -and $okRecords.Count -ge $minimumOkPolls -and
    [int64]$summary.maxPollGapMs -eq $maxPollGapMs -and $maxPollGapMs -le 8000) "duration=$($summary.durationSeconds) elapsedMs=$($summary.elapsedDurationMs) coverageMs=$coverageMs ok=$($okRecords.Count) requiredOk=$minimumOkPolls maxGapMs=$maxPollGapMs"

  $minVbus = if ($okRecords.Count -gt 0) { [int](($okRecords | Measure-Object -Property powerVbusMv -Minimum).Minimum) } else { -1 }
  $minReportedVbus = if ($okRecords.Count -gt 0) { [int](($okRecords | Measure-Object -Property powerVbusReportedMinMv -Minimum).Minimum) } else { -1 }
  $maxTemp = if ($okRecords.Count -gt 0) { [double](($okRecords | Measure-Object -Property chipTempC -Maximum).Maximum) } else { -1 }
  $maxFrame = if ($okRecords.Count -gt 0) { [int](($okRecords | Measure-Object -Property displayMaxFrameUs -Maximum).Maximum) } else { -1 }
  Add-Check "vbus-floor" ($minVbus -ge $MinPowerVbusMv -and $minReportedVbus -ge $MinPowerVbusMv) "sample=$minVbus reported=$minReportedVbus min=$MinPowerVbusMv"
  Add-Check "chip-temperature" ($maxTemp -ge 0 -and $maxTemp -le $MaxChipTempC) "observed=$maxTemp max=$MaxChipTempC"
  Add-Check "display-frame" ($maxFrame -gt 0 -and $maxFrame -le $MaxDisplayFrameUs) "observed=$maxFrame max=$MaxDisplayFrameUs"

  $powerReady = $okRecords.Count -gt 0 -and @($okRecords | Where-Object {
      [string]$_.powerForensicsSchema -cne "axp2101-v2" -or
      -not (Test-JsonBoolean $_ "powerForensicsEnabled" $true) -or
      -not (Test-JsonBoolean $_ "powerForensicsIrqEnabled" $true) -or
      -not (Test-JsonBoolean $_ "powerForensicsBootStatusValid" $true) -or
      [int64]$_.powerForensicsBootEventMask -ne 0 -or [string]$_.powerForensicsBootEvent -cne "none" -or
      -not (Test-JsonBoolean $_ "powerForensicsBootProtective" $false)
    }).Count -eq 0
  Add-Check "power-forensics-ready" $powerReady "all successful polls must report valid event-free boot forensics"
  foreach ($counter in @(
      "powerForensicsRuntimeEvents", "powerForensicsProtectiveEvents", "powerForensicsReadFailures",
      "powerForensicsClearFailures", "pmicVbusLossEntries", "vbusHardFloorEntries", "powerReadFailures",
      "pmicInputReadFailures", "pmicConfigReadFailures", "powerVsysReadFailures", "chipTempReadFailures"
    )) {
    $values = @($okRecords | ForEach-Object { Get-IntValue $_ $counter -1 } | Sort-Object -Unique)
    Add-Check ("stable-" + $counter) ($values.Count -eq 1 -and $values[0] -ge 0) "values=$($values -join ',')"
  }

  if ($RequireObservedTurn -or [bool]$summary.requireObservedTurn) {
    $captureDelta = [int64]$last.wakeCapturesCompleted - [int64]$first.wakeCapturesCompleted
    $turnDelta = [int64]$last.uplinkTurns - [int64]$first.uplinkTurns
    $playbackDelta = [int64]$last.playbackCompletions - [int64]$first.playbackCompletions
    $playbackErrorDelta = [int64]$last.playbackErrors - [int64]$first.playbackErrors
    Add-Check "conversation-lifecycle" ($captureDelta -ge 1 -and $turnDelta -ge 1 -and
      $playbackDelta -ge 1 -and $playbackErrorDelta -eq 0) "captures=$captureDelta turns=$turnDelta playback=$playbackDelta errors=$playbackErrorDelta; this does not prove STT correctness"
  }
  if ($RequireCameraHostVision -or [bool]$summary.requireCameraHostVision) {
    $cameraReady = $okRecords.Count -gt 0 -and @($okRecords | Where-Object {
        [int]$_.compiledCamera -ne 1 -or [int]$_.compiledCameraHostVision -ne 1 -or
        -not (Test-JsonBoolean $_ "cameraReady" $true) -or
        -not (Test-JsonBoolean $_ "cameraActive" $true)
      }).Count -eq 0
    $cameraFrameDelta = [int64]$last.cameraFrames - [int64]$first.cameraFrames
    $cameraRequestDelta = [int64]$last.cameraHostFrameRequests - [int64]$first.cameraHostFrameRequests
    Add-Check "camera-host-vision" ($cameraReady -and $cameraFrameDelta -ge 1 -and $cameraRequestDelta -ge 1) "frames=$cameraFrameDelta requests=$cameraRequestDelta"
  }

  Add-Check "summary-status" ([string]$summary.status -ceq "pass") "status=$($summary.status)"
  Add-Check "summary-issues" (@($summary.issues).Count -eq 0) "issues=$(@($summary.issues) -join ',')"
  Add-Check "fatal-error" ([string]::IsNullOrWhiteSpace([string]$summary.fatalError)) "fatalError=$($summary.fatalError)"
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$result = [ordered]@{
  schema = "stackchan.passive-no-motion-check.v2"
  status = $(if ($failed.Count -eq 0) { "pass" } else { "fail" })
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  checks = @($checks | ForEach-Object { $_ })
}
if ($Json) { $result | ConvertTo-Json -Depth 8 } else { $result }
if ($failed.Count -gt 0) { exit 1 }
