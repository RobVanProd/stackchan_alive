param(
  [string]$SummaryJsonPath = "",
  [int]$MinDurationSeconds = 28800,
  [double]$MinMotionSampleRatio = 0.95,
  [double]$MinMotionUnsuppressedSampleRatio = 0,
  [int]$MaxFailedPolls = -1,
  [double]$MaxFailedPollRatio = -1,
  [int]$MaxConsecutiveFailedPolls = 1,
  [int]$MinPowerVbusMv = 0,
  [int]$MinPowerVbusReportedMv = 0,
  [int]$MaxFrameUs = 50000,
  [int]$MaxSlowFrames = 120,
  [switch]$NoMotionProfile,
  [switch]$RequirePowerForensics,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Detail
  )
  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Get-IntValue {
  param($Object, [string]$Name, [int64]$DefaultValue = 0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int64]$property.Value
}

function Get-DoubleValue {
  param($Object, [string]$Name, [double]$DefaultValue = 0.0)
  if ($null -eq $Object) { return $DefaultValue }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [double]$property.Value
}

function Has-StrictFlag {
  param($Summary, [string]$Name)
  if ($null -eq $Summary -or $null -eq $Summary.strict) { return $false }
  $property = $Summary.strict.PSObject.Properties[$Name]
  return $null -ne $property -and [bool]$property.Value
}

function Get-StrictDoubleValue {
  param($Summary, [string]$Name, [double]$DefaultValue = 0.0)
  if ($null -eq $Summary -or $null -eq $Summary.strict) { return $DefaultValue }
  $property = $Summary.strict.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [double]$property.Value
}

function Get-StrictIntValue {
  param($Summary, [string]$Name, [int64]$DefaultValue = 0)
  if ($null -eq $Summary -or $null -eq $Summary.strict) { return $DefaultValue }
  $property = $Summary.strict.PSObject.Properties[$Name]
  if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
  return [int64]$property.Value
}

if ([string]::IsNullOrWhiteSpace($SummaryJsonPath)) {
  $candidates = Get-ChildItem -Path "output\pc-brain" -Recurse -Filter "summary.json" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match "full-system-soak|warm-rocm" } |
    Sort-Object LastWriteTime -Descending
  if ($candidates.Count -gt 0) {
    $SummaryJsonPath = $candidates[0].FullName
  }
}

$checks = @()
$summary = $null

if ([string]::IsNullOrWhiteSpace($SummaryJsonPath)) {
  Add-Check "summary-json" "pending" "Pass -SummaryJsonPath or place a full-system soak summary.json under output\pc-brain."
} elseif (-not (Test-Path -LiteralPath $SummaryJsonPath -PathType Leaf)) {
  Add-Check "summary-json" "fail" "Missing summary JSON: $SummaryJsonPath"
} else {
  Add-Check "summary-json" "pass" "Found summary JSON: $SummaryJsonPath"
  try {
    $summary = Get-Content -LiteralPath $SummaryJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "summary-json-parse" "fail" "Summary JSON is invalid: $($_.Exception.Message)"
  }
}

if ($summary) {
  Add-Check "schema" ($(if ($summary.schema -eq "stackchan.full-system-soak-summary.v1") { "pass" } else { "fail" })) "schema=$($summary.schema)"
  Add-Check "summary-status" ($(if ($summary.status -eq "pass") { "pass" } else { "fail" })) "status=$($summary.status)"
  $issues = @($summary.issues)
  Add-Check "summary-issues" ($(if ($issues.Count -eq 0) { "pass" } else { "fail" })) "issues=$($issues -join ', ')"

  $duration = Get-IntValue $summary "durationSeconds" 0
  Add-Check "duration" ($(if ($duration -ge $MinDurationSeconds) { "pass" } else { "fail" })) "durationSeconds=$duration min=$MinDurationSeconds"

  $records = Get-IntValue $summary "records" 0
  $okPolls = Get-IntValue $summary "okPolls" 0
  $failedPolls = Get-IntValue $summary "failedPolls" 0
  $failedPollRatio = Get-DoubleValue $summary "failedPollRatio" $(if ($records -gt 0) { $failedPolls / [double]$records } else { 0.0 })
  Add-Check "records" ($(if ($records -gt 0 -and $okPolls -gt 0 -and ($okPolls + $failedPolls) -eq $records) { "pass" } else { "fail" })) "records=$records okPolls=$okPolls failedPolls=$failedPolls"
  $effectiveMaxFailedPolls = $MaxFailedPolls
  if ($effectiveMaxFailedPolls -lt 0) {
    $effectiveMaxFailedPolls = Get-StrictIntValue $summary "maxFailedPolls" 0
  }
  $failedPollsPassed = $effectiveMaxFailedPolls -le 0 -or $failedPolls -le $effectiveMaxFailedPolls
  Add-Check "failed-polls" ($(if ($failedPollsPassed) { "pass" } else { "fail" })) "failedPolls=$failedPolls max=$(if ($effectiveMaxFailedPolls -gt 0) { $effectiveMaxFailedPolls } else { 'disabled' })"
  $effectiveMaxFailedPollRatio = $MaxFailedPollRatio
  if ($effectiveMaxFailedPollRatio -lt 0) {
    $effectiveMaxFailedPollRatio = Get-StrictDoubleValue $summary "maxFailedPollRatio" 0.0
  }
  if ($effectiveMaxFailedPollRatio -gt 0) {
    Add-Check "failed-poll-ratio" ($(if ($failedPollRatio -le $effectiveMaxFailedPollRatio) { "pass" } else { "fail" })) "failedPollRatio=$failedPollRatio max=$effectiveMaxFailedPollRatio"
  }
  $observedMaxConsecutiveFailedPolls = Get-IntValue $summary "maxConsecutiveFailedPolls" 0
  Add-Check "consecutive-failed-polls" ($(if ($observedMaxConsecutiveFailedPolls -le $MaxConsecutiveFailedPolls) { "pass" } else { "fail" })) "maxConsecutiveFailedPolls=$observedMaxConsecutiveFailedPolls max=$MaxConsecutiveFailedPolls"

  if ($NoMotionProfile) {
    $requiresMotion = Has-StrictFlag $summary "requireMotion"
    Add-Check "strict-requireMotion" ($(if (-not $requiresMotion) { "pass" } else { "fail" })) "requireMotion=$requiresMotion expected=False"
    Add-Check "strict-requireNoMotionTimeouts" "pass" "No-motion profile verifies the observed timeout count directly."
    Add-Check "strict-requireMotionTelemetry" "pass" "No-motion profile verifies observed motion telemetry coverage directly."
  } else {
    foreach ($flag in @("requireMotion", "requireNoMotionTimeouts", "requireMotionTelemetry")) {
      Add-Check "strict-$flag" ($(if (Has-StrictFlag $summary $flag) { "pass" } else { "fail" })) "$flag=$((Has-StrictFlag $summary $flag))"
    }
  }

  foreach ($flag in @(
      "requireBridgeSocket",
      "requireWakeReady",
      "requireMicReady",
      "requireSpeakerReady",
      "requireRvcWorker"
    )) {
    Add-Check "strict-$flag" ($(if (Has-StrictFlag $summary $flag) { "pass" } else { "fail" })) "$flag=$((Has-StrictFlag $summary $flag))"
  }

  $motionSamples = Get-IntValue $summary "motionSamples" 0
  $motionRatio = Get-DoubleValue $summary "motionSampleRatio" 0.0
  if ($NoMotionProfile) {
    Add-Check "motion-samples" ($(if ($motionSamples -eq 0 -and $motionRatio -eq 0) { "pass" } else { "fail" })) "motionSamples=$motionSamples ratio=$motionRatio expected=0"
  } else {
    Add-Check "motion-samples" ($(if ($motionSamples -gt 0 -and $motionRatio -ge $MinMotionSampleRatio) { "pass" } else { "fail" })) "motionSamples=$motionSamples ratio=$motionRatio min=$MinMotionSampleRatio"
  }
  $effectiveMinUnsuppressedRatio = $MinMotionUnsuppressedSampleRatio
  if ($effectiveMinUnsuppressedRatio -le 0) {
    $effectiveMinUnsuppressedRatio = Get-StrictDoubleValue $summary "minMotionUnsuppressedSampleRatio" 0.0
  }
  if (-not $NoMotionProfile -and $effectiveMinUnsuppressedRatio -gt 0) {
    $motionUnsuppressedSamples = Get-IntValue $summary "motionUnsuppressedSamples" 0
    $motionUnsuppressedRatio = Get-DoubleValue $summary "motionUnsuppressedSampleRatio" 0.0
    Add-Check "motion-unsuppressed-samples" ($(if ($motionUnsuppressedSamples -gt 0 -and $motionUnsuppressedRatio -ge $effectiveMinUnsuppressedRatio) { "pass" } else { "fail" })) "motionUnsuppressedSamples=$motionUnsuppressedSamples ratio=$motionUnsuppressedRatio min=$effectiveMinUnsuppressedRatio"
  }
  $motionTelemetrySamples = Get-IntValue $summary "motionTelemetrySamples" 0
  Add-Check "motion-telemetry" ($(if ($motionTelemetrySamples -eq $okPolls -and $okPolls -gt 0) { "pass" } else { "fail" })) "motionTelemetrySamples=$motionTelemetrySamples okPolls=$okPolls"
  $maxMotionSessionTimeouts = Get-IntValue $summary "maxMotionSessionTimeouts" 0
  Add-Check "motion-timeouts" ($(if ($maxMotionSessionTimeouts -eq 0) { "pass" } else { "fail" })) "maxMotionSessionTimeouts=$maxMotionSessionTimeouts"

  foreach ($field in @(
      @{ name = "bridgeReadySamples"; id = "bridge-ready" },
      @{ name = "bridgeHealthySamples"; id = "bridge-healthy" },
      @{ name = "networkConnectedSamples"; id = "network-connected" },
      @{ name = "socketPresentSamples"; id = "bridge-socket" },
      @{ name = "wakeReadySamples"; id = "wake-ready" },
      @{ name = "speakerReadySamples"; id = "speaker-ready" }
    )) {
    $value = Get-IntValue $summary $field.name 0
    $requiredCount = if ($field.id -eq "bridge-ready") { 0 } else { $okPolls }
    $passed = if ($field.id -eq "bridge-ready") { $value -gt 0 } else { $value -ge $requiredCount -and $okPolls -gt 0 }
    Add-Check $field.id ($(if ($passed) { "pass" } else { "fail" })) "$($field.name)=$value required=$requiredCount okPolls=$okPolls"
  }

  $micRequiredSamples = Get-IntValue $summary "micReadyRequiredSamples" $okPolls
  $micRequiredReadySamples = Get-IntValue $summary "micReadyRequiredReadySamples" (Get-IntValue $summary "micReadySamples" 0)
  $micPassed = $micRequiredSamples -gt 0 -and $micRequiredReadySamples -ge $micRequiredSamples
  Add-Check "mic-ready" ($(if ($micPassed) { "pass" } else { "fail" })) "micReadyRequiredReadySamples=$micRequiredReadySamples required=$micRequiredSamples rawMicReadySamples=$((Get-IntValue $summary "micReadySamples" 0)) okPolls=$okPolls"

  $rvcPolls = Get-IntValue $summary "rvcWorkerPolls" 0
  $rvcReady = Get-IntValue $summary "rvcWorkerReadySamples" 0
  Add-Check "rvc-worker" ($(if ($rvcPolls -gt 0 -and $rvcReady -eq $rvcPolls) { "pass" } else { "fail" })) "rvcWorkerReadySamples=$rvcReady rvcWorkerPolls=$rvcPolls"

  $effectiveMinPowerVbusReportedMv = $MinPowerVbusReportedMv
  if ($effectiveMinPowerVbusReportedMv -le 0) {
    $effectiveMinPowerVbusReportedMv = Get-StrictIntValue $summary "minPowerVbusReportedMv" 0
  }
  if ($effectiveMinPowerVbusReportedMv -gt 0) {
    $minPowerVbusReportedMv = Get-IntValue $summary "minPowerVbusReportedMv" 0
    Add-Check "power-vbus-reported-floor" ($(if ($minPowerVbusReportedMv -ge $effectiveMinPowerVbusReportedMv) { "pass" } else { "fail" })) "minPowerVbusReportedMv=$minPowerVbusReportedMv min=$effectiveMinPowerVbusReportedMv"
  }
  $effectiveMinPowerVbusMv = $MinPowerVbusMv
  if ($effectiveMinPowerVbusMv -le 0) {
    $effectiveMinPowerVbusMv = Get-StrictIntValue $summary "minPowerVbusMv" 0
  }
  if ($effectiveMinPowerVbusMv -gt 0) {
    $minPowerVbusMv = Get-IntValue $summary "minPowerVbusMv" 0
    Add-Check "power-vbus-sample-floor" ($(if ($minPowerVbusMv -ge $effectiveMinPowerVbusMv) { "pass" } else { "fail" })) "minPowerVbusMv=$minPowerVbusMv min=$effectiveMinPowerVbusMv"
  }
  if (Has-StrictFlag $summary "requireNoNewHardFloorEvents") {
    Add-Check "strict-requireNoNewHardFloorEvents" "pass" "requireNoNewHardFloorEvents=True"
    $hardFloorBaseline = Get-IntValue $summary "powerVbusHardFloorEntriesBaseline" -1
    $hardFloorLatest = Get-IntValue $summary "latestPowerVbusHardFloorEntries" -1
    $hardFloorNew = Get-IntValue $summary "newPowerVbusHardFloorEntries" -1
    $hardFloorPassed = $hardFloorBaseline -ge 0 -and $hardFloorLatest -ge 0 -and
      $hardFloorLatest -eq $hardFloorBaseline -and $hardFloorNew -eq 0
    Add-Check "power-vbus-hard-floor-events" ($(if ($hardFloorPassed) { "pass" } else { "fail" })) "baseline=$hardFloorBaseline latest=$hardFloorLatest new=$hardFloorNew"
  }

  $summaryRequiresPowerForensics = Has-StrictFlag $summary "requirePowerForensics"
  if ($RequirePowerForensics) {
    Add-Check "strict-requirePowerForensics" ($(if ($summaryRequiresPowerForensics) { "pass" } else { "fail" })) "requirePowerForensics=$summaryRequiresPowerForensics"
  }
  if ($RequirePowerForensics -or $summaryRequiresPowerForensics) {
    $latestForensics = $summary.latestPowerForensics
    $forensicsArmed = $null -ne $latestForensics -and
      [bool]$latestForensics.power_forensics_enabled -and
      [bool]$latestForensics.power_forensics_irq_enable_succeeded -and
      [bool]$latestForensics.power_forensics_boot_status_valid
    Add-Check "power-forensics-armed" ($(if ($forensicsArmed) { "pass" } else { "fail" })) "enabled=$($latestForensics.power_forensics_enabled) irq=$($latestForensics.power_forensics_irq_enable_succeeded) bootStatusValid=$($latestForensics.power_forensics_boot_status_valid)"
    $newRuntimeEvents = Get-IntValue $summary "newPowerForensicsRuntimeEvents" -1
    $newProtectiveEvents = Get-IntValue $summary "newPowerForensicsProtectiveEvents" -1
    Add-Check "power-forensics-runtime-events" ($(if ($newRuntimeEvents -eq 0) { "pass" } else { "fail" })) "newRuntimeEvents=$newRuntimeEvents expected=0"
    Add-Check "power-forensics-protective-events" ($(if ($newProtectiveEvents -eq 0) { "pass" } else { "fail" })) "newProtectiveEvents=$newProtectiveEvents expected=0"
  }

  $maxObservedFrameUs = Get-IntValue $summary "maxFrameUs" 0
  Add-Check "display-frame-time" ($(if ($maxObservedFrameUs -gt 0 -and $maxObservedFrameUs -le $MaxFrameUs) { "pass" } else { "fail" })) "maxFrameUs=$maxObservedFrameUs max=$MaxFrameUs"
  $maxObservedSlowFrames = Get-IntValue $summary "maxSlowFrames" 0
  Add-Check "display-slow-frames" ($(if ($maxObservedSlowFrames -le $MaxSlowFrames) { "pass" } else { "fail" })) "maxSlowFrames=$maxObservedSlowFrames max=$MaxSlowFrames"

  $refreshes = Get-IntValue $summary "motionRefreshes" 0
  $refreshFailures = Get-IntValue $summary "motionRefreshFailures" 0
  Add-Check "motion-refreshes" ($(if ($refreshFailures -eq 0) { "pass" } else { "fail" })) "motionRefreshes=$refreshes motionRefreshFailures=$refreshFailures"
  if (Has-StrictFlag $summary "requireVerifiedMotionStop") {
    $motionStopVerified = $null -ne $summary.PSObject.Properties["motionStopVerified"] -and
      [bool]$summary.motionStopVerified
    Add-Check "motion-stop-verified" ($(if ($motionStopVerified) { "pass" } else { "fail" })) "motionStopVerified=$motionStopVerified attempts=$((Get-IntValue $summary 'motionStopAttempts' 0))"
  }
  Add-Check "fatal-error" ($(if ([string]::IsNullOrWhiteSpace([string]$summary.fatalError)) { "pass" } else { "fail" })) "fatalError=$($summary.fatalError)"
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$pending = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failed.Count -gt 0) {
  "full-system-soak-not-ready"
} elseif ($pending.Count -gt 0) {
  "pending-full-system-soak-evidence"
} else {
  "full-system-soak-ready"
}

$result = [ordered]@{
  schema = "stackchan.full-system-soak-evidence-check.v1"
  profile = $(if ($NoMotionProfile) { "no-motion" } else { "full-system" })
  status = $status
  summaryJsonPath = $SummaryJsonPath
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  pending = $pending.Count
  checks = $checks
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-system soak evidence: $status"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0 -or ($RequireReady -and $status -ne "full-system-soak-ready")) {
  exit 1
}
