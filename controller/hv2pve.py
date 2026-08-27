#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path

from delta import apply_delta_bundle
from plan import cutover_plan, seed_plan
from proxmox import ProxmoxSSH
from safety import SafetyError, require_cutover_ready, require_isolated_test
from seed import seed_destination
from state import MigrationState, utc_now


def _write_json(value: object) -> None:
    print(json.dumps(value, indent=2, sort_keys=True))


def _pve(args: argparse.Namespace) -> ProxmoxSSH:
    return ProxmoxSSH(
        host=args.pve_host,
        user=getattr(args, "pve_user", "root"),
        identity_file=getattr(args, "identity_file", None),
    )


def cmd_init(args: argparse.Namespace) -> int:
    migration_id = args.migration_id or str(uuid.uuid4())
    state = MigrationState(migration_id=migration_id)
    state.source = {"computer_name": args.hyperv_host, "vm_name": args.vm_name}
    state.record_event("migration_created", hyperv_host=args.hyperv_host, vm_name=args.vm_name)
    state.save(args.state)
    print(args.state)
    return 0


def cmd_ingest_baseline(args: argparse.Namespace) -> int:
    payload = json.loads(Path(args.input).read_text(encoding="utf-8-sig"))
    state = MigrationState.from_hyperv_baseline(payload)
    state.record_event("baseline_ingested", input=str(args.input))
    state.save(args.state)
    print(f"Imported baseline migration {state.migration_id} -> {args.state}")
    return 0


def cmd_ingest_sync(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    payload = json.loads(Path(args.input).read_text(encoding="utf-8-sig"))
    migration_id = payload.get("migration_id") or payload.get("MigrationId")
    if migration_id and migration_id != state.migration_id:
        raise ValueError("sync metadata migration_id does not match state")
    sequence = int(payload.get("sequence") or payload.get("Sequence") or 0)
    if sequence <= int(state.sync.get("sequence") or 0):
        raise ValueError("pending sync sequence must be newer than authoritative sequence")
    nested_new = payload.get("new_reference_point") or payload.get("NewReferencePoint") or {}
    new_ref = (
        payload.get("new_reference_point_instance_id")
        or payload.get("NewReferencePointInstanceID")
        or payload.get("reference_to")
        or nested_new.get("InstanceID")
        or nested_new.get("instance_id")
    )
    if not new_ref:
        raise ValueError("sync metadata does not contain a new reference point")
    state.sync["pending_reference_point"] = new_ref
    state.sync["pending_sequence"] = sequence
    state.sync["pending_bundle"] = str(args.input)
    state.validation["last_sync_verified"] = False
    state.record_event("sync_pending", sequence=sequence, reference_point=new_ref, input=str(args.input))
    state.save(args.state)
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    _write_json(
        {
            "migration_id": state.migration_id,
            "phase": state.phase,
            "source_host": state.source.get("computer_name"),
            "source_vm": state.source.get("vm_name"),
            "source_state": state.source.get("state"),
            "reference_point": state.sync.get("authoritative_reference_point"),
            "pending_reference_point": state.sync.get("pending_reference_point"),
            "sync_sequence": state.sync.get("sequence"),
            "last_successful_sync_utc": state.sync.get("last_successful_sync_utc"),
            "proxmox_node": state.destination.get("proxmox_node"),
            "proxmox_vmid": state.destination.get("proxmox_vmid"),
            "tested": state.destination.get("tested", False),
            "powered_on": state.destination.get("powered_on", False),
            "production_vnet": state.destination.get("production_vnet"),
            "test_vnet": state.destination.get("test_vnet"),
            "cutover_authorized": state.cutover.get("authorized"),
            "source_stopped_at_utc": state.cutover.get("source_stopped_at_utc"),
            "final_sync_completed_at_utc": state.cutover.get("final_sync_completed_at_utc"),
        }
    )
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    state.validate()
    print(f"VALID: {state.migration_id} phase={state.phase}")
    return 0


def cmd_seed_plan(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    _write_json(seed_plan(state, storage=args.storage, test_vnet=args.test_vnet))
    return 0


def cmd_seed(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase != "BASELINE_READY":
        raise SafetyError(f"seed requires BASELINE_READY, current phase={state.phase}")
    result = seed_destination(
        state,
        pve=_pve(args),
        storage=args.storage,
        test_vnet=args.test_vnet,
        production_vnet=args.production_vnet,
        export_root=args.export_root,
        vmid=args.vmid,
        guest_os=args.guest_os,
        cleanup_on_failure=not args.keep_failed_vm,
    )
    state.destination.update(result)
    state.destination["powered_on"] = False
    state.validation["baseline_verified"] = True
    state.set_phase("SEEDED", reason="baseline imported into Proxmox")
    state.record_event("destination_seeded", **result)
    state.save(args.state)
    _write_json(result)
    return 0


def cmd_mark_seeded(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    state.destination.update(
        {
            "proxmox_node": args.node,
            "proxmox_vmid": args.vmid,
            "test_vnet": args.test_vnet,
            "production_vnet": args.production_vnet,
            "powered_on": False,
        }
    )
    state.validation["baseline_verified"] = bool(args.baseline_verified)
    state.set_phase("SEEDED", reason="Proxmox destination seeded")
    state.save(args.state)
    return 0


def cmd_test_start(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase not in {"SEEDED", "TESTED", "SYNCING", "CUTOVER_READY"}:
        raise SafetyError(f"isolated test boot is not allowed from phase {state.phase}")
    prod = state.destination.get("production_vnet")
    test = state.destination.get("test_vnet")
    if not test or test == prod:
        raise SafetyError("test VNet is missing or equals production VNet")
    vmid = int(state.destination["proxmox_vmid"])
    pve = _pve(args)
    cfg = pve.config(vmid)
    net0 = cfg.get("net0")
    if not net0:
        raise SafetyError("destination net0 is missing")
    pve.set_network(vmid, "net0", pve.with_bridge(net0, test))
    pve.start(vmid)
    state.destination["powered_on"] = True
    state.record_event("isolated_test_started", vmid=vmid, test_vnet=test)
    state.save(args.state)
    return 0


def cmd_test_stop(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    pve = _pve(args)
    vmid = int(state.destination["proxmox_vmid"])
    pve.stop(vmid, timeout=args.timeout)
    state.destination["powered_on"] = False
    state.record_event("isolated_test_stopped", vmid=vmid)
    state.save(args.state)
    return 0


def cmd_mark_tested(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.destination.get("powered_on"):
        raise SafetyError("stop the isolated destination before marking the test complete")
    if not args.guest_boot_verified:
        raise SafetyError("--guest-boot-verified is required")
    state.destination["tested"] = True
    state.validation["isolated_boot_verified"] = True
    state.validation["guest_boot_verified"] = True
    state.validation["application_verified"] = bool(args.application_verified)
    state.set_phase("TESTED", reason="isolated test boot verified")
    state.save(args.state)
    return 0


def cmd_apply_delta(args: argparse.Namespace) -> int:
    result = apply_delta_bundle(args.metadata, args.payload, args.target)
    _write_json(result)
    return 0


def cmd_apply_proxmox_delta(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.destination.get("powered_on"):
        raise SafetyError("destination must be stopped before applying a delta")
    disk_map = state.destination.get("disk_map") or {}
    entry = disk_map.get(str(args.disk_index))
    if not entry:
        raise ValueError(f"destination disk index {args.disk_index} is not recorded")
    volume = entry.get("volume")
    if not volume:
        raise ValueError("destination disk volume is missing")
    remote_script = Path(__file__).with_name("remote_apply_delta.py")
    output = _pve(args).apply_delta_to_volume(
        vmid=int(state.destination["proxmox_vmid"]),
        volume=volume,
        metadata_path=args.metadata,
        payload_path=args.payload,
        remote_script_path=remote_script,
    )
    state.record_event(
        "delta_applied",
        disk_index=args.disk_index,
        volume=volume,
        metadata=str(args.metadata),
        payload=str(args.payload),
    )
    state.save(args.state)
    print(output.strip())
    return 0


def cmd_register_sync(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    current = int(state.sync.get("sequence") or 0)
    if args.sequence <= current:
        raise ValueError(f"sync sequence must increase, current={current}")
    pending = state.sync.get("pending_reference_point")
    if pending and pending != args.reference_point:
        raise ValueError("reference point does not match pending synchronization")
    if not args.verified:
        raise SafetyError("a synchronization cannot become authoritative without --verified")
    state.sync["sequence"] = int(args.sequence)
    state.sync["authoritative_reference_point"] = args.reference_point
    state.sync["pending_reference_point"] = None
    state.sync.pop("pending_sequence", None)
    state.sync.pop("pending_bundle", None)
    state.sync["last_successful_sync_utc"] = utc_now()
    state.sync["last_bundle"] = args.bundle
    state.validation["last_sync_verified"] = True
    state.set_phase("SYNCING", reason=f"sync sequence {args.sequence} registered")
    state.record_event("sync_committed", sequence=args.sequence, reference_point=args.reference_point)
    if args.cutover_ready:
        state.set_phase("CUTOVER_READY", reason="latest sync verified and selected for cutover")
    state.save(args.state)
    return 0


def cmd_cutover_plan(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    require_cutover_ready(state)
    _write_json(cutover_plan(state))
    return 0


def cmd_authorize_cutover(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    require_cutover_ready(state)
    if args.confirm != state.source.get("vm_name"):
        raise SafetyError("--confirm must exactly match the source VM name")
    state.cutover["authorized"] = True
    state.cutover["authorized_at_utc"] = utc_now()
    state.record_event("cutover_authorized", source_vm=state.source.get("vm_name"))
    state.set_phase("CUTOVER_IN_PROGRESS", reason="operator authorized cutover")
    state.save(args.state)
    return 0


def cmd_mark_source_stopped(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase != "CUTOVER_IN_PROGRESS" or not state.cutover.get("authorized"):
        raise SafetyError("source stop can only be recorded during an authorized cutover")
    if args.confirm != state.source.get("vm_name"):
        raise SafetyError("--confirm must exactly match source VM name")
    state.cutover["source_stopped_at_utc"] = utc_now()
    state.source["state"] = "Off"
    state.record_event("source_stopped_for_cutover")
    state.save(args.state)
    return 0


def cmd_mark_final_sync(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if not state.cutover.get("source_stopped_at_utc"):
        raise SafetyError("final sync cannot be committed until the source is recorded stopped")
    if not args.verified:
        raise SafetyError("--verified is required for final sync")
    state.cutover["final_sync_completed_at_utc"] = utc_now()
    state.validation["last_sync_verified"] = True
    state.record_event("final_sync_verified")
    state.save(args.state)
    return 0


def cmd_activate_production(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase != "CUTOVER_IN_PROGRESS":
        raise SafetyError("production activation requires CUTOVER_IN_PROGRESS")
    if not state.cutover.get("source_stopped_at_utc"):
        raise SafetyError("source has not been recorded stopped")
    if not state.cutover.get("final_sync_completed_at_utc"):
        raise SafetyError("final synchronization has not been verified")
    pve = _pve(args)
    vmid = int(state.destination["proxmox_vmid"])
    pve.require_stopped(vmid)
    prod = state.destination.get("production_vnet")
    test = state.destination.get("test_vnet")
    if not prod or prod == test:
        raise SafetyError("production VNet is missing or not distinct from test VNet")
    cfg = pve.config(vmid)
    net0 = cfg.get("net0")
    if not net0:
        raise SafetyError("destination net0 is missing")
    pve.set_network(vmid, "net0", pve.with_bridge(net0, prod))
    pve.start(vmid)
    state.destination["powered_on"] = True
    state.cutover["destination_started_at_utc"] = utc_now()
    state.cutover["destination_writes_possible"] = True
    state.record_event("production_destination_started", vmid=vmid, production_vnet=prod)
    state.save(args.state)
    return 0


def cmd_mark_cutover_complete(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if not state.cutover.get("authorized"):
        raise SafetyError("cutover was not authorized")
    if not state.destination.get("powered_on"):
        raise SafetyError("destination is not recorded running")
    if not (args.network_verified and args.guest_verified and args.application_verified):
        raise SafetyError("all three validation flags are required to complete cutover")
    state.validation["network_identity_verified"] = True
    state.validation["guest_boot_verified"] = True
    state.validation["application_verified"] = True
    state.set_phase("CUTOVER_COMPLETE", reason="production destination validation passed")
    state.record_event("cutover_complete")
    state.save(args.state)
    return 0


def cmd_rollback_plan(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase not in {"CUTOVER_IN_PROGRESS", "CUTOVER_COMPLETE"}:
        raise SafetyError("rollback is only meaningful during/after cutover")
    _write_json(
        {
            "operation": "rollback",
            "migration_id": state.migration_id,
            "warning": (
                "Destination writes may be lost or require reconciliation. Stop and isolate the "
                "Proxmox VM before restarting the Hyper-V source."
            ),
            "destination_writes_possible": state.cutover.get("destination_writes_possible"),
            "steps": [
                "stop Proxmox destination",
                "move destination NIC back to isolated test VNet",
                "verify destination is stopped",
                "restart Hyper-V source",
                "validate source services and production identity",
                "record rollback complete",
            ],
        }
    )
    return 0


def cmd_begin_rollback(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase not in {"CUTOVER_IN_PROGRESS", "CUTOVER_COMPLETE"}:
        raise SafetyError("rollback can only begin during/after cutover")
    if args.confirm != state.source.get("vm_name"):
        raise SafetyError("--confirm must exactly match source VM name")
    pve = _pve(args)
    vmid = int(state.destination["proxmox_vmid"])
    pve.stop(vmid, timeout=args.timeout)
    cfg = pve.config(vmid)
    net0 = cfg.get("net0")
    test = state.destination.get("test_vnet")
    if net0 and test:
        pve.set_network(vmid, "net0", pve.with_bridge(net0, test))
    state.destination["powered_on"] = False
    state.set_phase("ROLLBACK_IN_PROGRESS", reason="destination stopped and isolated")
    state.record_event("rollback_started", destination_writes_possible=state.cutover.get("destination_writes_possible"))
    state.save(args.state)
    return 0


def cmd_mark_rolled_back(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase != "ROLLBACK_IN_PROGRESS":
        raise SafetyError("rollback is not in progress")
    if args.confirm != state.source.get("vm_name"):
        raise SafetyError("--confirm must exactly match source VM name")
    state.source["state"] = "Running"
    state.set_phase("ROLLED_BACK", reason="operator confirmed Hyper-V source restored")
    state.record_event("rollback_complete")
    state.save(args.state)
    return 0


def cmd_close(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if state.phase not in {"CUTOVER_COMPLETE", "ROLLED_BACK", "FAILED"}:
        raise SafetyError(f"cannot close migration from phase {state.phase}")
    if args.confirm != state.source.get("vm_name"):
        raise SafetyError("--confirm must exactly match source VM name")
    state.set_phase("CLOSED", reason="operator closed migration")
    state.record_event("migration_closed")
    state.save(args.state)
    return 0


def add_pve_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("--pve-host", required=True)
    p.add_argument("--pve-user", default="root")
    p.add_argument("--identity-file")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hv2pve", description="Staged Hyper-V to Proxmox VE migration controller"
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init")
    p.add_argument("--hyperv-host", required=True)
    p.add_argument("--vm-name", required=True)
    p.add_argument("--migration-id")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("ingest-baseline")
    p.add_argument("--input", required=True)
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_ingest_baseline)

    p = sub.add_parser("ingest-sync")
    p.add_argument("--input", required=True)
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_ingest_sync)

    p = sub.add_parser("status")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("validate-state")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_validate)

    p = sub.add_parser("seed-plan")
    p.add_argument("--state", required=True)
    p.add_argument("--storage", required=True)
    p.add_argument("--test-vnet", required=True)
    p.set_defaults(func=cmd_seed_plan)

    p = sub.add_parser("seed")
    p.add_argument("--state", required=True)
    p.add_argument("--storage", required=True)
    p.add_argument("--test-vnet", required=True)
    p.add_argument("--production-vnet", required=True)
    p.add_argument("--export-root")
    p.add_argument("--vmid", type=int)
    p.add_argument("--guest-os", choices=["auto", "windows", "linux", "unknown"], default="auto")
    p.add_argument("--keep-failed-vm", action="store_true")
    add_pve_args(p)
    p.set_defaults(func=cmd_seed)

    p = sub.add_parser("mark-seeded")
    p.add_argument("--state", required=True)
    p.add_argument("--node", required=True)
    p.add_argument("--vmid", required=True, type=int)
    p.add_argument("--test-vnet", required=True)
    p.add_argument("--production-vnet", required=True)
    p.add_argument("--baseline-verified", action="store_true")
    p.set_defaults(func=cmd_mark_seeded)

    p = sub.add_parser("test-start")
    p.add_argument("--state", required=True)
    add_pve_args(p)
    p.set_defaults(func=cmd_test_start)

    p = sub.add_parser("test-stop")
    p.add_argument("--state", required=True)
    p.add_argument("--timeout", type=int, default=120)
    add_pve_args(p)
    p.set_defaults(func=cmd_test_stop)

    p = sub.add_parser("mark-tested")
    p.add_argument("--state", required=True)
    p.add_argument("--guest-boot-verified", action="store_true")
    p.add_argument("--application-verified", action="store_true")
    p.set_defaults(func=cmd_mark_tested)

    p = sub.add_parser("apply-delta")
    p.add_argument("--metadata", required=True)
    p.add_argument("--payload", required=True)
    p.add_argument("--target", required=True)
    p.set_defaults(func=cmd_apply_delta)

    p = sub.add_parser("apply-proxmox-delta")
    p.add_argument("--state", required=True)
    p.add_argument("--disk-index", required=True, type=int)
    p.add_argument("--metadata", required=True)
    p.add_argument("--payload", required=True)
    add_pve_args(p)
    p.set_defaults(func=cmd_apply_proxmox_delta)

    p = sub.add_parser("register-sync")
    p.add_argument("--state", required=True)
    p.add_argument("--sequence", required=True, type=int)
    p.add_argument("--reference-point", required=True)
    p.add_argument("--bundle")
    p.add_argument("--verified", action="store_true")
    p.add_argument("--cutover-ready", action="store_true")
    p.set_defaults(func=cmd_register_sync)

    p = sub.add_parser("cutover-plan")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_cutover_plan)

    p = sub.add_parser("authorize-cutover")
    p.add_argument("--state", required=True)
    p.add_argument("--confirm", required=True)
    p.set_defaults(func=cmd_authorize_cutover)

    p = sub.add_parser("mark-source-stopped")
    p.add_argument("--state", required=True)
    p.add_argument("--confirm", required=True)
    p.set_defaults(func=cmd_mark_source_stopped)

    p = sub.add_parser("mark-final-sync")
    p.add_argument("--state", required=True)
    p.add_argument("--verified", action="store_true")
    p.set_defaults(func=cmd_mark_final_sync)

    p = sub.add_parser("activate-production")
    p.add_argument("--state", required=True)
    add_pve_args(p)
    p.set_defaults(func=cmd_activate_production)

    p = sub.add_parser("mark-cutover-complete")
    p.add_argument("--state", required=True)
    p.add_argument("--network-verified", action="store_true")
    p.add_argument("--guest-verified", action="store_true")
    p.add_argument("--application-verified", action="store_true")
    p.set_defaults(func=cmd_mark_cutover_complete)

    p = sub.add_parser("rollback-plan")
    p.add_argument("--state", required=True)
    p.set_defaults(func=cmd_rollback_plan)

    p = sub.add_parser("begin-rollback")
    p.add_argument("--state", required=True)
    p.add_argument("--confirm", required=True)
    p.add_argument("--timeout", type=int, default=120)
    add_pve_args(p)
    p.set_defaults(func=cmd_begin_rollback)

    p = sub.add_parser("mark-rolled-back")
    p.add_argument("--state", required=True)
    p.add_argument("--confirm", required=True)
    p.set_defaults(func=cmd_mark_rolled_back)

    p = sub.add_parser("close")
    p.add_argument("--state", required=True)
    p.add_argument("--confirm", required=True)
    p.set_defaults(func=cmd_close)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        return int(args.func(args))
    except (ValueError, FileNotFoundError, json.JSONDecodeError, SafetyError, RuntimeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
