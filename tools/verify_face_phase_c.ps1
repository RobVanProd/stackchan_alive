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
      throw "$Path missing Phase C marker: $pattern"
    }
  }
}

function Assert-NotText {
  param(
    [string]$Path,
    [string[]]$Patterns
  )

  $text = Get-Content -LiteralPath $Path -Raw
  foreach ($pattern in $Patterns) {
    if ($text -match [regex]::Escape($pattern)) {
      throw "$Path still contains pre-Phase-C split-layer marker: $pattern"
    }
  }
}

$sourceRoot = if (Test-Path -LiteralPath "src") { "src" } elseif (Test-Path -LiteralPath "provenance/src") { "provenance/src" } else { throw "Missing source root for Phase C verification." }
$previewScript = if (Test-Path -LiteralPath "tools/render_preview.py") { "tools/render_preview.py" } else { "" }

Assert-Text (Join-Path $sourceRoot "persona/StateMatrix.hpp") @("eyeWidthScale")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.hpp") @("FaceAutonomicTelemetry", "BlinkPhase", "SaccadeState", "setReducedMotion", "autonomicTelemetry")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.cpp") @("scheduleBlink", "startBlink", "updateSaccade", "chooseSaccadeTarget", "updateFidget", "reducedMotion_", "blinkCompression", "breathHz")
Assert-Text (Join-Path $sourceRoot "face/ProceduralFace.cpp") @("frame.face.eyeWidthScale", "animator_.composeFrame")
Assert-NotText (Join-Path $sourceRoot "face/ProceduralFace.cpp") @("blink_.update", "saccade_.update", "aliveYOffset")
if (-not [string]::IsNullOrWhiteSpace($previewScript)) {
  Assert-Text $previewScript @("phase_c_idle_10s.gif", "blink_open_at", "saccade_at", "phase_c_idle_targets", "eye_width_scale")
}

if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
  throw "Missing Phase C artifacts root: $ArtifactsRoot"
}

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from PIL import Image, ImageSequence


root = Path(sys.argv[1])
bg = (7, 16, 19)


def fail(message: str) -> None:
    raise SystemExit(message)


def is_white(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return r > 215 and g > 225 and b > 230


def is_pupil(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return 8 <= r <= 45 and 12 <= g <= 55 and 24 <= b <= 90


def differs_from_bg(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > 28


gif_path = root / "phase_c_idle_10s.gif"
if not gif_path.exists():
    fail(f"Missing Phase C idle GIF: {gif_path}")
if gif_path.stat().st_size < 100000:
    fail(f"Phase C idle GIF too small: {gif_path.stat().st_size} bytes")

image = Image.open(gif_path)
frames = [frame.convert("RGB") for frame in ImageSequence.Iterator(image)]
if len(frames) < 150:
    fail(f"Phase C idle GIF has too few frames: {len(frames)}")
if frames[0].size != (640, 480):
    fail(f"Phase C idle GIF has wrong frame size: {frames[0].size}")

eye_zone = (90, 90, 550, 300)
left_eye_zone = (110, 90, 310, 300)
white_counts: list[int] = []
left_widths: list[int] = []
pupil_centers: list[tuple[float, float] | None] = []
face_centers_y: list[float] = []

for frame in frames:
    eye = frame.crop(eye_zone)
    pixels = eye.load()
    white = 0
    pupil_x = 0
    pupil_y = 0
    pupil_count = 0
    non_bg_y = 0
    non_bg_count = 0
    for y in range(eye.height):
      for x in range(eye.width):
        pixel = pixels[x, y]
        if is_white(pixel):
          white += 1
        if is_pupil(pixel):
          pupil_x += x
          pupil_y += y
          pupil_count += 1
        if differs_from_bg(pixel):
          non_bg_y += y
          non_bg_count += 1
    white_counts.append(white)
    pupil_centers.append((pupil_x / pupil_count, pupil_y / pupil_count) if pupil_count > 20 else None)
    face_centers_y.append(non_bg_y / non_bg_count if non_bg_count else 0.0)

    left = frame.crop(left_eye_zone)
    left_pixels = left.load()
    xs: list[int] = []
    for y in range(left.height):
      for x in range(left.width):
        if differs_from_bg(left_pixels[x, y]):
          xs.append(x)
    left_widths.append(max(xs) - min(xs) + 1 if xs else 0)

median_white = sorted(white_counts)[len(white_counts) // 2]
low_threshold = median_white * 0.55
blink_events = 0
in_event = False
for count in white_counts:
    low = count < low_threshold
    if low and not in_event:
        blink_events += 1
    in_event = low

median_left_width = sorted(left_widths)[len(left_widths) // 2]
blink_squash_widen = max(left_widths) >= median_left_width + 4

saccade_jumps = 0
last_center = None
cooldown = 0
for center in pupil_centers:
    if center is None:
        continue
    if last_center is not None:
        dx = center[0] - last_center[0]
        dy = center[1] - last_center[1]
        if cooldown == 0 and (dx * dx + dy * dy) ** 0.5 >= 7.0:
            saccade_jumps += 1
            cooldown = 8
    last_center = center
    if cooldown > 0:
        cooldown -= 1

breathing_range = max(face_centers_y) - min(face_centers_y)
second_hashes = [hashlib.sha256(frames[round(i * (len(frames) - 1) / 9)].tobytes()).hexdigest() for i in range(10)]
adjacent_identical_seconds = sum(1 for i in range(1, len(second_hashes)) if second_hashes[i] == second_hashes[i - 1])

if blink_events < 2:
    fail(f"Phase C idle GIF needs at least 2 blink events, found {blink_events}")
if not blink_squash_widen:
    fail(f"Phase C idle GIF does not show blink squash/widen: median_width={median_left_width}, max_width={max(left_widths)}")
if saccade_jumps < 2:
    fail(f"Phase C idle GIF needs at least 2 saccade jumps, found {saccade_jumps}")
if breathing_range < 3.0:
    fail(f"Phase C idle GIF breathing range too small: {breathing_range}")
if adjacent_identical_seconds > 0:
    fail("Phase C idle GIF has identical adjacent second samples")

print(json.dumps({
    "artifactsRoot": str(root),
    "idleGifFrames": len(frames),
    "blinkEvents": blink_events,
    "blinkLeftWidthMedian": median_left_width,
    "blinkLeftWidthMax": max(left_widths),
    "saccadeJumps": saccade_jumps,
    "breathingRangePx": breathing_range,
    "adjacentIdenticalSeconds": adjacent_identical_seconds,
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_face_phase_c.py"
Set-Content -LiteralPath $tempScript -Value $pythonScript -Encoding UTF8
& $pythonPath $tempScript (Resolve-Path $ArtifactsRoot)
if ($LASTEXITCODE -ne 0) {
  throw "Phase C face artifact verification failed."
}

Write-Host "Phase C face artifacts verified:"
Write-Host (Resolve-Path $ArtifactsRoot)
Pop-Location
