param(
  [string]$OutputDir = "output/voice_auditions/rvc_base",
  [string]$ModelDir = "output/voice_sources/stackchan_rvc_base/model",
  [string]$PythonPath = "output/rvc_env/Scripts/python.exe"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$outputPath = Join-Path $repoRoot $OutputDir
$sourceDir = Join-Path $outputPath "source"
$convertedDir = Join-Path $outputPath "converted"
$finalDir = Join-Path $outputPath "final"
New-Item -ItemType Directory -Force -Path $sourceDir, $convertedDir, $finalDir | Out-Null

$modelPath = Join-Path $repoRoot (Join-Path $ModelDir "model.pth")
$indexPath = Join-Path $repoRoot (Join-Path $ModelDir "model.index")
if (-not (Test-Path -LiteralPath $modelPath)) {
  throw "Missing RVC model: $modelPath. Extract output/voice_sources/stackchan_rvc_base/stackchan_voice_weightsgg_model.zip first."
}
if (-not (Test-Path -LiteralPath $indexPath)) {
  throw "Missing RVC index: $indexPath"
}
if (-not (Test-Path -LiteralPath $PythonPath)) {
  throw "Missing RVC Python environment: $PythonPath"
}

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

Add-Type -AssemblyName System.Speech
$synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
$voiceNames = @($synth.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
if ($voiceNames -contains "Microsoft David Desktop") {
  $synth.SelectVoice("Microsoft David Desktop")
} elseif ($voiceNames.Count -gt 0) {
  $synth.SelectVoice($voiceNames[0])
}
$selectedVoice = $synth.Voice.Name
$synth.Rate = -2
$synth.Volume = 100

foreach ($sample in $samples) {
  $sourcePath = Join-Path $sourceDir "$($sample.Slug)_source.wav"
  $synth.SetOutputToWaveFile($sourcePath)
  $synth.Speak($sample.Text)
  $synth.SetOutputToNull()
}
$synth.Dispose()

$manifestPath = Join-Path $outputPath "rvc_audition_manifest.json"
$manifest = [ordered]@{
  schema = "stackchan.rvc-audition-manifest.v1"
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  sourceVoice = "Windows SpeechSynthesizer $selectedVoice"
  rvcModel = "data/voice_rvc_base.yaml"
  status = "review-only-candidate"
  rightsNote = "RVC candidate remains pending rights review; samples are not consumer-approved."
  leadAudition = [ordered]@{
    slug = "bright_robot"
    title = "RVC Bright Robot"
    file = "stackchan_rvc_bright_robot.wav"
    transcript = "Hello. I am Stackchan, and I am awake."
    userRating = "near-final direction, approximately 97 percent"
    pitch = 2
    index_rate = 0.62
    rms_mix_rate = 0.72
    protect = 0.28
    perceptualPurpose = "bright synthetic robot character with light vocoder and subtle phrase earcons"
    adjacentComparisons = @(
      "stackchan_rvc_bright_robot_less_static.wav",
      "stackchan_rvc_bright_robot_sweet_vocoder.wav",
      "stackchan_rvc_bright_robot_soft_boops.wav"
    )
  }
  samples = $samples
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8

$pythonScript = Join-Path $outputPath "render_rvc_auditions.py"
@'
import json
import math
import os
import struct
import sys
import wave

from rvc_python.infer import RVCInference

source_dir = sys.argv[1]
converted_dir = sys.argv[2]
final_dir = sys.argv[3]
model_path = sys.argv[4]
index_path = sys.argv[5]
manifest_path = sys.argv[6]

os.makedirs(converted_dir, exist_ok=True)
os.makedirs(final_dir, exist_ok=True)

with open(manifest_path, "r", encoding="utf-8-sig") as handle:
    manifest = json.load(handle)

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

def envelope_follow(samples, rate):
    attack = math.exp(-1.0 / max(1.0, rate * 0.006))
    release = math.exp(-1.0 / max(1.0, rate * 0.080))
    env = []
    state = 0.0
    for sample in samples:
        target = abs(sample)
        coeff = attack if target > state else release
        state = coeff * state + (1.0 - coeff) * target
        env.append(min(1.0, state * 4.2))
    return env

def lowpass(samples, amount):
    out = []
    state = 0.0
    for sample in samples:
        state += amount * (sample - state)
        out.append(state)
    return out

def sample_hold(samples, rate, hold_hz):
    step = max(1, int(round(rate / max(1.0, hold_hz))))
    out = []
    current = 0.0
    for i, sample in enumerate(samples):
        if i % step == 0:
            current = sample
        out.append(current)
    return out

def formant_edge(rate, samples, mix=0.18, carrier_hz=42.0):
    env = envelope_follow(samples, rate)
    out = []
    low = 0.0
    prev = 0.0
    for i, sample in enumerate(samples):
        t = i / rate
        low += 0.11 * (sample - low)
        bright = sample - 0.48 * low
        edge = bright - 0.26 * prev
        prev = bright
        carrier = 0.86 + 0.10 * math.sin(2.0 * math.pi * carrier_hz * t) + 0.04 * math.sin(2.0 * math.pi * carrier_hz * 2.0 * t)
        shaped = math.tanh(edge * 1.45) * carrier
        out.append(sample * (1.0 - mix) + shaped * mix * (0.35 + 0.65 * env[i]))
    return out

def phrase_earcons(rate, samples, mix=0.018):
    out = list(samples)
    env = envelope_follow(samples, rate)
    block = max(1, int(rate * 0.024))
    last_pos = -999999
    added = 0
    note_sets = [(784.0, 1174.7), (659.3, 987.8), (587.3, 880.0), (523.3, 784.0)]
    for pos in range(block * 2, len(samples), block):
        idx = min(len(env) - 1, pos)
        prev = max(0, idx - block)
        onset = env[idx] > 0.10 and max(env[max(0, prev - block):prev + 1] or [0.0]) < 0.055
        if not onset or pos - last_pos < int(rate * 0.48):
            continue
        last_pos = pos
        freqs = note_sets[added % len(note_sets)]
        added += 1
        start = max(0, pos - int(rate * 0.028))
        length = min(int(rate * 0.060), len(out) - start)
        for i in range(length):
            u = i / max(1, length)
            tone_env = math.sin(math.pi * u)
            t = i / rate
            tone = 0.62 * math.sin(2.0 * math.pi * freqs[0] * t) + 0.38 * math.sin(2.0 * math.pi * freqs[1] * t)
            out[start + i] += mix * tone_env * tone
        if added >= 5:
            break
    return out

def light_vocoder(rate, samples, mix=0.07):
    env = envelope_follow(samples, rate)
    out = []
    phase_root = 0.0
    phase_fifth = 0.0
    phase_fourth = 0.0
    note_roots = [220.0, 246.94, 261.63, 293.66, 329.63, 293.66]
    step_len = max(1, int(rate * 0.115))
    for i, sample in enumerate(samples):
        root = note_roots[(i // step_len) % len(note_roots)]
        phase_root = (phase_root + root / rate) % 1.0
        phase_fifth = (phase_fifth + root * 1.5 / rate) % 1.0
        phase_fourth = (phase_fourth + root * (4.0 / 3.0) / rate) % 1.0
        synth = 0.45 * math.sin(2.0 * math.pi * phase_root) + 0.35 * math.sin(2.0 * math.pi * phase_fifth) + 0.20 * math.sin(2.0 * math.pi * phase_fourth)
        gate = min(1.0, max(0.0, (env[i] - 0.025) * 8.0))
        out.append(sample * (1.0 - mix * gate) + synth * env[i] * mix * gate)
    return out

def soft_limit(samples, drive=1.0):
    return [math.tanh(s * drive) / math.tanh(drive) for s in samples]

def finalize_variant(path, style):
    rate, samples = read_wav(path)
    if style == "neutral":
        out = formant_edge(rate, samples, mix=0.10, carrier_hz=36.0)
    elif style == "warm_slow":
        out = lowpass(resample_linear(samples, 1.08), 0.34)
        out = formant_edge(rate, out, mix=0.08, carrier_hz=31.0)
    elif style == "bright_robot":
        out = sample_hold(samples, rate, 10400.0)
        out = formant_edge(rate, out, mix=0.20, carrier_hz=58.0)
        out = light_vocoder(rate, out, mix=0.065)
        out = phrase_earcons(rate, out, mix=0.014)
    elif style == "bright_robot_less_static":
        # Same winning RVC params, with the synthetic edge eased back slightly.
        out = sample_hold(samples, rate, 11200.0)
        out = formant_edge(rate, out, mix=0.185, carrier_hz=54.0)
        out = light_vocoder(rate, out, mix=0.062)
        out = phrase_earcons(rate, out, mix=0.012)
    elif style == "bright_robot_sweet_vocoder":
        # Keeps the bright identity but lets the musical fourth/fifth bed carry more life.
        out = sample_hold(samples, rate, 11200.0)
        out = formant_edge(rate, out, mix=0.178, carrier_hz=52.0)
        out = light_vocoder(rate, out, mix=0.078)
        out = phrase_earcons(rate, out, mix=0.010)
    elif style == "bright_robot_soft_boops":
        # Same core voice with the phrase earcons tucked farther under speech.
        out = sample_hold(samples, rate, 10800.0)
        out = formant_edge(rate, out, mix=0.188, carrier_hz=56.0)
        out = light_vocoder(rate, out, mix=0.066)
        out = phrase_earcons(rate, out, mix=0.007)
    elif style == "spark_boops":
        out = formant_edge(rate, samples, mix=0.16, carrier_hz=47.0)
        out = light_vocoder(rate, out, mix=0.050)
        out = phrase_earcons(rate, out, mix=0.026)
    elif style == "high_character":
        out = sample_hold(samples, rate, 9200.0)
        out = formant_edge(rate, out, mix=0.24, carrier_hz=72.0)
        out = light_vocoder(rate, out, mix=0.090)
    else:
        out = list(samples)
    out = soft_limit(out, drive=1.12)
    return rate, out

variants = [
    {
        "slug": "neutral",
        "title": "RVC Neutral",
        "sample_slug": "greeting",
        "style": "neutral",
        "pitch": 0,
        "index_rate": 0.55,
        "rms_mix_rate": 0.80,
        "protect": 0.33,
        "notes": "Closest to the raw RVC base with only a light Stackchan edge.",
    },
    {
        "slug": "warm_slow",
        "title": "RVC Warm Slow",
        "sample_slug": "greeting",
        "style": "warm_slow",
        "pitch": -1,
        "index_rate": 0.45,
        "rms_mix_rate": 0.90,
        "protect": 0.45,
        "notes": "Warmer, slower, softer consonants for small-speaker intelligibility.",
    },
    {
        "slug": "bright_robot",
        "title": "RVC Bright Robot",
        "sample_slug": "greeting",
        "style": "bright_robot",
        "pitch": 2,
        "index_rate": 0.62,
        "rms_mix_rate": 0.72,
        "protect": 0.28,
        "notes": "Brighter robot pass with light vocoder and subtle phrase earcons.",
    },
    {
        "slug": "bright_robot_less_static",
        "title": "RVC Bright Robot Less Static",
        "sample_slug": "greeting",
        "style": "bright_robot_less_static",
        "pitch": 2,
        "index_rate": 0.62,
        "rms_mix_rate": 0.72,
        "protect": 0.28,
        "notes": "Near-final pass: same RVC settings as Bright Robot with roughly 8 percent less static edge.",
    },
    {
        "slug": "bright_robot_sweet_vocoder",
        "title": "RVC Bright Robot Sweet Vocoder",
        "sample_slug": "greeting",
        "style": "bright_robot_sweet_vocoder",
        "pitch": 2,
        "index_rate": 0.62,
        "rms_mix_rate": 0.72,
        "protect": 0.28,
        "notes": "Near-final pass: same RVC settings with a slightly more pleasant fourth/fifth vocoder blend.",
    },
    {
        "slug": "bright_robot_soft_boops",
        "title": "RVC Bright Robot Soft Boops",
        "sample_slug": "greeting",
        "style": "bright_robot_soft_boops",
        "pitch": 2,
        "index_rate": 0.62,
        "rms_mix_rate": 0.72,
        "protect": 0.28,
        "notes": "Near-final pass: same RVC settings with the beeps and boops tucked lower under the voice.",
    },
    {
        "slug": "spark_boops",
        "title": "RVC Spark Boops",
        "sample_slug": "greeting",
        "style": "spark_boops",
        "pitch": 1,
        "index_rate": 0.58,
        "rms_mix_rate": 0.78,
        "protect": 0.32,
        "notes": "Friendly candidate with slightly more musical beeps and boops.",
    },
    {
        "slug": "high_character",
        "title": "RVC High Character",
        "sample_slug": "greeting",
        "style": "high_character",
        "pitch": 4,
        "index_rate": 0.70,
        "rms_mix_rate": 0.62,
        "protect": 0.22,
        "notes": "Most synthetic and animated; useful as an upper bound.",
    },
    {
        "slug": "thinking_neutral",
        "title": "RVC Thinking",
        "sample_slug": "thinking",
        "style": "neutral",
        "pitch": 0,
        "index_rate": 0.55,
        "rms_mix_rate": 0.80,
        "protect": 0.33,
        "notes": "Neutral RVC settings on the thinking line.",
    },
    {
        "slug": "safety_neutral",
        "title": "RVC Safety",
        "sample_slug": "safety",
        "style": "neutral",
        "pitch": 0,
        "index_rate": 0.55,
        "rms_mix_rate": 0.80,
        "protect": 0.33,
        "notes": "Neutral RVC settings on the safety line.",
    },
]

rvc = RVCInference(device="cpu:0")
rvc.load_model(model_path, version="v2", index_path=index_path)

rendered = []
for variant in variants:
    source_path = os.path.join(source_dir, f"{variant['sample_slug']}_source.wav")
    converted_path = os.path.join(converted_dir, f"stackchan_rvc_{variant['slug']}_raw.wav")
    final_path = os.path.join(final_dir, f"stackchan_rvc_{variant['slug']}.wav")
    rvc.set_params(
        f0method="harvest",
        f0up_key=variant["pitch"],
        index_rate=variant["index_rate"],
        filter_radius=3,
        resample_sr=0,
        rms_mix_rate=variant["rms_mix_rate"],
        protect=variant["protect"],
    )
    rvc.infer_file(source_path, converted_path)
    rate, final_samples = finalize_variant(converted_path, variant["style"])
    write_wav(final_path, rate, final_samples)
    rendered.append({**variant, "file": os.path.basename(final_path)})

manifest["rendered"] = rendered
with open(os.path.join(final_dir, "RVC_AUDITIONS.json"), "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2)

with open(os.path.join(final_dir, "RVC_AUDITIONS.md"), "w", encoding="utf-8") as handle:
    handle.write("# Stackchan RVC Base Auditions\n\n")
    handle.write("Review-only auditions using the selected RVC candidate base. These are not consumer-approved voice assets until rights and source provenance are cleared.\n\n")
    lead = manifest["leadAudition"]
    handle.write("## Current Lead\n\n")
    handle.write(f"- Lead audition: `{lead['file']}` / {lead['title']}.\n")
    handle.write(f"- Transcript: \"{lead['transcript']}\"\n")
    handle.write(f"- Tuning: pitch {lead['pitch']}, index {lead['index_rate']}, RMS mix {lead['rms_mix_rate']}, protect {lead['protect']}.\n")
    handle.write(f"- Listening note: {lead['userRating']}; {lead['perceptualPurpose']}.\n")
    handle.write("- Adjacent comparison passes: " + ", ".join(f"`{name}`" for name in lead["adjacentComparisons"]) + ".\n\n")
    handle.write("## Rendered Samples\n\n")
    for item in rendered:
        text = next(s["Text"] for s in manifest["samples"] if s["Slug"] == item["sample_slug"])
        handle.write(f"- `{item['file']}`: {item['title']} - {item['notes']} Transcript: \"{text}\"\n")

print(json.dumps(rendered, indent=2))
'@ | Set-Content -Path $pythonScript -Encoding UTF8

$env:TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD = "1"
& $PythonPath $pythonScript $sourceDir $convertedDir $finalDir $modelPath $indexPath $manifestPath
if ($LASTEXITCODE -ne 0) {
  throw "RVC audition rendering failed."
}

Write-Host "Rendered RVC auditions:"
Get-ChildItem -LiteralPath $finalDir -Filter "*.wav" | ForEach-Object { Write-Host $_.FullName }
