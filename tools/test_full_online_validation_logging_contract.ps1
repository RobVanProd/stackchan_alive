$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Write-Json {
  param([string]$Path, $Object)
  $Object | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-full-online-logging-" + [guid]::NewGuid().ToString("N"))
$debugPath = Join-Path $tempRoot "debug.json"
$evidenceRoot = Join-Path $tempRoot "evidence"

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  Write-Json $debugPath ([ordered]@{
      schema = "stackchan.bridge-debug.v1"
      network_state = "connected"
      bridge_state = "ready"
      network_error = ""
      speaker_volume = 150
      audio_stream_active = $false
    })

  $debugOnlyOutput = & "tools\start_full_online_validation_logging.ps1" `
    -EvidenceRoot $evidenceRoot `
    -DebugJsonPath $debugPath `
    -DurationSeconds 1 `
    -PollIntervalSeconds 1 `
    -DebugOnly `
    -Json
  if (-not $?) {
    throw "Expected debug-only logging to pass: $debugOnlyOutput"
  }
  $debugOnly = $debugOnlyOutput | ConvertFrom-Json
  if ($debugOnly.schema -ne "stackchan.full-online-validation-logging.v1") {
    throw "Unexpected logging schema: $($debugOnly.schema)."
  }
  if ($debugOnly.debugPolls -lt 1 -or $debugOnly.debugFailures -ne 0) {
    throw "Expected at least one successful debug poll, got polls=$($debugOnly.debugPolls) failures=$($debugOnly.debugFailures)."
  }
  if ($debugOnly.serialIncluded -ne $false) {
    throw "Expected debug-only logging to skip serial."
  }
  foreach ($file in @("FULL_ONLINE_DEBUG_POLL.jsonl", "FULL_ONLINE_DEBUG_ONLY_LOGGING.json", "FULL_ONLINE_DEBUG_ONLY_LOGGING.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $evidenceRoot $file) -PathType Leaf)) {
      throw "Expected logging artifact $file."
    }
  }
  if (Test-Path -LiteralPath (Join-Path $evidenceRoot "FULL_ONLINE_VALIDATION_LOGGING.json") -PathType Leaf) {
    throw "Debug-only logging must not overwrite FULL_ONLINE_VALIDATION_LOGGING.json."
  }
  $debugLog = Get-Content -LiteralPath (Join-Path $evidenceRoot "FULL_ONLINE_DEBUG_POLL.jsonl") -Raw
  if ($debugLog -notmatch "stackchan.bridge-debug.v1") {
    throw "Expected debug poll log to include bridge debug schema."
  }

  $refusalOutput = & "tools\start_full_online_validation_logging.ps1" `
    -EvidenceRoot $evidenceRoot `
    -DebugJsonPath $debugPath `
    -DurationSeconds 1 `
    -PollIntervalSeconds 1 `
    -Json
  if ($?) {
    throw "Expected serial logging without safety flags to fail."
  }
  $refusal = $refusalOutput | ConvertFrom-Json
  if ($refusal.status -ne "full-online-validation-logging-not-started") {
    throw "Expected not-started refusal, got $($refusal.status)."
  }
  if ($refusal.serialDtrEnable -ne $false -or $refusal.serialRtsEnable -ne $false) {
    throw "Expected DTR/RTS defaults to remain false."
  }
  foreach ($id in @("operator-present", "body-clear")) {
    $step = @($refusal.steps | Where-Object { $_.id -eq $id })[0]
    if ($null -eq $step -or $step.status -ne "fail") {
      throw "Expected $id to fail when serial logging is not explicitly confirmed."
    }
  }

  $serialLogPath = Join-Path $evidenceRoot "full_online_serial.log"
  "existing serial marker" | Set-Content -LiteralPath $serialLogPath -Encoding UTF8
  $appendRefusalOutput = & "tools\start_full_online_validation_logging.ps1" `
    -EvidenceRoot $evidenceRoot `
    -DebugJsonPath $debugPath `
    -DurationSeconds 1 `
    -PollIntervalSeconds 1 `
    -AppendSerial `
    -Json
  if ($?) {
    throw "Expected append serial logging without safety flags to fail."
  }
  $serialLogAfterRefusal = Get-Content -LiteralPath $serialLogPath -Raw
  if ($serialLogAfterRefusal -notmatch "existing serial marker") {
    throw "Append/refusal path should not overwrite existing serial evidence."
  }
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Full-online validation logging contract tests passed."
