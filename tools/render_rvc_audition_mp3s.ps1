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

html_path = os.path.join(voice_root, "RVC_AUDITION.html")
with open(html_path, "w", encoding="utf-8") as handle:
    handle.write("""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Stackchan RVC Voice Audition</title>
  <style>
    :root { color-scheme: dark; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #071113; color: #e8f4f2; }
    body { margin: 0; padding: 24px; }
    main { max-width: 820px; margin: 0 auto; }
    h1 { margin: 0 0 8px; font-size: 28px; letter-spacing: 0; }
    p { line-height: 1.5; color: #b7c8c5; }
    .sample { border: 1px solid #24413f; border-radius: 8px; padding: 16px; margin: 16px 0; background: #0d1b1e; }
    .sample h2 { margin: 0 0 8px; font-size: 18px; letter-spacing: 0; }
    audio { width: 100%; margin: 8px 0; }
    .transcript { color: #f5fffd; }
    .links a { color: #68e4d4; margin-right: 16px; }
    .note { border-left: 3px solid #68e4d4; padding-left: 12px; }
  </style>
</head>
<body>
  <main>
    <h1>Stackchan RVC Voice Audition</h1>
    <p class="note">Review-only RVC candidate samples for checking the preferred bright robot direction. These are not consumer-approved voice assets until source provenance and rights review are complete.</p>
""")
    sections = [
        {
            "title": "RVC Bright Robot",
            "mp3": "stackchan_rvc_bright_robot.mp3",
            "wav": "stackchan_rvc_bright_robot.wav",
            "transcript": "Hello. I am Stackchan, and I am awake.",
            "note": "Current lead: pitch 2, index 0.62, RMS mix 0.72, protect 0.28.",
        },
        {
            "title": "RVC Thinking",
            "mp3": "stackchan_rvc_thinking_neutral.mp3",
            "wav": "stackchan_rvc_thinking_neutral.wav",
            "transcript": "Input received. I am thinking now. Curiosity level rising.",
            "note": "Longer phrase for cadence, intelligibility, and timing review.",
        },
        {
            "title": "RVC Safety",
            "mp3": "stackchan_rvc_safety_neutral.mp3",
            "wav": "stackchan_rvc_safety_neutral.wav",
            "transcript": "Small problem found. I can help fix it. Safety first.",
            "note": "Safety phrase for clarity and calmness review.",
        },
    ]
    for section in sections:
        handle.write(f"""
    <section class="sample">
      <h2>{section["title"]}</h2>
      <audio src="{section["mp3"]}" controls preload="metadata"></audio>
      <p class="transcript">{section["transcript"]}</p>
      <p>{section["note"]}</p>
      <p class="links"><a href="{section["mp3"]}">MP3</a></p>
    </section>
""")
    handle.write("""  </main>
</body>
</html>
""")

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
  Write-Host (Join-Path $voiceRootPath "RVC_AUDITION.html")
} finally {
  Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
