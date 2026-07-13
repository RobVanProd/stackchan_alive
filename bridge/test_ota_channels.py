import json
import tempfile
import unittest
from pathlib import Path

from ota_channels import (
    OtaChannelError,
    build_manifest,
    make_channel_entry,
    validate_manifest,
    verify_firmware,
)


COMMIT = "a" * 40
STABLE_URL = "https://github.com/example/stackchan/releases/download/v1.2.3/firmware.bin"
BETA_URL = "https://github.com/example/stackchan/releases/download/v1.3.0-beta.1/firmware.bin"


class OtaChannelTests(unittest.TestCase):
    def test_build_and_verify_exact_stable_artifact(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            firmware = Path(temp_dir) / "firmware.bin"
            firmware.write_bytes(b"exact firmware image")
            stable = make_channel_entry(
                version="1.2.3",
                source_commit=COMMIT,
                url=STABLE_URL,
                firmware=firmware,
                published_at="2026-07-12T12:00:00Z",
            )
            manifest = build_manifest(
                stable=stable, generated_at="2026-07-12T12:00:00Z"
            )

            result = verify_firmware(manifest, "stable", firmware)

        self.assertTrue(result["ok"], result["issues"])
        self.assertEqual("1.2.3", result["version"])
        self.assertEqual(COMMIT, result["source_commit"])
        self.assertFalse(result["automatic_download"])
        self.assertFalse(result["automatic_upload"])

    def test_changed_artifact_fails_size_and_hash(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            firmware = Path(temp_dir) / "firmware.bin"
            firmware.write_bytes(b"release")
            stable = make_channel_entry(
                version="1.2.3",
                source_commit=COMMIT,
                url=STABLE_URL,
                firmware=firmware,
                published_at="2026-07-12T12:00:00Z",
            )
            manifest = build_manifest(stable=stable)
            firmware.write_bytes(b"different release")

            result = verify_firmware(manifest, "stable", firmware)

        self.assertFalse(result["ok"])
        self.assertIn("firmware_size_mismatch", result["issues"])
        self.assertIn("firmware_sha256_mismatch", result["issues"])

    def test_disabled_beta_is_explicit_and_cannot_verify(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            firmware = Path(temp_dir) / "firmware.bin"
            firmware.write_bytes(b"release")
            stable = make_channel_entry(
                version="1.2.3",
                source_commit=COMMIT,
                url=STABLE_URL,
                firmware=firmware,
                published_at="2026-07-12T12:00:00Z",
            )
            manifest = build_manifest(stable=stable)

            result = verify_firmware(manifest, "beta", firmware)

        self.assertFalse(result["ok"])
        self.assertEqual(["channel_disabled"], result["issues"])

    def test_beta_entry_is_hash_bound_when_enabled(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            stable_file = Path(temp_dir) / "stable.bin"
            beta_file = Path(temp_dir) / "beta.bin"
            stable_file.write_bytes(b"stable")
            beta_file.write_bytes(b"beta")
            stable = make_channel_entry(
                version="1.2.3",
                source_commit=COMMIT,
                url=STABLE_URL,
                firmware=stable_file,
                published_at="2026-07-12T12:00:00Z",
            )
            beta = make_channel_entry(
                version="1.3.0-beta.1",
                source_commit="b" * 40,
                url=BETA_URL,
                firmware=beta_file,
                published_at="2026-07-12T12:00:00Z",
            )
            manifest = build_manifest(stable=stable, beta=beta)

            result = verify_firmware(manifest, "beta", beta_file)

        self.assertTrue(result["ok"], result["issues"])
        self.assertEqual("1.3.0-beta.1", result["version"])

    def test_manifest_rejects_untrusted_or_ambiguous_metadata(self):
        base = {
            "schema": "stackchan.ota-channels.v1",
            "generated_at": "2026-07-12T12:00:00Z",
            "channels": {
                "stable": {
                    "enabled": True,
                    "version": "1.2.3",
                    "source_commit": COMMIT,
                    "published_at": "2026-07-12T12:00:00Z",
                    "artifact": {
                        "url": STABLE_URL,
                        "bytes": 123,
                        "sha256": "c" * 64,
                    },
                },
                "beta": {"enabled": False},
            },
        }
        cases = []
        http_url = json.loads(json.dumps(base))
        http_url["channels"]["stable"]["artifact"]["url"] = "http://example.test/firmware.bin"
        cases.append(http_url)
        prerelease_stable = json.loads(json.dumps(base))
        prerelease_stable["channels"]["stable"]["version"] = "1.2.3-beta.1"
        cases.append(prerelease_stable)
        unknown_channel = json.loads(json.dumps(base))
        unknown_channel["channels"]["nightly"] = {"enabled": False}
        cases.append(unknown_channel)
        decorated_disabled = json.loads(json.dumps(base))
        decorated_disabled["channels"]["beta"]["version"] = "1.3.0-beta.1"
        cases.append(decorated_disabled)

        for payload in cases:
            with self.subTest(payload=payload):
                with self.assertRaises(OtaChannelError):
                    validate_manifest(payload)


if __name__ == "__main__":
    unittest.main()
