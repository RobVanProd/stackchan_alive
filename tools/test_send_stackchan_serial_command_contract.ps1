$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-serial-command-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  $script = Join-Path $RepoRoot "tools\send_stackchan_serial_command.ps1"

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  $unsafeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
    -EvidenceRoot $tempRoot `
    -Command "servos on" `
    -OperatorPresent `
    -DryRun `
    -Json 2>&1
  $unsafeExit = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorActionPreference
  if ($unsafeExit -eq 0) {
    throw "Expected servos on without BodyClear/ConfirmServoRisk to fail."
  }
  if (($unsafeOutput -join "`n") -notmatch "BodyClear") {
    throw "Expected BodyClear error for servos on, got $unsafeOutput"
  }

  $stopOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
    -EvidenceRoot $tempRoot `
    -Command "motion stop" `
    -OperatorPresent `
    -DryRun `
    -Json
  if (-not $?) {
    throw "motion stop dry-run failed: $stopOutput"
  }
  $stop = $stopOutput | ConvertFrom-Json
  if ($stop.schema -ne "stackchan.serial-command.v1") {
    throw "Unexpected schema $($stop.schema)."
  }
  if ($stop.status -ne "serial-command-dry-run" -or $stop.command -ne "motion stop") {
    throw "Unexpected dry-run result $($stop.status) command=$($stop.command)."
  }
  if ($stop.dtrEnable -ne $false -or $stop.rtsEnable -ne $false) {
    throw "Serial command helper should default DTR/RTS off."
  }
  if (-not (Test-Path -LiteralPath $stop.logPath -PathType Leaf)) {
    throw "Expected log path $($stop.logPath)."
  }

  $wakeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
    -EvidenceRoot $tempRoot `
    -Command "wake" `
    -OperatorPresent `
    -DryRun `
    -Json
  if (-not $?) {
    throw "wake dry-run failed: $wakeOutput"
  }
  $wake = $wakeOutput | ConvertFrom-Json
  if ($wake.status -ne "serial-command-dry-run" -or $wake.command -ne "wake") {
    throw "Unexpected wake dry-run result $($wake.status) command=$($wake.command)."
  }

  $resumeOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script `
    -EvidenceRoot $tempRoot `
    -Command "servos on" `
    -OperatorPresent `
    -BodyClear `
    -ConfirmServoRisk `
    -DryRun `
    -Json
  if (-not $?) {
    throw "servos on dry-run failed: $resumeOutput"
  }
  $resume = $resumeOutput | ConvertFrom-Json
  if ($resume.command -ne "servos on" -or $resume.bodyClear -ne $true -or $resume.confirmServoRisk -ne $true) {
    throw "Unexpected resume dry-run result."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Stackchan serial command contract tests passed."
