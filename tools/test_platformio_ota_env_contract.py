import hashlib
import os
import runpy
import unittest
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name("platformio_apply_ota_env.py")


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


def run_hook(pio_environment: str, token=None):
    fake_environment = FakeEnvironment(pio_environment)
    environment = {}
    if token is not None:
        environment["STACKCHAN_OTA_TOKEN"] = token

    def fake_import(name: str) -> None:
        if name != "env":
            raise AssertionError(f"unexpected SCons import: {name}")

    with mock.patch.dict(os.environ, environment, clear=True):
        runpy.run_path(
            str(SCRIPT),
            init_globals={"Import": fake_import, "env": fake_environment},
        )
        utf8_environment = {
            "PYTHONIOENCODING": os.environ.get("PYTHONIOENCODING"),
            "PYTHONUTF8": os.environ.get("PYTHONUTF8"),
        }
    return fake_environment, utf8_environment


class PlatformioOtaEnvironmentContractTests(unittest.TestCase):
    def test_release_build_refuses_missing_token(self):
        with self.assertRaisesRegex(RuntimeError, "requires STACKCHAN_OTA_TOKEN"):
            run_hook("stackchan_release_forensics")

    def test_camera_build_refuses_missing_token(self):
        with self.assertRaisesRegex(RuntimeError, "requires STACKCHAN_OTA_TOKEN"):
            run_hook("stackchan_camera_probe")

    def test_nonproduction_environment_may_build_without_ota(self):
        fake, utf8_environment = run_hook("stackchan_voice_v2")
        self.assertEqual([], fake.append_calls)
        self.assertEqual("utf-8", utf8_environment["PYTHONIOENCODING"])
        self.assertEqual("1", utf8_environment["PYTHONUTF8"])

    def test_public_full_release_forbids_embedded_token(self):
        with self.assertRaisesRegex(RuntimeError, "forbids embedding an OTA token"):
            run_hook("stackchan_release_full", "correct-horse-battery-staple-ota-token-2026")

    def test_valid_token_enables_ota_with_digest_only(self):
        token = "correct-horse-battery-staple-ota-token-2026"
        fake, utf8_environment = run_hook("stackchan_release_forensics", token)
        self.assertEqual(1, len(fake.append_calls))
        append = fake.append_calls[0]
        self.assertIn(("STACKCHAN_ENABLE_LAN_OTA", 1), append["CPPDEFINES"])
        digest = hashlib.sha256(token.encode("utf-8")).hexdigest()
        flags = " ".join(append["CCFLAGS"])
        self.assertIn(digest, flags)
        self.assertNotIn(token, flags)
        self.assertEqual("utf-8", utf8_environment["PYTHONIOENCODING"])
        self.assertEqual("1", utf8_environment["PYTHONUTF8"])

    def test_token_validation_remains_strict(self):
        for token in ("short", " token-that-is-long-enough-but-leading-space", "x" * 129):
            with self.subTest(token_length=len(token)):
                with self.assertRaises(RuntimeError):
                    run_hook("stackchan_release_forensics", token)


if __name__ == "__main__":
    unittest.main()
