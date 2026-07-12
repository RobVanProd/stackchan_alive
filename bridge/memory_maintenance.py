#!/usr/bin/env python3
"""Audit or repair Stackchan bridge memory without exposing stored values."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path

from bridge_memory import BridgeMemory, load_bridge_memory, save_bridge_memory


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest().upper()


def _counts(data: object) -> dict[str, int]:
    if not isinstance(data, dict):
        return {"durable_facts": 0, "recent_context": 0, "recent_topics": 0, "physical_context": 0}
    return {
        "durable_facts": len(data.get("durable_facts", [])) if isinstance(data.get("durable_facts"), list) else 0,
        "recent_context": len(data.get("recent_context", [])) if isinstance(data.get("recent_context"), list) else 0,
        "recent_topics": len(data.get("recent_topics", [])) if isinstance(data.get("recent_topics"), list) else 0,
        "physical_context": len(data.get("physical_context", [])) if isinstance(data.get("physical_context"), list) else 0,
    }


def _comparable(data: object) -> object:
    if not isinstance(data, dict):
        return data
    comparable = dict(data)
    comparable.pop("updated_at", None)
    return comparable


def audit_or_repair(path: Path, *, apply: bool) -> dict[str, object]:
    exists = path.is_file()
    raw: object = {}
    parse_error = ""
    input_sha256 = ""
    if exists:
        input_sha256 = _sha256(path)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            parse_error = type(exc).__name__
            raw = {}

    memory = load_bridge_memory(path)
    sanitized = memory.to_dict()
    changed = (
        parse_error != ""
        or not isinstance(raw, dict)
        or _comparable(raw) != _comparable(sanitized)
    )
    backup_path = ""
    if apply and exists and changed:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup = path.with_name(f"{path.stem}.backup-{stamp}{path.suffix}")
        shutil.copy2(path, backup)
        backup_path = str(backup)
    if apply and changed:
        save_bridge_memory(path, memory)

    return {
        "schema": "stackchan.memory-maintenance.v1",
        "mode": "apply" if apply else "dry-run",
        "status": "repaired" if apply and changed else ("clean" if not changed else "repair-available"),
        "memory_file": str(path),
        "input_exists": exists,
        "input_sha256": input_sha256,
        "input_schema": str(raw.get("schema", "legacy-flat")) if isinstance(raw, dict) else "invalid",
        "parse_error": parse_error,
        "changed": changed,
        "backup_file": backup_path,
        "before_counts": _counts(raw),
        "after_counts": _counts(sanitized),
        "after_schema": sanitized["schema"],
        "after_schema_version": sanitized["schema_version"],
        "preferred_name_retained": bool(sanitized["preferred_name"]),
        "turns_seen": int(sanitized["turns_seen"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--memory-file", type=Path, required=True)
    parser.add_argument("--apply", action="store_true", help="Back up and atomically write sanitized v3 memory.")
    args = parser.parse_args()
    print(json.dumps(audit_or_repair(args.memory_file, apply=args.apply), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
