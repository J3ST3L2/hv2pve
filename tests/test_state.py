from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "controller"))

from state import MigrationState


class MigrationStateTests(unittest.TestCase):
    def test_atomic_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "state.json"
            state = MigrationState("m1")
            state.source = {"computer_name": "hv01", "vm_name": "vm01"}
            state.save(path)
            loaded = MigrationState.load(path)
            self.assertEqual(loaded.migration_id, "m1")
            self.assertEqual(loaded.source["vm_name"], "vm01")
            json.loads(path.read_text())

    def test_illegal_transition_refused(self) -> None:
        state = MigrationState("m1")
        with self.assertRaises(ValueError):
            state.set_phase("CUTOVER_COMPLETE")

    def test_production_and_test_vnet_cannot_match(self) -> None:
        state = MigrationState("m1")
        state.destination["production_vnet"] = "vlan60"
        state.destination["test_vnet"] = "vlan60"
        with self.assertRaises(ValueError):
            state.validate()

    def test_tested_requires_validation_flag(self) -> None:
        state = MigrationState("m1")
        state.destination["proxmox_vmid"] = 101
        state.destination["tested"] = True
        state.phase = "TESTED"
        with self.assertRaises(ValueError):
            state.validate()

    def test_v1_payload_is_normalized(self) -> None:
        state = MigrationState.from_dict({
            "schema_version": 1,
            "migration_id": "old",
            "phase": "BASELINE_READY",
            "source": {"vm_name": "oldvm"},
            "baseline": {},
            "destination": {},
            "sync": {"mode": "baseline-only", "rct_implemented": False},
        })
        self.assertEqual(state.schema_version, 2)
        self.assertIn("cutover", state.to_dict())
        self.assertIn("disk_map", state.destination)


if __name__ == "__main__":
    unittest.main()
