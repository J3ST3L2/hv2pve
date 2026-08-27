from __future__ import annotations

from typing import Any

from state import MigrationState


def seed_plan(state: MigrationState, *, storage: str, test_vnet: str) -> dict[str, Any]:
    source = state.source
    disks = source.get("disks", [])
    if not disks:
        raise ValueError("source disk inventory is empty")
    return {
        "operation": "seed",
        "migration_id": state.migration_id,
        "source": {
            "host": source.get("computer_name"),
            "vm": source.get("vm_name"),
            "generation": source.get("generation"),
        },
        "destination": {
            "storage": storage,
            "test_vnet": test_vnet,
            "must_remain_isolated": True,
        },
        "disks": [
            {
                "source_path": disk.get("Path") or disk.get("path"),
                "virtual_size": disk.get("VirtualSizeBytes") or disk.get("virtual_size_bytes"),
                "controller": disk.get("ControllerType") or disk.get("controller_type"),
                "location": disk.get("ControllerLocation") or disk.get("controller_location"),
            }
            for disk in disks
        ],
    }


def cutover_plan(state: MigrationState) -> dict[str, Any]:
    return {
        "operation": "cutover",
        "migration_id": state.migration_id,
        "preconditions": [
            "isolated destination test passed",
            "latest online sync verified",
            "destination powered off",
            "explicit operator authorization",
        ],
        "steps": [
            "quiesce applications if required",
            "stop source Hyper-V VM",
            "verify source is off",
            "create final recovery snapshot/reference point",
            "export/apply final RCT delta",
            "verify destination disks",
            "attach destination NIC to production VNet",
            "start destination VM",
            "validate network, guest boot, and applications",
            "leave source VM powered off for rollback window",
        ],
        "rollback_warning": (
            "Once the destination accepts writes, rollback to the source discards or requires "
            "reconciliation of those destination-side writes."
        ),
    }
