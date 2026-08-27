from __future__ import annotations

import json
import tempfile
import unittest
from io import BytesIO
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "controller"))

from delta import ChangedRange, apply_delta_bundle, build_bundle_from_raw, validate_ranges


class DeltaTests(unittest.TestCase):
    def test_round_trip(self) -> None:
        original = bytearray(b"A" * 4096)
        source_data = bytearray(original)
        source_data[100:110] = b"0123456789"
        source_data[2048:2056] = b"DEADBEEF"

        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            target = td / "target.raw"
            payload = td / "delta.bin"
            meta = td / "delta.json"
            target.write_bytes(original)
            build_bundle_from_raw(
                BytesIO(source_data),
                [ChangedRange(100, 10), ChangedRange(2048, 8)],
                payload,
                meta,
                migration_id="m1",
                disk_id="disk0",
                virtual_size=len(source_data),
                sequence=1,
                reference_from="r0",
                reference_to="r1",
            )
            result = apply_delta_bundle(meta, payload, target)
            self.assertEqual(result["bytes_written"], 18)
            data = target.read_bytes()
            self.assertEqual(data[100:110], b"0123456789")
            self.assertEqual(data[2048:2056], b"DEADBEEF")

    def test_overlap_refused(self) -> None:
        with self.assertRaises(ValueError):
            validate_ranges([ChangedRange(0, 100), ChangedRange(50, 10)], 1000)

    def test_out_of_bounds_refused(self) -> None:
        with self.assertRaises(ValueError):
            validate_ranges([ChangedRange(900, 101)], 1000)

    def test_payload_checksum_refused(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            td = Path(td)
            target = td / "target.raw"
            payload = td / "delta.bin"
            meta = td / "delta.json"
            target.write_bytes(b"\0" * 1024)
            build_bundle_from_raw(
                BytesIO(b"X" * 1024), [ChangedRange(0, 16)], payload, meta,
                migration_id="m", disk_id="d", virtual_size=1024,
                sequence=1, reference_from="a", reference_to="b",
            )
            payload.write_bytes(b"corrupt")
            with self.assertRaises(ValueError):
                apply_delta_bundle(meta, payload, target)


if __name__ == "__main__":
    unittest.main()
