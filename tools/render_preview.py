from __future__ import annotations

import math
from pathlib import Path

import imageio.v2 as imageio
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "media"
OUT.mkdir(parents=True, exist_ok=True)

WIDTH = 320
HEIGHT = 240
SCALE = 2
BG = (7, 16, 19)
EYE = (247, 251, 255)
PUPIL = (17, 24, 39)
ACCENT = (97, 228, 215)
MOUTH = (255, 107, 138)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def face_targets(t: float) -> dict[str, float]:
    # Preview the same style of continuous parameters used by the firmware.
    mode = int(t / 1.25) % 4
    arousal = 0.35 + 0.35 * max(0.0, math.sin(t * 1.7))
    valence = 0.35 + 0.45 * math.sin(t * 0.9)
    focus = 0.65 + 0.25 * math.sin(t * 1.1 + 0.8)

    mouth_open = 0.0
    pupil_y = 0.0
    if mode == 1:  # listen
        focus = 0.92
        arousal = 0.48
    elif mode == 2:  # think
        pupil_y = -0.2
        valence = 0.2
    elif mode == 3:  # speak
        mouth_open = 0.45 + 0.35 * abs(math.sin(t * 12.0))
        valence = 0.6

    blink_phase = (t % 3.8)
    blink = 1.0
    if 2.9 < blink_phase < 3.02:
        blink = 1.0 - (blink_phase - 2.9) / 0.12
    elif 3.02 <= blink_phase < 3.09:
        blink = 0.0
    elif 3.09 <= blink_phase < 3.24:
        blink = (blink_phase - 3.09) / 0.15

    return {
        "eye_open": clamp(0.72 + arousal * 0.3, 0.15, 1.0) * blink,
        "squint": clamp(max(0.0, -valence) * 0.5, 0.0, 1.0),
        "eye_smile": clamp(max(0.0, valence) * 0.55, 0.0, 1.0),
        "pupil_x": math.sin(t * 1.8) * (1.0 - focus) * 0.5,
        "pupil_y": pupil_y + math.sin(t * 1.2) * 0.08,
        "brow_tilt": clamp(valence * 0.30 + arousal * 0.15, -1.0, 1.0),
        "mouth_smile": clamp(valence * 0.75, -1.0, 1.0),
        "mouth_open": mouth_open,
    }


def rounded_rect(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], radius: int, fill: tuple[int, int, int]) -> None:
    draw.rounded_rectangle(xy, radius=radius, fill=fill)


def draw_eye(draw: ImageDraw.ImageDraw, cx: float, cy: float, target: dict[str, float], right: bool) -> None:
    width = 70 - target["squint"] * 10
    height = 56
    x0 = int(cx - width / 2)
    y0 = int(cy - height / 2)
    x1 = int(cx + width / 2)
    y1 = int(cy + height / 2)
    rounded_rect(draw, (x0, y0, x1, y1), min(18, int(height / 2)), EYE)

    px = int(cx + target["pupil_x"] * width * 0.22)
    py = int(cy + target["pupil_y"] * height * 0.18)
    rx = max(4, int(width / 10))
    ry = max(4, int(height / 5))
    draw.ellipse((px - rx, py - ry, px + rx, py + ry), fill=PUPIL)
    draw.ellipse((px - rx, py - ry, px - rx // 3, py - ry // 3), fill=EYE)

    upper_coverage = int((1.0 - clamp(target["eye_open"], 0.0, 1.0)) * height)
    if upper_coverage > 0:
        draw.rectangle((x0, y0, x1, y0 + upper_coverage), fill=BG)
        if upper_coverage < height - 2:
            lid_y = y0 + upper_coverage
            draw.line((x0 + 4, lid_y, x1 - 4, lid_y), fill=ACCENT, width=1)

    lower_coverage = int(target["eye_smile"] * 10)
    if lower_coverage > 0:
        lid_y = y1 - lower_coverage
        draw.rectangle((x0, lid_y, x1, y1), fill=BG)
        draw.line((x0 + 4, lid_y, x1 - 4, lid_y), fill=ACCENT, width=1)

    if abs(target["brow_tilt"]) > 0.03 or target["squint"] > 0.05:
        brow_y = int(cy - height * 0.72)
        brow_half = max(16, int(width / 4))
        tilt = clamp(target["brow_tilt"] + target["squint"] * 0.35, -1.0, 1.0) * 9
        inner_y = brow_y + int(tilt)
        outer_y = brow_y - int(tilt)
        x_left = int(cx - brow_half)
        x_right = int(cx + brow_half)
        y_left = inner_y if right else outer_y
        y_right = outer_y if right else inner_y
        draw.line((x_left, y_left, x_right, y_right), fill=EYE, width=2)


def draw_mouth(draw: ImageDraw.ImageDraw, target: dict[str, float]) -> None:
    cx, cy, width = 160, target.get("mouth_y", 172), 64
    smile = target["mouth_smile"]
    curve = int((1 if smile >= 0 else -1) * (abs(smile) ** 0.6) * 22)
    open_px = int(target["mouth_open"] * 18)
    if open_px > 3:
        draw.ellipse((cx - width // 4, cy - open_px // 2, cx + width // 4, cy + open_px), fill=MOUTH)
        draw.ellipse((cx - width // 6, cy - open_px // 4, cx + width // 6, cy + open_px // 2), fill=BG)
        return

    points = []
    for i in range(33):
        u = i / 32
        x = (1 - u) ** 2 * (cx - width // 2) + 2 * (1 - u) * u * cx + u**2 * (cx + width // 2)
        y = (1 - u) ** 2 * cy + 2 * (1 - u) * u * (cy + curve) + u**2 * cy
        points.append((int(x), int(y)))
    draw.line(points, fill=MOUTH, width=3)


def render_frame(t: float) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    target = face_targets(t)
    alive_y = math.sin(t * 2.0) * 2
    draw_eye(draw, 106, 104 + alive_y, target, False)
    draw_eye(draw, 214, 104 + alive_y, target, True)
    target = {**target, "mouth_y": 172 + alive_y}
    draw_mouth(draw, target)
    draw.text((160, 220), "Stackchan Alive", fill=ACCENT, anchor="mm")
    return img.resize((WIDTH * SCALE, HEIGHT * SCALE), Image.Resampling.NEAREST)


def main() -> None:
    still = render_frame(2.7)
    still.save(OUT / "stackchan_alive_preview.png")

    fps = 30
    frames = [render_frame(i / fps) for i in range(fps * 6)]
    imageio.mimsave(OUT / "stackchan_alive_preview.gif", frames, fps=fps)

    try:
      imageio.mimsave(OUT / "stackchan_alive_preview.mp4", frames, fps=fps, quality=8)
    except Exception as exc:
      print(f"mp4 generation skipped: {exc}")

    print(f"Wrote preview media to {OUT}")


if __name__ == "__main__":
    main()
