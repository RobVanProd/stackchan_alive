param(
  [string]$OutDir = "output\pc-brain\stt-preflight-latest",
  [string]$Text = "hello stackchan",
  [string]$RunnerCommand = "python bridge\ollama_stackchan_runner.py",
  [string]$Model = "gemma4:e2b-it-qat",
  [string]$SttCommand = "python bridge\whisper_cpp_stt.py",
  [string]$TtsCommand = "python bridge\selected_voice_tts.py",
  [string]$TtsVoice = "stackchan-rvc-bright-robot",
  [int]$SelectedVoiceStartBytes = 65536,
  [int]$SelectedVoiceMaxAudioBytes = 65536,
  [double]$SelectedVoiceGain = 0.30,
  [int]$TimeoutMs = 120000,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$ResolvedOutDir = Resolve-Path $OutDir
$WavePath = Join-Path $ResolvedOutDir "windows_tts_sample.wav"
$PcmPath = Join-Path $ResolvedOutDir "windows_tts_sample.s16le"

Add-Type -AssemblyName System.Speech
$Synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
try {
  $Synth.SetOutputToWaveFile($WavePath)
  $Synth.Speak($Text)
} finally {
  $Synth.Dispose()
}

$env:STACKCHAN_PREFLIGHT_WAV = $WavePath
$env:STACKCHAN_PREFLIGHT_PCM = $PcmPath
$SampleRate = @'
import os
import wave

wave_path = os.environ["STACKCHAN_PREFLIGHT_WAV"]
pcm_path = os.environ["STACKCHAN_PREFLIGHT_PCM"]
with wave.open(wave_path, "rb") as wav:
    if wav.getnchannels() != 1 or wav.getsampwidth() != 2:
        raise SystemExit(
            f"Expected mono 16-bit WAV; got channels={wav.getnchannels()} width={wav.getsampwidth()}"
        )
    sample_rate = wav.getframerate()
    pcm = wav.readframes(wav.getnframes())
with open(pcm_path, "wb") as handle:
    handle.write(pcm)
print(sample_rate)
'@ | python -

if (-not $SampleRate) {
  throw "Failed to extract sample rate from $WavePath"
}

$env:PYTHONPATH = "bridge"
$env:STACKCHAN_GEMMA4_E2B_GGUF_COMMAND = $RunnerCommand
$env:STACKCHAN_OLLAMA_MODEL = $Model
$env:STACKCHAN_SELECTED_VOICE_START_BYTES = [string]$SelectedVoiceStartBytes
$env:STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES = [string]$SelectedVoiceMaxAudioBytes
$env:STACKCHAN_SELECTED_VOICE_GAIN = [string]$SelectedVoiceGain

$ArgsList = @(
  "bridge\engine_probe.py",
  "--profile", "gemma4-e2b-gguf",
  "--run-model-smoke",
  "--stt-command", $SttCommand,
  "--stt-pcm-file", $PcmPath,
  "--stt-sample-rate", "$SampleRate",
  "--tts-command", $TtsCommand,
  "--tts-voice", $TtsVoice,
  "--timeout-ms", "$TimeoutMs",
  "--out-dir", $OutDir
)
if ($Json) {
  $ArgsList += "--json"
}

python @ArgsList
exit $LASTEXITCODE
