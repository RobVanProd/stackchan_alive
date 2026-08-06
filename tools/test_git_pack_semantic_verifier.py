#!/usr/bin/env python3
"""Hostile contract for the release Git-pack semantic verifier."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


TOOLS_ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOLS_ROOT))

import verify_git_pack_semantics as verifier  # noqa: E402

VerificationError = verifier.VerificationError
verify_pack_triplet = verifier.verify_pack_triplet


def _run_git(*args: str, cwd: Path | None = None) -> str:
    environment = os.environ.copy()
    environment.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    completed = subprocess.run(
        ["git", *args],
        cwd=cwd,
        env=environment,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if completed.returncode:
        raise AssertionError(
            f"git {' '.join(args)} failed ({completed.returncode}):\n"
            f"{completed.stdout}\n{completed.stderr}"
        )
    return completed.stdout.strip()


def _swap_index_offsets_without_changing_object_ids(index_path: Path) -> None:
    data = bytearray(index_path.read_bytes())
    if data[:4] != b"\xfftOc" or struct.unpack_from(">I", data, 4)[0] != 2:
        raise AssertionError("fixture did not produce a Git pack index v2")
    count = struct.unpack_from(">I", data, 8 + 255 * 4)[0]
    if count < 2:
        raise AssertionError("fixture pack needs at least two objects")
    crc_start = 8 + 256 * 4 + count * 20
    offset_start = crc_start + count * 4
    chosen: list[int] = []
    for position in range(count):
        encoded = struct.unpack_from(">I", data, offset_start + position * 4)[0]
        if encoded & 0x80000000 == 0:
            chosen.append(position)
            if len(chosen) == 2:
                break
    if len(chosen) != 2:
        raise AssertionError("fixture pack did not expose two ordinary offsets")
    first, second = chosen
    first_offset = data[offset_start + first * 4 : offset_start + first * 4 + 4]
    second_offset = data[offset_start + second * 4 : offset_start + second * 4 + 4]
    data[offset_start + first * 4 : offset_start + first * 4 + 4] = second_offset
    data[offset_start + second * 4 : offset_start + second * 4 + 4] = first_offset
    # Keep the index structurally valid so only semantic decoding can reject it.
    data[-20:] = hashlib.sha1(data[:-20]).digest()
    os.chmod(index_path, 0o600)
    index_path.write_bytes(data)


class GitPackSemanticVerifierContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_root = Path(tempfile.mkdtemp(prefix="stackchan-git-pack-semantic-"))
        self.repo = self.temp_root / "repo"
        _run_git("init", "--initial-branch=main", str(self.repo))
        _run_git("config", "user.name", "Stackchan Contract", cwd=self.repo)
        _run_git("config", "user.email", "contract@example.invalid", cwd=self.repo)
        _run_git("config", "core.autocrlf", "false", cwd=self.repo)
        for index in range(24):
            source = self.repo / f"source-{index:02d}.txt"
            source.write_text((f"object-{index:02d}\n" * (index + 3)), encoding="utf-8")
            _run_git("add", "--", source.name, cwd=self.repo)
            _run_git("commit", "-m", f"fixture {index:02d}", cwd=self.repo)
        _run_git("repack", "-ad", cwd=self.repo)
        pack_root = self.repo / ".git" / "objects" / "pack"
        self.pack = next(pack_root.glob("*.pack"))
        self.index = self.pack.with_suffix(".idx")
        self.reverse = self.pack.with_suffix(".rev")
        if not self.reverse.exists():
            _run_git("index-pack", "--rev-index", str(self.pack), cwd=self.repo)

    def tearDown(self) -> None:
        shutil.rmtree(self.temp_root, ignore_errors=True)

    def test_valid_pack_proves_exact_object_offset_and_reverse_index_mapping(self) -> None:
        result = verify_pack_triplet(self.pack, self.index, self.reverse)
        self.assertGreater(result["objectCount"], 20)
        self.assertTrue(result["objectOffsetMappingVerified"])
        self.assertTrue(result["reverseIndexMappingVerified"])
        self.assertEqual(result["objectCount"], len(result["objectIds"]))

    def test_checksum_valid_index_with_swapped_offsets_is_rejected(self) -> None:
        _swap_index_offsets_without_changing_object_ids(self.index)
        with self.assertRaisesRegex(VerificationError, "object-to-offset mapping"):
            verify_pack_triplet(self.pack, self.index, self.reverse)

    def test_object_resource_limit_is_fail_closed(self) -> None:
        with mock.patch.object(verifier, "MAX_OBJECT_BYTES", 0):
            with self.assertRaisesRegex(VerificationError, "resource limit"):
                verify_pack_triplet(self.pack, self.index, self.reverse)

    def test_symbolic_link_triplet_is_rejected_when_supported(self) -> None:
        linked_pack = self.pack.with_name("linked.pack")
        try:
            linked_pack.symlink_to(self.pack)
        except OSError:
            self.skipTest("symbolic links are unavailable to this Windows user")
        with self.assertRaisesRegex(VerificationError, "symbolic link"):
            verify_pack_triplet(linked_pack, self.index, self.reverse)


if __name__ == "__main__":
    unittest.main(verbosity=2)
