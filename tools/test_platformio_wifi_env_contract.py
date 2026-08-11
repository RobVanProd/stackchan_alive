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

    def test_private_camera_profiles_require_pairing_code(self):
        for profile in (
            "stackchan_camera_probe",
            "stackchan_camera_probe_pmic_telemetry_only",
            "stackchan_camera_probe_pmic_policy_only",
            "stackchan_camera_probe_pmic_all_off",
            "stackchan_release_forensics_vision",
        ):
            with self.subTest(profile=profile):
                with self.assertRaisesRegex(RuntimeError, "requires STACKCHAN_PAIRING_SHORT_CODE"):
                    run_hook(profile)

    def test_every_camera_environment_refuses_to_build_without_pairing(self):
        # The hook matches paired-camera environments by name because it cannot
        # see resolved build flags. Derive the real set from platformio.ini so a
        # new camera environment cannot be added without the pairing guard: a
        # camera image built without a pairing code serves its camera endpoints
        # unauthenticated.
        ini = (Path(__file__).resolve().parents[1] / "platformio.ini").read_text(encoding="utf-8")
        blocks = {}
        current = None
        for line in ini.splitlines():
            stripped = line.strip()
            if stripped.startswith("[env:") and stripped.endswith("]"):
                current = stripped[5:-1]
                blocks[current] = []
            elif current is not None:
                blocks[current].append(stripped)

        camera_environments = {
            name
            for name, body in blocks.items()
            if any(entry.startswith("-D STACKCHAN_ENABLE_CAMERA=1") for entry in body)
        }
        # Inheritance: an environment extending a camera environment is one too.
        for _ in range(len(blocks)):
            for name, body in blocks.items():
                for entry in body:
                    if entry.startswith("extends = env:"):
                        if entry.split("extends = env:", 1)[1].strip() in camera_environments:
                            camera_environments.add(name)

        # stackchan_release_full also compiles the camera in, but it is the
        # public secret-free image: it deliberately embeds no pairing code and
        # owners provision pairing after flash. Requiring one at build time would
        # make the public release unbuildable. Every *private* per-device camera
        # environment must still refuse.
        camera_environments.discard("stackchan_release_full")

        self.assertIn("stackchan_camera_probe", camera_environments)
        self.assertIn("stackchan_release_forensics_vision", camera_environments)
        for profile in sorted(camera_environments):
            with self.subTest(profile=profile):
                with self.assertRaisesRegex(RuntimeError, "requires STACKCHAN_PAIRING_SHORT_CODE"):
                    run_hook(profile)

    def test_embedded_host_without_port_uses_canonical_bridge_port(self):
        fake = run_hook(
            "stackchan_wifi_uplink",
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
