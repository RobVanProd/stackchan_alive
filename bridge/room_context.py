"""Low-rate, privacy-filtered room context for the host bridge."""

from __future__ import annotations

from dataclasses import dataclass, replace
import ipaddress
import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable

try:
    from .cancellable_process import ProcessTimeoutError, run_cancellable_process
except ImportError:
    from cancellable_process import ProcessTimeoutError, run_cancellable_process


MAX_FRAME_BYTES = 32_768
MIN_INTERVAL_SECONDS = 120
MAX_INTERVAL_SECONDS = 1_800
PRIVATE_NETWORKS = (
    ipaddress.ip_network("10.0.0.0/8"),
    ipaddress.ip_network("172.16.0.0/12"),
    ipaddress.ip_network("192.168.0.0/16"),
    ipaddress.ip_network("fc00::/7"),
)
ACTIVITIES = {
    "empty",
    "person_seated",
    "person_standing",
    "people_present",
    "unknown",
}
LIGHTING = {"bright", "dim", "mixed", "unknown"}
OBJECTS = {
    "chair",
    "desk",
    "door",
    "lamp",
    "monitor",
    "plant",
    "shelf",
    "sofa",
    "table",
    "window",
}
SCENE_CHANGES = {
    "person_arrived",
    "person_left",
    "person_count_changed",
    "objects_changed",
    "lighting_changed",
}


@dataclass(frozen=True)
class RoomSceneSummary:
    person_count: int | None = None
    activity: str = "unknown"
    objects: tuple[str, ...] = ()
    lighting: str = "unknown"
    changes: tuple[str, ...] = ()
    observed_ms: int = 0

    @property
    def person_present(self) -> bool | None:
        if self.person_count is None:
            return None
        return self.person_count > 0

    def prompt_line(self) -> str:
        count = "unknown" if self.person_count is None else str(self.person_count)
        objects = ",".join(self.objects) if self.objects else "none_observed"
        changes = ",".join(self.changes) if self.changes else "none"
        return (
            "ambient_room: "
            f"people={count}; activity={self.activity}; lighting={self.lighting}; "
            f"coarse_objects={objects}; recent_changes={changes}. "
            "Treat this as fallible grayscale scene context; do not infer identity or private traits."
        )


@dataclass(frozen=True)
class RoomObservationConfig:
    enabled: bool = False
    interval_seconds: int = 300
    command: str = ""
    timeout_ms: int = 30_000

    def __post_init__(self) -> None:
        if not MIN_INTERVAL_SECONDS <= self.interval_seconds <= MAX_INTERVAL_SECONDS:
            raise ValueError(
                f"interval_seconds must be between {MIN_INTERVAL_SECONDS} and {MAX_INTERVAL_SECONDS}"
            )
        if self.timeout_ms <= 0:
            raise ValueError("timeout_ms must be positive")


class RoomObservationCancelled(RuntimeError):
    """Raised when an operator disables observation during an in-flight capture."""


class _RejectRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _open_without_redirects(request: urllib.request.Request, *, timeout: float):
    return urllib.request.build_opener(_RejectRedirects()).open(request, timeout=timeout)


def sanitize_scene(payload: object, *, observed_ms: int) -> RoomSceneSummary:
    if not isinstance(payload, dict):
        raise ValueError("vision model output must be a JSON object")
    raw_count = payload.get("person_count")
    if raw_count is None:
        person_count = None
    elif isinstance(raw_count, bool):
        raise ValueError("person_count must be an integer or null")
    else:
        try:
            person_count = int(raw_count)
        except (TypeError, ValueError) as exc:
            raise ValueError("person_count must be an integer or null") from exc
        if not 0 <= person_count <= 4:
            raise ValueError("person_count must be between zero and four")

    activity = str(payload.get("activity", "unknown")).strip().lower()
    if activity not in ACTIVITIES:
        activity = "unknown"
    lighting = str(payload.get("lighting", "unknown")).strip().lower()
    if lighting not in LIGHTING:
        lighting = "unknown"
    raw_objects = payload.get("objects", ())
    if not isinstance(raw_objects, (list, tuple)):
        raw_objects = ()
    objects = tuple(
        sorted(
            {
                str(item).strip().lower()
                for item in raw_objects
                if str(item).strip().lower() in OBJECTS
            }
        )
    )[:6]
    return RoomSceneSummary(
        person_count=person_count,
        activity=activity,
        objects=objects,
        lighting=lighting,
        observed_ms=max(0, int(observed_ms)),
    )


def diff_scenes(
    previous: RoomSceneSummary | None,
    current: RoomSceneSummary,
) -> tuple[str, ...]:
    if previous is None:
        return ()
    changes: list[str] = []
    if previous.person_count is not None and current.person_count is not None:
        if previous.person_count == 0 and current.person_count > 0:
            changes.append("person_arrived")
        elif previous.person_count > 0 and current.person_count == 0:
            changes.append("person_left")
        elif previous.person_count != current.person_count:
            changes.append("person_count_changed")
    if previous.objects != current.objects:
        changes.append("objects_changed")
    if (
        previous.lighting != "unknown"
        and current.lighting != "unknown"
        and previous.lighting != current.lighting
    ):
        changes.append("lighting_changed")
    return tuple(item for item in changes if item in SCENE_CHANGES)


def _private_robot_url(url: str) -> str:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "http" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("robot camera URL must be plain HTTP with no embedded credentials")
    try:
        address = ipaddress.ip_address(parsed.hostname)
    except ValueError as exc:
        raise ValueError("robot camera URL must use a literal private or loopback IP") from exc
    if not (address.is_loopback or any(address in network for network in PRIVATE_NETWORKS)):
        raise ValueError("robot camera URL must stay on a private or loopback address")
    if parsed.path not in ("", "/") or parsed.query or parsed.fragment:
        raise ValueError("robot camera URL must contain only scheme, host, and optional port")
    return url.rstrip("/")


def _pairing_code(value: str) -> str:
    code = str(value).strip()
    if len(code) != 6 or not code.isascii() or not code.isdigit():
        raise ValueError("camera pairing code must be exactly six ASCII digits")
    return code


class PrivateCameraFrameSource:
    """Fetches one authenticated grayscale frame and never writes it to disk."""

    def __init__(self, robot_url: str, pairing_code: str, *, timeout_seconds: float = 4.0) -> None:
        self.robot_url = _private_robot_url(robot_url)
        self.pairing_code = _pairing_code(pairing_code)
        self.timeout_seconds = max(0.5, float(timeout_seconds))

    def __call__(self) -> bytes:
        query = urllib.parse.urlencode({"p": self.pairing_code})
        request = urllib.request.Request(
            f"{self.robot_url}/camera-gray.pgm?{query}",
            headers={"Cache-Control": "no-store", "User-Agent": "stackchan-room-context/1"},
        )
        try:
            with _open_without_redirects(request, timeout=self.timeout_seconds) as response:
                if response.status != 200:
                    raise RuntimeError(f"robot camera returned HTTP {response.status}")
                frame = response.read(MAX_FRAME_BYTES + 1)
        except (OSError, urllib.error.URLError) as exc:
            raise RuntimeError(f"robot camera unavailable: {getattr(exc, 'reason', exc)}") from exc
        if len(frame) > MAX_FRAME_BYTES or not frame.startswith(b"P5\n"):
            raise RuntimeError("robot camera returned an invalid or oversized PGM frame")
        return frame


class ExternalRoomVisionModel:
    """Runs an operator-configured local vision adapter with PGM bytes on stdin."""

    def __init__(self, command: str, *, timeout_ms: int = 30_000) -> None:
        if not str(command).strip():
            raise ValueError("room vision command is required")
        self.command = str(command).strip()
        self.timeout_ms = max(1, int(timeout_ms))

    def __call__(self, frame: bytes) -> dict[str, object]:
        try:
            completed = run_cancellable_process(
                self.command,
                input_data=bytes(frame),
                timeout_ms=self.timeout_ms,
            )
        except ProcessTimeoutError as exc:
            raise RuntimeError("room vision model timed out") from exc
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"room vision model failed: {detail[:180]}")
        try:
            payload = json.loads(completed.stdout.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise RuntimeError("room vision model returned invalid JSON") from exc
        if not isinstance(payload, dict):
            raise RuntimeError("room vision model returned a non-object")
        return payload


class RoomContextRuntime:
    """Owns low-rate observation state and exposes only sanitized aggregate facts."""

    def __init__(
        self,
        config: RoomObservationConfig,
        *,
        frame_source: Callable[[], bytes] | None = None,
        model_observer: Callable[[bytes], dict[str, object]] | None = None,
        on_summary: Callable[[RoomSceneSummary], None] | None = None,
    ) -> None:
        self.config = config
        self._frame_source = frame_source
        self._model_observer = model_observer
        self._on_summary = on_summary
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._enabled = config.enabled
        self._interval_seconds = config.interval_seconds
        self._summary: RoomSceneSummary | None = None
        self._last_error = ""
        self._observations = 0
        self._failures = 0
        self._last_observed_monotonic = 0.0
        self._control_epoch = 0

    def set_controls(self, *, enabled: bool, interval_seconds: int) -> dict[str, object]:
        interval = int(interval_seconds)
        if not MIN_INTERVAL_SECONDS <= interval <= MAX_INTERVAL_SECONDS:
            raise ValueError(
                f"intervalSeconds must be between {MIN_INTERVAL_SECONDS} and {MAX_INTERVAL_SECONDS}"
            )
        with self._lock:
            requested = bool(enabled)
            if requested != self._enabled:
                self._control_epoch += 1
            self._enabled = requested
            self._interval_seconds = interval
            if not self._enabled:
                self._summary = None
                self._last_observed_monotonic = 0.0
                self._last_error = ""
        self._wake.set()
        return self.status()

    def observe_once(self, *, now_ms: int | None = None) -> RoomSceneSummary:
        try:
            with self._lock:
                if not self._enabled:
                    raise RoomObservationCancelled("room observation is disabled")
                control_epoch = self._control_epoch
            if self._frame_source is None:
                raise RuntimeError("camera pairing is not configured")
            if self._model_observer is None:
                raise RuntimeError("vision-capable model is not configured")
            observed = int(time.time() * 1000) if now_ms is None else max(0, int(now_ms))
            frame = self._frame_source()
            payload = self._model_observer(frame)
            current = sanitize_scene(payload, observed_ms=observed)
            with self._lock:
                if not self._enabled or control_epoch != self._control_epoch:
                    raise RoomObservationCancelled(
                        "room observation was disabled during capture"
                    )
                changes = diff_scenes(self._summary, current)
                current = replace(current, changes=changes)
                self._summary = current
                self._last_error = ""
                self._observations += 1
                self._last_observed_monotonic = time.monotonic()
            if self._on_summary is not None:
                self._on_summary(current)
            return current
        except RoomObservationCancelled:
            raise
        except Exception as exc:
            with self._lock:
                self._failures += 1
                self._last_error = self._public_error_code(exc)
            raise

    @staticmethod
    def _public_error_code(exc: Exception) -> str:
        message = str(exc).lower()
        if "pairing" in message:
            return "camera_not_configured"
        if "camera" in message and ("invalid" in message or "oversized" in message):
            return "camera_frame_invalid"
        if "camera" in message:
            return "camera_unavailable"
        if "vision-capable" in message or "vision model is not configured" in message:
            return "vision_not_configured"
        if "timed out" in message:
            return "vision_timeout"
        if "vision" in message or "model" in message:
            return "vision_model_error"
        return "observation_failed"

    def prompt_lines(self) -> tuple[str, ...]:
        with self._lock:
            if not self._enabled or self._summary is None:
                return ()
            maximum_age = max(self._interval_seconds * 2, 900)
            if (
                self._last_observed_monotonic
                and time.monotonic() - self._last_observed_monotonic > maximum_age
            ):
                return ()
            return (self._summary.prompt_line(),)

    def latest_summary(self) -> RoomSceneSummary | None:
        with self._lock:
            return self._summary

    def status(self) -> dict[str, object]:
        with self._lock:
            age = (
                max(0.0, time.monotonic() - self._last_observed_monotonic)
                if self._last_observed_monotonic
                else None
            )
            summary = self._summary
            return {
                "enabled": self._enabled,
                "configured": self._frame_source is not None and self._model_observer is not None,
                "intervalSeconds": self._interval_seconds,
                "observations": self._observations,
                "failures": self._failures,
                "lastError": self._last_error,
                "ageSeconds": round(age, 1) if age is not None else None,
                "personPresent": summary.person_present if summary is not None else None,
                "personCount": summary.person_count if summary is not None else None,
                "activity": summary.activity if summary is not None else "unknown",
                "changes": list(summary.changes) if summary is not None else [],
            }

    def _worker(self) -> None:
        while not self._stop.is_set():
            with self._lock:
                enabled = self._enabled
                interval = self._interval_seconds
            wait_seconds = interval if enabled else 60
            self._wake.wait(wait_seconds)
            self._wake.clear()
            if self._stop.is_set():
                break
            with self._lock:
                enabled = self._enabled
            if not enabled:
                continue
            try:
                self.observe_once()
            except Exception:
                continue

    def start(self) -> None:
        with self._lock:
            if self._thread is not None and self._thread.is_alive():
                return
            self._stop.clear()
            self._thread = threading.Thread(
                target=self._worker,
                name="stackchan-room-context",
                daemon=True,
            )
            self._thread.start()
            if self._enabled:
                self._wake.set()

    def stop(self) -> None:
        with self._lock:
            self._control_epoch += 1
            self._stop.set()
            self._wake.set()
            thread = self._thread
        if thread is not None:
            thread.join(timeout=3.0)
