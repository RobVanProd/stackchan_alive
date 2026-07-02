param(
  [string]$VoiceRoot = "output/voice_auditions/rvc_base/final"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

if (-not (Test-Path -LiteralPath $VoiceRoot)) {
  throw "Missing RVC audition directory: $VoiceRoot"
}

$voiceRootPath = (Resolve-Path $VoiceRoot).Path
$pythonPath = Get-StackchanPreviewPython
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-rvc-mp3-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

try {
  $encoderScript = Join-Path $tempDir "encode_rvc_mp3s.py"
  @'
import json
import os
import subprocess
import sys

import imageio_ffmpeg

voice_root = sys.argv[1]
targets = [
    {
        "wav": "stackchan_rvc_bright_robot.wav",
        "mp3": "stackchan_rvc_bright_robot.mp3",
        "purpose": "browser-friendly MP3 of the current lead RVC Bright Robot audition",
    },
    {
        "wav": "stackchan_rvc_thinking_neutral.wav",
        "mp3": "stackchan_rvc_thinking_neutral.mp3",
        "purpose": "browser-friendly MP3 of the RVC thinking line",
    },
    {
        "wav": "stackchan_rvc_safety_neutral.wav",
        "mp3": "stackchan_rvc_safety_neutral.mp3",
        "purpose": "browser-friendly MP3 of the RVC safety line",
    },
]

ffmpeg = imageio_ffmpeg.get_ffmpeg_exe()

for target in targets:
    wav_path = os.path.join(voice_root, target["wav"])
    mp3_path = os.path.join(voice_root, target["mp3"])
    if not os.path.exists(wav_path):
        raise RuntimeError(f"Missing RVC source WAV for MP3 export: {target['wav']}")
    subprocess.run(
        [
            ffmpeg,
            "-y",
            "-hide_banner",
            "-loglevel",
            "error",
            "-i",
            wav_path,
            "-vn",
            "-codec:a",
            "libmp3lame",
            "-b:a",
            "128k",
            mp3_path,
        ],
        check=True,
    )

json_path = os.path.join(voice_root, "RVC_AUDITIONS.json")
if os.path.exists(json_path):
    with open(json_path, "r", encoding="utf-8-sig") as handle:
        manifest = json.load(handle)
    target_by_wav = {target["wav"]: target for target in targets}
    lead = manifest.get("leadAudition")
    if isinstance(lead, dict) and lead.get("file") in target_by_wav:
        lead["mp3File"] = target_by_wav[lead["file"]]["mp3"]
    for item in manifest.get("rendered", []):
        if isinstance(item, dict) and item.get("file") in target_by_wav:
            item["mp3File"] = target_by_wav[item["file"]]["mp3"]
    manifest["quickMp3Copies"] = [
        {
            "file": target["mp3"],
            "sourceWav": target["wav"],
            "purpose": target["purpose"],
        }
        for target in targets
    ]
    with open(json_path, "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")

notes_path = os.path.join(voice_root, "RVC_AUDITIONS.md")
if os.path.exists(notes_path):
    with open(notes_path, "r", encoding="utf-8-sig") as handle:
        notes = handle.read().rstrip()
    marker = "\n\n## Quick MP3 Copies\n"
    if marker in notes:
        notes = notes.split(marker, 1)[0].rstrip()
    lines = [
        "",
        "## Quick MP3 Copies",
        "",
        "These MP3 files mirror the lead and core RVC review lines for browser playback. The WAV files remain the reference audio.",
        "",
    ]
    for target in targets:
        lines.append(f"- `{target['mp3']}` from `{target['wav']}`: {target['purpose']}.")
    lines.append("")
    lines.append("Rollout note: these remain review-only RVC candidate samples until voice-source provenance and rights review are complete.")
    notes = notes + "\n".join(lines) + "\n"
    with open(notes_path, "w", encoding="utf-8") as handle:
        handle.write(notes)

print(json.dumps(targets, indent=2))
'@ | Set-Content -Path $encoderScript -Encoding UTF8

  & $pythonPath $encoderScript $voiceRootPath
  if ($LASTEXITCODE -ne 0) {
    throw "RVC audition MP3 export failed."
  }

  Write-Host "Rendered RVC audition MP3s:"
  Get-ChildItem -LiteralPath $voiceRootPath -Filter "*.mp3" |
    Sort-Object Name |
    ForEach-Object { Write-Host $_.FullName }
} finally {
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
