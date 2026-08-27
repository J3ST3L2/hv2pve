#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

CHUNK = 4 * 1024 * 1024


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--metadata", required=True)
    ap.add_argument("--payload", required=True)
    ap.add_argument("--target", required=True)
    args = ap.parse_args()

    meta = json.loads(Path(args.metadata).read_text(encoding="utf-8"))
    payload = Path(args.payload)
    if int(meta.get("format_version", 0)) != 1:
        raise SystemExit("unsupported delta bundle format")
    if sha256_file(payload) != str(meta["payload_sha256"]).lower():
        raise SystemExit("payload checksum mismatch")

    ranges = sorted(meta["ranges"], key=lambda x: int(x["offset"]))
    previous_end = 0
    fd = os.open(args.target, os.O_RDWR)
    written = 0
    try:
        with payload.open("rb") as src:
            for i, entry in enumerate(ranges):
                offset = int(entry["offset"])
                length = int(entry["length"])
                if length <= 0 or (i and offset < previous_end):
                    raise SystemExit("invalid or overlapping changed ranges")
                if offset + length > int(meta["virtual_size"]):
                    raise SystemExit("changed range exceeds virtual size")
                src.seek(int(entry["payload_offset"]))
                h = hashlib.sha256()
                remaining = length
                dest = offset
                while remaining:
                    block = src.read(min(CHUNK, remaining))
                    if not block:
                        raise SystemExit("payload ended early")
                    os.pwrite(fd, block, dest)
                    h.update(block)
                    remaining -= len(block)
                    dest += len(block)
                    written += len(block)
                if h.hexdigest() != str(entry["sha256"]).lower():
                    raise SystemExit(f"range checksum mismatch at {offset}")
                previous_end = offset + length
        os.fsync(fd)
    finally:
        os.close(fd)

    print(json.dumps({"bytes_written": written, "ranges": len(ranges), "target": args.target}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
