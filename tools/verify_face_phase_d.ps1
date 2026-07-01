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
      throw "$Path missing Phase D marker: $pattern"
    }
  }
}

$sourceRoot = if (Test-Path -LiteralPath "src") { "src" } elseif (Test-Path -LiteralPath "provenance/src") { "provenance/src" } else { throw "Missing source root for Phase D verification." }
$previewScript = if (Test-Path -LiteralPath "tools/render_preview.py") { "tools/render_preview.py" } else { "" }

Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.hpp") @("FaceGestureTelemetry", "GestureState", "gestureTelemetry", "updateTransition", "startGesture", "gestureDuration")
Assert-Text (Join-Path $sourceRoot "face/FaceAnimator.cpp") @("applyGesture", "CharacterMode::Listen", "CharacterMode::Think", "CharacterMode::Speak", "CharacterMode::Sleep", "120.0f", "220.0f", "gesture_.durationMs", "blink_.nextMs = nowMs")
if (-not [string]::IsNullOrWhiteSpace($previewScript)) {
  Assert-Text $previewScript @("phase_d_idle_to_listen_filmstrip_50ms.png", "phase_d_think_to_speak_filmstrip_50ms.png", "phase_d_idle_to_sleep_filmstrip_50ms.png", "phase_d_transition_targets", "render_transition_filmstrip")
}

if (-not (Test-Path -LiteralPath $ArtifactsRoot)) {
  throw "Missing Phase D artifacts root: $ArtifactsRoot"
}

$pythonPath = Get-StackchanPreviewPython
$pythonScript = @'
from __future__ import annotations

import json
import sys
from pathlib import Path

from PIL import Image


root = Path(sys.argv[1])


def fail(message: str) -> None:
    raise SystemExit(message)


def load_strip(name: str, min_frames: int) -> list[Image.Image]:
    path = root / name
    if not path.exists():
        fail(f"Missing Phase D filmstrip: {path}")
    if path.stat().st_size < 1000:
        fail(f"Phase D filmstrip too small: {path.stat().st_size} bytes")
    image = Image.open(path).convert("RGB")
    if image.height != 240 or image.width % 320 != 0:
        fail(f"Phase D filmstrip has wrong dimensions: {name} {image.size}")
    frames = [image.crop((i * 320, 0, (i + 1) * 320, 240)) for i in range(image.width // 320)]
    if len(frames) < min_frames:
        fail(f"Phase D filmstrip has too few frames: {name} {len(frames)}")
    return frames


def pixels(frame: Image.Image):
    if hasattr(frame, "get_flattened_data"):
        return frame.get_flattened_data()
    return frame.getdata()


def white_count(frame: Image.Image) -> int:
    return sum(1 for r, g, b in pixels(frame) if r > 215 and g > 225 and b > 230)


def mouth_count(frame: Image.Image) -> int:
    return sum(1 for r, g, b in pixels(frame) if r > 200 and 50 < g < 150 and 90 < b < 180)


idle_listen = load_strip("phase_d_idle_to_listen_filmstrip_50ms.png", 10)
think_speak = load_strip("phase_d_think_to_speak_filmstrip_50ms.png", 7)
idle_sleep = load_strip("phase_d_idle_to_sleep_filmstrip_50ms.png", 60)

idle_listen_white = [white_count(frame) for frame in idle_listen]
think_speak_mouth = [mouth_count(frame) for frame in think_speak]
idle_sleep_white = [white_count(frame) for frame in idle_sleep]

if min(idle_listen_white[1:3]) > idle_listen_white[0] * 0.70:
    fail(f"Idle->Listen filmstrip is missing visible blink anticipation: {idle_listen_white[:4]}")
if idle_listen_white[-1] < idle_listen_white[0] * 1.10:
    fail(f"Idle->Listen filmstrip is missing eye-pop arrival: start={idle_listen_white[0]} end={idle_listen_white[-1]}")

if think_speak_mouth[1] < think_speak_mouth[0] * 1.30:
    fail(f"Think->Speak filmstrip is missing mouth pre-open: {think_speak_mouth[:3]}")
if think_speak_mouth[-1] < think_speak_mouth[0] * 2.50:
    fail(f"Think->Speak filmstrip mouth does not reach speaking shape: start={think_speak_mouth[0]} end={think_speak_mouth[-1]}")

if idle_sleep_white[-1] > idle_sleep_white[0] * 0.25:
    fail(f"Idle->Sleep filmstrip does not close down enough: start={idle_sleep_white[0]} end={idle_sleep_white[-1]}")
if min(idle_sleep_white[20:40]) > idle_sleep_white[0] * 0.75:
    fail("Idle->Sleep filmstrip is missing the fighting-sleep half-lid stage")

print(json.dumps({
    "artifactsRoot": str(root),
    "idleToListenFrames": len(idle_listen),
    "idleToListenWhiteStart": idle_listen_white[0],
    "idleToListenWhiteMinAnticipation": min(idle_listen_white[1:3]),
    "idleToListenWhiteEnd": idle_listen_white[-1],
    "thinkToSpeakFrames": len(think_speak),
    "thinkToSpeakMouthStart": think_speak_mouth[0],
    "thinkToSpeakMouthPreOpen": think_speak_mouth[1],
    "thinkToSpeakMouthEnd": think_speak_mouth[-1],
    "idleToSleepFrames": len(idle_sleep),
    "idleToSleepWhiteStart": idle_sleep_white[0],
    "idleToSleepWhiteMidMin": min(idle_sleep_white[20:40]),
    "idleToSleepWhiteEnd": idle_sleep_white[-1],
}, indent=2))
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan_verify_face_phase_d.py"
Set-Content -LiteralPath $tempScript -Value $pythonScript -Encoding UTF8
& $pythonPath $tempScript (Resolve-Path $ArtifactsRoot)
if ($LASTEXITCODE -ne 0) {
  throw "Phase D face artifact verification failed."
}

Write-Host "Phase D face artifacts verified:"
Write-Host (Resolve-Path $ArtifactsRoot)
Pop-Location
