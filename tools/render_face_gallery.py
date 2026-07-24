"""Render every installed persona's face into one comparison sheet.

This is the "what will my face actually look like?" tool. It drives the same
drawing code as tools/render_preview.py, which mirrors the firmware renderer, so
a row here is what that persona shows on the panel.

    python tools/render_face_gallery.py                 # every installed pack
    python tools/render_face_gallery.py spark bolt      # only these

Writes docs/media/face_gallery.png plus one strip per persona.
"""

from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "media"
sys.path.insert(0, str(ROOT / "tools"))
sys.path.insert(0, str(ROOT / "bridge"))

# Poses chosen to show the range: resting, attentive, thinking, talking, asleep.
POSES = ("idle", "listen", "think", "speak", "sleep")

LABEL_W = 116
PAD = 8
BAR_H = 26


def installed_personas() -> list[str]:
    packs = sorted(p.name for p in (ROOT / "personas").iterdir() if (p / "pack.yaml").is_file())
    # Keep the reference pack first; it is the one docs talk about.
    packs.sort(key=lambda name: (name != "spark", name))
    return packs


def render_persona_row(persona: str) -> tuple[list[Image.Image], tuple[int, int, int]]:
    """Import the preview module fresh so its module-level face spec is re-read."""
    os.environ["STACKCHAN_PERSONA"] = persona
    sys.modules.pop("render_preview", None)
    rp = importlib.import_module("render_preview")

    frames = []
    for pose in POSES:
        target = rp.phase_d_pose(pose)
        frames.append(rp.render_pose(pose, target, show_label=False, show_brand=False))
    return frames, rp.ACCENT


def main() -> int:
    requested = [a for a in sys.argv[1:] if not a.startswith("-")]
    personas = requested or installed_personas()

    rows: list[tuple[str, list[Image.Image], tuple[int, int, int]]] = []
    for persona in personas:
        try:
            frames, accent = render_persona_row(persona)
        except Exception as exc:
            print(f"[gallery] skipping {persona}: {exc}")
            continue
        rows.append((persona, frames, accent))
        strip = Image.new("RGB", (frames[0].width * len(frames), frames[0].height), (0, 0, 0))
        for i, frame in enumerate(frames):
            strip.paste(frame, (i * frame.width, 0))
        OUT.mkdir(parents=True, exist_ok=True)
        strip_path = OUT / f"face_{persona}.png"
        strip.save(strip_path)
        print(f"[gallery] {persona}: {strip_path.relative_to(ROOT)}")

    if not rows:
        print("[gallery] no personas rendered")
        return 1

    cell_w, cell_h = rows[0][1][0].size
    sheet_w = LABEL_W + len(POSES) * (cell_w + PAD) + PAD
    sheet_h = BAR_H + len(rows) * (cell_h + PAD) + PAD
    sheet = Image.new("RGB", (sheet_w, sheet_h), (18, 18, 22))
    draw = ImageDraw.Draw(sheet)

    for i, pose in enumerate(POSES):
        x = LABEL_W + i * (cell_w + PAD) + cell_w // 2
        draw.text((x, BAR_H // 2), pose, fill=(210, 214, 222), anchor="mm")

    for r, (persona, frames, accent) in enumerate(rows):
        y = BAR_H + r * (cell_h + PAD) + PAD // 2
        draw.text((PAD, y + cell_h // 2), persona, fill=accent, anchor="lm")
        for c, frame in enumerate(frames):
            sheet.paste(frame, (LABEL_W + c * (cell_w + PAD), y))

    OUT.mkdir(parents=True, exist_ok=True)
    sheet_path = OUT / "face_gallery.png"
    sheet.save(sheet_path)
    print(f"[gallery] sheet -> {sheet_path.relative_to(ROOT)}  ({len(rows)} personas)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
