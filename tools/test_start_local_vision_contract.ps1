$ErrorActionPreference = "Stop"

$launcherPath = Join-Path $PSScriptRoot "start_local_vision.ps1"
$text = Get-Content -LiteralPath $launcherPath -Raw
$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  $launcherPath,
  [ref]$tokens,
  [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
  throw "Local vision launcher has PowerShell parse errors: $($parseErrors -join '; ')"
}

foreach ($required in @(
  "[Parameter(Mandatory = `$true)]",
  "--pairing-code-file",
  "--preflight",
  "stackchan.local-vision-preflight.v1",
  "Refusing to stop PID",
  "bridge[\\/]vision_service\.py",
  "RedirectStandardOutput",
  "RedirectStandardError",
  "-WindowStyle Hidden",
  "rawFramePersistence = `$false",
  "vision_service.pid"
)) {
  if (-not $text.Contains($required)) {
    throw "Local vision launcher missing contract token: $required"
  }
}

if ($text.Contains('"--pairing-code",')) {
  throw "Local vision launcher must keep the pairing secret out of the process command line."
}
if ($text -match "Get-CimInstance Win32_Process\s*\|\s*Stop-Process") {
  throw "Local vision launcher must not broadly stop discovered processes."
}

Write-Host "Local vision launcher contract tests passed."
