param(
  [string]$Root = "",
  [string]$DiagnosticsExportPath = "output/android-speech/latest/ANDROID_DIAGNOSTICS_EXPORT.json",
  [string]$LogcatPath = "output/android-speech/latest/android_speech_logcat.txt",
  [string]$RobotLogPath = "output/android-speech/latest/robot_speech_serial.log",
  [string]$ReviewPath = "output/android-speech/latest/ANDROID_SPEECH_REVIEW.md",
  [switch]$WriteTemplate,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

Set-Location $Root

foreach ($name in @("DiagnosticsExportPath", "LogcatPath", "RobotLogPath", "ReviewPath")) {
  $value = Get-Variable -Name $name -ValueOnly
  if (-not [System.IO.Path]::IsPathRooted($value)) {
    Set-Variable -Name $name -Value (Join-Path $Root $value)
  }
}

$checks = @()

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Convert-ToRelativePath {
  param([string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $rootFull = [System.IO.Path]::GetFullPath([string]$Root)
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($rootFull.Length).TrimStart("\", "/") -replace "\\", "/"
  }
  return $full -replace "\\", "/"
}

function Get-Field {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) {
    return $null
  }
  $property = $Object.PSObject.Properties[$Name]
  if ($null -eq $property) {
    return $null
  }
  return $property.Value
}

function Test-HasField {
  param(
    [object]$Object,
    [string]$Name
  )

  return $null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]
}

function Test-TrueField {
  param(
    [object]$Object,
    [string]$Name
  )

  return (Test-HasField $Object $Name) -and ((Get-Field $Object $Name) -eq $true)
}

function Convert-ToIntOrZero {
  param([object]$Value)

  try {
    return [int]$Value
  } catch {
    return 0
  }
}

function Add-ExactFieldCheck {
  param(
    [string]$Id,
    [string]$Name,
    [object]$Actual,
    [object]$Expected,
    [string]$Evidence
  )

  if ($Actual -eq $Expected) {
    Add-Check $Id $Name "pass" $Evidence "Value matches expected release contract."
  } else {
    Add-Check $Id $Name "fail" $Evidence "Expected '$Expected' but found '$Actual'."
  }
}

function Add-RequiredTextPatterns {
  param(
    [string]$Id,
    [string]$Name,
    [string]$Text,
    [string[]]$Patterns,
    [string]$Evidence,
    [string]$MissingDetail
  )

  $missing = @()
  foreach ($pattern in $Patterns) {
    if ($Text -notmatch [regex]::Escape($pattern)) {
      $missing += $pattern
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "pending" $Evidence ($MissingDetail + " Missing: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" $Evidence "Required markers are present."
  }
}

function Write-SpeechReviewTemplate {
  $reviewDirectory = Split-Path -Parent $ReviewPath
  if (-not [string]::IsNullOrWhiteSpace($reviewDirectory)) {
    New-Item -ItemType Directory -Force -Path $reviewDirectory | Out-Null
  }

  @"
# Android Push-To-Talk Speech Evidence Review

Complete this after running the final Android build on a real phone with the physical Stack-chan connected.

- Reviewer:
- Review date:
- Support decision: pending
- Android device:
- Android version:
- App version:
- Source commit:
- Diagnostics export path: ANDROID_DIAGNOSTICS_EXPORT.json
- Logcat path: android_speech_logcat.txt
- Robot serial log path: robot_speech_serial.log
- Speech recognizer decision: pending
- Transcript submission decision: pending
- Robot response-frame decision: pending
- Privacy decision: pending

Required review:

- Push-to-talk requests `RECORD_AUDIO` if needed and does not send a denied turn.
- Android SpeechRecognizer reports a final transcript without exporting transcript text in diagnostics.
- Logcat contains `stackchan_speech_evidence` markers for `listening_start`, `final_transcript`, and `submit_result`.
- The submit marker has `accepted=1`, `seq_present=1`, and `message_type=app_text_turn`.
- Robot serial evidence shows `thinking`, `response_start`, `audio_stream_start`, `audio_stream_end`, and `response_end`.
- Diagnostics export keeps `last_text_turn_present=true`, `raw_audio_retention=none`, and transcript export redacted to presence only.
"@ | Set-Content -Path $ReviewPath -Encoding UTF8
}

if ($WriteTemplate) {
  Write-SpeechReviewTemplate
}

$exportEvidence = Convert-ToRelativePath $DiagnosticsExportPath
$logcatEvidence = Convert-ToRelativePath $LogcatPath
$robotEvidence = Convert-ToRelativePath $RobotLogPath
$reviewEvidence = Convert-ToRelativePath $ReviewPath

if (-not (Test-Path -LiteralPath $DiagnosticsExportPath -PathType Leaf)) {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pending" $exportEvidence "Share ANDROID_DIAGNOSTICS_EXPORT.json after a push-to-talk turn on a connected robot."
} else {
  Add-Check "diagnostics-export-json" "Android diagnostics export JSON" "pass" $exportEvidence "Diagnostics export JSON exists."
  try {
    $diagnostics = Get-Content -LiteralPath $DiagnosticsExportPath -Raw | ConvertFrom-Json
  } catch {
    Add-Check "diagnostics-export-json-parse" "Android diagnostics export parses" "fail" $exportEvidence $_.Exception.Message
    $diagnostics = $null
  }

  if ($null -ne $diagnostics) {
    Add-ExactFieldCheck "schema" "Diagnostics export schema" (Get-Field $diagnostics "schema") "stackchan.android.diagnostics-export.v1" $exportEvidence
    $bridge = Get-Field $diagnostics "bridge"
    $privacy = Get-Field $diagnostics "privacy"

    Add-ExactFieldCheck "last-message-type" "Last bridge message type" (Get-Field $bridge "last_message_type") "app_text_turn" $exportEvidence
    if ((Convert-ToIntOrZero (Get-Field $bridge "text_turns_submitted")) -gt 0 -and (Test-TrueField $bridge "last_text_turn_present")) {
      Add-Check "speech-turn-present" "Speech text turn redacted presence" "pass" $exportEvidence "A text turn was submitted and diagnostics expose only last_text_turn_present=true."
    } else {
      Add-Check "speech-turn-present" "Speech text turn redacted presence" "pending" $exportEvidence "Run a push-to-talk turn before exporting diagnostics."
    }

    if ((Test-TrueField $bridge "robot_socket_connected") -and (Get-Field (Get-Field $diagnostics "robot") "connected") -eq $true) {
      Add-Check "robot-connected" "Robot connected during speech turn" "pass" $exportEvidence "Diagnostics show a connected robot session."
    } else {
      Add-Check "robot-connected" "Robot connected during speech turn" "pending" $exportEvidence "Capture diagnostics while the physical robot is connected."
    }

    Add-ExactFieldCheck "raw-audio-retention" "Raw audio retention" (Get-Field $privacy "raw_audio_retention") "none" $exportEvidence
    Add-ExactFieldCheck "transcript-export" "Transcript export privacy" (Get-Field $privacy "transcript_export") "last text turn redacted to presence only" $exportEvidence
  }
}

if (-not (Test-Path -LiteralPath $LogcatPath -PathType Leaf)) {
  Add-Check "speech-logcat" "Android push-to-talk logcat" "pending" $logcatEvidence "Capture Android logcat after a push-to-talk turn."
} else {
  $logText = Get-Content -LiteralPath $LogcatPath -Raw
  Add-RequiredTextPatterns `
    -Id "speech-logcat-markers" `
    -Name "Android speech evidence markers" `
    -Text $logText `
    -Patterns @("stackchan_speech_evidence", "event=listening_start", "event=final_transcript", "transcript_present=1", "transcript_redacted=1", "raw_audio_retention=none", "event=submit_result", "accepted=1", "seq_present=1", "message_type=app_text_turn") `
    -Evidence $logcatEvidence `
    -MissingDetail "Capture a complete push-to-talk logcat run."

  if ($logText -match [regex]::Escape("event=permission_denied") -or $logText -match [regex]::Escape("event=recognizer_error")) {
    Add-Check "speech-logcat-errors" "Android speech log has no denied/error terminal event" "fail" $logcatEvidence "Logcat includes permission_denied or recognizer_error; recapture a successful push-to-talk turn."
  } else {
    Add-Check "speech-logcat-errors" "Android speech log has no denied/error terminal event" "pass" $logcatEvidence "No denied/error terminal speech event found."
  }
}

if (-not (Test-Path -LiteralPath $RobotLogPath -PathType Leaf)) {
  Add-Check "robot-speech-log" "Robot serial speech response log" "pending" $robotEvidence "Capture robot serial log for the push-to-talk turn."
} else {
  $robotText = Get-Content -LiteralPath $RobotLogPath -Raw
  Add-RequiredTextPatterns `
    -Id "robot-response-frames" `
    -Name "Robot response frame evidence" `
    -Text $robotText `
    -Patterns @("app_text_turn", "thinking", "response_start", "audio_stream_start", "audio_stream_end", "response_end") `
    -Evidence $robotEvidence `
    -MissingDetail "Capture robot bridge frames for the speech turn."
}

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  Add-Check "speech-review" "Android speech human review packet" "pending" $reviewEvidence "Run with -WriteTemplate and complete the speech review after the real-device run."
} else {
  $reviewText = Get-Content -LiteralPath $ReviewPath -Raw
  $reviewerOk = $reviewText -match "(?im)^-\s*Reviewer:\s*\S+"
  $dateOk = $reviewText -match "(?im)^-\s*Review date:\s*\d{4}-\d{2}-\d{2}\s*$"
  $supportOk = $reviewText -match "(?im)^-\s*Support decision:\s*pass\s*$"
  $recognizerOk = $reviewText -match "(?im)^-\s*Speech recognizer decision:\s*pass\s*$"
  $submissionOk = $reviewText -match "(?im)^-\s*Transcript submission decision:\s*pass\s*$"
  $responseOk = $reviewText -match "(?im)^-\s*Robot response-frame decision:\s*pass\s*$"
  $privacyOk = $reviewText -match "(?im)^-\s*Privacy decision:\s*pass\s*$"
  if ($reviewerOk -and $dateOk -and $supportOk -and $recognizerOk -and $submissionOk -and $responseOk -and $privacyOk) {
    Add-Check "speech-review" "Android speech human review packet" "pass" $reviewEvidence "Reviewer, date, support, recognizer, submission, robot response, and privacy decisions are pass."
  } else {
    Add-Check "speech-review" "Android speech human review packet" "pending" $reviewEvidence "Complete Reviewer, Review date (YYYY-MM-DD), Support decision: pass, Speech recognizer decision: pass, Transcript submission decision: pass, Robot response-frame decision: pass, and Privacy decision: pass."
  }
}

$failCount = @($checks | Where-Object { $_.status -eq "fail" }).Count
$pendingCount = @($checks | Where-Object { $_.status -eq "pending" }).Count
$passCount = @($checks | Where-Object { $_.status -eq "pass" }).Count
$status = if ($failCount -gt 0) { "not-ready" } elseif ($pendingCount -gt 0) { "pending-android-speech-evidence" } else { "android-speech-ready" }

$report = [ordered]@{
  schema = "stackchan.android-speech-evidence.v1"
  status = $status
  root = [string]$Root
  diagnosticsExportPath = Convert-ToRelativePath $DiagnosticsExportPath
  logcatPath = Convert-ToRelativePath $LogcatPath
  robotLogPath = Convert-ToRelativePath $RobotLogPath
  reviewPath = Convert-ToRelativePath $ReviewPath
  passCount = $passCount
  failCount = $failCount
  pendingCount = $pendingCount
  requireReady = [bool]$RequireReady
  checks = $checks
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Android speech evidence status: $status"
  Write-Host "Pass: $passCount  Fail: $failCount  Pending: $pendingCount"
  foreach ($check in $checks) {
    Write-Host ("[{0}] {1} - {2}" -f $check.status, $check.id, $check.detail)
  }
}

if ($failCount -gt 0 -or ($RequireReady -and $pendingCount -gt 0)) {
  exit 1
}
