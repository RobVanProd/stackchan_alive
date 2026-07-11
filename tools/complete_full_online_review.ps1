param(
  [string]$EvidenceRoot = "output\pc-brain\full-online-validation-latest",
  [string]$Operator = "",
  [string]$ExactSpokenPrompt = "",
  [string]$ObservedTranscript = "",
  [string]$ServoMotionObserved = "",
  [string]$SafeStopCommand = "motion stop",
  [switch]$ConfirmMicUplink,
  [switch]$ConfirmStt,
  [switch]$ConfirmSelectedVoice,
  [switch]$ConfirmVoiceMatch,
  [switch]$ConfirmServoControlled,
  [switch]$ConfirmSafeStop,
  [switch]$ConfirmNoServoRisk,
  [switch]$ConfirmNoAudioRisk,
  [switch]$Check,
  [switch]$RequireReady,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$ReviewPath = Join-Path $EvidencePath "FULL_ONLINE_REVIEW.md"
$CheckScript = Join-Path $PSScriptRoot "check_full_online_validation.ps1"

if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  $null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckScript -EvidenceRoot $EvidencePath -WriteTemplate -Json
}

function Set-ReviewLine {
  param([string]$Text, [string]$Label, [string]$Value)
  $pattern = "(?m)^- $([regex]::Escape($Label)):\s*.*$"
  $line = "- $Label`: $Value"
  if ($Text -match $pattern) {
    return [regex]::Replace($Text, $pattern, { param($m) $line })
  }
  return ($Text.TrimEnd() + "`r`n$line`r`n")
}

function Require-NonBlank {
  param([string]$Name, [string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw "$Name is required for this confirmed review."
  }
}

if ($ConfirmMicUplink -or $ConfirmStt -or $ConfirmSelectedVoice -or $ConfirmVoiceMatch) {
  Require-NonBlank "ExactSpokenPrompt" $ExactSpokenPrompt
}
if ($ConfirmStt) {
  Require-NonBlank "ObservedTranscript" $ObservedTranscript
}
if ($ConfirmServoControlled) {
  Require-NonBlank "ServoMotionObserved" $ServoMotionObserved
}
if ($ConfirmSafeStop) {
  Require-NonBlank "SafeStopCommand" $SafeStopCommand
}

$review = Get-Content -LiteralPath $ReviewPath -Raw

if ($ConfirmMicUplink) {
  $review = Set-ReviewLine $review "Robot mic voice-in produced uplink chunks" "yes"
}
if ($ConfirmStt) {
  $review = Set-ReviewLine $review "STT transcript was produced from robot mic input" "yes"
}
if ($ConfirmSelectedVoice) {
  $review = Set-ReviewLine $review "Selected voice response returned through robot speaker" "yes"
}
if ($ConfirmVoiceMatch) {
  $review = Set-ReviewLine $review 'Voice sounded like selected `stackchan-rvc-bright-robot`' "yes"
}
if ($ConfirmServoControlled) {
  $review = Set-ReviewLine $review "Servo motion was controlled and expected" "yes"
}
if ($ConfirmSafeStop) {
  $review = Set-ReviewLine $review "Motion stop or safe stop was verified" "yes"
}
if ($ConfirmNoServoRisk) {
  $review = Set-ReviewLine $review "Servo binding, runaway spin, tip, snag, or unsafe heat observed" "no"
}
if ($ConfirmNoAudioRisk) {
  $review = Set-ReviewLine $review "Audio clipping, choppiness, or dropout observed" "no"
}
if (-not [string]::IsNullOrWhiteSpace($Operator)) {
  $review = Set-ReviewLine $review "Operator" $Operator
}
$review = Set-ReviewLine $review "Date/time" (Get-Date).ToString("o")
if (-not [string]::IsNullOrWhiteSpace($ExactSpokenPrompt)) {
  $review = Set-ReviewLine $review "Exact spoken prompt" $ExactSpokenPrompt
}
if (-not [string]::IsNullOrWhiteSpace($ObservedTranscript)) {
  $review = Set-ReviewLine $review "Observed transcript" $ObservedTranscript
}
if (-not [string]::IsNullOrWhiteSpace($ServoMotionObserved)) {
  $review = Set-ReviewLine $review "Servo motion observed" $ServoMotionObserved
}
if (-not [string]::IsNullOrWhiteSpace($SafeStopCommand)) {
  $review = Set-ReviewLine $review "Safe-stop command used" $SafeStopCommand
}

$review | Set-Content -LiteralPath $ReviewPath -Encoding UTF8

$validation = $null
if ($Check -or $RequireReady) {
  $checkArgs = @("-EvidenceRoot", $EvidencePath, "-Json")
  if ($RequireReady) {
    $checkArgs += "-RequireReady"
  }
  $checkOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $CheckScript @checkArgs
  if ($checkOutput) {
    $validation = $checkOutput | ConvertFrom-Json
  }
}

$result = [ordered]@{
  schema = "stackchan.full-online-review-completion.v1"
  reviewPath = $ReviewPath
  evidenceRoot = $EvidencePath
  confirmed = [ordered]@{
    micUplink = [bool]$ConfirmMicUplink
    stt = [bool]$ConfirmStt
    selectedVoice = [bool]$ConfirmSelectedVoice
    voiceMatch = [bool]$ConfirmVoiceMatch
    servoControlled = [bool]$ConfirmServoControlled
    safeStop = [bool]$ConfirmSafeStop
    noServoRisk = [bool]$ConfirmNoServoRisk
    noAudioRisk = [bool]$ConfirmNoAudioRisk
  }
  validationStatus = $(if ($null -ne $validation) { $validation.status } else { $null })
  validationPending = $(if ($null -ne $validation) { $validation.pending } else { $null })
  validationFailed = $(if ($null -ne $validation) { $validation.failed } else { $null })
}

if ($Json) {
  $result | ConvertTo-Json -Depth 8
} else {
  Write-Host "Full-online review updated: $ReviewPath"
  if ($null -ne $validation) {
    Write-Host "Validation: $($validation.status) failed=$($validation.failed) pending=$($validation.pending)"
  }
}
