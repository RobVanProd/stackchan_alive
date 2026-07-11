$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Invoke-RuntimeCheck {
  param([string]$CommandLine)
  $output = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $CommandLine -Json
  return ($output | ConvertFrom-Json)
}

function Invoke-RuntimeCheckSubprocess {
  param([string]$CommandLine)
  $escaped = $CommandLine.Replace("'@", "' + '@'")
  $script = @"
Set-Location '$RepoRoot'
`$ProgressPreference = 'SilentlyContinue'
& 'tools\check_pc_brain_runtime.ps1' -ProcessCommandLine @'
$escaped
'@ -Json
"@
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = $output
    json = ($output | ConvertFrom-Json)
  }
}

$goodCommand = '"C:\Python310\python.exe" bridge\lan_service.py --host 0.0.0.0 --port 8765 --runner-profile gemma4-e2b-gguf --runner-timeout-ms 120000 --stt-command "python bridge\whisper_cpp_stt.py" --stt-timeout-ms 15000 --tts-command "python bridge\selected_voice_tts.py" --tts-voice stackchan-rvc-bright-robot --tts-timeout-ms 120000 --downlink-audio-chunk-bytes 4096 --downlink-binary-frame-delay-ms 20 --downlink-text-frame-delay-ms 40 --client-idle-timeout-s 120 --memory-file output\pc-brain\latest\memory.json --turn-log-file output\pc-brain\latest\turns.jsonl --disable-audio-downlink --runner-command "python bridge\ollama_stackchan_runner.py" --require-runner'
$good = Invoke-RuntimeCheck -CommandLine $goodCommand
if (-not $good.machineReady) {
  throw "Expected good command line to be machine-ready."
}
if ($good.failed -ne 0) {
  throw "Expected good command line to have zero failed checks."
}
foreach ($id in @("stt-command", "audio-wake-phrase", "audio-downlink-disabled", "tts-command", "tts-voice", "runner-command", "require-runner", "binary-delay", "client-idle-timeout", "turn-log-file")) {
  $check = @($good.checks | Where-Object { $_.id -eq $id })[0]
  if ($null -eq $check -or $check.status -ne "pass") {
    throw "Expected $id to pass."
  }
}

$strictCommand = $goodCommand -replace "--tts-command", "--require-audio-wake-phrase --tts-command"
$strict = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $strictCommand -ExpectedRequireAudioWakePhrase $true -Json | ConvertFrom-Json
if (-not $strict.machineReady -or $strict.failed -ne 0) {
  throw "Expected strict wake-phrase command line to pass when explicitly requested."
}

$enabledAudioCommand = $goodCommand -replace " --disable-audio-downlink", ""
$enabledAudio = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $enabledAudioCommand -ExpectedDisableAudioDownlink $false -Json | ConvertFrom-Json
if (-not $enabledAudio.machineReady -or $enabledAudio.failed -ne 0) {
  throw "Expected explicitly enabled audio-downlink command line to pass when requested."
}

$badCommand = $goodCommand -replace "--stt-command `"python bridge\\whisper_cpp_stt.py`" ", ""
$badResult = Invoke-RuntimeCheckSubprocess -CommandLine $badCommand
if ($badResult.exitCode -eq 0) {
  throw "Expected missing STT command to fail."
}
$bad = $badResult.json
$sttCheck = @($bad.checks | Where-Object { $_.id -eq "stt-command" })[0]
if ($null -eq $sttCheck -or $sttCheck.status -ne "fail") {
  throw "Expected missing STT command check to fail."
}

Write-Host "PC brain runtime check contract tests passed."
