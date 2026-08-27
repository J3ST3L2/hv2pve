from __future__ import annotations

import unittest
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "controller"))

from proxmox import ProxmoxSSH


class ProxmoxTests(unittest.TestCase):
    def test_bridge_replacement_preserves_other_options(self) -> None:
        value = "e1000=AA:BB:CC:DD:EE:FF,bridge=hv2pve-test,firewall=1"
        updated = ProxmoxSSH.with_bridge(value, "vlan60")
        self.assertIn("bridge=vlan60", updated)
        self.assertNotIn("bridge=hv2pve-test", updated)
        self.assertIn("firewall=1", updated)
        self.assertIn("AA:BB:CC:DD:EE:FF", updated)


if __name__ == "__main__":
    unittest.main()
