$ErrorActionPreference = "Stop"

$ScriptPath = Join-Path $PSScriptRoot "start_whisper_server.ps1"
$Text = Get-Content -LiteralPath $ScriptPath -Raw
$SetupScriptPath = Join-Path $PSScriptRoot "setup_whisper_cpp.ps1"
$SetupText = Get-Content -LiteralPath $SetupScriptPath -Raw
$Tokens = $null
$Errors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  $ScriptPath,
  [ref]$Tokens,
  [ref]$Errors
) | Out-Null
if ($Errors.Count -ne 0) {
  throw "Whisper server launcher has PowerShell parse errors: $($Errors -join '; ')"
}

foreach ($Required in @(
  "whisper-server.exe",
  "--host", "127.0.0.1",
  "/health",
  "Refusing to use or stop non-whisper listener",
  "-WindowStyle Hidden",
  "ggml-base.en.bin",
  "modelSha256",
  "stackchan.whisper-server-start.v1"
)) {
  if (-not $Text.Contains($Required)) {
    throw "Whisper server launcher missing contract token: $Required"
  }
}

if ($Text.Contains('"--host", "0.0.0.0"')) {
  throw "Whisper server must never bind to a non-loopback host."
}

foreach ($Required in @(
  "Find-WhisperServer",
  "whisper-server.exe",
  "STACKCHAN_WHISPER_SERVER_EXE",
  "whisperServerExe"
)) {
  if (-not $SetupText.Contains($Required)) {
    throw "whisper.cpp setup missing resident-server contract token: $Required"
  }
}

Write-Host "Whisper server launcher contract tests passed."
