from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO, Iterable

CHUNK_SIZE = 4 * 1024 * 1024


@dataclass(frozen=True)
class ChangedRange:
    offset: int
    length: int

    def validate(self) -> None:
        if self.offset < 0:
            raise ValueError("range offset cannot be negative")
        if self.length <= 0:
            raise ValueError("range length must be positive")


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(CHUNK_SIZE), b""):
            h.update(chunk)
    return h.hexdigest()


def validate_ranges(ranges: Iterable[ChangedRange], virtual_size: int | None = None) -> list[ChangedRange]:
    ordered = sorted(ranges, key=lambda r: r.offset)
    previous_end = 0
    for i, item in enumerate(ordered):
        item.validate()
        if i and item.offset < previous_end:
            raise ValueError("changed ranges overlap")
        end = item.offset + item.length
        if virtual_size is not None and end > virtual_size:
            raise ValueError("changed range extends beyond virtual disk size")
        previous_end = end
    return ordered


def apply_delta_bundle(
    metadata_path: str | Path,
    payload_path: str | Path,
    target_path: str | Path,
    *,
    fsync: bool = True,
) -> dict:
    metadata_file = Path(metadata_path)
    payload_file = Path(payload_path)
    target = Path(target_path)
    meta = json.loads(metadata_file.read_text(encoding="utf-8"))

    if int(meta.get("format_version", 0)) != 1:
        raise ValueError("unsupported delta bundle format")

    expected_payload_hash = meta.get("payload_sha256")
    if expected_payload_hash:
        actual = _sha256_file(payload_file)
        if actual.lower() != expected_payload_hash.lower():
            raise ValueError("delta payload SHA-256 mismatch")

    ranges = [ChangedRange(int(x["offset"]), int(x["length"])) for x in meta["ranges"]]
    ranges = validate_ranges(ranges, int(meta.get("virtual_size", 0)) or None)

    flags = os.O_RDWR
    fd = os.open(target, flags)
    total_written = 0
    try:
        with payload_file.open("rb") as payload:
            for item, entry in zip(ranges, meta["ranges"], strict=True):
                payload_offset = int(entry["payload_offset"])
                payload.seek(payload_offset)
                remaining = item.length
                dest = item.offset
                range_hash = hashlib.sha256()
                while remaining:
                    block = payload.read(min(CHUNK_SIZE, remaining))
                    if not block:
                        raise ValueError("delta payload ended before range data completed")
                    os.pwrite(fd, block, dest)
                    range_hash.update(block)
                    dest += len(block)
                    remaining -= len(block)
                    total_written += len(block)
                expected = entry.get("sha256")
                if expected and range_hash.hexdigest().lower() != expected.lower():
                    raise ValueError(f"range checksum mismatch at offset {item.offset}")
        if fsync:
            os.fsync(fd)
    finally:
        os.close(fd)

    return {
        "target": str(target),
        "ranges": len(ranges),
        "bytes_written": total_written,
        "sequence": meta.get("sequence"),
        "reference_from": meta.get("reference_from"),
        "reference_to": meta.get("reference_to"),
    }


def build_bundle_from_raw(
    source: BinaryIO,
    ranges: Iterable[ChangedRange],
    payload_path: str | Path,
    metadata_path: str | Path,
    *,
    migration_id: str,
    disk_id: str,
    virtual_size: int,
    sequence: int,
    reference_from: str,
    reference_to: str,
) -> dict:
    ordered = validate_ranges(ranges, virtual_size)
    payload_file = Path(payload_path)
    payload_file.parent.mkdir(parents=True, exist_ok=True)
    entries: list[dict] = []
    payload_offset = 0
    payload_hash = hashlib.sha256()

    with payload_file.open("wb") as out:
        for item in ordered:
            source.seek(item.offset)
            remaining = item.length
            range_hash = hashlib.sha256()
            start = payload_offset
            while remaining:
                data = source.read(min(CHUNK_SIZE, remaining))
                if not data:
                    raise ValueError("source ended before requested changed range")
                out.write(data)
                range_hash.update(data)
                payload_hash.update(data)
                remaining -= len(data)
                payload_offset += len(data)
            entries.append(
                {
                    "offset": item.offset,
                    "length": item.length,
                    "payload_offset": start,
                    "sha256": range_hash.hexdigest(),
                }
            )

    meta = {
        "format_version": 1,
        "migration_id": migration_id,
        "disk_id": disk_id,
        "virtual_size": virtual_size,
        "sequence": sequence,
        "reference_from": reference_from,
        "reference_to": reference_to,
        "ranges": entries,
        "payload_size": payload_offset,
        "payload_sha256": payload_hash.hexdigest(),
    }
    Path(metadata_path).write_text(json.dumps(meta, indent=2) + "\n", encoding="utf-8")
    return meta
