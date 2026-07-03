param(
  [string]$EvidenceRoot = "",
  [string]$BaselineReport = "",
  [string]$ReportPath = "",
  [switch]$NoWriteReport
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $latestEvidence = Get-ChildItem -Directory -Path "output/hardware-evidence" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if ($null -eq $latestEvidence) {
    throw "No evidence packet found under output/hardware-evidence. Pass -EvidenceRoot explicitly."
  }
  $EvidenceRoot = $latestEvidence.FullName
}

if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
  throw "Missing evidence packet: $EvidenceRoot"
}

$evidencePath = (Resolve-Path $EvidenceRoot).Path
$checks = New-Object System.Collections.Generic.List[object]

function Join-EvidencePath {
  param([string]$RelativePath)
  return Join-Path $evidencePath ($RelativePath -replace "/", "\")
}

function Add-Check {
  param(
    [ValidateSet("pass", "pending", "fail")]
    [string]$Status,
    [string]$Scope,
    [string]$Name,
    [string]$Detail
  )

  $checks.Add([ordered]@{
      status = $Status
      scope = $Scope
      name = $Name
      detail = $Detail
    }) | Out-Null
}

function Read-EvidenceText {
  param([string]$RelativePath)

  $path = Join-EvidencePath $RelativePath
  if (-not (Test-Path -LiteralPath $path)) {
    return $null
  }
  return Get-Content -LiteralPath $path -Raw
}

function Test-LogPattern {
  param(
    [string]$RelativePath,
    [string]$Pattern,
    [string]$Name,
    [string]$Detail
  )

  $text = Read-EvidenceText $RelativePath
  if ($null -eq $text) {
    Add-Check -Status "pending" -Scope $RelativePath -Name $Name -Detail "Missing log. $Detail"
    return
  }

  if ($text -notmatch $Pattern) {
    Add-Check -Status "fail" -Scope $RelativePath -Name $Name -Detail "Log exists but does not contain the expected marker. $Detail"
    return
  }

  Add-Check -Status "pass" -Scope $RelativePath -Name $Name -Detail $Detail
}

function Get-Scenario {
  param(
    [object]$Summary,
    [string]$Name
  )

  $matches = @($Summary.scenarios | Where-Object { [string]$_.scenario -eq $Name })
  if ($matches.Count -lt 1) {
    return $null
  }
  return $matches[0]
}

function Test-TelemetryAtLeast {
  param(
    [object]$Scenario,
    [string]$Field,
    [int]$Minimum,
    [string]$Name
  )

  $actual = [int]$Scenario.telemetry.$Field
  if ($actual -lt $Minimum) {
    Add-Check -Status "fail" -Scope "simulation/$($Scenario.scenario)" -Name $Name -Detail "$Field expected >= $Minimum, got $actual."
    return
  }
  Add-Check -Status "pass" -Scope "simulation/$($Scenario.scenario)" -Name $Name -Detail "$Field=$actual."
}

function Test-TelemetryEquals {
  param(
    [object]$Scenario,
    [string]$Field,
    [object]$Expected,
    [string]$Name
  )

  $actual = $Scenario.telemetry.$Field
  if ([string]$actual -ne [string]$Expected) {
    Add-Check -Status "fail" -Scope "simulation/$($Scenario.scenario)" -Name $Name -Detail "$Field expected $Expected, got $actual."
    return
  }
  Add-Check -Status "pass" -Scope "simulation/$($Scenario.scenario)" -Name $Name -Detail "$field=$actual."
}

function Test-BaselineScenario {
  param(
    [object]$Summary,
    [string]$Name
  )

  $scenario = Get-Scenario -Summary $Summary -Name $Name
  if ($null -eq $scenario) {
    Add-Check -Status "fail" -Scope "simulation" -Name "$Name scenario present" -Detail "Baseline report is missing the required simulator scenario."
    return $null
  }
  if ([string]$scenario.status -ne "pass") {
    Add-Check -Status "fail" -Scope "simulation/$Name" -Name "$Name scenario pass" -Detail "Scenario status is $($scenario.status); issues: $(@($scenario.issues) -join ', ')."
  } else {
    Add-Check -Status "pass" -Scope "simulation/$Name" -Name "$Name scenario pass" -Detail "Scenario passed in the no-hardware baseline."
  }
  return $scenario
}

function Test-RuntimeCounters {
  param(
    [string]$RelativePath,
    [string]$Text
  )

  if ($null -eq $Text) {
    return
  }

  $runtimeLines = @([regex]::Matches($Text, "(?m)^\s*(?:\[[^\]]+\]\s+<\s+)?\[runtime\].*$") | ForEach-Object { $_.Value })
  if ($runtimeLines.Count -lt 1) {
    Add-Check -Status "pending" -Scope $RelativePath -Name "runtime status line" -Detail "No [runtime] line was captured, so bridge counters cannot be compared yet."
    return
  }

  Add-Check -Status "pass" -Scope $RelativePath -Name "runtime status line" -Detail "Captured $($runtimeLines.Count) runtime status line(s)."

  foreach ($field in @("bridge_parse_errors", "bridge_timeouts", "bridge_downlink_errors", "bridge_downlink_playback_errors")) {
    $values = @([regex]::Matches($Text, "\b$([regex]::Escape($field))=(\d+)") | ForEach-Object { [int]$_.Groups[1].Value })
    if ($values.Count -lt 1) {
      Add-Check -Status "pending" -Scope $RelativePath -Name "$field captured" -Detail "Runtime line did not include $field."
      continue
    }
    $maxValue = ($values | Measure-Object -Maximum).Maximum
    if ($maxValue -gt 0) {
      Add-Check -Status "fail" -Scope $RelativePath -Name "$field remains zero" -Detail "$field reached $maxValue; simulator baseline expects zero for this comparison."
    } else {
      Add-Check -Status "pass" -Scope $RelativePath -Name "$field remains zero" -Detail "$field stayed at 0."
    }
  }
}

if ([string]::IsNullOrWhiteSpace($BaselineReport)) {
  $BaselineReport = Join-EvidencePath "simulation/hardware-sim/latest/hardware_simulation.json"
} elseif (-not [System.IO.Path]::IsPathRooted($BaselineReport)) {
  $BaselineReport = Join-EvidencePath $BaselineReport
}

$baselineSummary = $null
if (-not (Test-Path -LiteralPath $BaselineReport)) {
  Add-Check -Status "pending" -Scope "simulation" -Name "baseline report present" -Detail "Run RUN_HARDWARE_SIM_BASELINE.cmd before comparing hardware logs."
} else {
  $baselineSummary = Get-Content -LiteralPath $BaselineReport -Raw | ConvertFrom-Json
  if ([string]$baselineSummary.schema -ne "stackchan.hardware-sim.v1") {
    Add-Check -Status "fail" -Scope "simulation" -Name "baseline schema" -Detail "Unexpected simulator schema: $($baselineSummary.schema)."
  } else {
    Add-Check -Status "pass" -Scope "simulation" -Name "baseline schema" -Detail "Simulator schema is stackchan.hardware-sim.v1."
  }
  if ([string]$baselineSummary.status -ne "pass") {
    Add-Check -Status "fail" -Scope "simulation" -Name "baseline status" -Detail "Simulator summary status is $($baselineSummary.status)."
  } else {
    Add-Check -Status "pass" -Scope "simulation" -Name "baseline status" -Detail "All default simulator scenarios passed."
  }

  $arrival = Test-BaselineScenario -Summary $baselineSummary -Name "arrival-rehearsal"
  if ($null -ne $arrival) {
    Test-TelemetryAtLeast -Scenario $arrival -Field "display_frames" -Minimum 1 -Name "virtual display rendered"
    Test-TelemetryAtLeast -Scenario $arrival -Field "core_inputs" -Minimum 5 -Name "virtual CoreS3 inputs covered"
    Test-TelemetryAtLeast -Scenario $arrival -Field "bridge_downlink_playback_starts" -Minimum 1 -Name "virtual PCM16 playback started"
    Test-TelemetryAtLeast -Scenario $arrival -Field "bridge_downlink_playback_bytes" -Minimum 5000 -Name "virtual PCM16 bytes played"
    Test-TelemetryAtLeast -Scenario $arrival -Field "power_cycles" -Minimum 1 -Name "virtual power-cycle recovery covered"
    Test-TelemetryEquals -Scenario $arrival -Field "bridge_state" -Expected "Ready" -Name "virtual bridge returns ready"
  }

  $audioLoop = Test-BaselineScenario -Summary $baselineSummary -Name "conversation-audio-loop"
  if ($null -ne $audioLoop) {
    Test-TelemetryAtLeast -Scenario $audioLoop -Field "bridge_upload_audio_bytes" -Minimum 6400 -Name "virtual mic upload covered"
    Test-TelemetryAtLeast -Scenario $audioLoop -Field "bridge_stt_runs" -Minimum 1 -Name "virtual STT path covered"
    Test-TelemetryAtLeast -Scenario $audioLoop -Field "bridge_downlink_playback_bytes" -Minimum 5000 -Name "virtual TTS playback covered"
    Test-TelemetryEquals -Scenario $audioLoop -Field "bridge_state" -Expected "Ready" -Name "virtual audio loop returns ready"
  }

  $recovery = Test-BaselineScenario -Summary $baselineSummary -Name "bridge-kill-recovery"
  if ($null -ne $recovery) {
    Test-TelemetryAtLeast -Scenario $recovery -Field "bridge_recoveries" -Minimum 1 -Name "virtual bridge recovery covered"
    Test-TelemetryAtLeast -Scenario $recovery -Field "offline_fallback_prompts" -Minimum 1 -Name "virtual offline fallback covered"
  }
}

Test-LogPattern "logs/display_only_serial.log" "\[boot\]\s+stackchan_alive\s+mode=display_only\s+serial=v1" "hardware display boot" "Real device boot marker matches the display-only firmware."
Test-LogPattern "logs/display_only_serial.log" "\[display\]\s+M5 display renderer ready" "hardware display ready" "Real device reports the display renderer."
Test-LogPattern "logs/display_only_serial.log" "\[display\]\s+frame_ms_avg=.*fps_window=.*frame_budget_us=33333.*slow_frames=\d+" "hardware display frame budget" "Real device emits the same frame-budget telemetry shape as the simulator target."
Test-LogPattern "logs/display_only_serial.log" "\[face\]\s+mode=\d+\s+blink_count=\d+\s+saccade_count=\d+.*gesture_active=\d+\s+speech_active=\d+\s+speech_env=" "hardware face life telemetry" "Blink, saccade, gesture, and speech envelope counters are visible."
Test-LogPattern "logs/display_only_serial.log" "\[system\]\s+heap_free=\d+\s+heap_min=\d+\s+stack_loop_hwm=\d+.*stack_face_hwm=\d+" "hardware system telemetry" "Runtime health is present for real-hardware comparison."

Test-LogPattern "logs/speech_mouth_demo_serial.log" "\[demo\]\s+>\s+speech\s+[0-9]" "hardware speech envelope sent" "Speech-mouth demo streamed envelope frames."
Test-LogPattern "logs/speech_mouth_demo_serial.log" "\[demo\]\s+Speech mouth demo complete\." "hardware speech envelope completed" "Speech-mouth demo returned to clear/complete."

Test-LogPattern "logs/speak_all_intents_serial.log" "\[speak-all\]\s+>\s+speak\s+boot\b" "hardware packaged prompts started" "Speak-all-intents sent the first packaged prompt."
Test-LogPattern "logs/speak_all_intents_serial.log" "\[audio_out\]\s+seq=\d+\s+source=packaged_prompt\s+prompt_id=" "hardware audio output handoff" "Packaged prompt handoff reached audio_out telemetry."
Test-LogPattern "logs/speak_all_intents_serial.log" "\[speak-all\]\s+Speak-all-intents demo complete\." "hardware packaged prompts completed" "Speak-all-intents completed."

$bridgeReplayText = Read-EvidenceText "logs/bridge_replay_serial.log"
if ($null -eq $bridgeReplayText) {
  Add-Check -Status "pending" -Scope "logs/bridge_replay_serial.log" -Name "hardware bridge replay" -Detail "Run RUN_BRIDGE_REPLAY.cmd to compare the text bridge parser against the baseline."
} else {
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge-replay\]\s+>\s+bridge\s+hello\b" "bridge replay sent hello" "Replay drove the P7 bridge bench command path."
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge\]\s+type=session_ready\b" "bridge replay session ready" "Firmware accepted the bridge hello and emitted session_ready."
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge\]\s+type=response_start\b" "bridge replay response start" "Firmware accepted the response_start frame."
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge\]\s+type=audio\b" "bridge replay mouth audio frames" "Firmware accepted speech-envelope audio frames."
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge\]\s+type=response_end\b" "bridge replay response end" "Firmware returned through response_end."
  Test-LogPattern "logs/bridge_replay_serial.log" "\[bridge-replay\]\s+Bridge replay demo complete\." "bridge replay completed" "The bridge replay helper finished cleanly."
  Test-RuntimeCounters -RelativePath "logs/bridge_replay_serial.log" -Text $bridgeReplayText
}

$checkArray = @($checks.ToArray())
$passCount = @($checkArray | Where-Object { $_.status -eq "pass" }).Count
$pendingCount = @($checkArray | Where-Object { $_.status -eq "pending" }).Count
$failCount = @($checkArray | Where-Object { $_.status -eq "fail" }).Count

$status = "pass"
if ($failCount -gt 0) {
  $status = "fail"
} elseif ($pendingCount -gt 0) {
  $status = "pending"
}

$nextAction = "Continue the hardware evidence flow."
$nextCommand = "RUN_PROGRESS_CHECK.cmd"
if ($status -eq "fail") {
  $nextAction = "Inspect SIM_HARDWARE_COMPARE.md and fix the failed hardware-vs-simulator marker before promotion review."
  $nextCommand = "RUN_SIM_HARDWARE_COMPARE.cmd"
} elseif ($status -eq "pending") {
  $missingBaseline = @($checkArray | Where-Object { $_.scope -eq "simulation" -and $_.status -eq "pending" }).Count -gt 0
  if ($missingBaseline) {
    $nextAction = "Capture the no-hardware baseline before comparing hardware logs."
    $nextCommand = "RUN_HARDWARE_SIM_BASELINE.cmd"
  } else {
    $nextAction = "Run the missing hardware demo logs, then re-run the simulator comparison."
    $nextCommand = "RUN_DISPLAY_ONLY.cmd; RUN_SPEECH_MOUTH_DEMO.cmd; RUN_SPEAK_ALL_INTENTS.cmd; RUN_BRIDGE_REPLAY.cmd; RUN_SIM_HARDWARE_COMPARE.cmd"
  }
}

$generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$report = [ordered]@{
  schema = "stackchan.hardware-sim-compare.v1"
  evidenceRoot = $evidencePath
  generatedUtc = $generatedUtc
  status = $status
  baselineReport = $BaselineReport
  nextAction = $nextAction
  nextCommand = $nextCommand
  passCount = $passCount
  pendingCount = $pendingCount
  failCount = $failCount
  checks = $checkArray
}

$jsonFullPath = ""
$markdownFullPath = ""
if (-not $NoWriteReport) {
  if ([string]::IsNullOrWhiteSpace($ReportPath)) {
    $jsonFullPath = Join-EvidencePath "SIM_HARDWARE_COMPARE.json"
  } elseif ([System.IO.Path]::IsPathRooted($ReportPath)) {
    $jsonFullPath = $ReportPath
  } else {
    $jsonFullPath = Join-EvidencePath $ReportPath
  }
  $jsonDir = Split-Path -Parent $jsonFullPath
  if (-not [string]::IsNullOrWhiteSpace($jsonDir)) {
    New-Item -ItemType Directory -Force -Path $jsonDir | Out-Null
  }
  $markdownFullPath = [System.IO.Path]::ChangeExtension($jsonFullPath, ".md")

  $report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonFullPath -Encoding UTF8

  $markdown = @(
    "# Stackchan Sim/Hardware Comparison",
    "",
    "- Schema: stackchan.hardware-sim-compare.v1",
    "- Generated UTC: $generatedUtc",
    "- Status: $status",
    "- Evidence root: $evidencePath",
    "- Baseline report: $BaselineReport",
    "- Next action: $nextAction",
    "- Next command: ``$nextCommand``",
    "- Passing checks: $($report.passCount)",
    "- Pending checks: $($report.pendingCount)",
    "- Failed checks: $($report.failCount)",
    "",
    "This is an advisory comparison only. It does not replace real display, speaker, microphone, camera, touch, IMU, servo, heat, power, soak, or promotion evidence.",
    "",
    "## Checks"
  )
  foreach ($check in $checkArray) {
    $markdown += "- [$($check.status)] $($check.scope) - $($check.name): $($check.detail)"
  }
  $markdown | Set-Content -Path $markdownFullPath -Encoding UTF8
}

Write-Host "Hardware simulation comparison:"
Write-Host $evidencePath
Write-Host "Status: $status"
if (-not $NoWriteReport) {
  Write-Host "Report:"
  Write-Host "  $markdownFullPath"
  Write-Host "  $jsonFullPath"
}
Write-Host "Next command: $nextCommand"

if ($status -eq "fail") {
  exit 1
}
if ($status -eq "pending") {
  exit 2
}
exit 0
