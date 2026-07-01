param(
  [string]$MediaRoot = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

if ([string]::IsNullOrWhiteSpace($MediaRoot)) {
  if (Test-Path -LiteralPath "media") {
    $MediaRoot = "media"
  } elseif (Test-Path -LiteralPath "docs/media") {
    $MediaRoot = "docs/media"
  } else {
    throw "Could not find preview media. Pass -MediaRoot explicitly."
  }
}

if (-not (Test-Path -LiteralPath $MediaRoot)) {
  throw "Missing media root: $MediaRoot"
}

$mediaRootPath = (Resolve-Path $MediaRoot).Path

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import json
import sys
from pathlib import Path

import imageio.v2 as imageio
from PIL import Image, ImageStat


media_root = Path(sys.argv[1])
expected_size = (640, 480)


def fail(message: str) -> None:
    raise SystemExit(message)


def require_file(name: str, min_bytes: int) -> Path:
    path = media_root / name
    if not path.exists():
        fail(f"Missing preview media: {path}")
    if path.stat().st_size < min_bytes:
        fail(f"Preview media too small: {path} ({path.stat().st_size} bytes)")
    return path


def image_stats(image: Image.Image) -> dict[str, object]:
    rgb = image.convert("RGB")
    colors = rgb.getcolors(maxcolors=1_000_000)
    unique = len(colors or [])
    stat = ImageStat.Stat(rgb)
    # Count pixels that differ from the dark preview background enough to prove visible content.
    bg = (7, 16, 19)
    visible = 0
    sample_stride = max(1, (rgb.width * rgb.height) // 120_000)
    pixels = rgb.load()
    total = 0
    idx = 0
    for y in range(rgb.height):
        for x in range(rgb.width):
            idx += 1
            if idx % sample_stride:
                continue
            total += 1
            pixel = pixels[x, y]
            if sum(abs(pixel[i] - bg[i]) for i in range(3)) > 30:
                visible += 1
    visible_ratio = visible / max(1, total)
    return {
        "size": rgb.size,
        "unique_colors": unique,
        "visible_ratio": visible_ratio,
        "channel_extrema": stat.extrema,
    }


def assert_nonblank(stats: dict[str, object], label: str) -> None:
    if stats["size"] != expected_size:
        fail(f"{label} has wrong dimensions: {stats['size']}, expected {expected_size}")
    if stats["unique_colors"] < 8:
        fail(f"{label} has too few colors to be credible preview media: {stats['unique_colors']}")
    if stats["visible_ratio"] < 0.02:
        fail(f"{label} appears blank or near-blank: visible_ratio={stats['visible_ratio']:.4f}")


png = require_file("stackchan_alive_preview.png", 1000)
gif = require_file("stackchan_alive_preview.gif", 1000)
mp4 = require_file("stackchan_alive_preview.mp4", 1000)

with Image.open(png) as im:
    png_stats = image_stats(im)
    assert_nonblank(png_stats, "PNG preview")

gif_reader = imageio.get_reader(gif)
try:
    gif_meta = gif_reader.get_meta_data()
    gif_count = 0
    first_gif_stats = None
    for frame in gif_reader:
        gif_count += 1
        if first_gif_stats is None:
            first_gif_stats = image_stats(Image.fromarray(frame))
        if gif_count >= 240:
            break
    if first_gif_stats is None:
        fail("GIF preview has no readable frames")
    assert_nonblank(first_gif_stats, "GIF preview")
    if gif_count < 30:
        fail(f"GIF preview has too few readable frames: {gif_count}")
finally:
    gif_reader.close()

mp4_reader = imageio.get_reader(mp4)
try:
    mp4_meta = mp4_reader.get_meta_data()
    fps = float(mp4_meta.get("fps") or 0)
    duration = float(mp4_meta.get("duration") or 0)
    mp4_count = 0
    first_mp4_stats = None
    for frame in mp4_reader:
        mp4_count += 1
        if first_mp4_stats is None:
            first_mp4_stats = image_stats(Image.fromarray(frame))
        if mp4_count >= 240:
            break
    if first_mp4_stats is None:
        fail("MP4 preview has no readable frames")
    assert_nonblank(first_mp4_stats, "MP4 preview")
    if mp4_count < 30:
        fail(f"MP4 preview has too few readable frames: {mp4_count}")
    if fps <= 0:
        fail("MP4 preview has missing/invalid fps metadata")
    if duration and duration < 2.0:
        fail(f"MP4 preview duration too short: {duration:.2f}s")
finally:
    mp4_reader.close()

print(json.dumps({
    "mediaRoot": str(media_root),
    "png": {
        "size": png_stats["size"],
        "uniqueColors": png_stats["unique_colors"],
        "visibleRatio": round(float(png_stats["visible_ratio"]), 4),
    },
    "gif": {
        "framesChecked": gif_count,
        "metadata": {k: str(v) for k, v in gif_meta.items() if k in {"duration", "fps", "loop"}},
    },
    "mp4": {
        "framesChecked": mp4_count,
        "fps": fps,
        "duration": duration,
    },
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_preview_media.py"
$pythonScript | Set-Content -Path $tempScript -Encoding UTF8
try {
  & $pythonPath $tempScript $mediaRootPath
  if ($LASTEXITCODE -ne 0) {
    throw "Preview media verification failed with exit code $LASTEXITCODE"
  }
} finally {
  Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}

Write-Host "Preview media verified:"
Write-Host $mediaRootPath
