import tempfile
import unittest
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "controller"))

from state import MigrationState  # noqa: E402


class MigrationStateTests(unittest.TestCase):
    def test_round_trip(self):
        state = MigrationState(migration_id="test-1")
        state.source = {"vm_name": "demo", "computer_name": "hyperv01"}

        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "state.json"
            state.save(path)
            loaded = MigrationState.load(path)

        self.assertEqual(loaded.migration_id, "test-1")
        self.assertEqual(loaded.source["vm_name"], "demo")
        self.assertEqual(loaded.phase, "NEW")

    def test_invalid_phase_rejected(self):
        state = MigrationState(migration_id="test-2", phase="WISHFUL_THINKING")
        with self.assertRaises(ValueError):
            state.validate()

    def test_seeded_requires_destination_vmid(self):
        state = MigrationState(migration_id="test-3", phase="SEEDED")
        with self.assertRaises(ValueError):
            state.validate()

    def test_tested_phase_requires_test_flag(self):
        state = MigrationState(
            migration_id="test-4",
            phase="TESTED",
            destination={"proxmox_vmid": 104, "tested": False},
        )
        with self.assertRaises(ValueError):
            state.validate()

    def test_valid_tested_state(self):
        state = MigrationState(
            migration_id="test-5",
            phase="TESTED",
            destination={"proxmox_vmid": 104, "tested": True},
        )
        state.validate()


if __name__ == "__main__":
    unittest.main()
