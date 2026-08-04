#!/usr/bin/env python3
"""Independently decode one Git SHA-1 pack/index/reverse-index triplet.

The release dependency proof must not accept a checksum-valid index whose object IDs
point at the wrong packed-object offsets.  This verifier uses only the byte-identified
CPython runtime and its standard library; it never invokes Git.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
from typing import Any
import zlib


MAX_PACK_BYTES = 64 * 1024 * 1024
MAX_INDEX_BYTES = 16 * 1024 * 1024
MAX_REVERSE_INDEX_BYTES = 8 * 1024 * 1024
MAX_OBJECT_COUNT = 50_000
MAX_OBJECT_BYTES = 64 * 1024 * 1024
MAX_TOTAL_INFLATED_BYTES = 256 * 1024 * 1024
MAX_DELTA_DEPTH = 128


class VerificationError(ValueError):
    """The pack triplet is malformed, unsupported, or semantically inconsistent."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise VerificationError(message)


def _u32(data: bytes, offset: int, context: str) -> int:
    _require(offset >= 0 and offset + 4 <= len(data), f"truncated {context}")
    return struct.unpack_from(">I", data, offset)[0]


def _u64(data: bytes, offset: int, context: str) -> int:
    _require(offset >= 0 and offset + 8 <= len(data), f"truncated {context}")
    return struct.unpack_from(">Q", data, offset)[0]


def _sha1(data: bytes) -> bytes:
    return hashlib.sha1(data).digest()


def _parse_index(index_data: bytes) -> dict[str, Any]:
    _require(len(index_data) <= MAX_INDEX_BYTES, "Git pack index exceeds the verifier resource limit")
    _require(len(index_data) >= 8 + 256 * 4 + 40, "Git pack index is truncated")
    _require(index_data[:4] == b"\xfftOc", "unsupported Git pack index signature")
    _require(_u32(index_data, 4, "Git pack index version") == 2, "unsupported Git pack index version")
    _require(_sha1(index_data[:-20]) == index_data[-20:], "Git pack index checksum mismatch")

    fanout = [_u32(index_data, 8 + number * 4, "Git pack fanout") for number in range(256)]
    _require(all(fanout[index] <= fanout[index + 1] for index in range(255)), "Git pack fanout is not monotonic")
    count = fanout[-1]
    _require(count <= MAX_OBJECT_COUNT, "Git pack object count exceeds the verifier resource limit")
    object_id_start = 8 + 256 * 4
    crc_start = object_id_start + count * 20
    offset_start = crc_start + count * 4
    ordinary_offset_end = offset_start + count * 4
    _require(ordinary_offset_end + 40 <= len(index_data), "Git pack index tables are truncated")

    object_ids = [
        index_data[object_id_start + index * 20 : object_id_start + (index + 1) * 20]
        for index in range(count)
    ]
    _require(
        all(object_ids[index] < object_ids[index + 1] for index in range(max(0, count - 1))),
        "Git pack index object IDs are duplicated or unsorted",
    )
    observed_fanout = [0] * 256
    for object_id in object_ids:
        observed_fanout[object_id[0]] += 1
    running = 0
    for index, value in enumerate(observed_fanout):
        running += value
        observed_fanout[index] = running
    _require(observed_fanout == fanout, "Git pack fanout does not match indexed object IDs")

    encoded_offsets = [
        _u32(index_data, offset_start + index * 4, "Git pack object offset")
        for index in range(count)
    ]
    large_slots = [offset & 0x7FFFFFFF for offset in encoded_offsets if offset & 0x80000000]
    large_count = len(large_slots)
    expected_length = ordinary_offset_end + large_count * 8 + 40
    _require(len(index_data) == expected_length, "Git pack index has trailing or missing offset data")
    _require(sorted(large_slots) == list(range(large_count)), "Git pack large-offset table is ambiguous")
    large_offsets = [
        _u64(index_data, ordinary_offset_end + index * 8, "Git pack large offset")
        for index in range(large_count)
    ]
    offsets: list[int] = []
    for encoded in encoded_offsets:
        offsets.append(large_offsets[encoded & 0x7FFFFFFF] if encoded & 0x80000000 else encoded)
    _require(len(set(offsets)) == count, "Git pack index contains duplicate object offsets")

    crc_values = [_u32(index_data, crc_start + index * 4, "Git pack CRC") for index in range(count)]
    entries = [
        {
            "ordinal": index,
            "object_id": object_ids[index],
            "offset": offsets[index],
            "crc32": crc_values[index],
        }
        for index in range(count)
    ]
    return {
        "count": count,
        "entries": entries,
        "pack_checksum": index_data[-40:-20],
        "index_checksum": index_data[-20:],
    }


def _parse_object_header(pack_data: bytes, position: int, end: int) -> tuple[int, int, int]:
    start = position
    _require(position < end, "truncated Git packed-object header")
    current = pack_data[position]
    position += 1
    object_type = (current >> 4) & 0x07
    declared_size = current & 0x0F
    shift = 4
    while current & 0x80:
        _require(position < end and shift < 64, "invalid Git packed-object size")
        current = pack_data[position]
        position += 1
        declared_size |= (current & 0x7F) << shift
        shift += 7
    _require(object_type in {1, 2, 3, 4, 6, 7}, f"unsupported Git packed-object type {object_type} at {start}")
    return object_type, declared_size, position


def _parse_ofs_delta_base(pack_data: bytes, position: int, end: int, object_offset: int) -> tuple[int, int]:
    _require(position < end, "truncated Git OFS_DELTA base")
    current = pack_data[position]
    position += 1
    distance = current & 0x7F
    while current & 0x80:
        _require(position < end and distance < (1 << 56), "invalid Git OFS_DELTA base")
        current = pack_data[position]
        position += 1
        distance = ((distance + 1) << 7) | (current & 0x7F)
    base_offset = object_offset - distance
    _require(base_offset >= 12 and base_offset < object_offset, "Git OFS_DELTA base offset is invalid")
    return base_offset, position


def _inflate_one(pack_data: bytes, position: int, end: int, declared_size: int) -> tuple[bytes, int]:
    _require(position < end, "missing Git packed-object zlib stream")
    _require(declared_size <= MAX_OBJECT_BYTES, "Git packed object exceeds the verifier resource limit")
    compressed_and_tail = pack_data[position:end]
    decoder = zlib.decompressobj()
    try:
        payload = decoder.decompress(compressed_and_tail, declared_size + 1)
        _require(len(payload) <= declared_size, "Git packed object exceeds its declared size")
        payload += decoder.flush(declared_size + 1 - len(payload))
    except zlib.error as error:
        raise VerificationError(f"invalid Git packed-object zlib stream: {error}") from error
    _require(decoder.eof, "truncated Git packed-object zlib stream")
    _require(not decoder.unconsumed_tail, "Git packed-object zlib stream was not fully consumed")
    consumed = len(compressed_and_tail) - len(decoder.unused_data)
    _require(consumed > 0, "empty Git packed-object zlib stream")
    _require(len(payload) == declared_size, "Git packed-object declared size mismatch")
    return payload, position + consumed


def _read_delta_varint(delta: bytes, position: int, label: str) -> tuple[int, int]:
    value = 0
    shift = 0
    while True:
        _require(position < len(delta) and shift < 64, f"invalid Git delta {label} size")
        current = delta[position]
        position += 1
        value |= (current & 0x7F) << shift
        if current & 0x80 == 0:
            return value, position
        shift += 7


def _apply_delta(base: bytes, delta: bytes) -> bytes:
    base_size, position = _read_delta_varint(delta, 0, "base")
    result_size, position = _read_delta_varint(delta, position, "result")
    _require(base_size == len(base), "Git delta base size mismatch")
    _require(result_size <= MAX_OBJECT_BYTES, "Git delta result exceeds the verifier resource limit")
    result = bytearray()
    while position < len(delta):
        opcode = delta[position]
        position += 1
        if opcode & 0x80:
            copy_offset = 0
            copy_size = 0
            for bit, shift in ((0x01, 0), (0x02, 8), (0x04, 16), (0x08, 24)):
                if opcode & bit:
                    _require(position < len(delta), "truncated Git delta copy offset")
                    copy_offset |= delta[position] << shift
                    position += 1
            for bit, shift in ((0x10, 0), (0x20, 8), (0x40, 16)):
                if opcode & bit:
                    _require(position < len(delta), "truncated Git delta copy size")
                    copy_size |= delta[position] << shift
                    position += 1
            if copy_size == 0:
                copy_size = 0x10000
            _require(copy_offset + copy_size <= len(base), "Git delta copy escapes base object")
            result.extend(base[copy_offset : copy_offset + copy_size])
        else:
            _require(opcode != 0, "Git delta contains reserved zero opcode")
            _require(position + opcode <= len(delta), "Git delta insert is truncated")
            result.extend(delta[position : position + opcode])
            position += opcode
        _require(len(result) <= result_size, "Git delta exceeds declared result size")
    _require(len(result) == result_size, "Git delta result size mismatch")
    return bytes(result)


def _object_id(object_type: str, payload: bytes) -> bytes:
    header = f"{object_type} {len(payload)}\0".encode("ascii")
    return _sha1(header + payload)


def _parse_pack(pack_data: bytes) -> dict[str, Any]:
    _require(len(pack_data) <= MAX_PACK_BYTES, "Git pack exceeds the verifier resource limit")
    _require(len(pack_data) >= 32, "Git pack is truncated")
    _require(pack_data[:4] == b"PACK", "invalid Git pack signature")
    version = _u32(pack_data, 4, "Git pack version")
    _require(version in {2, 3}, f"unsupported Git pack version {version}")
    count = _u32(pack_data, 8, "Git pack object count")
    _require(count <= MAX_OBJECT_COUNT, "Git pack object count exceeds the verifier resource limit")
    content_end = len(pack_data) - 20
    pack_checksum = pack_data[-20:]
    _require(_sha1(pack_data[:content_end]) == pack_checksum, "Git pack checksum mismatch")

    records: list[dict[str, Any]] = []
    total_inflated_bytes = 0
    position = 12
    for _ in range(count):
        object_offset = position
        object_type, declared_size, position = _parse_object_header(pack_data, position, content_end)
        base_offset: int | None = None
        base_object_id: bytes | None = None
        if object_type == 6:
            base_offset, position = _parse_ofs_delta_base(pack_data, position, content_end, object_offset)
        elif object_type == 7:
            _require(position + 20 <= content_end, "truncated Git REF_DELTA base")
            base_object_id = pack_data[position : position + 20]
            position += 20
        packed_payload, position = _inflate_one(pack_data, position, content_end, declared_size)
        total_inflated_bytes += len(packed_payload)
        _require(
            total_inflated_bytes <= MAX_TOTAL_INFLATED_BYTES,
            "Git pack inflated data exceeds the verifier resource limit",
        )
        records.append(
            {
                "offset": object_offset,
                "packed_type": object_type,
                "packed_payload": packed_payload,
                "base_offset": base_offset,
                "base_object_id": base_object_id,
                "end": position,
            }
        )
    _require(position == content_end, "Git pack contains trailing bytes or a mismatched object count")

    resolved_by_offset: dict[int, dict[str, Any]] = {}
    resolved_by_id: dict[bytes, dict[str, Any]] = {}
    type_names = {1: "commit", 2: "tree", 3: "blob", 4: "tag"}
    unresolved = list(records)
    while unresolved:
        progress = False
        next_unresolved: list[dict[str, Any]] = []
        for record in unresolved:
            packed_type = record["packed_type"]
            if packed_type in type_names:
                object_type = type_names[packed_type]
                payload = record["packed_payload"]
                delta_depth = 0
            else:
                base = (
                    resolved_by_offset.get(record["base_offset"])
                    if packed_type == 6
                    else resolved_by_id.get(record["base_object_id"])
                )
                if base is None:
                    next_unresolved.append(record)
                    continue
                delta_depth = int(base["delta_depth"]) + 1
                _require(delta_depth <= MAX_DELTA_DEPTH, "Git pack delta chain exceeds the verifier depth limit")
                object_type = base["object_type"]
                payload = _apply_delta(base["payload"], record["packed_payload"])
            identifier = _object_id(object_type, payload)
            _require(identifier not in resolved_by_id, "Git pack contains duplicate decoded object IDs")
            record["object_type"] = object_type
            record["payload"] = payload
            record["object_id"] = identifier
            record["delta_depth"] = delta_depth
            resolved_by_offset[record["offset"]] = record
            resolved_by_id[identifier] = record
            progress = True
        _require(progress, "Git pack contains an unresolved thin or cyclic delta base")
        unresolved = next_unresolved
    return {
        "version": version,
        "count": count,
        "checksum": pack_checksum,
        "records": records,
    }


def _verify_reverse_index(reverse_data: bytes, index: dict[str, Any], pack_checksum: bytes) -> None:
    _require(len(reverse_data) <= MAX_REVERSE_INDEX_BYTES, "Git reverse index exceeds the verifier resource limit")
    count = index["count"]
    expected_length = 12 + count * 4 + 40
    _require(len(reverse_data) == expected_length, "Git reverse index length mismatch")
    _require(reverse_data[:4] == b"RIDX", "invalid Git reverse index signature")
    _require(_u32(reverse_data, 4, "Git reverse index version") == 1, "unsupported Git reverse index version")
    _require(_u32(reverse_data, 8, "Git reverse index hash") == 1, "unsupported Git reverse index hash")
    _require(reverse_data[-40:-20] == pack_checksum, "Git reverse index pack checksum mismatch")
    _require(_sha1(reverse_data[:-20]) == reverse_data[-20:], "Git reverse index checksum mismatch")
    actual = [_u32(reverse_data, 12 + position * 4, "Git reverse index position") for position in range(count)]
    _require(sorted(actual) == list(range(count)), "Git reverse index is not a permutation")
    expected = [entry["ordinal"] for entry in sorted(index["entries"], key=lambda entry: entry["offset"])]
    _require(actual == expected, "Git reverse index does not match indexed object offsets")


def _stable_read(path: Path, maximum_bytes: int, label: str) -> tuple[bytes, tuple[int, int, int, int]]:
    _require(not path.is_symlink(), f"{label} path is a symbolic link")
    with path.open("rb") as stream:
        before = os.fstat(stream.fileno())
        _require(before.st_size <= maximum_bytes, f"{label} exceeds the verifier resource limit")
        data = stream.read(maximum_bytes + 1)
        after = os.fstat(stream.fileno())
    _require(len(data) <= maximum_bytes, f"{label} exceeds the verifier resource limit")
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    _require(
        identity == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns),
        f"{label} changed while it was read",
    )
    current = path.stat()
    _require(
        identity == (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns),
        f"{label} was replaced while it was read",
    )
    return data, identity


def verify_pack_triplet(pack_path: Path | str, index_path: Path | str, reverse_path: Path | str) -> dict[str, Any]:
    unresolved_paths = (Path(pack_path), Path(index_path), Path(reverse_path))
    _require(all(not path.is_symlink() for path in unresolved_paths), "Git pack triplet contains a symbolic link")
    pack_file, index_file, reverse_file = (path.resolve(strict=True) for path in unresolved_paths)
    _require(pack_file.suffix == ".pack" and index_file.suffix == ".idx" and reverse_file.suffix == ".rev", "Git pack triplet extensions are invalid")
    _require(pack_file.stem == index_file.stem == reverse_file.stem, "Git pack triplet names do not match")

    pack_data, pack_identity = _stable_read(pack_file, MAX_PACK_BYTES, "Git pack")
    index_data, index_identity = _stable_read(index_file, MAX_INDEX_BYTES, "Git pack index")
    reverse_data, reverse_identity = _stable_read(
        reverse_file, MAX_REVERSE_INDEX_BYTES, "Git reverse index"
    )
    for path, identity, label in (
        (pack_file, pack_identity, "Git pack"),
        (index_file, index_identity, "Git pack index"),
        (reverse_file, reverse_identity, "Git reverse index"),
    ):
        current = path.stat()
        _require(
            identity == (current.st_dev, current.st_ino, current.st_size, current.st_mtime_ns),
            f"{label} changed while the triplet was snapshotted",
        )
    pack = _parse_pack(pack_data)
    index = _parse_index(index_data)
    _require(pack["count"] == index["count"], "Git pack/index object count mismatch")
    _require(pack["checksum"] == index["pack_checksum"], "Git pack/index checksum linkage mismatch")
    expected_stem = f"pack-{pack['checksum'].hex()}"
    _require(pack_file.stem == expected_stem, "Git pack filename does not match its content identity")

    decoded_by_id = {record["object_id"]: record for record in pack["records"]}
    _require(len(decoded_by_id) == pack["count"], "Git pack decoded object count mismatch")
    for entry in index["entries"]:
        record = decoded_by_id.get(entry["object_id"])
        _require(record is not None, "Git pack index advertises an undecoded object ID")
        _require(record["offset"] == entry["offset"], "Git pack object-to-offset mapping mismatch")
        actual_crc = zlib.crc32(pack_data[record["offset"] : record["end"]]) & 0xFFFFFFFF
        _require(actual_crc == entry["crc32"], "Git pack indexed object CRC mismatch")

    _verify_reverse_index(reverse_data, index, pack["checksum"])
    object_ids = sorted(identifier.hex() for identifier in decoded_by_id)
    return {
        "schema": "stackchan.git-pack-semantics.v1",
        "packSha1": pack["checksum"].hex(),
        "objectCount": pack["count"],
        "objectIds": object_ids,
        "objectOffsetMappingVerified": True,
        "objectCrcMappingVerified": True,
        "reverseIndexMappingVerified": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pack", required=True, type=Path)
    parser.add_argument("--index", required=True, type=Path)
    parser.add_argument("--reverse-index", required=True, type=Path)
    arguments = parser.parse_args()
    try:
        result = verify_pack_triplet(arguments.pack, arguments.index, arguments.reverse_index)
    except (OSError, VerificationError) as error:
        print(json.dumps({"schema": "stackchan.git-pack-semantics.v1", "status": "rejected", "error": str(error)}, sort_keys=True), file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
