param(
  [string]$OutputDir = "docs/media/voice"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$outputPath = Join-Path $repoRoot $OutputDir
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$speechRate = -1
$robotPitchCadenceFactor = 1.2
$ringModBaseHz = 39.0
$ringModHarmonicHz = 78.0

$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-voice-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

$samples = @(
  [ordered]@{
    Slug = "greeting"
    Title = "Greeting"
    Text = "Hello. I am Stackchan, and I am awake."
  },
  [ordered]@{
    Slug = "thinking"
    Title = "Thinking"
    Text = "Input received. I am thinking now. Curiosity level rising."
  },
  [ordered]@{
    Slug = "safety"
    Title = "Safety"
    Text = "Small problem found. I can help fix it. Safety first."
  }
)

try {
  Add-Type -AssemblyName System.Speech
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $voiceNames = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
  if ($voiceNames -contains "Microsoft David Desktop") {
    $synth.SelectVoice("Microsoft David Desktop")
  } elseif ($voiceNames.Count -gt 0) {
    $synth.SelectVoice($voiceNames[0])
  }
  $selectedVoice = $synth.Voice.Name
  $synth.Rate = $speechRate
  $synth.Volume = 100

  foreach ($sample in $samples) {
    $sourcePath = Join-Path $tempDir "$($sample.Slug)-source.wav"
    $synth.SetOutputToWaveFile($sourcePath)
    $synth.Speak($sample.Text)
    $synth.SetOutputToNull()
  }
  $synth.Dispose()

  $pythonPath = Get-StackchanPreviewPython
  $effectScript = Join-Path $tempDir "stackchan_robotize.py"
  @"
import math
import os
import struct
import sys
import wave

source_dir = sys.argv[1]
out_dir = sys.argv[2]

def read_wav(path):
    with wave.open(path, "rb") as wav:
        channels = wav.getnchannels()
        width = wav.getsampwidth()
        rate = wav.getframerate()
        frames = wav.readframes(wav.getnframes())
    if width != 2:
        raise RuntimeError(f"Expected 16-bit PCM WAV: {path}")
    values = struct.unpack("<" + "h" * (len(frames) // 2), frames)
    if channels == 1:
        return rate, [v / 32768.0 for v in values]
    mono = []
    for i in range(0, len(values), channels):
        mono.append(sum(values[i:i + channels]) / (32768.0 * channels))
    return rate, mono

def write_wav(path, rate, samples):
    peak = max((abs(s) for s in samples), default=0.0)
    gain = 0.92 / peak if peak > 0.92 else 1.0
    pcm = bytearray()
    for sample in samples:
        clamped = max(-1.0, min(1.0, sample * gain))
        pcm.extend(struct.pack("<h", int(round(clamped * 32767.0))))
    with wave.open(path, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(bytes(pcm))

def resample_linear(samples, factor):
    if factor <= 0:
        raise RuntimeError("Resample factor must be positive")
    if not samples:
        return []
    out_len = max(1, int(round(len(samples) * factor)))
    out = []
    for i in range(out_len):
        source = i / factor
        left = int(source)
        right = min(left + 1, len(samples) - 1)
        frac = source - left
        out.append(samples[left] * (1.0 - frac) + samples[right] * frac)
    return out

def robotize(rate, samples):
    samples = resample_linear(samples, $robotPitchCadenceFactor)
    delay_a = max(1, int(rate * 0.055))
    delay_b = max(1, int(rate * 0.095))
    out = [0.0] * (len(samples) + delay_b + 1)
    low = 0.0
    for i, sample in enumerate(samples):
        low += 0.18 * (sample - low)
        bright = sample - 0.45 * low
        carrier = (
            0.78
            + 0.17 * math.sin(2.0 * math.pi * $ringModBaseHz * i / rate)
            + 0.05 * math.sin(2.0 * math.pi * $ringModHarmonicHz * i / rate)
        )
        shaped = math.tanh(bright * 1.45) * carrier
        crushed = round(shaped * 80.0) / 80.0
        out[i] += crushed
        out[i + delay_a] += crushed * 0.16
        out[i + delay_b] += crushed * 0.07
    fade = min(int(rate * 0.025), len(out) // 2)
    for i in range(fade):
        ramp = i / max(1, fade)
        out[i] *= ramp
        out[-1 - i] *= ramp
    return out

for name in sorted(os.listdir(source_dir)):
    if not name.endswith("-source.wav"):
        continue
    slug = name[:-len("-source.wav")]
    rate, samples = read_wav(os.path.join(source_dir, name))
    out_path = os.path.join(out_dir, f"stackchan_spark_{slug}.wav")
    write_wav(out_path, rate, robotize(rate, samples))
"@ | Set-Content -Path $effectScript -Encoding UTF8

  & $pythonPath $effectScript $tempDir $outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "Voice sample effect processing failed."
  }

  $sampleList = ($samples | ForEach-Object {
    "- ``stackchan_spark_$($_.Slug).wav``: $($_.Title) - `"$($_.Text)`""
  }) -join [Environment]::NewLine

  @"
# Stackchan Spark Voice Samples

These are prototype audition samples for the original Stackchan Spark voice direction. They are not a Johnny 5 clone, are not trained from soundboard clips, and do not use RVC character models.

Generated source:
- Local Windows SpeechSynthesizer voice: ``$selectedVoice``
- Deterministic robot effect chain: measured source cadence, lowered-pitch resample, high-pass shaping, light ring modulation, subtle bit-depth reduction, soft saturation, and short echo
- Tuning: SpeechSynthesizer rate ``$speechRate`` with pitch/cadence resample factor ``$robotPitchCadenceFactor`` for a slightly slower, lower robot read
- Renderer: ``tools/render_voice_samples.ps1``

Samples:
$sampleList

Rollout note: these WAVs are for direction review. Before consumer promotion, the voice source still needs a licensed or owned production source and real-device speaker evidence.
"@ | Set-Content -Path (Join-Path $outputPath "VOICE_SAMPLES.md") -Encoding UTF8

  Write-Host "Rendered Stackchan Spark voice samples:"
  Get-ChildItem -LiteralPath $outputPath -Filter "stackchan_spark_*.wav" | ForEach-Object {
    Write-Host $_.FullName
  }
} finally {
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
