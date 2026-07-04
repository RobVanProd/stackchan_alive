#!/usr/bin/env python3
"""Listen for Android Stackchan Companion UDP discovery beacons."""

from __future__ import annotations

import argparse
import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA = "stackchan.android-udp-beacon-probe.v1"
PROTOCOL = "stackchan.bridge.v1"
BEACON_TYPE = "stackchan_bridge_beacon"
DEFAULT_BEACON_PORT = 8766
DEFAULT_BRIDGE_PORT = 8765


class BeaconProbeError(RuntimeError):
    """Raised when the UDP beacon probe cannot complete."""


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def validate_beacon(
    beacon: dict[str, Any],
    require_android: bool,
    expected_bridge_port: int,
    expected_endpoint_id: str,
) -> list[str]:
    issues: list[str] = []
    if beacon.get("type") != BEACON_TYPE:
        issues.append(f"expected type {BEACON_TYPE}, got {beacon.get('type')!r}")
    if beacon.get("protocol") != PROTOCOL:
        issues.append(f"expected protocol {PROTOCOL}, got {beacon.get('protocol')!r}")
    if require_android and beacon.get("endpoint_kind") != "android":
        issues.append(f"expected endpoint_kind android, got {beacon.get('endpoint_kind')!r}")
    if not str(beacon.get("endpoint_id", "")).strip():
        issues.append("endpoint_id is missing")
    if expected_endpoint_id and beacon.get("endpoint_id") != expected_endpoint_id:
        issues.append(f"expected endpoint_id {expected_endpoint_id!r}, got {beacon.get('endpoint_id')!r}")
    if beacon.get("port") != expected_bridge_port:
        issues.append(f"expected bridge port {expected_bridge_port}, got {beacon.get('port')!r}")
    capabilities = beacon.get("capabilities")
    if not isinstance(capabilities, list):
        issues.append("capabilities must be a list")
    else:
        for required in ("settings", "diagnostics"):
            if required not in capabilities:
                issues.append(f"capabilities missing {required!r}")
    return issues


def listen_for_beacon(bind_host: str, port: int, timeout: float, max_bytes: int) -> tuple[dict[str, Any], tuple[str, int], float]:
    started = time.perf_counter()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((bind_host, port))
        sock.settimeout(timeout)
        try:
            payload, address = sock.recvfrom(max_bytes)
        except socket.timeout as exc:
            raise BeaconProbeError(f"timed out waiting for UDP beacon on {bind_host or '0.0.0.0'}:{port}") from exc
    elapsed_ms = (time.perf_counter() - started) * 1000.0
    try:
        beacon = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BeaconProbeError(f"UDP beacon payload is not valid JSON: {exc}") from exc
    if not isinstance(beacon, dict):
        raise BeaconProbeError("UDP beacon payload must be a JSON object")
    return beacon, (str(address[0]), int(address[1])), elapsed_ms


def build_report(
    bind_host: str,
    port: int,
    timeout: float,
    require_android: bool,
    expected_bridge_port: int,
    expected_endpoint_id: str,
    max_bytes: int = 8192,
) -> dict[str, Any]:
    report: dict[str, Any] = {
        "schema": SCHEMA,
        "generated_at": utc_timestamp(),
        "bind_host": bind_host or "0.0.0.0",
        "beacon_port": port,
        "status": "fail",
        "issues": [],
    }
    try:
        beacon, source, elapsed_ms = listen_for_beacon(bind_host, port, timeout, max_bytes)
        issues = validate_beacon(beacon, require_android, expected_bridge_port, expected_endpoint_id)
        report.update(
            {
                "status": "pass" if not issues else "fail",
                "issues": issues,
                "elapsed_ms": round(elapsed_ms, 2),
                "source_host": source[0],
                "source_port": source[1],
                "beacon": beacon,
            }
        )
    except Exception as exc:
        report["issues"] = [f"{type(exc).__name__}: {exc}"]
    return report


def write_outputs(report: dict[str, Any], out_dir: Path) -> tuple[Path, Path]:
    out_dir.mkdir(parents=True, exist_ok=True)
    json_path = out_dir / "android_udp_beacon_probe.json"
    md_path = out_dir / "ANDROID_UDP_BEACON_PROBE.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    lines = [
        "# Android UDP Beacon Probe",
        "",
        f"- Status: `{report['status']}`",
        f"- Listen: `{report.get('bind_host', '0.0.0.0')}:{report.get('beacon_port', DEFAULT_BEACON_PORT)}`",
        f"- Generated: `{report['generated_at']}`",
    ]
    if "elapsed_ms" in report:
        lines.append(f"- Elapsed: `{report['elapsed_ms']} ms`")
    if "source_host" in report:
        lines.append(f"- Source: `{report['source_host']}:{report['source_port']}`")
    beacon = report.get("beacon")
    if isinstance(beacon, dict):
        lines.extend(
            [
                f"- Endpoint ID: `{beacon.get('endpoint_id', '')}`",
                f"- Endpoint kind: `{beacon.get('endpoint_kind', '')}`",
                f"- Protocol: `{beacon.get('protocol', '')}`",
                f"- Bridge port: `{beacon.get('port', '')}`",
                f"- Capabilities: `{', '.join(beacon.get('capabilities', []))}`",
            ]
        )
    lines.append("")
    lines.append("## Issues")
    issues = report.get("issues", [])
    if issues:
        lines.extend(f"- {issue}" for issue in issues)
    else:
        lines.append("- None")
    lines.append("")
    md_path.write_text("\n".join(lines), encoding="utf-8")
    return json_path, md_path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Listen for an Android Stackchan Companion UDP beacon.")
    parser.add_argument("--bind-host", default="", help="Local interface to bind. Default listens on all IPv4 interfaces.")
    parser.add_argument("--port", type=int, default=DEFAULT_BEACON_PORT, help="UDP beacon listen port.")
    parser.add_argument("--timeout", type=float, default=10.0, help="Seconds to wait for one beacon.")
    parser.add_argument("--expected-bridge-port", type=int, default=DEFAULT_BRIDGE_PORT, help="Expected WebSocket bridge port in the beacon.")
    parser.add_argument("--expected-endpoint-id", default="", help="Optional exact endpoint_id expected in the beacon.")
    parser.add_argument("--allow-non-android", action="store_true", help="Do not require endpoint_kind=android.")
    parser.add_argument("--out-dir", default="output/android-udp-beacon/latest", help="Report output directory.")
    parser.add_argument("--json", action="store_true", help="Print the JSON report to stdout.")
    args = parser.parse_args(argv)

    report = build_report(
        bind_host=args.bind_host,
        port=args.port,
        timeout=args.timeout,
        require_android=not args.allow_non_android,
        expected_bridge_port=args.expected_bridge_port,
        expected_endpoint_id=args.expected_endpoint_id,
    )
    json_path, md_path = write_outputs(report, Path(args.out_dir))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Android UDP beacon probe report: {json_path}")
        print(f"Android UDP beacon probe summary: {md_path}")
        print(f"Status: {report['status']}")
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
