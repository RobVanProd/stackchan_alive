from pathlib import Path
import json
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

import numpy as np

from vision_service import (
    FaceTarget,
    CameraVisionService,
    OpenCvYuNetDetector,
    YUNET_MODEL_PATH,
    YUNET_SCORE_THRESHOLD,
    encode_face_targets,
    main,
    normalize_face_targets,
    parse_pgm,
    read_pairing_code_file,
    require_private_robot_url,
    validate_pairing_code,
    verify_yunet_model,
)


class VisionServiceTests(unittest.TestCase):
    def test_parse_pgm_validates_dimensions_and_length(self) -> None:
        frame = parse_pgm(b"P5\n4 2\n255\n" + bytes(range(8)))
        self.assertEqual((2, 4), frame.shape)
        self.assertEqual(np.uint8(7), frame[1, 3])
        with self.assertRaises(ValueError):
            parse_pgm(b"P5\n4 2\n255\n" + bytes(range(7)))

    def test_normalize_faces_sorts_and_bounds_candidates(self) -> None:
        faces = normalize_face_targets(
            [(10, 20, 20, 20), (80, 10, 60, 60)], 160, 120, [1.0, 4.0]
        )
        self.assertEqual(2, len(faces))
        self.assertGreater(faces[0].size, faces[1].size)
        self.assertAlmostEqual(0.375, faces[0].x, places=3)
        self.assertGreaterEqual(faces[0].confidence, 0.25)
        self.assertLessEqual(faces[0].confidence, 1.0)

    def test_target_encoding_matches_firmware_wire_contract(self) -> None:
        path = encode_face_targets(
            "123456",
            [FaceTarget(x=-0.65, y=0.1, size=0.32, confidence=0.9)],
        )
        self.assertEqual("/vision-target?p=123456&f=-650,100,320,900", path)
        self.assertEqual("/vision-target?p=123456&f=", encode_face_targets("123456", []))

    def test_pairing_and_robot_address_are_restricted(self) -> None:
        self.assertEqual("123456", validate_pairing_code("123456"))
        with self.assertRaises(ValueError):
            validate_pairing_code("12345x")
        self.assertEqual(
            "http://192.168.1.238:8789",
            require_private_robot_url("http://192.168.1.238:8789/"),
        )
        with self.assertRaises(ValueError):
            require_private_robot_url("https://example.com")

    def test_pairing_code_file_keeps_secret_out_of_command_line(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "pairing.txt"
            path.write_text("123456\n", encoding="ascii")
            self.assertEqual(read_pairing_code_file(str(path)), "123456")
            path.write_text("12 3456", encoding="ascii")
            with self.assertRaises(ValueError):
                read_pairing_code_file(str(path))

    def test_hash_pinned_yunet_model_loads_and_rejects_blank_frame(self) -> None:
        self.assertEqual(0.35, YUNET_SCORE_THRESHOLD)
        self.assertEqual(YUNET_MODEL_PATH.resolve(), verify_yunet_model(YUNET_MODEL_PATH))
        detector = OpenCvYuNetDetector()
        self.assertEqual([], detector.detect(np.zeros((120, 160), dtype=np.uint8)))

        with tempfile.TemporaryDirectory() as directory:
            bad_model = Path(directory) / "face.onnx"
            bad_model.write_bytes(b"not an onnx model")
            with self.assertRaises(RuntimeError):
                verify_yunet_model(bad_model)

    def _run_preflight(self, debug_payload):
        with tempfile.TemporaryDirectory() as directory:
            pairing = Path(directory) / "pairing.txt"
            pairing.write_text("123456\n", encoding="ascii")
            argv = [
                "vision_service.py",
                "--robot-url",
                "http://127.0.0.1:8789",
                "--pairing-code-file",
                str(pairing),
                "--preflight",
            ]
            with patch.object(sys, "argv", argv), patch("builtins.print") as emit, patch.object(
                CameraVisionService, "_get", **debug_payload
            ):
                result = main()
        return result, json.loads(emit.call_args.args[0])

    def test_preflight_reports_ready_without_leaking_pairing_code(self) -> None:
        result, payload = self._run_preflight(
            {"return_value": b'{"compiled_enable_camera":1,"compiled_enable_camera_host_vision":1}'}
        )

        self.assertEqual(0, result)
        self.assertTrue(payload["ready"])
        self.assertFalse(payload["raw_frame_persistence"])
        self.assertNotIn("123456", json.dumps(payload))

    def test_preflight_refuses_a_camera_less_image(self) -> None:
        # F3's signature failure: the worker runs happily against firmware with the
        # camera compiled out and returns zero detections forever, which is
        # indistinguishable from a detector that simply sees nobody.
        result, payload = self._run_preflight(
            {"return_value": b'{"compiled_enable_camera":0,"compiled_enable_camera_host_vision":0}'}
        )

        self.assertEqual(2, result)
        self.assertFalse(payload["ready"])
        self.assertIn("firmware-camera-disabled", payload["reason"])
        self.assertIn("compiled_enable_camera", payload["reason"])

    def test_preflight_refuses_an_unreachable_robot(self) -> None:
        result, payload = self._run_preflight(
            {"side_effect": urllib.error.URLError("offline")}
        )

        self.assertEqual(2, result)
        self.assertFalse(payload["ready"])
        self.assertIn("robot-unreachable", payload["reason"])

    def test_preflight_treats_a_truncated_debug_response_as_unknown_not_disabled(self) -> None:
        # /debug truncates by omitting fields rather than zeroing them, so an
        # absent flag must not be read as "camera disabled".
        result, payload = self._run_preflight({"return_value": b'{"bridge_state":"ready"}'})

        self.assertEqual(0, result)
        self.assertTrue(payload["ready"])

    def test_camera_service_retries_one_transport_miss_and_records_recovery(self) -> None:
        class Detector:
            @staticmethod
            def detect(frame):
                self.assertEqual((2, 4), frame.shape)
                return []

        service = CameraVisionService("http://127.0.0.1:8789", "123456", Detector())
        pgm = b"P5\n4 2\n255\n" + bytes(range(8))
        with patch.object(
            service,
            "_get",
            side_effect=[urllib.error.URLError("transient"), pgm, b'{"ok":true}'],
        ):
            self.assertEqual([], service.step())

        self.assertEqual(1, service.stats.transport_retries)
        self.assertEqual(1, service.stats.transport_recoveries)
        self.assertEqual(0, service.stats.frame_failures)
        self.assertEqual(1, service.stats.frames)


if __name__ == "__main__":
    unittest.main()
