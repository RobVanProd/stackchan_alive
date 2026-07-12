import os
import runpy
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("platformio_apply_wifi_bridge_env.py")


class FakeEnvironment:
    def __init__(self, pio_environment: str) -> None:
        self.pio_environment = pio_environment
        self.append_calls = []

    def subst(self, value: str) -> str:
        if value != "$PIOENV":
            raise AssertionError(f"unexpected substitution: {value}")
        return self.pio_environment

    def Append(self, **kwargs) -> None:
        self.append_calls.append(kwargs)


def run_hook(pio_environment: str, values=None):
    fake_environment = FakeEnvironment(pio_environment)

    def fake_import(name: str) -> None:
        if name != "env":
            raise AssertionError(f"unexpected SCons import: {name}")

    with mock.patch.dict(os.environ, values or {}, clear=True):
        runpy.run_path(
            str(SCRIPT),
            init_globals={"Import": fake_import, "env": fake_environment},
        )
    return fake_environment


class PlatformioWifiEnvironmentContractTests(unittest.TestCase):
    def test_public_full_release_allows_secret_free_build(self):
        fake = run_hook("stackchan_release_full")
        self.assertEqual(1, len(fake.append_calls))
        self.assertIn(("STACKCHAN_ENABLE_WIFI_BRIDGE", 1), fake.append_calls[0]["CPPDEFINES"])
        self.assertEqual([], fake.append_calls[0]["CCFLAGS"])

    def test_public_full_release_rejects_every_private_value(self):
        private_values = {
            "STACKCHAN_WIFI_SSID": "private-network",
            "STACKCHAN_WIFI_PASSWORD": "private-password",
            "STACKCHAN_BRIDGE_HOST": "192.168.1.10",
            "STACKCHAN_BRIDGE_PORT": "8765",
            "STACKCHAN_BRIDGE_PATH": "/bridge",
            "STACKCHAN_PAIRING_SHORT_CODE": "ABC123",
        }
        for name, value in private_values.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError, "forbids embedded"):
                    run_hook("stackchan_release_full", {name: value})

    def test_private_lab_profile_can_receive_values(self):
        fake = run_hook(
            "stackchan_camera_probe",
            {
                "STACKCHAN_BRIDGE_HOST": "192.168.1.10",
                "STACKCHAN_PAIRING_SHORT_CODE": "123456",
            },
        )
        flags = " ".join(fake.append_calls[0]["CCFLAGS"])
        self.assertIn("STACKCHAN_BRIDGE_HOST", flags)
        self.assertIn("STACKCHAN_PAIRING_SHORT_CODE", flags)

    def test_embedded_host_without_port_uses_canonical_bridge_port(self):
        fake = run_hook(
            "stackchan_camera_probe",
            {"STACKCHAN_BRIDGE_HOST": "192.168.1.10"},
        )
        self.assertIn(
            ("STACKCHAN_BRIDGE_PORT", 8765),
            fake.append_calls[0]["CPPDEFINES"],
        )

    def test_bridge_port_must_be_in_tcp_range(self):
        for value in ("0", "65536"):
            with self.subTest(value=value):
                with self.assertRaisesRegex(RuntimeError, "between 1 and 65535"):
                    run_hook("stackchan_camera_probe", {"STACKCHAN_BRIDGE_PORT": value})


if __name__ == "__main__":
    unittest.main()
