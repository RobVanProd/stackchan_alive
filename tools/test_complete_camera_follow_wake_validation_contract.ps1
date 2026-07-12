$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-camera-review-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $TempRoot | Out-Null

function Write-Fixture([string]$Root, [string]$Status, [bool]$CheckPass) {
  New-Item -ItemType Directory -Force -Path $Root | Out-Null
  [ordered]@{
    schema = "stackchan.camera-follow-wake-validation.v1"
    status = $Status
    sourceCommit = ("a" * 40)
    sourceDirty = $false
    installedFirmwareSha256 = ("b" * 64)
    visualVerdict = "pending_operator"
    captureTargetSamples = 6
    captureFollowSamples = 6
    chunksSubmittedDelta = 96
    bridgeTurnDelta = 1
    motionStopVerified = $true
    checks = @([ordered]@{ id = "fixture"; status = $(if ($CheckPass) { "pass" } else { "fail" }); detail = "fixture" })
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $Root "summary.json") -Encoding UTF8
}

try {
  $passRoot = Join-Path $TempRoot "pass"
  Write-Fixture $passRoot "telemetry_pass_pending_visual" $true
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\complete_camera_follow_wake_validation.ps1 -EvidenceRoot $passRoot -VisualVerdict pass -OperatorNotes "Following visibly continued while the microphone captured." -OperatorName "fixture" -Json
  if ($LASTEXITCODE -ne 0) { throw "Expected visual pass fixture to complete: $output" }
  $result = $output | ConvertFrom-Json
  $completed = Get-Content -LiteralPath (Join-Path $passRoot "summary.json") -Raw | ConvertFrom-Json
  if ($result.status -ne "pass" -or $completed.status -ne "pass" -or $completed.visualReview.verdict -ne "pass") {
    throw "Expected completed visual pass evidence."
  }

  $telemetryFailRoot = Join-Path $TempRoot "telemetry-fail"
  Write-Fixture $telemetryFailRoot "fail" $false
  $savedErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $bad = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\complete_camera_follow_wake_validation.ps1 -EvidenceRoot $telemetryFailRoot -VisualVerdict pass -OperatorNotes "This must not override failed telemetry." 2>&1 | Out-String
  $ErrorActionPreference = $savedErrorAction
  if ($LASTEXITCODE -eq 0 -or $bad -notmatch "Cannot record a visual pass") {
    throw "Expected failed telemetry to reject a visual pass."
  }

  $blankRoot = Join-Path $TempRoot "blank-note"
  Write-Fixture $blankRoot "telemetry_pass_pending_visual" $true
  $savedErrorAction = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $blank = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools\complete_camera_follow_wake_validation.ps1 -EvidenceRoot $blankRoot -VisualVerdict pass -OperatorNotes "short" 2>&1 | Out-String
  $ErrorActionPreference = $savedErrorAction
  if ($LASTEXITCODE -eq 0 -or $blank -notmatch "at least eight characters") {
    throw "Expected a vague operator note to be rejected."
  }

  Write-Output "Camera follow visual review contract verified."
} finally {
  Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
