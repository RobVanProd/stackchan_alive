param(
  [string]$OutputDir = "docs/media/voice",
  [ValidateSet("auto", "system", "espeak")]
  [string]$Engine = "auto"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

$outputPath = Join-Path $repoRoot $OutputDir
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

$speechRate = -1
$robotPitchCadenceFactor = 1.16
$ringModBaseHz = 36.0
$ringModHarmonicHz = 72.0
$sampleHoldHz = 14500.0

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

function Get-StackchanEspeakCommand {
  foreach ($name in @("espeak-ng", "espeak")) {
    $command = Get-Command $name -ErrorAction SilentlyContinue
    if ($null -ne $command) {
      return $command
    }
  }
  return $null
}

try {
  $espeakCommand = Get-StackchanEspeakCommand
  $useEspeak = $false
  if ($Engine -eq "espeak") {
    if ($null -eq $espeakCommand) {
      throw "Requested eSpeak renderer, but neither espeak-ng nor espeak is available on PATH."
    }
    $useEspeak = $true
  } elseif ($Engine -eq "auto" -and $null -ne $espeakCommand) {
    $useEspeak = $true
  }

  if ($useEspeak) {
    $selectedVoice = "$($espeakCommand.Name) en-us+m3"
    foreach ($sample in $samples) {
      $sourcePath = Join-Path $tempDir "$($sample.Slug)-source.wav"
      & $espeakCommand.Source -v "en-us+m3" -s 142 -p 46 -g 7 -a 175 -w $sourcePath $sample.Text
      if ($LASTEXITCODE -ne 0) {
        throw "eSpeak source rendering failed for $($sample.Slug)."
      }
    }
  } else {
    Add-Type -AssemblyName System.Speech
    $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
    $voiceNames = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
    if ($voiceNames -contains "Microsoft David Desktop") {
      $synth.SelectVoice("Microsoft David Desktop")
    } elseif ($voiceNames.Count -gt 0) {
      $synth.SelectVoice($voiceNames[0])
    }
    $selectedVoice = "Windows SpeechSynthesizer $($synth.Voice.Name)"
    $synth.Rate = $speechRate
    $synth.Volume = 100

    foreach ($sample in $samples) {
      $sourcePath = Join-Path $tempDir "$($sample.Slug)-source.wav"
      $synth.SetOutputToWaveFile($sourcePath)
      $synth.Speak($sample.Text)
      $synth.SetOutputToNull()
    }
    $synth.Dispose()
  }

  $pythonPath = Get-StackchanPreviewPython
  $effectScript = Join-Path $tempDir "stackchan_spark_synth.py"
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
        source = min(len(samples) - 1, i / factor)
        left = int(source)
        right = min(left + 1, len(samples) - 1)
        frac = source - left
        out.append(samples[left] * (1.0 - frac) + samples[right] * frac)
    return out

def remove_dc(samples):
    if not samples:
        return []
    dc = sum(samples) / len(samples)
    return [s - dc for s in samples]

def sample_hold(samples, rate, hold_hz):
    step = max(1, int(round(rate / max(1.0, hold_hz))))
    held = []
    current = 0.0
    for i, sample in enumerate(samples):
        if i % step == 0:
            current = sample
        held.append(current)
    return held

def phrase_micro_prosody(rate, samples):
    window = max(1, int(rate * 0.11))
    shaped = []
    pattern = [1.045, 0.965, 1.025, 0.985, 1.065, 0.955]
    voiced_index = 0
    for start in range(0, len(samples), window):
        chunk = samples[start:start + window]
        rms = math.sqrt(sum(s * s for s in chunk) / max(1, len(chunk)))
        if rms > 0.010:
            factor = pattern[voiced_index % len(pattern)]
            voiced_index += 1
            chunk = resample_linear(chunk, factor)
            attack = max(1, int(rate * 0.010))
            release = max(1, int(rate * 0.014))
            for i in range(min(attack, len(chunk))):
                chunk[i] *= 0.55 + 0.45 * (i / attack)
            for i in range(min(release, len(chunk))):
                chunk[-1 - i] *= 0.52 + 0.48 * (i / release)
        shaped.extend(chunk)
    return shaped

def add_spark_chirps(rate, samples):
    out = list(samples)
    block = max(1, int(rate * 0.018))
    energies = []
    for start in range(0, len(samples), block):
        chunk = samples[start:start + block]
        energies.append(math.sqrt(sum(s * s for s in chunk) / max(1, len(chunk))))
    silent_blocks = 8
    chirps_added = 0
    for idx in range(1, len(energies)):
        if energies[idx] > 0.030 and all(e < 0.010 for e in energies[max(0, idx - silent_blocks):idx]):
            pos = max(0, idx * block - int(rate * 0.028))
            length = min(int(rate * 0.030), len(out) - pos)
            if length <= 0:
                continue
            chirps_added += 1
            if chirps_added > 4:
                break
            for i in range(length):
                t = i / rate
                sweep = 820.0 + 900.0 * (i / max(1, length))
                env = math.sin(math.pi * i / max(1, length))
                out[pos + i] += 0.030 * env * math.sin(2.0 * math.pi * sweep * t)
    return out

def stackchan_spark_synth(rate, samples):
    samples = remove_dc(samples)
    samples = resample_linear(samples, $robotPitchCadenceFactor)
    samples = phrase_micro_prosody(rate, samples)
    samples = sample_hold(samples, rate, $sampleHoldHz)

    delay_a = max(1, int(rate * 0.0045))
    delay_b = max(1, int(rate * 0.0095))
    echo_a = max(1, int(rate * 0.052))
    echo_b = max(1, int(rate * 0.087))
    out = [0.0] * (len(samples) + echo_b + 1)
    low = 0.0
    prev = 0.0
    comb_a = [0.0] * delay_a
    comb_b = [0.0] * delay_b
    for i, sample in enumerate(samples):
        low += 0.16 * (sample - low)
        bright = sample - 0.62 * low
        t = i / rate
        wobble = math.sin(2.0 * math.pi * 4.3 * t)
        pulse = 0.91 + 0.09 * math.sin(2.0 * math.pi * 7.6 * t)
        carrier = (
            0.70
            + 0.18 * math.sin(2.0 * math.pi * ($ringModBaseHz + wobble * 2.5) * t)
            + 0.08 * math.sin(2.0 * math.pi * $ringModHarmonicHz * t)
        )
        emphasized = bright - 0.34 * prev
        prev = bright
        resonant = emphasized + 0.32 * comb_a[i % delay_a] - 0.18 * comb_b[i % delay_b]
        comb_a[i % delay_a] = resonant
        comb_b[i % delay_b] = resonant
        shaped = math.tanh(resonant * 1.75) * carrier * pulse
        crushed = round(shaped * 62.0) / 62.0
        out[i] += crushed
        out[i + echo_a] += crushed * 0.12
        out[i + echo_b] += crushed * 0.055

    out = add_spark_chirps(rate, out)
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
    write_wav(out_path, rate, stackchan_spark_synth(rate, samples))
"@ | Set-Content -Path $effectScript -Encoding UTF8

  & $pythonPath $effectScript $tempDir $outputPath
  if ($LASTEXITCODE -ne 0) {
    throw "Voice sample effect processing failed."
  }

  $sampleList = ($samples | ForEach-Object {
    "- ``stackchan_spark_$($_.Slug).wav``: $($_.Title) - `"$($_.Text)`""
  }) -join [Environment]::NewLine

  $sourceMode = if ($useEspeak) {
    "formant source via ``$selectedVoice``"
  } else {
    "fallback source via ``$selectedVoice``; install eSpeak-NG or pass ``-Engine espeak`` to use a formant source"
  }

  @"
# Stackchan Spark Voice Samples

These are prototype audition samples for the original Stackchan Spark voice direction. They are not a Johnny 5 clone, are not trained from soundboard clips, and do not use RVC character models.

Generated source:
- Source mode: $sourceMode
- Stackchan Spark Synth v2 DSP: phrase-level micro-prosody, staccato amplitude shaping, lowered-pitch resample, sample-hold texture, high-pass formant emphasis, light ring modulation, comb-filter resonance, subtle bit-depth reduction, soft saturation, short echo, and tiny synthetic chirps
- Tuning: source speech rate ``$speechRate`` where supported, pitch/cadence resample factor ``$robotPitchCadenceFactor``, ring modulation ``$ringModBaseHz``/``$ringModHarmonicHz`` Hz, sample-hold target ``$sampleHoldHz`` Hz
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
