$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

function Invoke-RuntimeCheck {
  param(
    [string]$CommandLine,
    [string]$ExpectedHostName = "0.0.0.0",
    [string]$DeviceHost = "192.0.2.10"
  )
  $output = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $CommandLine `
    -ExpectedHostName $ExpectedHostName -DeviceHost $DeviceHost -Json
  return ($output | ConvertFrom-Json)
}

function Invoke-RuntimeCheckSubprocess {
  param(
    [string]$CommandLine,
    [string]$ExpectedHostName = "0.0.0.0",
    [string]$DeviceHost = "192.0.2.10"
  )
  $escaped = $CommandLine.Replace("'@", "' + '@'")
  $script = @"
Set-Location '$RepoRoot'
`$ProgressPreference = 'SilentlyContinue'
& 'tools\check_pc_brain_runtime.ps1' -ProcessCommandLine @'
$escaped
'@ -ExpectedHostName '$ExpectedHostName' -DeviceHost '$DeviceHost' -Json
"@
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded
  return [pscustomobject]@{
    exitCode = $LASTEXITCODE
    output = $output
    json = ($output | ConvertFrom-Json)
  }
}

$goodCommand = '"C:\Python310\python.exe" bridge\lan_service.py --host 0.0.0.0 --port 8765 --robot-host 192.0.2.10 --runner-profile gemma4-e2b-gguf --runner-timeout-ms 120000 --stt-command "python bridge\whisper_cpp_stt.py" --stt-timeout-ms 15000 --tts-command "python bridge\selected_voice_tts.py" --tts-voice stackchan-rvc-bright-robot --tts-timeout-ms 120000 --downlink-audio-chunk-bytes 4096 --downlink-binary-frame-delay-ms 20 --downlink-text-frame-delay-ms 40 --client-idle-timeout-s 20 --memory-file output\pc-brain\latest\memory.json --turn-log-file output\pc-brain\latest\turns.jsonl --disable-audio-downlink --runner-command "python bridge\ollama_stackchan_runner.py" --require-runner'
$good = Invoke-RuntimeCheck -CommandLine $goodCommand
if (-not $good.machineReady) {
  throw "Expected good command line to be machine-ready."
}
if ($good.failed -ne 0) {
  throw "Expected good command line to have zero failed checks."
}
foreach ($id in @("robot-peer", "stt-command", "audio-wake-phrase", "audio-downlink-disabled", "stream-tts-phrases", "tts-command", "tts-voice", "runner-command", "require-runner", "binary-delay", "client-idle-timeout", "turn-log-file")) {
  $check = @($good.checks | Where-Object { $_.id -eq $id })[0]
  if ($null -eq $check -or $check.status -ne "pass") {
    throw "Expected $id to pass."
  }
}

$strictCommand = $goodCommand -replace "--tts-command", "--require-audio-wake-phrase --tts-command"
$strict = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $strictCommand -DeviceHost "192.0.2.10" -ExpectedRequireAudioWakePhrase $true -Json | ConvertFrom-Json
if (-not $strict.machineReady -or $strict.failed -ne 0) {
  throw "Expected strict wake-phrase command line to pass when explicitly requested."
}

$enabledAudioCommand = $goodCommand -replace " --disable-audio-downlink", ""
$enabledAudio = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $enabledAudioCommand -DeviceHost "192.0.2.10" -ExpectedDisableAudioDownlink $false -Json | ConvertFrom-Json
if (-not $enabledAudio.machineReady -or $enabledAudio.failed -ne 0) {
  throw "Expected explicitly enabled audio-downlink command line to pass when requested."
}

$directMlCommand = $goodCommand `
  -replace "bridge\\selected_voice_tts.py", "bridge\rvc_directml_tts_client.py" `
  -replace "stackchan-rvc-bright-robot", "stackchan-rvc-directml-v2" `
  -replace "--downlink-binary-frame-delay-ms 20", "--stream-tts-phrases --downlink-binary-frame-delay-ms 70" `
  -replace " --disable-audio-downlink", ""
$directMl = & "tools\check_pc_brain_runtime.ps1" -ProcessCommandLine $directMlCommand `
  -DeviceHost "192.0.2.10" `
  -ExpectedTtsCommand "bridge\rvc_directml_tts_client.py" `
  -ExpectedTtsVoice "stackchan-rvc-directml-v2" `
  -ExpectedDownlinkBinaryFrameDelayMs 70 `
  -ExpectedDisableAudioDownlink $false `
  -ExpectedStreamTtsPhrases $true -Json | ConvertFrom-Json
if (-not $directMl.machineReady -or $directMl.failed -ne 0) {
  throw "Expected DirectML phrase-streaming command line to pass."
}

$missingPeerCommand = $goodCommand -replace " --robot-host 192\.0\.2\.10", ""
$missingPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $missingPeerCommand
if ($missingPeerResult.exitCode -eq 0) {
  throw "Expected a non-loopback command without --robot-host to fail."
}
$missingPeerCheck = @($missingPeerResult.json.checks | Where-Object { $_.id -eq "robot-peer" })[0]
if ($null -eq $missingPeerCheck -or $missingPeerCheck.status -ne "fail") {
  throw "Expected the missing robot-peer check to fail."
}

$wrongPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host 192.0.2.20"
$wrongPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $wrongPeerCommand
if ($wrongPeerResult.exitCode -eq 0) {
  throw "Expected a non-loopback command with the wrong --robot-host to fail."
}
$wrongPeerCheck = @($wrongPeerResult.json.checks | Where-Object { $_.id -eq "robot-peer" })[0]
if ($null -eq $wrongPeerCheck -or $wrongPeerCheck.status -ne "fail") {
  throw "Expected the wrong robot-peer check to fail."
}

$prefixPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host 192.0.2.100"
$prefixPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $prefixPeerCommand
if ($prefixPeerResult.exitCode -eq 0) {
  throw "Expected a prefix-colliding --robot-host value to fail."
}
$prefixPeerCheck = @($prefixPeerResult.json.checks | Where-Object { $_.id -eq "robot-peer" })[0]
if ($null -eq $prefixPeerCheck -or $prefixPeerCheck.status -ne "fail") {
  throw "Expected the prefix-colliding robot-peer check to fail."
}

$suffixPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host x192.0.2.10"
$suffixPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $suffixPeerCommand
if ($suffixPeerResult.exitCode -eq 0) {
  throw "Expected a suffix-colliding --robot-host value to fail."
}

$decoyPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host 192.0.2.20 --note 192.0.2.10"
$decoyPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $decoyPeerCommand
if ($decoyPeerResult.exitCode -eq 0) {
  throw "Expected an unrelated decoy peer value to fail."
}

$duplicatePeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host 192.0.2.10 --robot-host 192.0.2.20"
$duplicatePeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $duplicatePeerCommand
if ($duplicatePeerResult.exitCode -eq 0) {
  throw "Expected duplicate --robot-host arguments to fail certification."
}

$duplicateEqualsPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host 192.0.2.10 --robot-host=192.0.2.20"
$duplicateEqualsPeerResult = Invoke-RuntimeCheckSubprocess -CommandLine $duplicateEqualsPeerCommand
if ($duplicateEqualsPeerResult.exitCode -eq 0) {
  throw "Expected mixed space/equals duplicate --robot-host arguments to fail certification."
}

$equalsPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", "--robot-host=192.0.2.10"
$equalsPeer = Invoke-RuntimeCheck -CommandLine $equalsPeerCommand
if (-not $equalsPeer.machineReady -or $equalsPeer.failed -ne 0) {
  throw "Expected one exact equals-form --robot-host argument to pass."
}

$quotedPeerCommand = $goodCommand -replace "--robot-host 192\.0\.2\.10", '--robot-host "192.0.2.10"'
$quotedPeer = Invoke-RuntimeCheck -CommandLine $quotedPeerCommand
if (-not $quotedPeer.machineReady -or $quotedPeer.failed -ne 0) {
  throw "Expected one exact quoted --robot-host argument to pass."
}

$duplicateHostCommand = $goodCommand -replace "--host 0\.0\.0\.0", "--host 0.0.0.0 --host=127.0.0.1"
$duplicateHostResult = Invoke-RuntimeCheckSubprocess -CommandLine $duplicateHostCommand
if ($duplicateHostResult.exitCode -eq 0) {
  throw "Expected duplicate --host arguments to fail certification."
}

$loopbackCommand = $goodCommand `
  -replace "--host 0\.0\.0\.0", "--host 127.0.0.1" `
  -replace " --robot-host 192\.0\.2\.10", ""
$loopback = Invoke-RuntimeCheck -CommandLine $loopbackCommand `
  -ExpectedHostName "127.0.0.1" -DeviceHost ""
if (-not $loopback.machineReady -or $loopback.failed -ne 0) {
  throw "Expected a loopback-only command without --robot-host to pass."
}
$loopbackPeerCheck = @($loopback.checks | Where-Object { $_.id -eq "robot-peer" })[0]
if ($null -eq $loopbackPeerCheck -or $loopbackPeerCheck.status -ne "pass") {
  throw "Expected loopback robot-peer check to be optional and pass."
}

$loopbackOverrideCommand = $loopbackCommand + " --host=0.0.0.0"
$loopbackOverrideResult = Invoke-RuntimeCheckSubprocess -CommandLine $loopbackOverrideCommand `
  -ExpectedHostName "127.0.0.1" -DeviceHost ""
if ($loopbackOverrideResult.exitCode -eq 0) {
  throw "Expected a later non-loopback host override to fail loopback certification."
}

$quotedFlagDecoyCommand = $goodCommand `
  -replace " --host 0\.0\.0\.0", "" `
  -replace " --robot-host 192\.0\.2\.10", ""
$quotedFlagDecoyCommand = $quotedFlagDecoyCommand.Replace(
  'python bridge\ollama_stackchan_runner.py',
  'python bridge\ollama_stackchan_runner.py --host 0.0.0.0 --robot-host 192.0.2.10'
)
$quotedFlagDecoyResult = Invoke-RuntimeCheckSubprocess -CommandLine $quotedFlagDecoyCommand
if ($quotedFlagDecoyResult.exitCode -eq 0) {
  throw "Expected host and robot-peer decoys inside a quoted runner command to fail certification."
}
$quotedDecoyHostCheck = @($quotedFlagDecoyResult.json.checks | Where-Object { $_.id -eq "host" })[0]
$quotedDecoyPeerCheck = @($quotedFlagDecoyResult.json.checks | Where-Object { $_.id -eq "robot-peer" })[0]
if ($quotedDecoyHostCheck.status -ne "fail" -or $quotedDecoyPeerCheck.status -ne "fail") {
  throw "Quoted runner-command decoys must not be parsed as top-level security arguments."
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
