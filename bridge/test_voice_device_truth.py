import sys
import types
import unittest
from unittest.mock import patch

from voice_device_truth import directml_device_truth, torch_device_truth


class VoiceDeviceTruthTests(unittest.TestCase):
    def test_cuda_health_reports_actual_adapter_name(self):
        fake_torch = types.SimpleNamespace(
            cuda=types.SimpleNamespace(
                is_available=lambda: True,
                get_device_name=lambda index: f"Test GPU {index}",
            )
        )
        with patch.dict(sys.modules, {"torch": fake_torch}):
            self.assertEqual(("Test GPU 0", True), torch_device_truth("cuda:0"))

    def test_unavailable_cuda_is_explicit(self):
        fake_torch = types.SimpleNamespace(
            cuda=types.SimpleNamespace(is_available=lambda: False)
        )
        with patch.dict(sys.modules, {"torch": fake_torch}):
            self.assertEqual(("unavailable", False), torch_device_truth("cuda:0"))

    def test_cpu_is_not_misreported_as_accelerator(self):
        fake_torch = types.SimpleNamespace(cuda=types.SimpleNamespace())
        with patch.dict(sys.modules, {"torch": fake_torch}):
            self.assertEqual(("CPU", True), torch_device_truth("cpu:0"))

    def test_directml_health_reports_adapter_name(self):
        fake_directml = types.SimpleNamespace(device_name=lambda index: f"DirectML Test GPU {index}\x00")
        with patch.dict(sys.modules, {"torch_directml": fake_directml}):
            self.assertEqual(
                ("DirectML Test GPU 0", True),
                directml_device_truth("privateuseone:0"),
            )


if __name__ == "__main__":
    unittest.main()
