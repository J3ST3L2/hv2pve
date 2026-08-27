# hv2pve

`hv2pve` is a staged Hyper-V to Proxmox VE migration toolkit designed around low-downtime migrations.

The goal is not a one-shot VHDX copy. The project is being built around a workflow closer to backup/replication products:

1. Discover a live Hyper-V VM.
2. Create a production checkpoint and capture a consistent baseline while the source remains online.
3. Seed the destination VM into Proxmox VE.
4. Boot the destination on an isolated test network and validate it.
5. Synchronize changes from the still-live Hyper-V source.
6. At cutover, quiesce/stop the source, perform a final synchronization, and start the Proxmox VM.
7. Preserve the source VM for a defined rollback window.

## Current status

Early development. The repository currently provides the project structure, migration state model, Hyper-V discovery/baseline PowerShell tooling, and a Linux-side controller skeleton.

**RCT incremental synchronization is intentionally not marked complete yet.** Hyper-V Resilient Change Tracking/reference-point handling will be implemented and validated separately rather than pretending an AVHDX file copy is equivalent to changed-block replication.

## Repository layout

```text
hv2pve/
├── controller/            Linux migration controller
├── hyperv/                Hyper-V PowerShell module and scripts
├── config/                Example controller configuration
├── docs/                  Architecture and workflow documentation
├── schemas/               Migration-state schema
└── tests/                 Controller tests
```

## Migration lifecycle

```text
DISCOVER
   ↓
BASELINE
   ↓
SEED PROXMOX
   ↓
ISOLATED TEST BOOT
   ↓
SYNC
   ↓
SYNC
   ↓
CUTOVER
   ├── quiesce source
   ├── stop Hyper-V VM
   ├── final sync
   ├── start Proxmox VM
   └── validate
```

## Safety principles

- Never delete the source VM automatically during migration.
- Never boot the destination on the production network while the source VM is still live.
- Treat checkpoints/reference points as migration state and record their IDs.
- Refuse ambiguous disk mappings.
- Make cutover an explicit operation.
- Keep rollback possible until the operator explicitly closes the migration.

## Companion infrastructure

The generic Proxmox VM builder, Semaphore templates, appliance provisioning, and reusable Proxmox disk-expansion automation live in the `J3ST3L2/ansible` repository. This repository contains the migration application itself.

## Development phases

### Phase 1

- Hyper-V VM discovery
- Production checkpoint creation
- Baseline export metadata
- Migration state tracking
- Proxmox destination planning

### Phase 2

- Baseline transfer/import
- Isolated destination test boot
- Guest conversion and VirtIO preparation

### Phase 3

- Hyper-V RCT/reference-point changed-block synchronization
- Repeatable delta sync

### Phase 4

- Controlled cutover
- Validation gates
- Rollback workflow

## License

No license has been selected yet. The repository is private while the design is being developed.
