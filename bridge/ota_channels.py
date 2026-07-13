#!/usr/bin/env python3
"""Build and verify hash-bound Stackchan stable/beta OTA channel manifests."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urlsplit


MANIFEST_SCHEMA = "stackchan.ota-channels.v1"
VERIFY_SCHEMA = "stackchan.ota-channel-verification.v1"
CHANNEL_NAMES = ("stable", "beta")
MAX_FIRMWARE_BYTES = 16 * 1024 * 1024
_VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$")
_COMMIT_RE = re.compile(r"^[0-9a-fA-F]{40}$")
_SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


class OtaChannelError(ValueError):
    """Raised when an OTA channel manifest violates the public contract."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def _timestamp(value: object, field: str) -> str:
    rendered = str(value or "").strip()
    try:
        parsed = datetime.fromisoformat(rendered.replace("Z", "+00:00"))
    except ValueError as exc:
        raise OtaChannelError(f"{field} must be an ISO-8601 timestamp") from exc
    if parsed.tzinfo is None:
        raise OtaChannelError(f"{field} must include a timezone")
    return rendered


def _artifact_metadata(path: Path) -> dict[str, object]:
    resolved = path.resolve(strict=True)
    size = resolved.stat().st_size
    if size <= 0 or size > MAX_FIRMWARE_BYTES:
        raise OtaChannelError(
            f"firmware bytes must be between 1 and {MAX_FIRMWARE_BYTES}: {resolved}"
        )
    digest = hashlib.sha256()
    with resolved.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"path": str(resolved), "bytes": size, "sha256": digest.hexdigest()}


def _validate_url(value: object, field: str) -> str:
    rendered = str(value or "").strip()
    parsed = urlsplit(rendered)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise OtaChannelError(
            f"{field} must be a durable HTTPS URL without credentials, query, or fragment"
        )
    return rendered


def _validate_channel(name: str, value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise OtaChannelError(f"channels.{name} must be an object")
    allowed = {"enabled", "version", "source_commit", "published_at", "artifact"}
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise OtaChannelError(f"channels.{name} has unknown fields: {', '.join(unknown)}")
    enabled = value.get("enabled")
    if not isinstance(enabled, bool):
        raise OtaChannelError(f"channels.{name}.enabled must be a boolean")
    if not enabled:
        if set(value) != {"enabled"}:
            raise OtaChannelError(f"disabled channel {name} must contain only enabled=false")
        return {"enabled": False}

    version = str(value.get("version") or "").strip()
    if not _VERSION_RE.fullmatch(version):
        raise OtaChannelError(f"channels.{name}.version must be semantic version text")
    if name == "stable" and "-" in version:
        raise OtaChannelError("the stable channel cannot point at a prerelease version")
    source_commit = str(value.get("source_commit") or "").strip()
    if not _COMMIT_RE.fullmatch(source_commit):
        raise OtaChannelError(f"channels.{name}.source_commit must be a 40-character Git commit")
    published_at = _timestamp(value.get("published_at"), f"channels.{name}.published_at")
    artifact = value.get("artifact")
    if not isinstance(artifact, dict):
        raise OtaChannelError(f"channels.{name}.artifact must be an object")
    if set(artifact) != {"url", "bytes", "sha256"}:
        raise OtaChannelError(
            f"channels.{name}.artifact requires exactly url, bytes, and sha256"
        )
    byte_count = artifact.get("bytes")
    if (
        isinstance(byte_count, bool)
        or not isinstance(byte_count, int)
        or byte_count <= 0
        or byte_count > MAX_FIRMWARE_BYTES
    ):
        raise OtaChannelError(
            f"channels.{name}.artifact.bytes must be between 1 and {MAX_FIRMWARE_BYTES}"
        )
    sha256 = str(artifact.get("sha256") or "").strip().lower()
    if not _SHA256_RE.fullmatch(sha256):
        raise OtaChannelError(f"channels.{name}.artifact.sha256 must be 64 hexadecimal characters")
    return {
        "enabled": True,
        "version": version,
        "source_commit": source_commit.lower(),
        "published_at": published_at,
        "artifact": {
            "url": _validate_url(artifact.get("url"), f"channels.{name}.artifact.url"),
            "bytes": byte_count,
            "sha256": sha256,
        },
    }


def validate_manifest(payload: object) -> dict[str, object]:
    if not isinstance(payload, dict):
        raise OtaChannelError("OTA channel manifest must be an object")
    if set(payload) != {"schema", "generated_at", "channels"}:
        raise OtaChannelError("manifest requires exactly schema, generated_at, and channels")
    if payload.get("schema") != MANIFEST_SCHEMA:
        raise OtaChannelError(f"manifest schema must be {MANIFEST_SCHEMA}")
    generated_at = _timestamp(payload.get("generated_at"), "generated_at")
    channels = payload.get("channels")
    if not isinstance(channels, dict) or set(channels) != set(CHANNEL_NAMES):
        raise OtaChannelError("manifest channels must contain exactly stable and beta")
    normalized = {
        name: _validate_channel(name, channels[name]) for name in CHANNEL_NAMES
    }
    if not normalized["stable"]["enabled"]:
        raise OtaChannelError("the stable channel must be enabled")
    return {"schema": MANIFEST_SCHEMA, "generated_at": generated_at, "channels": normalized}


def make_channel_entry(
    *, version: str, source_commit: str, url: str, firmware: Path, published_at: str
) -> dict[str, object]:
    metadata = _artifact_metadata(firmware)
    return {
        "enabled": True,
        "version": version,
        "source_commit": source_commit,
        "published_at": published_at,
        "artifact": {
            "url": url,
            "bytes": metadata["bytes"],
            "sha256": metadata["sha256"],
        },
    }


def build_manifest(
    *, stable: dict[str, object], beta: dict[str, object] | None = None, generated_at: str = ""
) -> dict[str, object]:
    payload = {
        "schema": MANIFEST_SCHEMA,
        "generated_at": generated_at or _utc_now(),
        "channels": {"stable": stable, "beta": beta or {"enabled": False}},
    }
    return validate_manifest(payload)


def verify_firmware(
    manifest: dict[str, object], channel: str, firmware: Path
) -> dict[str, object]:
    normalized = validate_manifest(manifest)
    selected = normalized["channels"][channel]
    issues: list[str] = []
    if not selected["enabled"]:
        issues.append("channel_disabled")
        return {
            "schema": VERIFY_SCHEMA,
            "ok": False,
            "channel": channel,
            "issues": issues,
            "automatic_download": False,
            "automatic_upload": False,
        }
    local = _artifact_metadata(firmware)
    expected = selected["artifact"]
    if local["bytes"] != expected["bytes"]:
        issues.append("firmware_size_mismatch")
    if local["sha256"] != expected["sha256"]:
        issues.append("firmware_sha256_mismatch")
    return {
        "schema": VERIFY_SCHEMA,
        "ok": not issues,
        "channel": channel,
        "version": selected["version"],
        "source_commit": selected["source_commit"],
        "published_at": selected["published_at"],
        "artifact_url": expected["url"],
        "expected_bytes": expected["bytes"],
        "expected_sha256": expected["sha256"],
        "local_firmware": local,
        "issues": issues,
        "automatic_download": False,
        "automatic_upload": False,
    }


def _write_json_atomic(path: Path, payload: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", newline="\n", dir=path.parent, delete=False
    ) as handle:
        handle.write(rendered)
        temporary = Path(handle.name)
    temporary.replace(path)


def _load_manifest(path: Path) -> dict[str, object]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    return validate_manifest(payload)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build", help="Build a channel manifest from local binaries.")
    build.add_argument("--stable-firmware", type=Path, required=True)
    build.add_argument("--stable-version", required=True)
    build.add_argument("--stable-source-commit", required=True)
    build.add_argument("--stable-url", required=True)
    build.add_argument("--beta-firmware", type=Path)
    build.add_argument("--beta-version")
    build.add_argument("--beta-source-commit")
    build.add_argument("--beta-url")
    build.add_argument("--output", type=Path, required=True)

    verify = subparsers.add_parser("verify", help="Verify a local binary against one channel.")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--channel", choices=CHANNEL_NAMES, required=True)
    verify.add_argument("--firmware", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "build":
            published_at = _utc_now()
            stable = make_channel_entry(
                version=args.stable_version,
                source_commit=args.stable_source_commit,
                url=args.stable_url,
                firmware=args.stable_firmware,
                published_at=published_at,
            )
            beta_values = (args.beta_firmware, args.beta_version, args.beta_source_commit, args.beta_url)
            if any(value is not None for value in beta_values) and not all(
                value is not None for value in beta_values
            ):
                raise OtaChannelError("beta firmware, version, source commit, and URL are all required together")
            beta = None
            if args.beta_firmware is not None:
                beta = make_channel_entry(
                    version=args.beta_version,
                    source_commit=args.beta_source_commit,
                    url=args.beta_url,
                    firmware=args.beta_firmware,
                    published_at=published_at,
                )
            payload = build_manifest(stable=stable, beta=beta, generated_at=published_at)
            _write_json_atomic(args.output.resolve(), payload)
        else:
            payload = verify_firmware(
                _load_manifest(args.manifest.resolve()), args.channel, args.firmware
            )
    except (OSError, OtaChannelError, json.JSONDecodeError) as exc:
        payload = {
            "schema": VERIFY_SCHEMA,
            "ok": False,
            "issues": [str(exc)],
            "automatic_download": False,
            "automatic_upload": False,
        }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if payload.get("ok", True) else 1


if __name__ == "__main__":
    raise SystemExit(main())
