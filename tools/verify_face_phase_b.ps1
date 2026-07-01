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
      throw "$Path missing Phase B marker: $pattern"
    }
  }
}

$sourceRoot = if (Test-Path -LiteralPath "src") { "src" } elseif (Test-Path -LiteralPath "provenance/src") { "provenance/src" } else { throw "Missing source root for Phase B verification." }
$previewScript = if (Test-Path -LiteralPath "tools/render_preview.py") { "tools/render_preview.py" } else { "" }

Assert-Text (Join-Path $sourceRoot "persona/StateMatrix.hpp") @("CharacterMode", "EyeCorners", "pupilScale", "mouthCornerL", "upperLidTilt", "faceY")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.cpp") @("CharacterMode::Think", "CharacterMode::Error", "leftCorners.tr", "rightCorners.tl", "mouthWidthDelta", "pupilScale")
Assert-Text (Join-Path $sourceRoot "face/ProceduralFace.cpp") @("frame.face.faceX", "frame.face.leftCorners", "frame.face.mouthWidthDelta", "frame.face.pupilScale")
Assert-Text (Join-Path $sourceRoot "io/DisplayAdapter.cpp") @("fillTriangle", "cornerTL", "upperLidTilt", "lowerLidTilt", "qbez", "mouth.cornerL")
if (-not [string]::IsNullOrWhiteSpace($previewScript)) {
  Assert-Text $previewScript @("phase_b_unlabeled_expression_sheet.png", "mouth_corner_l", "upper_lid_tilt", "pupil_scale")
}

if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
  throw "Missing Phase B artifacts root: $ArtifactsRoot"
}

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import hashlib
import json
import sys
from pathlib import Path

from PIL import Image


root = Path(sys.argv[1])
bg = (7, 16, 19)


def fail(message: str) -> None:
    raise SystemExit(message)


sheet_path = root / "phase_b_unlabeled_expression_sheet.png"
if not sheet_path.exists():
    fail(f"Missing Phase B unlabeled sheet: {sheet_path}")
if sheet_path.stat().st_size < 1000:
    fail(f"Phase B sheet too small: {sheet_path.stat().st_size} bytes")

sheet = Image.open(sheet_path).convert("RGB")
if sheet.size != (960, 480):
    fail(f"Phase B sheet has wrong size: {sheet.size}")

hashes: list[str] = []
visible_ratios: list[float] = []
asymmetry_scores: list[float] = []
for row in range(2):
    for col in range(3):
        tile = sheet.crop((col * 320, row * 240, (col + 1) * 320, (row + 1) * 240))
        hashes.append(hashlib.sha256(tile.tobytes()).hexdigest())
        pixels = tile.load()
        visible = 0
        asym = 0
        samples = 0
        for y in range(tile.height):
            for x in range(tile.width):
                r, g, b = pixels[x, y]
                if abs(r - bg[0]) + abs(g - bg[1]) + abs(b - bg[2]) > 28:
                    visible += 1
        # Focus the symmetry check on the face zone, not the empty margins.
        zone = tile.crop((55, 55, 265, 190))
        zp = zone.load()
        for y in range(zone.height):
            for x in range(zone.width // 2):
                left = zp[x, y]
                right = zp[zone.width - 1 - x, y]
                if left != right:
                    asym += 1
                samples += 1
        visible_ratios.append(visible / (tile.width * tile.height))
        asymmetry_scores.append(asym / max(1, samples))

if len(set(hashes)) < 6:
    fail("Phase B sheet cells are not all visually distinct")
if min(visible_ratios) < 0.025:
    fail(f"Phase B sheet has a nearly blank pose: {visible_ratios}")
if min(asymmetry_scores) < 0.010:
    fail(f"Phase B sheet has a pose that is too bilaterally symmetric: {asymmetry_scores}")

print(json.dumps({
    "artifactsRoot": str(root),
    "sheetSize": sheet.size,
    "uniquePoseCells": len(set(hashes)),
    "visibleRatioMin": min(visible_ratios),
    "asymmetryScoreMin": min(asymmetry_scores),
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_face_phase_b.py"
Set-Content -LiteralPath $tempScript -Value $pythonScript -Encoding UTF8
& $pythonPath $tempScript (Resolve-Path $ArtifactsRoot)
if ($LASTEXITCODE -ne 0) {
  throw "Phase B face artifact verification failed."
}

Write-Host "Phase B face artifacts verified:"
Write-Host (Resolve-Path $ArtifactsRoot)
Pop-Location
