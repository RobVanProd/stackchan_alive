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
$SetupTokens = $null
$SetupErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  $SetupScriptPath,
  [ref]$SetupTokens,
  [ref]$SetupErrors
) | Out-Null
if ($SetupErrors.Count -ne 0) {
  throw "whisper.cpp setup has PowerShell parse errors: $($SetupErrors -join '; ')"
}

foreach ($Required in @(
  "whisper-server.exe",
  "--host", "127.0.0.1",
  "/health",
  "Refusing to use or stop non-whisper listener",
  "does not match the requested executable, model, threads, and prompt",
  "-WindowStyle Hidden",
  "ggml-base.en.bin",
  "[int]`$Threads = 12",
  "[string]`$InitialPrompt",
  "--prompt",
  '[ValidateSet("auto", "cpu", "vulkan")]',
  "Get-WhisperBackendEvidence",
  "using\s+(Vulkan(?<device>\d+))\s+backend",
  "Invoke-WhisperWarmup",
  "MultipartFormDataContent",
  "warmup inference returned no transcription",
  "backendVerified",
  "warmupVerified",
  "warmupElapsedMs",
  "warmupWavSha256",
  "executableSha256",
  "configVerified",
  "executable",
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
  "whisperServerExe",
  '[ValidateSet("prebuilt", "vulkan")]',
  "f049fff95a089aa9969deb009cdd4892b3e74916",
  "https://github.com/ggml-org/whisper.cpp.git",
  "GGML_VULKAN=ON",
  "Vulkan_GLSLC_EXECUTABLE",
  "BUILD_SHARED_LIBS=OFF",
  "c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d",
  "whisperServerSha256",
  "sourceCommit",
  "vulkanSdkVersion",
  "modelSha256"
)) {
  if (-not $SetupText.Contains($Required)) {
    throw "whisper.cpp setup missing resident-server contract token: $Required"
  }
}

Write-Host "Whisper server launcher contract tests passed."
