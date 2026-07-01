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

$speechRate = -2
$robotPitchCadenceFactor = 1.12
$ringModBaseHz = 44.0
$ringModHarmonicHz = 88.0
$sampleHoldHz = 11800.0
$robotBasePitchHz = 104.0
$syntheticMaskMix = 0.48

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

def envelope_follow(samples, rate):
    attack = math.exp(-1.0 / max(1.0, rate * 0.004))
    release = math.exp(-1.0 / max(1.0, rate * 0.050))
    env = []
    state = 0.0
    for sample in samples:
        target = abs(sample)
        coeff = attack if target > state else release
        state = coeff * state + (1.0 - coeff) * target
        env.append(min(1.0, state * 3.8))
    return env

def syllable_gate(rate, samples):
    env = envelope_follow(samples, rate)
    window = max(1, int(rate * 0.082))
    out = []
    for i, sample in enumerate(samples):
        segment = (i // window) % 5
        t = (i % window) / max(1, window)
        punch = 0.78 + 0.22 * math.sin(math.pi * min(1.0, t * 1.4))
        if segment in (1, 4):
            punch *= 0.88
        if env[i] < 0.030:
            punch *= 0.70
        out.append(sample * punch)
    return out

def formant_resonator(samples, rate, freq, radius):
    omega = 2.0 * math.pi * freq / rate
    coeff = 2.0 * radius * math.cos(omega)
    radius_sq = radius * radius
    y1 = 0.0
    y2 = 0.0
    out = []
    for sample in samples:
        y = sample + coeff * y1 - radius_sq * y2
        out.append(y * (1.0 - radius))
        y2 = y1
        y1 = y
    return out

def add_electromechanical_mask(rate, samples):
    env = envelope_follow(samples, rate)
    mask_seed = []
    stepped_pitch = $robotBasePitchHz
    step_len = max(1, int(rate * 0.075))
    phase = 0.0
    for i, amp in enumerate(env):
        if i % step_len == 0:
            step = ((i // step_len) % 6) - 2
            stepped_pitch = $robotBasePitchHz * (2.0 ** (step / 24.0))
        t = i / rate
        pitch = stepped_pitch + 2.4 * math.sin(2.0 * math.pi * 3.2 * t)
        phase = (phase + pitch / rate) % 1.0
        square = 1.0 if phase < 0.52 else -1.0
        saw = (phase * 2.0) - 1.0
        undertone = math.sin(2.0 * math.pi * 52.0 * t)
        mask_seed.append(amp * (0.34 * square + 0.20 * saw + 0.08 * undertone))

    f1 = formant_resonator(mask_seed, rate, 760.0, 0.970)
    f2 = formant_resonator(mask_seed, rate, 1420.0, 0.965)
    f3 = formant_resonator(mask_seed, rate, 2380.0, 0.955)
    out = []
    for i, sample in enumerate(samples):
        t = i / rate
        ticker = 0.86 + 0.14 * (1.0 if math.sin(2.0 * math.pi * 18.0 * t) > 0.0 else -1.0)
        synthetic = (0.54 * f1[i] + 0.34 * f2[i] + 0.18 * f3[i]) * ticker
        out.append(sample * (1.0 - $syntheticMaskMix) + synthetic * $syntheticMaskMix)
    return out

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
    samples = syllable_gate(rate, samples)
    samples = sample_hold(samples, rate, $sampleHoldHz)
    samples = add_electromechanical_mask(rate, samples)

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

def lowpass(samples, amount):
    out = []
    state = 0.0
    for sample in samples:
        state += amount * (sample - state)
        out.append(state)
    return out

def audition_warm_slow(rate, samples):
    slowed = resample_linear(samples, 1.10)
    rounded = lowpass(slowed, 0.34)
    out = []
    for i, sample in enumerate(rounded):
        t = i / rate
        motion = 0.96 + 0.04 * math.sin(2.0 * math.pi * 5.1 * t)
        out.append(math.tanh(sample * 1.18) * motion)
    return out

def audition_bright_robot(rate, samples):
    held = sample_hold(samples, rate, 8200.0)
    delay = max(1, int(rate * 0.0038))
    comb = [0.0] * delay
    out = [0.0] * len(held)
    prev = 0.0
    for i, sample in enumerate(held):
        t = i / rate
        edge = sample - 0.44 * prev
        prev = sample
        carrier = 0.76 + 0.20 * math.sin(2.0 * math.pi * 58.0 * t) + 0.06 * math.sin(2.0 * math.pi * 116.0 * t)
        resonant = edge + 0.42 * comb[i % delay]
        comb[i % delay] = resonant
        out[i] = round(math.tanh(resonant * 2.05) * carrier * 46.0) / 46.0
    return out

for name in sorted(os.listdir(source_dir)):
    if not name.endswith("-source.wav"):
        continue
    slug = name[:-len("-source.wav")]
    rate, samples = read_wav(os.path.join(source_dir, name))
    processed = stackchan_spark_synth(rate, samples)
    out_path = os.path.join(out_dir, f"stackchan_spark_{slug}.wav")
    write_wav(out_path, rate, processed)
    if slug == "greeting":
        write_wav(os.path.join(out_dir, "stackchan_spark_audition_warm_slow_greeting.wav"), rate, audition_warm_slow(rate, processed))
        write_wav(os.path.join(out_dir, "stackchan_spark_audition_bright_robot_greeting.wav"), rate, audition_bright_robot(rate, processed))
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
- Stackchan Spark Synth v3 DSP: phrase-level micro-prosody, syllable gating, lowered-pitch resample, speech-envelope electromechanical mask, formant-like resonators, sample-hold texture, light ring modulation, comb-filter resonance, subtle bit-depth reduction, soft saturation, short echo, and tiny synthetic chirps
- Tuning: source speech rate ``$speechRate`` where supported, pitch/cadence resample factor ``$robotPitchCadenceFactor``, synthetic mask base pitch ``$robotBasePitchHz`` Hz, mask mix ``$syntheticMaskMix``, ring modulation ``$ringModBaseHz``/``$ringModHarmonicHz`` Hz, sample-hold target ``$sampleHoldHz`` Hz
- Renderer: ``tools/render_voice_samples.ps1``

Samples:
$sampleList

Audition variants:
- ``stackchan_spark_audition_warm_slow_greeting.wav``: warmer, slightly slower review pass for small-speaker intelligibility
- ``stackchan_spark_audition_bright_robot_greeting.wav``: brighter, more synthetic review pass with stronger ring/comb edge

Rollout note: these WAVs are for direction review. Before consumer promotion, the voice source still needs a licensed or owned production source and real-device speaker evidence.
"@ | Set-Content -Path (Join-Path $outputPath "VOICE_SAMPLES.md") -Encoding UTF8

  Write-Host "Rendered Stackchan Spark voice samples:"
  Get-ChildItem -LiteralPath $outputPath -Filter "stackchan_spark_*.wav" | ForEach-Object {
    Write-Host $_.FullName
  }
} finally {
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
