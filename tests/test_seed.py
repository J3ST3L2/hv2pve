from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "controller"))

from seed import resolve_exported_disks
from state import MigrationState


class SeedMappingTests(unittest.TestCase):
    def test_exact_basename_mapping(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "Virtual Hard Disks").mkdir()
            disk = root / "Virtual Hard Disks" / "vm01.vhdx"
            disk.write_bytes(b"")
            state = MigrationState("m")
            state.phase = "BASELINE_READY"
            state.source = {"disks": [{"Path": r"D:\VMs\vm01.vhdx", "VirtualSizeBytes": 123}]}
            state.baseline = {"export_root": str(root)}
            result = resolve_exported_disks(state)
            self.assertEqual(result[0].exported_path, disk)

    def test_ambiguous_mapping_refused(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "a").mkdir(); (root / "b").mkdir()
            (root / "a" / "vm.vhdx").write_bytes(b"")
            (root / "b" / "vm.vhdx").write_bytes(b"")
            state = MigrationState("m")
            state.phase = "BASELINE_READY"
            state.source = {"disks": [{"Path": r"D:\vm.vhdx"}]}
            state.baseline = {"export_root": str(root)}
            with self.assertRaises(ValueError):
                resolve_exported_disks(state)


if __name__ == "__main__":
    unittest.main()
