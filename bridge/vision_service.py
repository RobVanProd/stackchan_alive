#!/usr/bin/env python3
"""Local-only Stackchan camera face detection and target relay."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import math
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass

import numpy as np


MAX_FACES = 4
MAX_FRAME_BYTES = 32768
YUNET_MODEL_PATH = Path(__file__).resolve().parent / "models" / "face_detection_yunet_2023mar.onnx"
YUNET_MODEL_SHA256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
YUNET_SCORE_THRESHOLD = 0.35


@dataclass(frozen=True)
class FaceTarget:
    x: float
    y: float
    size: float
    confidence: float


@dataclass
class VisionStats:
    frames: int = 0
    frame_failures: int = 0
    target_updates: int = 0
    faces_observed: int = 0
    max_fetch_ms: float = 0.0
    max_detect_ms: float = 0.0
    last_error: str = ""


def require_private_robot_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("robot URL must be plain HTTP with no embedded credentials")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise ValueError("robot URL must use a literal private or loopback IP address") from exc
    if not (address.is_private or address.is_loopback):
        raise ValueError("robot URL must stay on a private or loopback address")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("robot URL must contain only scheme, host, and optional port")
    return url.rstrip("/")


def validate_pairing_code(value: str) -> str:
    if len(value) != 6 or not value.isascii() or not value.isdigit():
        raise ValueError("pairing code must be exactly six ASCII digits")
    return value


def read_pairing_code_file(path: str) -> str:
    try:
        value = Path(path).read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as exc:
        raise ValueError("pairing code file could not be read as ASCII") from exc
    return validate_pairing_code(value)


def parse_pgm(payload: bytes) -> np.ndarray:
    if len(payload) > MAX_FRAME_BYTES or not payload.startswith(b"P5\n"):
        raise ValueError("invalid or oversized PGM frame")
    try:
        _, dimensions, maximum, pixels = payload.split(b"\n", 3)
        width_text, height_text = dimensions.split(b" ", 1)
        width = int(width_text)
        height = int(height_text)
        max_value = int(maximum)
    except (ValueError, TypeError) as exc:
        raise ValueError("malformed PGM header") from exc
    if width <= 0 or height <= 0 or width > 320 or height > 240 or max_value != 255:
        raise ValueError("unsupported PGM dimensions")
    expected = width * height
    if len(pixels) != expected:
        raise ValueError("PGM payload length mismatch")
    return np.frombuffer(pixels, dtype=np.uint8).reshape((height, width))


def normalize_face_targets(
    boxes: list[tuple[int, int, int, int]],
    frame_width: int,
    frame_height: int,
    weights: list[float] | None = None,
) -> list[FaceTarget]:
    if frame_width <= 0 or frame_height <= 0:
        raise ValueError("invalid frame dimensions")
    candidates: list[FaceTarget] = []
    for index, (left, top, width, height) in enumerate(boxes):
        if width <= 0 or height <= 0:
            continue
        center_x = left + width / 2.0
        center_y = top + height / 2.0
        x = max(-1.0, min(1.0, center_x / frame_width * 2.0 - 1.0))
        y = max(-1.0, min(1.0, center_y / frame_height * 2.0 - 1.0))
        size = max(0.0, min(1.0, math.sqrt((width * height) / (frame_width * frame_height))))
        weight = weights[index] if weights is not None and index < len(weights) else 2.0
        confidence = max(0.25, min(1.0, 0.55 + 0.05 * float(weight)))
        candidates.append(FaceTarget(x=x, y=y, size=size, confidence=confidence))
    candidates.sort(key=lambda item: item.size * item.confidence, reverse=True)
    return candidates[:MAX_FACES]


def encode_face_targets(pairing_code: str, faces: list[FaceTarget]) -> str:
    pairing_code = validate_pairing_code(pairing_code)
    encoded: list[str] = []
    for face in faces[:MAX_FACES]:
        values = (
            round(max(-1.0, min(1.0, face.x)) * 1000),
            round(max(-1.0, min(1.0, face.y)) * 1000),
            round(max(0.0, min(1.0, face.size)) * 1000),
            round(max(0.0, min(1.0, face.confidence)) * 1000),
        )
        encoded.append(",".join(str(value) for value in values))
    return f"/vision-target?p={pairing_code}&f={';'.join(encoded)}"


def verify_yunet_model(path: str | Path) -> Path:
    model_path = Path(path).resolve()
    try:
        payload = model_path.read_bytes()
    except OSError as exc:
        raise RuntimeError("YuNet face detector model is missing or unreadable") from exc
    if hashlib.sha256(payload).hexdigest() != YUNET_MODEL_SHA256:
        raise RuntimeError("YuNet face detector model SHA-256 does not match provenance")
    return model_path


class OpenCvYuNetDetector:
    def __init__(self, model_path: str | Path = YUNET_MODEL_PATH) -> None:
        try:
            import cv2  # type: ignore
        except ImportError as exc:
            raise RuntimeError(
                "OpenCV vision dependency is missing; install bridge/requirements-vision.txt"
            ) from exc
        verified_model = verify_yunet_model(model_path)
        self._cv2 = cv2
        self._detector = cv2.FaceDetectorYN_create(
            str(verified_model), "", (160, 120), YUNET_SCORE_THRESHOLD, 0.30, 5000
        )

    def detect(self, frame: np.ndarray) -> list[FaceTarget]:
        if frame.ndim != 2:
            raise ValueError("YuNet detector expects one-channel grayscale input")
        height, width = frame.shape
        bgr = self._cv2.cvtColor(frame, self._cv2.COLOR_GRAY2BGR)
        self._detector.setInputSize((width, height))
        _, detections = self._detector.detect(bgr)
        if detections is None:
            return []

        candidates: list[FaceTarget] = []
        for detection in detections:
            left, top, box_width, box_height = (float(value) for value in detection[:4])
            if box_width <= 0.0 or box_height <= 0.0:
                continue
            center_x = left + box_width * 0.5
            center_y = top + box_height * 0.5
            x = max(-1.0, min(1.0, center_x / width * 2.0 - 1.0))
            y = max(-1.0, min(1.0, center_y / height * 2.0 - 1.0))
            size = max(0.0, min(1.0, math.sqrt((box_width * box_height) / (width * height))))
            confidence = max(0.0, min(1.0, float(detection[-1])))
            candidates.append(FaceTarget(x=x, y=y, size=size, confidence=confidence))

        candidates.sort(key=lambda item: item.size * item.confidence, reverse=True)
        return candidates[:MAX_FACES]


class CameraVisionService:
    def __init__(self, robot_url: str, pairing_code: str, detector: OpenCvYuNetDetector) -> None:
        self.robot_url = require_private_robot_url(robot_url)
        self.pairing_code = validate_pairing_code(pairing_code)
        self.detector = detector
        self.stats = VisionStats()

    def _get(self, path: str, timeout: float) -> bytes:
        request = urllib.request.Request(
            self.robot_url + path,
            headers={"Cache-Control": "no-store", "User-Agent": "stackchan-local-vision/1"},
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            if response.status != 200:
                raise RuntimeError(f"robot HTTP status {response.status}")
            return response.read(MAX_FRAME_BYTES + 1)

    def step(self, timeout: float = 4.0) -> list[FaceTarget]:
        try:
            started = time.perf_counter()
            payload = self._get(f"/camera-gray.pgm?p={self.pairing_code}", timeout)
            self.stats.max_fetch_ms = max(
                self.stats.max_fetch_ms, (time.perf_counter() - started) * 1000.0
            )
            frame = parse_pgm(payload)
            detect_started = time.perf_counter()
            faces = self.detector.detect(frame)
            self.stats.max_detect_ms = max(
                self.stats.max_detect_ms, (time.perf_counter() - detect_started) * 1000.0
            )
            self._get(encode_face_targets(self.pairing_code, faces), timeout)
            self.stats.frames += 1
            self.stats.target_updates += 1
            self.stats.faces_observed += len(faces)
            self.stats.last_error = ""
            return faces
        except (OSError, RuntimeError, ValueError, urllib.error.URLError) as exc:
            self.stats.frame_failures += 1
            self.stats.last_error = str(exc)[:240]
            raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--robot-url", default="http://192.168.1.238:8789")
    pairing = parser.add_mutually_exclusive_group(required=True)
    pairing.add_argument("--pairing-code")
    pairing.add_argument("--pairing-code-file")
    parser.add_argument("--interval-seconds", type=float, default=1.0)
    parser.add_argument("--duration-seconds", type=float, default=0.0)
    parser.add_argument("--model-path", default=str(YUNET_MODEL_PATH))
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    if args.interval_seconds < 0.5:
        parser.error("--interval-seconds must be at least 0.5")

    pairing_code = (
        read_pairing_code_file(args.pairing_code_file)
        if args.pairing_code_file
        else validate_pairing_code(args.pairing_code)
    )
    service = CameraVisionService(args.robot_url, pairing_code, OpenCvYuNetDetector(args.model_path))
    started = time.monotonic()
    exit_code = 0
    try:
        while True:
            step_started = time.monotonic()
            try:
                faces = service.step()
                print(json.dumps({"faces": len(faces), "stats": asdict(service.stats)}), flush=True)
            except Exception:
                print(json.dumps({"faces": 0, "stats": asdict(service.stats)}), flush=True)
                exit_code = 1
            if args.once or (args.duration_seconds > 0 and time.monotonic() - started >= args.duration_seconds):
                break
            remaining = args.interval_seconds - (time.monotonic() - step_started)
            if remaining > 0:
                time.sleep(remaining)
    except KeyboardInterrupt:
        pass
    print(json.dumps({"schema": "stackchan.local-vision-summary.v1", **asdict(service.stats)}))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
