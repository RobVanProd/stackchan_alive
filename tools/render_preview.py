from __future__ import annotations

import math
from pathlib import Path

import imageio.v2 as imageio
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "media"
OUT.mkdir(parents=True, exist_ok=True)
FACE_ARTIFACTS = ROOT / "artifacts" / "face"
FACE_ARTIFACTS.mkdir(parents=True, exist_ok=True)

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


def qbez(p0: float, p1: float, p2: float, u: float) -> float:
    a = 1.0 - u
    return a * a * p0 + 2 * a * u * p1 + u * u * p2


def target_with_defaults(target: dict[str, float]) -> dict[str, float]:
    defaults = {
        "eye_open": 0.85,
        "eye_width_scale": 1.0,
        "squint": 0.0,
        "eye_smile": 0.15,
        "pupil_x": 0.0,
        "pupil_y": 0.0,
        "pupil_scale": 1.0,
        "brow_tilt": 0.0,
        "mouth_smile": 0.15,
        "mouth_open": 0.0,
        "mouth_width_delta": 0.0,
        "mouth_corner_l": 0.0,
        "mouth_corner_r": 0.0,
        "upper_lid_tilt": 0.0,
        "lower_lid_tilt": 0.0,
        "face_x": 0.0,
        "face_y": 0.0,
        "left_tl": 0.0,
        "left_tr": 0.0,
        "left_bl": 0.0,
        "left_br": 0.0,
        "right_tl": 0.0,
        "right_tr": 0.0,
        "right_bl": 0.0,
        "right_br": 0.0,
    }
    return {**defaults, **target}


def ease_in_quad(x: float) -> float:
    x = clamp(x, 0.0, 1.0)
    return x * x


def ease_out_back(x: float) -> float:
    x = clamp(x, 0.0, 1.0)
    c1 = 1.70158
    c3 = c1 + 1.0
    u = x - 1.0
    return 1.0 + c3 * u * u * u + c1 * u * u


def blink_open_at(t: float) -> float:
    # Phase C preview blink FSM: fast close, short hold, slower overshooting open.
    for start, close_s, hold_s, open_s in ((1.50, 0.07, 0.04, 0.18), (5.42, 0.08, 0.04, 0.20), (7.72, 0.07, 0.04, 0.16)):
        local = t - start
        if local < 0.0:
            continue
        if local < close_s:
            return 1.0 - ease_in_quad(local / close_s)
        if local < close_s + hold_s:
            return 0.0
        if local < close_s + hold_s + open_s:
            return clamp(ease_out_back((local - close_s - hold_s) / open_s), 0.0, 1.05)
    return 1.0


def saccade_at(t: float) -> tuple[float, float]:
    # Snap to a slight overshoot, then settle over 80 ms. Holds are deliberately uneven.
    events = [
        (0.72, 0.10, -0.03),
        (2.36, -0.16, 0.08),
        (4.84, 0.54, -0.22),
        (6.92, -0.10, 0.04),
        (8.68, 0.18, -0.02),
    ]
    last_x, last_y = 0.0, 0.0
    for index, (start, target_x, target_y) in enumerate(events):
        if t < start:
            break
        prev_x, prev_y = last_x, last_y
        next_start = events[index + 1][0] if index + 1 < len(events) else 999.0
        if t < min(start + 0.08, next_start):
            p = ease_out_back((t - start) / 0.08)
            over_x = target_x + (target_x - prev_x) * 0.15
            over_y = target_y + (target_y - prev_y) * 0.15
            return (over_x + (target_x - over_x) * p, over_y + (target_y - over_y) * p)
        last_x, last_y = target_x, target_y
    return last_x, last_y


def phase_c_idle_targets(t: float) -> dict[str, float]:
    target = target_with_defaults({
        "eye_open": 0.84,
        "eye_smile": 0.12,
        "pupil_scale": 1.0,
        "brow_tilt": 0.12,
        "mouth_smile": 0.24,
        "mouth_width_delta": 5.0,
        "left_tr": 0.04,
        "right_tl": 0.07,
    })
    blink = blink_open_at(t)
    gaze_x, gaze_y = saccade_at(t)
    breath_y = math.sin(2.0 * math.pi * 0.20 * t) * 1.5
    target["eye_open"] = clamp(target["eye_open"] * blink, 0.02, 1.08)
    target["eye_width_scale"] = 1.0 + (1.0 - clamp(blink, 0.0, 1.0)) * 0.15
    target["pupil_x"] += gaze_x
    target["pupil_y"] += gaze_y
    target["face_x"] += gaze_x * 4.0
    target["face_y"] += breath_y + gaze_y * 3.0
    if 9.10 <= t <= 9.85:
        pulse = math.sin(((t - 9.10) / 0.75) * math.pi)
        target["brow_tilt"] += pulse * 0.18
    return target


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

    target = {
        "eye_open": clamp(0.72 + arousal * 0.3, 0.15, 1.0) * blink,
        "squint": clamp(max(0.0, -valence) * 0.5, 0.0, 1.0),
        "eye_smile": clamp(max(0.0, valence) * 0.55, 0.0, 1.0),
        "pupil_x": math.sin(t * 1.8) * (1.0 - focus) * 0.5,
        "pupil_y": pupil_y + math.sin(t * 1.2) * 0.08,
        "pupil_scale": 0.85 + arousal * 0.30,
        "brow_tilt": clamp(valence * 0.30 + arousal * 0.15, -1.0, 1.0),
        "mouth_smile": clamp(valence * 0.75, -1.0, 1.0),
        "mouth_open": mouth_open,
    }
    if mode == 1:
        target.update({"right_br": 0.08, "mouth_width_delta": -2, "pupil_scale": 1.05})
    elif mode == 2:
        target.update({"left_tr": 0.30, "mouth_width_delta": -8, "upper_lid_tilt": 0.08})
    elif mode == 3:
        target.update({"mouth_width_delta": 4, "pupil_scale": 1.08})
    return target_with_defaults(target)


def rounded_rect(draw: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], radius: int, fill: tuple[int, int, int]) -> None:
    draw.rounded_rectangle(xy, radius=radius, fill=fill)


def draw_eye(draw: ImageDraw.ImageDraw, cx: float, cy: float, target: dict[str, float], right: bool) -> None:
    target = target_with_defaults(target)
    width = (70 - target["squint"] * 10) * target["eye_width_scale"]
    height = 56
    cx += target["face_x"]
    cy += target["face_y"]
    x0 = int(cx - width / 2)
    y0 = int(cy - height / 2)
    x1 = int(cx + width / 2)
    y1 = int(cy + height / 2)
    rounded_rect(draw, (x0, y0, x1, y1), min(18, int(height / 2)), EYE)

    prefix = "right" if right else "left"
    cuts = {
        "tl": int(clamp(target[f"{prefix}_tl"], 0.0, 1.0) * height * 0.5),
        "tr": int(clamp(target[f"{prefix}_tr"], 0.0, 1.0) * height * 0.5),
        "bl": int(clamp(target[f"{prefix}_bl"], 0.0, 1.0) * height * 0.5),
        "br": int(clamp(target[f"{prefix}_br"], 0.0, 1.0) * height * 0.5),
    }
    if cuts["tl"] >= 2:
        draw.polygon([(x0, y0), (x0 + cuts["tl"], y0), (x0, y0 + cuts["tl"])], fill=BG)
    if cuts["tr"] >= 2:
        draw.polygon([(x1, y0), (x1 - cuts["tr"], y0), (x1, y0 + cuts["tr"])], fill=BG)
    if cuts["bl"] >= 2:
        draw.polygon([(x0, y1), (x0 + cuts["bl"], y1), (x0, y1 - cuts["bl"])], fill=BG)
    if cuts["br"] >= 2:
        draw.polygon([(x1, y1), (x1 - cuts["br"], y1), (x1, y1 - cuts["br"])], fill=BG)

    px = int(cx + target["pupil_x"] * width * 0.22)
    py = int(cy + target["pupil_y"] * height * 0.18)
    rx = max(4, int(width / 10 * target["pupil_scale"]))
    ry = max(4, int(height / 5 * target["pupil_scale"]))
    draw.ellipse((px - rx, py - ry, px + rx, py + ry), fill=PUPIL)
    draw.ellipse((px - rx - int(target["pupil_x"]), py - ry - int(target["pupil_y"]), px - rx // 3, py - ry // 3), fill=EYE)

    upper_coverage = int((1.0 - clamp(target["eye_open"], 0.0, 1.0)) * height)
    if upper_coverage > 0:
        tilt = int(clamp(target["upper_lid_tilt"], -1.0, 1.0) * 15)
        edge_l = int(clamp(y0 + upper_coverage + tilt, y0, y1))
        edge_r = int(clamp(y0 + upper_coverage - tilt, y0, y1))
        draw.polygon([(x0, y0), (x1, y0), (x1, edge_r), (x0, edge_l)], fill=BG)
        if upper_coverage < height - 2:
            draw.line((x0 + 4, edge_l, x1 - 4, edge_r), fill=ACCENT, width=1)

    lower_coverage = int(target["eye_smile"] * 10)
    if lower_coverage > 0:
        tilt = int(clamp(target["lower_lid_tilt"], -1.0, 1.0) * 8)
        edge_l = int(clamp(y1 - lower_coverage + tilt, y0, y1))
        edge_r = int(clamp(y1 - lower_coverage - tilt, y0, y1))
        draw.polygon([(x0, edge_l), (x1, edge_r), (x1, y1), (x0, y1)], fill=BG)
        draw.line((x0 + 4, edge_l, x1 - 4, edge_r), fill=ACCENT, width=1)

    if abs(target["brow_tilt"]) > 0.03 or target["squint"] > 0.05:
        brow_y = int(cy - height * 0.72)
        brow_half = max(16, int(width / 4))
        squint_tilt = 0.0 if target["brow_tilt"] < 0.0 else target["squint"] * 0.35
        tilt = clamp(target["brow_tilt"] + squint_tilt, -1.0, 1.0) * 9
        inner_y = brow_y + int(tilt)
        outer_y = brow_y - int(tilt)
        x_left = int(cx - brow_half)
        x_right = int(cx + brow_half)
        y_left = inner_y if right else outer_y
        y_right = outer_y if right else inner_y
        draw.line((x_left, y_left, x_right, y_right), fill=EYE, width=2)


def draw_mouth(draw: ImageDraw.ImageDraw, target: dict[str, float]) -> None:
    target = target_with_defaults(target)
    cx, cy, width = 160 + target["face_x"], target.get("mouth_y", 172) + target["face_y"], 64 + target["mouth_width_delta"]
    smile = target["mouth_smile"]
    curve = int((1 if smile >= 0 else -1) * (abs(smile) ** 0.6) * 22)
    open_px = int(target["mouth_open"] * 18)
    left_y = cy + target["mouth_corner_l"]
    right_y = cy + target["mouth_corner_r"]
    if open_px > 3:
        top_ctrl_y = cy - max(2, open_px // 3)
        bottom_ctrl_y = cy + curve + open_px
        top = []
        bottom = []
        for i in range(19):
            u = i / 18
            x = qbez(cx - width / 2, cx, cx + width / 2, u)
            top.append((int(x), int(qbez(left_y, top_ctrl_y, right_y, u))))
            bottom.append((int(x), int(qbez(left_y + open_px / 2, bottom_ctrl_y, right_y + open_px / 2, u))))
        draw.polygon(top + list(reversed(bottom)), fill=MOUTH)
        return

    points = []
    for i in range(33):
        u = i / 32
        x = qbez(cx - width // 2, cx, cx + width // 2, u)
        y = qbez(left_y, cy + curve, right_y, u)
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
    draw.text((160, 220), "Stackchan: Alive", fill=ACCENT, anchor="mm")
    return img.resize((WIDTH * SCALE, HEIGHT * SCALE), Image.Resampling.NEAREST)


def render_idle_frame(t: float) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    target = phase_c_idle_targets(t)
    draw_eye(draw, 106, 104, target, False)
    draw_eye(draw, 214, 104, target, True)
    draw_mouth(draw, target)
    draw.text((160, 220), "Stackchan: Alive", fill=ACCENT, anchor="mm")
    return img.resize((WIDTH * SCALE, HEIGHT * SCALE), Image.Resampling.NEAREST)


def render_pose(label: str, target: dict[str, float], *, show_label: bool = True, show_brand: bool = True) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    draw_eye(draw, 106, 104, target, False)
    draw_eye(draw, 214, 104, target, True)
    draw_mouth(draw, target)
    if show_label:
        draw.text((12, 14), label, fill=ACCENT, anchor="lm")
    if show_brand:
        draw.text((160, 220), "Stackchan: Alive", fill=ACCENT, anchor="mm")
    return img


def render_expression_sheet(*, show_labels: bool = True, show_brand: bool = True) -> Image.Image:
    poses = [
        ("Idle", {
            "eye_open": 0.84,
            "squint": 0.0,
            "eye_smile": 0.12,
            "pupil_scale": 1.0,
            "pupil_x": 0.0,
            "pupil_y": 0.0,
            "brow_tilt": 0.16,
            "mouth_smile": 0.26,
            "mouth_width_delta": 5.0,
            "mouth_open": 0.0,
            "left_tr": 0.04,
            "right_tl": 0.07,
        }),
        ("Listen", {
            "eye_open": 0.92,
            "squint": 0.0,
            "eye_smile": 0.08,
            "pupil_scale": 1.08,
            "pupil_x": -0.05,
            "pupil_y": 0.0,
            "brow_tilt": 0.12,
            "mouth_smile": 0.10,
            "mouth_width_delta": -1.0,
            "mouth_open": 0.0,
            "right_br": 0.08,
            "left_bl": 0.04,
        }),
        ("Think", {
            "eye_open": 0.78,
            "squint": 0.05,
            "eye_smile": 0.04,
            "pupil_scale": 0.95,
            "pupil_x": 0.10,
            "pupil_y": -0.20,
            "brow_tilt": 0.10,
            "mouth_smile": 0.15,
            "mouth_width_delta": -6.0,
            "mouth_corner_l": -1.0,
            "mouth_corner_r": 1.0,
            "mouth_open": 0.0,
            "left_tr": 0.30,
            "right_br": 0.06,
            "upper_lid_tilt": 0.08,
        }),
        ("Happy", {
            "eye_open": 0.88,
            "squint": 0.0,
            "eye_smile": 0.44,
            "pupil_scale": 1.15,
            "pupil_x": 0.0,
            "pupil_y": 0.02,
            "brow_tilt": 0.28,
            "mouth_smile": 0.62,
            "mouth_width_delta": 17.0,
            "mouth_corner_l": 2.0,
            "mouth_corner_r": 1.0,
            "mouth_open": 0.0,
            "left_bl": 0.16,
            "left_br": 0.26,
            "right_bl": 0.12,
            "right_br": 0.20,
            "lower_lid_tilt": -0.08,
        }),
        ("Concern", {
            "eye_open": 0.76,
            "squint": 0.32,
            "eye_smile": 0.0,
            "pupil_scale": 0.88,
            "pupil_x": 0.0,
            "pupil_y": 0.05,
            "brow_tilt": -0.32,
            "mouth_smile": -0.52,
            "mouth_width_delta": -10.0,
            "mouth_corner_l": -3.0,
            "mouth_corner_r": 1.0,
            "mouth_open": 0.0,
            "left_tl": 0.35,
            "right_tl": 0.50,
            "left_br": 0.06,
            "right_bl": 0.10,
            "upper_lid_tilt": -0.15,
            "lower_lid_tilt": 0.08,
            "face_y": 2.0,
        }),
        ("Sleep", {
            "eye_open": 0.28,
            "squint": 0.0,
            "eye_smile": 0.08,
            "pupil_scale": 0.90,
            "pupil_x": 0.0,
            "pupil_y": 0.0,
            "brow_tilt": -0.16,
            "mouth_smile": -0.06,
            "mouth_width_delta": -14.0,
            "mouth_corner_l": -3.0,
            "mouth_corner_r": 3.0,
            "mouth_open": 0.0,
            "left_tr": 0.06,
            "left_bl": 0.12,
            "right_tl": 0.14,
            "right_br": 0.28,
            "upper_lid_tilt": 0.06,
            "lower_lid_tilt": -0.04,
            "face_y": 3.0,
        }),
    ]

    sheet = Image.new("RGB", (WIDTH * 3, HEIGHT * 2), BG)
    for index, (label, target) in enumerate(poses):
        x = (index % 3) * WIDTH
        y = (index // 3) * HEIGHT
        sheet.paste(render_pose(label, target, show_label=show_labels, show_brand=show_brand), (x, y))
    return sheet


def phase_d_pose(name: str) -> dict[str, float]:
    poses = {
        "idle": {
            "eye_open": 0.84,
            "eye_smile": 0.12,
            "pupil_scale": 1.0,
            "brow_tilt": 0.16,
            "mouth_smile": 0.26,
            "mouth_width_delta": 5.0,
            "left_tr": 0.04,
            "right_tl": 0.07,
        },
        "listen": {
            "eye_open": 0.94,
            "eye_smile": 0.06,
            "pupil_x": -0.03,
            "pupil_scale": 1.05,
            "brow_tilt": 0.20,
            "mouth_smile": 0.10,
            "mouth_width_delta": -2.0,
            "left_bl": 0.04,
            "right_br": 0.08,
        },
        "think": {
            "eye_open": 0.78,
            "squint": 0.08,
            "pupil_x": 0.18,
            "pupil_y": -0.22,
            "pupil_scale": 0.95,
            "brow_tilt": 0.12,
            "mouth_smile": 0.08,
            "mouth_width_delta": -8.0,
            "mouth_corner_l": -1.0,
            "mouth_corner_r": 1.0,
            "left_tr": 0.30,
            "right_tl": 0.04,
            "right_br": 0.06,
            "upper_lid_tilt": 0.08,
        },
        "speak": {
            "eye_open": 0.90,
            "eye_smile": 0.08,
            "pupil_scale": 1.08,
            "brow_tilt": 0.18,
            "mouth_smile": 0.18,
            "mouth_open": 0.45,
            "mouth_width_delta": 4.0,
            "left_bl": 0.05,
            "right_br": 0.10,
        },
        "sleep": {
            "eye_open": 0.28,
            "eye_smile": 0.08,
            "pupil_scale": 0.90,
            "brow_tilt": -0.16,
            "mouth_smile": -0.06,
            "mouth_width_delta": -14.0,
            "mouth_corner_l": -3.0,
            "mouth_corner_r": 3.0,
            "left_tr": 0.06,
            "left_bl": 0.12,
            "right_tl": 0.14,
            "right_br": 0.28,
            "upper_lid_tilt": 0.06,
            "lower_lid_tilt": -0.04,
            "face_y": 3.0,
        },
    }
    return target_with_defaults(poses[name])


def mix_targets(a: dict[str, float], b: dict[str, float], amount: float) -> dict[str, float]:
    amount = clamp(amount, 0.0, 1.0)
    a = target_with_defaults(a)
    b = target_with_defaults(b)
    return {key: a[key] + (b[key] - a[key]) * amount for key in a.keys()}


def phase_d_transition_targets(name: str, t: float) -> dict[str, float]:
    if name == "idle_to_listen":
        target = mix_targets(phase_d_pose("idle"), phase_d_pose("listen"), ease_out_back((t - 0.08) / 0.27))
        if t < 0.12:
            blink = 1.0 - ease_in_quad(t / 0.08) if t < 0.08 else 0.18
            target["eye_open"] = max(0.05, target["eye_open"] * blink)
            target["eye_width_scale"] = 1.0 + (1.0 - blink) * 0.15
        pop = ease_out_back((t - 0.08) / 0.27)
        target["eye_open"] = clamp(target["eye_open"] + pop * 0.16, 0.02, 1.12)
        target["face_y"] -= pop * 2.0
        target["brow_tilt"] += pop * 0.20
        target["pupil_x"] = target["pupil_x"] * 0.55 - pop * 0.03
        return target

    if name == "think_to_speak":
        target = mix_targets(phase_d_pose("think"), phase_d_pose("speak"), ease_out_back(t / 0.32))
        center = ease_out_back(t / 0.12)
        pre_open = ease_in_quad(t / 0.06) if t < 0.06 else 1.0
        target["pupil_x"] *= 1.0 - center
        target["pupil_y"] *= 1.0 - center
        if t < 0.16:
            target["mouth_open"] = max(target["mouth_open"], 0.18 * pre_open)
            target["mouth_smile"] -= 0.10 * pre_open
        return target

    if name == "idle_to_sleep":
        target = mix_targets(phase_d_pose("idle"), phase_d_pose("sleep"), ease_in_quad(t / 3.4))
        droop = clamp(t / 1.0, 0.0, 1.0)
        fight = ease_in_quad((t - 1.0) / 1.5) if t > 1.0 else 0.0
        close = ease_in_quad((t - 2.5) / 0.9) if t > 2.5 else 0.0
        if 1.25 <= t <= 1.85:
            half_blink = math.sin(((t - 1.25) / 0.60) * math.pi)
            target["eye_open"] = min(target["eye_open"], 0.58 - half_blink * 0.20)
        target["pupil_y"] = clamp(target["pupil_y"] + 0.22 * droop, -1.0, 1.0)
        target["brow_tilt"] -= 0.10 * droop
        target["eye_open"] = clamp(target["eye_open"] - 0.14 * fight - 0.18 * close, 0.02, 1.08)
        target["face_y"] += 2.0 * droop
        return target

    raise ValueError(f"unknown Phase D transition: {name}")


def render_transition_frame(name: str, t: float) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    target = phase_d_transition_targets(name, t)
    draw_eye(draw, 106, 104, target, False)
    draw_eye(draw, 214, 104, target, True)
    draw_mouth(draw, target)
    return img


def render_filmstrip(start_t: float, frames: int, step_s: float) -> Image.Image:
    strip = Image.new("RGB", (WIDTH * frames, HEIGHT), BG)
    for index in range(frames):
        strip.paste(render_frame(start_t + index * step_s).resize((WIDTH, HEIGHT), Image.Resampling.NEAREST), (index * WIDTH, 0))
    return strip


def render_transition_filmstrip(name: str, duration_s: float, step_s: float = 0.05) -> Image.Image:
    frames = int(duration_s / step_s) + 1
    strip = Image.new("RGB", (WIDTH * frames, HEIGHT), BG)
    for index in range(frames):
        strip.paste(render_transition_frame(name, index * step_s), (index * WIDTH, 0))
    return strip


def phase_e_speech_envelope(t: float) -> float:
    # Fixed 50 Hz-style sidecar preview: syllable peaks followed by a clean return to rest.
    pulses = [
        (0.18, 0.40), (0.48, 0.78), (0.82, 0.55), (1.16, 0.86),
        (1.54, 0.52), (1.94, 0.72), (2.30, 0.62), (2.74, 0.88),
        (3.18, 0.58), (3.56, 0.75), (4.02, 0.64), (4.42, 0.84),
        (4.82, 0.44),
    ]
    value = 0.0
    for center, amp in pulses:
        value += amp * math.exp(-((t - center) / 0.085) ** 2)
    if t > 5.05:
        value *= max(0.0, 1.0 - (t - 5.05) / 0.35)
    return clamp(value, 0.0, 1.0)


def phase_e_speech_viseme(t: float) -> str:
    sequence = ["ah", "ee", "ah", "oh", "ee", "ah", "oh", "ah", "ee", "oh", "ah", "ee", "oh"]
    index = min(len(sequence) - 1, max(0, int((t + 0.05) / 0.38)))
    return sequence[index]


def phase_e_speech_targets(t: float) -> dict[str, float]:
    target = phase_d_pose("speak")
    env = phase_e_speech_envelope(t)
    viseme = phase_e_speech_viseme(t)

    target["mouth_open"] = 0.0 if env < 0.04 else 0.05 + ((env - 0.04) / 0.76) * 0.65
    target["mouth_open"] = clamp(target["mouth_open"], 0.0, 0.72)
    if viseme == "oh":
        target["mouth_width_delta"] -= 10.0
        target["mouth_smile"] -= 0.06
        target["mouth_corner_l"] -= 1.5
        target["mouth_corner_r"] += 1.0
    elif viseme == "ee":
        target["mouth_open"] *= 0.72
        target["mouth_width_delta"] += 12.0
        target["mouth_smile"] += 0.08
        target["mouth_corner_l"] += 1.0
        target["mouth_corner_r"] -= 0.5
    else:
        target["mouth_width_delta"] += 2.0
        target["mouth_smile"] = max(target["mouth_smile"], 0.06)

    if env > 0.55:
        target["brow_tilt"] += 0.08 * env
    target["face_y"] += math.sin(2.0 * math.pi * 0.20 * t) * 1.2
    target["pupil_x"] += math.sin(t * 3.2) * 0.04
    target["pupil_y"] += math.sin(t * 2.4 + 0.6) * 0.025
    return target_with_defaults(target)


def render_speech_frame(t: float) -> Image.Image:
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    draw = ImageDraw.Draw(img)
    target = phase_e_speech_targets(t)
    draw_eye(draw, 106, 104, target, False)
    draw_eye(draw, 214, 104, target, True)
    draw_mouth(draw, target)
    draw.text((160, 220), "Stackchan: Alive", fill=ACCENT, anchor="mm")
    return img.resize((WIDTH * SCALE, HEIGHT * SCALE), Image.Resampling.NEAREST)


def main() -> None:
    still = render_frame(2.7)
    still.save(OUT / "stackchan_alive_preview.png")
    render_expression_sheet().save(OUT / "stackchan_alive_expression_sheet.png")
    render_expression_sheet(show_labels=False, show_brand=False).save(FACE_ARTIFACTS / "phase_a_unlabeled_expression_sheet.png")
    render_expression_sheet(show_labels=False, show_brand=False).save(FACE_ARTIFACTS / "phase_b_unlabeled_expression_sheet.png")
    render_filmstrip(2.85, 14, 0.05).save(FACE_ARTIFACTS / "phase_a_blink_filmstrip_50ms.png")
    render_transition_filmstrip("idle_to_listen", 0.50).save(FACE_ARTIFACTS / "phase_d_idle_to_listen_filmstrip_50ms.png")
    render_transition_filmstrip("think_to_speak", 0.35).save(FACE_ARTIFACTS / "phase_d_think_to_speak_filmstrip_50ms.png")
    render_transition_filmstrip("idle_to_sleep", 3.40).save(FACE_ARTIFACTS / "phase_d_idle_to_sleep_filmstrip_50ms.png")

    fps = 30
    frames = [render_frame(i / fps) for i in range(fps * 6)]
    imageio.mimsave(OUT / "stackchan_alive_preview.gif", frames, fps=fps)
    idle_frames = [render_frame(i / fps) for i in range(fps * 10)]
    imageio.mimsave(FACE_ARTIFACTS / "phase_a_idle_10s.gif", idle_frames, fps=fps)
    phase_c_idle_frames = [render_idle_frame(i / fps) for i in range(fps * 10)]
    imageio.mimsave(FACE_ARTIFACTS / "phase_c_idle_10s.gif", phase_c_idle_frames, fps=fps)
    phase_e_speech_frames = [render_speech_frame(i / fps) for i in range(fps * 6)]
    imageio.mimsave(FACE_ARTIFACTS / "phase_e_speech_reactive_6s.gif", phase_e_speech_frames, fps=fps)
    imageio.mimsave(OUT / "stackchan_alive_speech_preview.gif", phase_e_speech_frames, fps=fps)

    try:
      imageio.mimsave(OUT / "stackchan_alive_preview.mp4", frames, fps=fps, quality=8)
    except Exception as exc:
      print(f"mp4 generation skipped: {exc}")

    print(f"Wrote preview media to {OUT}")


if __name__ == "__main__":
    main()
