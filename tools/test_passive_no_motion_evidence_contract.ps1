$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$runnerPath = "tools\run_passive_no_motion_evidence.ps1"
$checkerPath = "tools\check_passive_no_motion_evidence.ps1"
$runner = Get-Content -LiteralPath $runnerPath -Raw
$checker = Get-Content -LiteralPath $checkerPath -Raw
$RunnerCommit = (& git rev-parse HEAD).Trim().ToLowerInvariant()
$RunnerBlob = ((& git rev-parse "$RunnerCommit`:tools/run_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()
$CheckerBlob = ((& git rev-parse "$RunnerCommit`:tools/check_passive_no_motion_evidence.ps1" 2>$null) -join "").Trim().ToLowerInvariant()

$tokens = $null
$parseErrors = $null
$runnerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path -LiteralPath $runnerPath), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw "Passive runner does not parse." }
$checkerTokens = $null
$checkerParseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path -LiteralPath $checkerPath), [ref]$checkerTokens, [ref]$checkerParseErrors)
if ($checkerParseErrors.Count -ne 0) { throw "Passive checker does not parse." }

foreach ($needle in @(
    "GET /debug",
    "GET /motion-stop only after an observed motion breach",
    "Test-MotionBreach",
    "Invoke-SafetyMotionStop",
    "stopRequestAccepted",
    "postStopDebugAvailable",
    "postStopDebug",
    "verifiedOff",
    "Write-JsonAtomic",
    "emergency_stop_only",
    "CandidateManifestPath is required.",
    "HostRuntimeManifestPath",
    "EvidenceRoot must be new or empty.",
    "stackchan.passive-no-motion-seal.v1",
    "PollMilliseconds must be 50 through 2000.",
    "PollTimeoutSeconds must be 1 through 4.",
    "elapsedMs",
    "MaxAllowedPollGapMs",
    "powerForensicsBootEventMask",
    "powerForensicsRuntimeEvents",
    "runnerSourceDirty",
    "reset_reason_not_clean",
    "motion_breach"
  )) {
  if (-not $runner.Contains($needle)) { throw "Passive runner contract missing: $needle" }
}
foreach ($field in @(
    "motionRequested", "motionAutonomous", "motionEnabled", "servoPowerAllowed",
    "servoRailEnabled", "servoTorqueEnabled", "powerMotionRequested", "powerMotionAllowed",
    "powerServoRailAllowed", "motionActuatorReady", "cameraGazeMotionOutput"
  )) {
  if (-not $runner.Contains($field) -or -not $checker.Contains($field)) {
    throw "Passive no-motion predicate is missing field: $field"
  }
}
foreach ($forbidden in @(
    "/motion-resume", "/motion-on", "/servos-on", "/recover", "/reboot", "/restart",
    "/wake-reset", "/tone", "Set-NetIPInterface", "Set-DnsClientServerAddress", "netsh",
    "Restart-Computer", "Stop-Process", "Start-Process", "pio run", "ota/upload"
  )) {
  if ($runner.Contains($forbidden)) { throw "Passive runner contains forbidden authority: $forbidden" }
}
if (-not $checker.Contains("Read-JsonWithRetry") -or -not $checker.Contains("Start-Sleep -Milliseconds")) {
  throw "Passive checker must retry bounded concurrent reads."
}

$webUris = @($runnerAst.FindAll({
      param($node)
      ($node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and
      $node.Value -match '^http://\$DeviceHost:'
    }, $true) | ForEach-Object { $_.Value })
if ($webUris.Count -ne 3 -or
    @($webUris | Where-Object { $_ -notmatch "/(?:debug|motion-stop)$" }).Count -ne 0 -or
    @($webUris | Where-Object { $_ -match "/debug$" }).Count -ne 2 -or
    @($webUris | Where-Object { $_ -match "/motion-stop$" }).Count -ne 1) {
  throw "Passive runner robot URI surface must be exactly two /debug reads and one conditional /motion-stop."
}

$preflightMotionIndex = $runner.IndexOf('if (Test-MotionBreach $preflightSample)')
$preflightBindingIndex = $runner.IndexOf('$preflightBindingIssue = Test-SampleBinding $preflightSample')
$loopMotionIndex = $runner.IndexOf('if (Test-MotionBreach $sample)')
$loopBindingIndex = $runner.IndexOf('$bindingIssue = Test-SampleBinding $sample')
if ($preflightMotionIndex -lt 0 -or $preflightBindingIndex -lt 0 -or
    $preflightMotionIndex -ge $preflightBindingIndex) {
  throw "Preflight must stop an observed motion breach before checking identity binding."
}
if ($loopMotionIndex -lt 0 -or $loopBindingIndex -lt 0 -or $loopMotionIndex -ge $loopBindingIndex) {
  throw "Polling must stop an observed motion breach before checking identity binding."
}

$probe = & $runnerPath -ContractProbe | ConvertFrom-Json
if ($LASTEXITCODE -ne 0 -or $probe.motionRefresh -ne $false -or $probe.networkMutation -ne $false -or
    @($probe.ordinaryRobotMethods).Count -ne 1 -or $probe.ordinaryRobotMethods[0] -cne "GET /debug") {
  throw "Passive runner contract probe failed."
}

function Write-Fixture {
  param([string]$Path, $Value)
  $Value | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Write-Seal {
  param([string]$EvidenceRoot, [string]$RunId, [string]$FirmwarePath, [string]$SourcePath)
  $summary = Get-Content -LiteralPath (Join-Path $EvidenceRoot "summary.json") -Raw | ConvertFrom-Json
  $files = [ordered]@{}
  foreach ($name in @(
      "run.json", "polls.json", "summary.json", "preflight.json", "runner.ps1", "checker.ps1",
      "candidate-manifest.json", "host-runtime-manifest.json"
    )) {
    $files[$name] = Get-Sha256 (Join-Path $EvidenceRoot $name)
  }
  Write-Fixture (Join-Path $EvidenceRoot "seal.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-seal.v1"
      runId = $RunId
      sealedAt = [DateTime]::UtcNow.ToString("o")
      summaryStatus = [string]$summary.status
      files = $files
      externalBindings = [ordered]@{
        candidateFirmwarePath = $FirmwarePath
        candidateFirmwareSha256 = Get-Sha256 $FirmwarePath
        candidateSourcePath = $SourcePath
        candidateSourceSha256 = Get-Sha256 $SourcePath
      }
    })
}

function Invoke-Checker {
  param([string]$EvidenceRoot, [string]$FirmwareSha, [switch]$RequireObservedTurn, [switch]$RequireCameraHostVision)
  $output = & $checkerPath `
    -SummaryJsonPath (Join-Path $EvidenceRoot "summary.json") `
    -ExpectedFirmwareSha256 $FirmwareSha `
    -FirmwareSourceCommit ("a" * 40) `
    -RunnerSourceCommit $RunnerCommit `
    -MinDurationSeconds 600 `
    -RequireObservedTurn:$RequireObservedTurn `
    -RequireCameraHostVision:$RequireCameraHostVision `
    -Json
  return [pscustomobject]@{ exitCode = $LASTEXITCODE; json = $output | ConvertFrom-Json }
}

function Copy-Packet {
  param([string]$Source, [string]$Destination)
  New-Item -ItemType Directory -Path $Destination | Out-Null
  Copy-Item -Path (Join-Path $Source "*") -Destination $Destination -Recurse -Force
}

function Set-SummaryFailure {
  param([string]$EvidenceRoot, [string]$Issue)
  $summaryPath = Join-Path $EvidenceRoot "summary.json"
  $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
  $summary.status = "fail"
  $summary.issues = @($Issue)
  Write-Fixture $summaryPath $summary
}

function Assert-CheckerFailure {
  param([string]$Name, [string]$EvidenceRoot, [string]$FirmwareSha, [string]$CheckId)
  $result = Invoke-Checker $EvidenceRoot $FirmwareSha -RequireObservedTurn -RequireCameraHostVision
  if ($result.exitCode -eq 0 -or $result.json.status -ne "fail" -or
      @($result.json.checks | Where-Object { $_.id -eq $CheckId -and $_.status -eq "fail" }).Count -ne 1) {
    throw "Expected $Name packet to fail check $CheckId."
  }
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-passive-no-motion-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
  $artifactRoot = Join-Path $tempRoot "artifacts"
  $passRoot = Join-Path $tempRoot "pass"
  New-Item -ItemType Directory -Path $artifactRoot, $passRoot | Out-Null
  $firmwarePath = Join-Path $artifactRoot "firmware.bin"
  $sourcePath = Join-Path $artifactRoot ("source-" + ("a" * 8) + ".zip")
  [System.IO.File]::WriteAllBytes($firmwarePath, [byte[]](0..255))
  [System.IO.File]::WriteAllBytes($sourcePath, [byte[]](255..0))
  $firmwareSha = Get-Sha256 $firmwarePath
  $sourceSha = Get-Sha256 $sourcePath
  $runId = [guid]::NewGuid().ToString("N")
  $baseTime = [DateTime]::Parse("2026-08-05T12:00:00Z").ToUniversalTime()

  $records = New-Object System.Collections.Generic.List[object]
  for ($index = 0; $index -le 300; $index++) {
    $conversationCounter = if ($index -ge 50) { 1 } else { 0 }
    $records.Add([pscustomobject][ordered]@{
        sequence = $index
        generatedAt = $baseTime.AddMilliseconds($index * 2000).ToString("o")
        elapsedMs = $index * 2000
        ok = $true
        debugResponseTruncated = $false
        controlPolicy = "emergency_stop_only"
        firmwareSha256 = $firmwareSha
        appConfirmed = $true
        motionRequested = $false
        motionAutonomous = $false
        motionEnabled = $false
        servoPowerAllowed = $false
        servoRailEnabled = $false
        servoTorqueEnabled = $false
        powerMotionRequested = $false
        powerMotionAllowed = $false
        powerServoRailAllowed = $false
        motionActuatorReady = $false
        cameraGazeMotionOutput = $false
        motionEnableRequests = 0
        motionSessionRefreshes = 0
        motionLastWriteMs = 0
        servoRailEnableEntries = 0
        powerMotionGrants = 0
        networkConnected = $true
        bridgeReady = $true
        bridgeUplinkReady = $true
        socketPresent = $true
        bridgePid = 4242
        hostRuntimePidAlive = $true
        wakeReady = $true
        micReady = $true
        wakeAudioPauseRequested = $false
        wakeAudioPaused = $false
        wakeCuePhase = "idle"
        audioStreamActive = $false
        speakerRunning = $false
        speakerReady = $true
        hostOperational = $true
        hostSpeechReady = $true
        hostSttHealthy = $true
        hostVoiceConfigured = $true
        resetReason = "software"
        resetReasonCode = 3
        bootCount = 1
        uptimeMs = 100000 + ($index * 2000)
        powerVbusMv = 4950
        powerVbusReportedMinMv = 4948
        chipTempC = 60.5
        displayMaxFrameUs = 24000
        powerForensicsSchema = "axp2101-v2"
        powerForensicsEnabled = $true
        powerForensicsIrqEnabled = $true
        powerForensicsBootStatusValid = $true
        powerForensicsBootEventMask = 0
        powerForensicsBootEvent = "none"
        powerForensicsBootProtective = $false
        powerForensicsRuntimeEvents = 0
        powerForensicsProtectiveEvents = 0
        powerForensicsReadFailures = 0
        powerForensicsClearFailures = 0
        pmicVbusLossEntries = 0
        vbusHardFloorEntries = 0
        powerReadFailures = 0
        pmicInputReadFailures = 0
        pmicConfigReadFailures = 0
        powerVsysReadFailures = 0
        chipTempReadFailures = 0
        wakeCapturesCompleted = $conversationCounter
        uplinkTurns = $conversationCounter
        playbackCompletions = $conversationCounter
        playbackErrors = 0
        compiledCamera = 1
        compiledCameraHostVision = 1
        cameraReady = $true
        cameraActive = $true
        cameraFrames = $index
        cameraHostFrameRequests = $index
      })
  }

  Write-Fixture (Join-Path $passRoot "candidate-manifest.json") ([ordered]@{
      sourceCommit = "a" * 40
      firmwareSha256 = $firmwareSha
      sourceArchiveSha256 = $sourceSha
      installation = [ordered]@{ confirmed = $true }
    })
  Write-Fixture (Join-Path $passRoot "host-runtime-manifest.json") ([ordered]@{
      schema = "stackchan.pc-brain-runtime.v1"
      generatedAt = $baseTime.ToString("o")
      sourceCommit = "a" * 40
      sourceRoot = [string]$RepoRoot
      sourceWorktreeClean = $true
      bridgePid = 4242
    })
  Copy-Item -LiteralPath $runnerPath -Destination (Join-Path $passRoot "runner.ps1")
  Copy-Item -LiteralPath $checkerPath -Destination (Join-Path $passRoot "checker.ps1")
  Write-Fixture (Join-Path $passRoot "preflight.json") ([ordered]@{ runId = $runId; sample = $records[0] })
  Write-Fixture (Join-Path $passRoot "run.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-run.v1"
      runId = $runId
      qualificationRoot = [string]$RepoRoot
      durationSeconds = 600
      pollMilliseconds = 2000
      pollTimeoutSeconds = 4
      expectedFirmwareSha256 = $firmwareSha
      firmwareSourceCommit = "a" * 40
      runnerSourceCommit = $RunnerCommit
      runnerSourceDirty = $false
      runnerSourceBlob = $RunnerBlob
      checkerSourceBlob = $CheckerBlob
      hostRuntimePid = 4242
      hostProcessStartedAt = $baseTime.AddSeconds(-5).ToString("o")
      hostRuntimeGeneratedAt = $baseTime.ToString("o")
      hostCommandLineSha256 = "d" * 64
      controlPolicy = "emergency_stop_only"
      ordinaryRobotMethods = @("GET /debug")
    })
  Write-Fixture (Join-Path $passRoot "polls.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-polls.v1"
      runId = $runId
      records = @($records | ForEach-Object { $_ })
    })
  Write-Fixture (Join-Path $passRoot "summary.json") ([ordered]@{
      schema = "stackchan.passive-no-motion-summary.v1"
      runId = $runId
      status = "pass"
      issues = @()
      durationSeconds = 600
      elapsedDurationMs = 600000
      maxPollGapMs = 2000
      firmwareSourceCommit = "a" * 40
      installedFirmwareSha256 = $firmwareSha
      runnerSourceCommit = $RunnerCommit
      runnerSourceCommitEnd = $RunnerCommit
      runnerSourceDirty = $false
      runnerSourceDirtyEnd = $false
      hostRuntimePid = 4242
      controlPolicy = "emergency_stop_only"
      ordinaryRobotMethods = @("GET /debug")
      records = 301
      okPolls = 301
      failedPolls = 0
      safetyStop = $null
      requireObservedTurn = $true
      requireCameraHostVision = $true
      fatalError = ""
    })
  Write-Seal $passRoot $runId $firmwarePath $sourcePath

  $pass = Invoke-Checker $passRoot $firmwareSha -RequireObservedTurn -RequireCameraHostVision
  if ($pass.exitCode -ne 0 -or $pass.json.status -ne "pass" -or $pass.json.failed -ne 0) {
    $failedIds = @($pass.json.checks | Where-Object { $_.status -eq "fail" } | ForEach-Object { $_.id }) -join ","
    throw "Expected complete passive packet to pass; failed=$failedIds"
  }

  $panicRoot = Join-Path $tempRoot "panic"
  Copy-Packet $passRoot $panicRoot
  $panicPolls = Get-Content -LiteralPath (Join-Path $panicRoot "polls.json") -Raw | ConvertFrom-Json
  foreach ($record in $panicPolls.records) { $record.resetReason = "panic"; $record.resetReasonCode = 4 }
  Write-Fixture (Join-Path $panicRoot "polls.json") $panicPolls
  Set-SummaryFailure $panicRoot "reset_reason_not_clean"
  Write-Seal $panicRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "panic" $panicRoot $firmwareSha "clean-reset"

  $motionRoot = Join-Path $tempRoot "motion-and-binding"
  Copy-Packet $passRoot $motionRoot
  $motionPolls = Get-Content -LiteralPath (Join-Path $motionRoot "polls.json") -Raw | ConvertFrom-Json
  $motionPolls.records[1].motionEnabled = $true
  $motionPolls.records[1].firmwareSha256 = "f" * 64
  Write-Fixture (Join-Path $motionRoot "polls.json") $motionPolls
  Set-SummaryFailure $motionRoot "motion_breach"
  Write-Seal $motionRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "simultaneous motion and binding" $motionRoot $firmwareSha "no-motion-authority"
  Assert-CheckerFailure "simultaneous motion and binding" $motionRoot $firmwareSha "per-poll-binding"

  $tamperRoot = Join-Path $tempRoot "tamper"
  Copy-Packet $passRoot $tamperRoot
  Add-Content -LiteralPath (Join-Path $tamperRoot "run.json") -Value " "
  Assert-CheckerFailure "post-seal tamper" $tamperRoot $firmwareSha "sealed-run.json"

  $runIdRoot = Join-Path $tempRoot "run-id"
  Copy-Packet $passRoot $runIdRoot
  $runIdPolls = Get-Content -LiteralPath (Join-Path $runIdRoot "polls.json") -Raw | ConvertFrom-Json
  $runIdPolls.runId = [guid]::NewGuid().ToString("N")
  Write-Fixture (Join-Path $runIdRoot "polls.json") $runIdPolls
  Set-SummaryFailure $runIdRoot "run_id_mismatch"
  Write-Seal $runIdRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "run id mismatch" $runIdRoot $firmwareSha "run-id"

  $preflightRoot = Join-Path $tempRoot "preflight-mismatch"
  Copy-Packet $passRoot $preflightRoot
  $preflightFixture = Get-Content -LiteralPath (Join-Path $preflightRoot "preflight.json") -Raw | ConvertFrom-Json
  $preflightFixture.sample.sequence = 99
  Write-Fixture (Join-Path $preflightRoot "preflight.json") $preflightFixture
  Set-SummaryFailure $preflightRoot "preflight_mismatch"
  Write-Seal $preflightRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "preflight mismatch" $preflightRoot $firmwareSha "preflight-record"

  $gapRoot = Join-Path $tempRoot "long-gap"
  Copy-Packet $passRoot $gapRoot
  $gapPolls = Get-Content -LiteralPath (Join-Path $gapRoot "polls.json") -Raw | ConvertFrom-Json
  for ($index = 150; $index -lt $gapPolls.records.Count; $index++) {
    $gapPolls.records[$index].elapsedMs = [int64]$gapPolls.records[$index].elapsedMs + 9000
  }
  Write-Fixture (Join-Path $gapRoot "polls.json") $gapPolls
  $gapSummary = Get-Content -LiteralPath (Join-Path $gapRoot "summary.json") -Raw | ConvertFrom-Json
  $gapSummary.status = "fail"
  $gapSummary.issues = @("poll_gap_exceeded")
  $gapSummary.elapsedDurationMs = 609000
  $gapSummary.maxPollGapMs = 11000
  Write-Fixture (Join-Path $gapRoot "summary.json") $gapSummary
  Write-Seal $gapRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "long observation gap" $gapRoot $firmwareSha "poll-monotonic"

  $boolRoot = Join-Path $tempRoot "boolean-coercion"
  Copy-Packet $passRoot $boolRoot
  $boolPolls = Get-Content -LiteralPath (Join-Path $boolRoot "polls.json") -Raw | ConvertFrom-Json
  $boolPolls.records[1].motionEnabled = "false"
  $boolPolls.records[2].appConfirmed = "true"
  Write-Fixture (Join-Path $boolRoot "polls.json") $boolPolls
  Set-SummaryFailure $boolRoot "invalid_boolean_types"
  Write-Seal $boolRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "authority boolean coercion" $boolRoot $firmwareSha "no-motion-authority"
  Assert-CheckerFailure "binding boolean coercion" $boolRoot $firmwareSha "per-poll-binding"

  $pollContractRoot = Join-Path $tempRoot "poll-contract"
  Copy-Packet $passRoot $pollContractRoot
  $pollRun = Get-Content -LiteralPath (Join-Path $pollContractRoot "run.json") -Raw | ConvertFrom-Json
  $pollRun.pollMilliseconds = 1000
  Write-Fixture (Join-Path $pollContractRoot "run.json") $pollRun
  Set-SummaryFailure $pollContractRoot "qualification_poll_contract_mismatch"
  Write-Seal $pollContractRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "qualification poll contract" $pollContractRoot $firmwareSha "poll-contract"

  $blobRoot = Join-Path $tempRoot "runner-blob"
  Copy-Packet $passRoot $blobRoot
  Add-Content -LiteralPath (Join-Path $blobRoot "runner.ps1") -Value "# post-copy mutation"
  Set-SummaryFailure $blobRoot "runner_blob_mismatch"
  Write-Seal $blobRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "runner source blob" $blobRoot $firmwareSha "runner-git-blobs"

  $powerRoot = Join-Path $tempRoot "power-event"
  Copy-Packet $passRoot $powerRoot
  $powerPolls = Get-Content -LiteralPath (Join-Path $powerRoot "polls.json") -Raw | ConvertFrom-Json
  $powerPolls.records[300].powerForensicsBootEventMask = 1
  $powerPolls.records[300].powerForensicsBootEvent = "vbus_loss"
  $powerPolls.records[300].powerForensicsRuntimeEvents = 1
  Write-Fixture (Join-Path $powerRoot "polls.json") $powerPolls
  Set-SummaryFailure $powerRoot "power_forensics_not_clean"
  Write-Seal $powerRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "power event" $powerRoot $firmwareSha "power-forensics-ready"
  Assert-CheckerFailure "power counter change" $powerRoot $firmwareSha "stable-powerForensicsRuntimeEvents"

  $dirtyRoot = Join-Path $tempRoot "dirty"
  Copy-Packet $passRoot $dirtyRoot
  $dirtyRun = Get-Content -LiteralPath (Join-Path $dirtyRoot "run.json") -Raw | ConvertFrom-Json
  $dirtyRun.runnerSourceDirty = $true
  Write-Fixture (Join-Path $dirtyRoot "run.json") $dirtyRun
  $dirtySummary = Get-Content -LiteralPath (Join-Path $dirtyRoot "summary.json") -Raw | ConvertFrom-Json
  $dirtySummary.runnerSourceDirty = $true
  $dirtySummary.status = "fail"
  $dirtySummary.issues = @("runner_source_dirty")
  Write-Fixture (Join-Path $dirtyRoot "summary.json") $dirtySummary
  Write-Seal $dirtyRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "dirty runner" $dirtyRoot $firmwareSha "runner-clean"

  $turnRoot = Join-Path $tempRoot "turn"
  Copy-Packet $passRoot $turnRoot
  $turnPolls = Get-Content -LiteralPath (Join-Path $turnRoot "polls.json") -Raw | ConvertFrom-Json
  foreach ($record in $turnPolls.records) {
    $record.wakeCapturesCompleted = 0
    $record.uplinkTurns = 0
    $record.playbackCompletions = 0
  }
  Write-Fixture (Join-Path $turnRoot "polls.json") $turnPolls
  Set-SummaryFailure $turnRoot "required_turn_not_observed"
  Write-Seal $turnRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "missing conversation lifecycle" $turnRoot $firmwareSha "conversation-lifecycle"

  $cameraRoot = Join-Path $tempRoot "camera"
  Copy-Packet $passRoot $cameraRoot
  $cameraPolls = Get-Content -LiteralPath (Join-Path $cameraRoot "polls.json") -Raw | ConvertFrom-Json
  foreach ($record in $cameraPolls.records) {
    $record.compiledCamera = 0
    $record.compiledCameraHostVision = 0
    $record.cameraReady = $false
    $record.cameraActive = $false
    $record.cameraFrames = 0
    $record.cameraHostFrameRequests = 0
  }
  Write-Fixture (Join-Path $cameraRoot "polls.json") $cameraPolls
  Set-SummaryFailure $cameraRoot "camera_host_vision_not_observed"
  Write-Seal $cameraRoot $runId $firmwarePath $sourcePath
  Assert-CheckerFailure "missing camera host vision" $cameraRoot $firmwareSha "camera-host-vision"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force
}

Write-Host "Passive no-motion evidence contract: PASS"
