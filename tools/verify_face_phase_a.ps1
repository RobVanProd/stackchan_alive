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
      throw "$Path missing Phase A marker: $pattern"
    }
  }
}

$sourceRoot = if (Test-Path -LiteralPath "src") { "src" } elseif (Test-Path -LiteralPath "provenance/src") { "provenance/src" } else { throw "Missing source root for Phase A verification." }
$previewScript = if (Test-Path -LiteralPath "tools/render_preview.py") { "tools/render_preview.py" } else { "" }

Assert-Text (Join-Path $sourceRoot "io/DisplayAdapter.cpp") @("M5Canvas", "createSprite(320, 240)", "pushSprite(0, 0)", "frame_ms_avg", "fps_avg", "canvas=double-buffered")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.hpp") @("enum class Ease", "FaceTargets composeFrame", "applyEase")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.cpp") @("Ease::OutBack", "smoothChannel", "applyAutonomic", "applyGesture", "applyReactive")
if (-not [string]::IsNullOrWhiteSpace($previewScript)) {
  Assert-Text $previewScript @("phase_a_idle_10s.gif", "phase_a_blink_filmstrip_50ms.png", "phase_a_unlabeled_expression_sheet.png")
}

if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
  throw "Missing Phase A artifacts root: $ArtifactsRoot"
}

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

import imageio.v2 as imageio
from PIL import Image


root = Path(sys.argv[1])
bg = (7, 16, 19)
accent = (97, 228, 215)


def fail(message: str) -> None:
    raise SystemExit(message)


def require_file(name: str, min_bytes: int) -> Path:
    path = root / name
    if not path.exists():
        fail(f"Missing Phase A artifact: {path}")
    if path.stat().st_size < min_bytes:
        fail(f"Phase A artifact too small: {path} ({path.stat().st_size} bytes)")
    return path


def visible_ratio(image: Image.Image) -> float:
    rgb = image.convert("RGB")
    visible = 0
    total = rgb.width * rgb.height
    pixels = rgb.load()
    for y in range(rgb.height):
        for x in range(rgb.width):
            r, g, b = pixels[x, y]
            if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > 28:
                visible += 1
    return visible / total


sheet_path = require_file("phase_a_unlabeled_expression_sheet.png", 1000)
filmstrip_path = require_file("phase_a_blink_filmstrip_50ms.png", 1000)
gif_path = require_file("phase_a_idle_10s.gif", 100000)

sheet = Image.open(sheet_path)
if sheet.size != (960, 480):
    fail(f"Unlabeled sheet has wrong size: {sheet.size}")
if visible_ratio(sheet) < 0.04:
    fail("Unlabeled sheet appears blank")

filmstrip = Image.open(filmstrip_path)
if filmstrip.size[0] < 320 * 10 or filmstrip.size[1] != 240:
    fail(f"Filmstrip has wrong size: {filmstrip.size}")
if visible_ratio(filmstrip) < 0.04:
    fail("Filmstrip appears blank")

reader = imageio.get_reader(gif_path)
sample_hashes: list[str] = []
accent_counts: list[int] = []
frame_count = 0
for frame in reader:
    if frame_count % 30 == 0:
        image = Image.fromarray(frame).convert("RGB")
        sample_hashes.append(hashlib.sha256(image.tobytes()).hexdigest())
        band = image.crop((0, int(image.height * 0.86), image.width, image.height))
        pixels = band.load()
        count = 0
        for y in range(band.height):
            for x in range(band.width):
                r, g, b = pixels[x, y]
                if abs(r - accent[0]) + abs(g - accent[1]) + abs(b - accent[2]) < 35:
                    count += 1
        accent_counts.append(count)
    frame_count += 1

if frame_count < 240:
    fail(f"Idle GIF too short for Phase A gate: {frame_count} frames")
if len(set(sample_hashes)) < 4:
    fail("Idle GIF does not show enough frame-to-frame life")
if min(accent_counts or [0]) < 40:
    fail("Idle GIF does not keep the Stackchan Alive label visible")

print(json.dumps({
    "artifactsRoot": str(root),
    "idleGifFrames": frame_count,
    "sampledUniqueSeconds": len(set(sample_hashes)),
    "labelAccentPixelMin": min(accent_counts),
    "sheetSize": sheet.size,
    "filmstripSize": filmstrip.size,
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_face_phase_a.py"
Set-Content -LiteralPath $tempScript -Value $pythonScript -Encoding UTF8
& $pythonPath $tempScript (Resolve-Path $ArtifactsRoot)
if ($LASTEXITCODE -ne 0) {
  throw "Phase A face artifact verification failed."
}

Write-Host "Phase A face artifacts verified:"
Write-Host (Resolve-Path $ArtifactsRoot)
Pop-Location
