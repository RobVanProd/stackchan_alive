param(
  [string]$ArtifactsRoot = "artifacts/face"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")
Push-Location $repoRoot
trap {
  Pop-Location
  throw
}

function Assert-Text {
  param(
    [string]$Path,
    [string[]]$Patterns
  )

  $text = Get-Content -LiteralPath $Path -Raw
  foreach ($pattern in $Patterns) {
    if ($text -notmatch [regex]::Escape($pattern)) {
      throw "$Path missing Phase E marker: $pattern"
    }
  }
}

$sourceRoot = if (Test-Path -LiteralPath "src") { "src" } elseif (Test-Path -LiteralPath "provenance/src") { "provenance/src" } else { throw "Missing source root for Phase E verification." }
$previewScript = if (Test-Path -LiteralPath "tools/render_preview.py") { "tools/render_preview.py" } else { "" }

Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.hpp") @("SpeechViseme", "FaceSpeechTelemetry", "setSpeechEnvelope", "clearSpeechEnvelope", "speechTelemetry")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.cpp") @("speech_.rollingPeak", "Speech onset blink suppression", "Speech brow accent", "mouthWidthDelta", "SpeechViseme::Oh", "SpeechViseme::Ee")
if (-not [string]::IsNullOrWhiteSpace($previewScript)) {
  Assert-Text $previewScript @("phase_e_speech_reactive_6s.gif", "phase_e_speech_targets", "phase_e_speech_envelope", "render_speech_frame")
}

if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
  throw "Missing Phase E artifacts root: $ArtifactsRoot"
}

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image, ImageSequence


root = Path(sys.argv[1])
path = root / "phase_e_speech_reactive_6s.gif"


def fail(message: str) -> None:
    raise SystemExit(message)


if not path.exists():
    fail(f"Missing Phase E speech GIF: {path}")
if path.stat().st_size < 1000:
    fail(f"Phase E speech GIF too small: {path.stat().st_size} bytes")

image = Image.open(path)
frames = [frame.convert("RGB") for frame in ImageSequence.Iterator(image)]
if len(frames) < 140:
    fail(f"Phase E speech GIF has too few frames: {len(frames)}")
if frames[0].size != (640, 480):
    fail(f"Phase E speech GIF has wrong dimensions: {frames[0].size}")


def mouth_count(frame: Image.Image) -> int:
    crop = frame.crop((160, 250, 480, 390))
    if hasattr(crop, "get_flattened_data"):
        pixels = crop.get_flattened_data()
    else:
        pixels = crop.getdata()
    return sum(1 for r, g, b in pixels if r > 200 and 45 < g < 165 and 80 < b < 195)


counts = [mouth_count(frame) for frame in frames]
max_count = max(counts)
min_count = min(counts)
if max_count - min_count < 450:
    fail(f"Phase E mouth motion range too small: min={min_count} max={max_count}")

peaks = 0
for index in range(2, len(counts) - 2):
    if counts[index] > counts[index - 1] and counts[index] >= counts[index + 1] and counts[index] > min_count + 280:
        if index == 2 or counts[index - 2] < counts[index] - 40:
            peaks += 1
if peaks < 3:
    fail(f"Phase E speech GIF has too few visible syllable peaks: {peaks}")

tail = counts[-18:]
if sum(tail) / len(tail) > max_count * 0.45:
    fail(f"Phase E mouth does not return to rest after speech: tail_avg={sum(tail) / len(tail):.1f} max={max_count}")

print(json.dumps({
    "artifact": str(path),
    "frames": len(frames),
    "size": frames[0].size,
    "mouthMin": min_count,
    "mouthMax": max_count,
    "mouthRange": max_count - min_count,
    "visiblePeaks": peaks,
    "tailAverage": round(sum(tail) / len(tail), 2),
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_face_phase_e.py"
Set-Content -LiteralPath $tempScript -Value $pythonScript -Encoding UTF8
& $pythonPath $tempScript (Resolve-Path $ArtifactsRoot)
if ($LASTEXITCODE -ne 0) {
  throw "Phase E face artifact verification failed."
}

Write-Host "Phase E face artifacts verified:"
Write-Host (Resolve-Path $ArtifactsRoot)
Pop-Location
