#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import uuid
from pathlib import Path

from state import MigrationState


def cmd_init(args: argparse.Namespace) -> int:
    migration_id = args.migration_id or str(uuid.uuid4())
    state = MigrationState(migration_id=migration_id)
    state.source = {
        "computer_name": args.hyperv_host,
        "vm_name": args.vm_name,
    }
    state.save(args.state)
    print(args.state)
    return 0


def cmd_ingest_baseline(args: argparse.Namespace) -> int:
    payload = json.loads(Path(args.input).read_text(encoding="utf-8-sig"))
    state = MigrationState.from_hyperv_baseline(payload)
    state.save(args.state)
    print(f"Imported baseline migration {state.migration_id} -> {args.state}")
    return 0


def cmd_status(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    summary = {
        "migration_id": state.migration_id,
        "phase": state.phase,
        "source_host": state.source.get("computer_name"),
        "source_vm": state.source.get("vm_name"),
        "source_vm_id": state.source.get("vm_id"),
        "checkpoint": state.baseline.get("checkpoint_name"),
        "export_root": state.baseline.get("export_root"),
        "proxmox_node": state.destination.get("proxmox_node"),
        "proxmox_vmid": state.destination.get("proxmox_vmid"),
        "tested": state.destination.get("tested", False),
        "sync_mode": state.sync.get("mode"),
        "rct_implemented": state.sync.get("rct_implemented", False),
    }
    print(json.dumps(summary, indent=2))
    return 0


def cmd_validate(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    state.validate()
    print(f"VALID: {state.migration_id} phase={state.phase}")
    return 0


def cmd_sync(args: argparse.Namespace) -> int:
    state = MigrationState.load(args.state)
    if not state.sync.get("rct_implemented", False):
        print(
            "RCT incremental synchronization is not implemented yet. "
            "Refusing to pretend a checkpoint differencing-disk copy is equivalent.",
            file=sys.stderr,
        )
        return 3
    raise NotImplementedError("RCT synchronization engine is not wired yet")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="hv2pve",
        description="Staged Hyper-V to Proxmox VE migration controller",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init", help="create a new migration state file")
    init.add_argument("--hyperv-host", required=True)
    init.add_argument("--vm-name", required=True)
    init.add_argument("--migration-id")
    init.add_argument("--state", required=True)
    init.set_defaults(func=cmd_init)

    ingest = sub.add_parser("ingest-baseline", help="import baseline JSON produced on Hyper-V")
    ingest.add_argument("--input", required=True)
    ingest.add_argument("--state", required=True)
    ingest.set_defaults(func=cmd_ingest_baseline)

    status = sub.add_parser("status", help="show migration state")
    status.add_argument("--state", required=True)
    status.set_defaults(func=cmd_status)

    validate = sub.add_parser("validate-state", help="validate migration state invariants")
    validate.add_argument("--state", required=True)
    validate.set_defaults(func=cmd_validate)

    sync = sub.add_parser("sync", help="run an incremental synchronization")
    sync.add_argument("--state", required=True)
    sync.set_defaults(func=cmd_sync)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except (ValueError, FileNotFoundError, json.JSONDecodeError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
