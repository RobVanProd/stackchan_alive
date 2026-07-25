import json
import sys
import unittest
from pathlib import Path

BRIDGE_DIR = Path(__file__).resolve().parent
if str(BRIDGE_DIR) not in sys.path:
    sys.path.insert(0, str(BRIDGE_DIR))

from room_context import (  # noqa: E402
    PrivateCameraFrameSource,
    RoomContextRuntime,
    RoomObservationConfig,
    RoomObservationCancelled,
    _private_robot_url,
    diff_scenes,
    sanitize_scene,
)


class RoomContextTests(unittest.TestCase):
    def test_model_output_is_reduced_to_allowlisted_typed_fields(self) -> None:
        summary = sanitize_scene(
            {
                "person_count": 1,
                "activity": "person_seated",
                "objects": ["desk", "monitor", "prescription", "desk"],
                "lighting": "bright",
                "person_description": "private free-form description",
            },
            observed_ms=123,
        )

        self.assertEqual(1, summary.person_count)
        self.assertEqual(("desk", "monitor"), summary.objects)
        serialized = json.dumps(summary.prompt_line())
        self.assertNotIn("prescription", serialized)
        self.assertNotIn("free-form description", serialized)

    def test_scene_diff_tracks_changes_not_static_presence(self) -> None:
        first = sanitize_scene(
            {"person_count": 0, "activity": "empty", "objects": ["desk"], "lighting": "dim"},
            observed_ms=1,
        )
        second = sanitize_scene(
            {
                "person_count": 1,
                "activity": "person_seated",
                "objects": ["desk", "lamp"],
                "lighting": "bright",
            },
            observed_ms=2,
        )

        self.assertEqual(
            ("person_arrived", "objects_changed", "lighting_changed"),
            diff_scenes(first, second),
        )
        self.assertEqual((), diff_scenes(second, second))

    def test_runtime_never_exposes_or_persists_raw_frame(self) -> None:
        raw_frame = b"P5\n2 2\n255\n\x00\x01\x02\x03"
        received: list[bytes] = []
        runtime = RoomContextRuntime(
            RoomObservationConfig(enabled=True, interval_seconds=300, command="fixture"),
            frame_source=lambda: raw_frame,
            model_observer=lambda frame: (
                received.append(frame)
                or {
                    "person_count": 1,
                    "activity": "person_standing",
                    "objects": ["door"],
                    "lighting": "mixed",
                }
            ),
        )

        summary = runtime.observe_once(now_ms=100)
        status = runtime.status()

        self.assertEqual([raw_frame], received)
        self.assertEqual(1, summary.person_count)
        self.assertNotIn("P5", json.dumps(status))
        self.assertNotIn("frame", json.dumps(status).lower())
        self.assertEqual(1, status["observations"])

    def test_missing_camera_or_model_degrades_without_prompt_context(self) -> None:
        runtime = RoomContextRuntime(
            RoomObservationConfig(enabled=True, interval_seconds=300, command="")
        )

        with self.assertRaises(RuntimeError):
            runtime.observe_once(now_ms=10)

        self.assertEqual((), runtime.prompt_lines())
        self.assertEqual(1, runtime.status()["failures"])
        self.assertEqual("camera_not_configured", runtime.status()["lastError"])

    def test_user_controls_enforce_low_rate_capture(self) -> None:
        runtime = RoomContextRuntime(RoomObservationConfig(interval_seconds=300))
        with self.assertRaises(ValueError):
            runtime.set_controls(enabled=True, interval_seconds=60)

        status = runtime.set_controls(enabled=True, interval_seconds=600)

        self.assertTrue(status["enabled"])
        self.assertEqual(600, status["intervalSeconds"])

    def test_camera_source_accepts_only_loopback_or_private_lan_literals(self) -> None:
        self.assertEqual(
            "http://192.168.1.238:8789",
            _private_robot_url("http://192.168.1.238:8789"),
        )
        self.assertEqual("http://127.0.0.1:8789", _private_robot_url("http://127.0.0.1:8789/"))
        for url in (
            "http://169.254.169.254",
            "http://0.0.0.0",
            "http://224.0.0.1",
            "http://example.com",
        ):
            with self.subTest(url=url), self.assertRaises(ValueError):
                _private_robot_url(url)

    def test_camera_transport_rejects_redirects(self) -> None:
        source = PrivateCameraFrameSource("http://127.0.0.1:8789", "123456")
        handler = __import__("room_context")._RejectRedirects()

        self.assertIsNone(
            handler.redirect_request(None, None, 307, "redirect", {}, "https://example.com")
        )
        self.assertEqual("123456", source.pairing_code)

    def test_disabling_during_capture_discards_in_flight_summary(self) -> None:
        raw_frame = b"P5\n2 2\n255\n\x00\x01\x02\x03"
        runtime = None

        def frame_source() -> bytes:
            runtime.set_controls(enabled=False, interval_seconds=300)
            return raw_frame

        runtime = RoomContextRuntime(
            RoomObservationConfig(enabled=True, interval_seconds=300, command="fixture"),
            frame_source=frame_source,
            model_observer=lambda frame: {
                "person_count": 1,
                "activity": "person_seated",
                "objects": ["desk"],
                "lighting": "bright",
            },
        )

        with self.assertRaises(RoomObservationCancelled):
            runtime.observe_once(now_ms=100)

        status = runtime.status()
        self.assertFalse(status["enabled"])
        self.assertIsNone(runtime.latest_summary())
        self.assertEqual(0, status["observations"])
        self.assertEqual(0, status["failures"])
        self.assertIsNone(status["ageSeconds"])


if __name__ == "__main__":
    unittest.main()
