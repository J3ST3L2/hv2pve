# Architecture

## Components

### Hyper-V source component

Runs locally and elevated on the Hyper-V host. It owns operations that require local Hyper-V/WMI/Virtual Disk API access:

- VM discovery
- RCT reference point creation
- reference point export
- change-range discovery
- read-only virtual disk attachment
- logical-range bundle generation
- graceful source shutdown
- old reference point cleanup only after destination commit

### hv2pve controller appliance

Runs on Linux, currently `hv2pve01` in the lab. It owns:

- durable migration state
- transfer/staging
- baseline seed
- Proxmox VM construction
- isolated test orchestration
- delta bundle verification/application
- cutover safety gates
- production network activation
- rollback isolation

### Proxmox VE

The destination hypervisor stores the staged VM. A destination stays powered off except during an explicitly isolated test or after production cutover.

## State machine

```text
NEW
 |
 v
DISCOVERED
 |
 v
BASELINE_READY
 |
 v
SEEDED
 |
 v
TESTED
 |
 +----> SYNCING ----+
 |                  |
 +<-----------------+
 |
 v
CUTOVER_READY
 |
 v
CUTOVER_IN_PROGRESS
 |              |
 v              v
CUTOVER_COMPLETE   ROLLBACK_IN_PROGRESS
 |                      |
 v                      v
CLOSED                ROLLED_BACK -> CLOSED
```

Illegal phase jumps are rejected by `controller/state.py`.

## Data paths

### Baseline

The correctness-first baseline uses Hyper-V RCT reference point export. The export is transferred to the controller, then seeded into Proxmox.

### Incremental WMI export

A new RCT reference point is created with an existing authoritative reference point as the base. `ExportReferencePoint` is asked to export the new point relative to that base. The old base is retained until the destination has verified the new state.

### Native RCT acceleration

The Win32 `QueryChangesVirtualDisk` path is designed to avoid large WMI exports:

1. Seal/identify a stable Hyper-V reference point.
2. Query logical ranges changed since the previous RCT ID.
3. Attach the frozen VHD/VHDX read-only.
4. Read the changed ranges from the attached logical disk device.
5. Hash and package each range.
6. Transfer bundle metadata + payload.
7. Stop the destination.
8. Map its destination block volume.
9. Verify hashes and apply ranges at identical logical offsets.
10. Verify destination.
11. Only then advance the authoritative reference point and remove the old source reference point.

The important word is **logical**. RCT offsets do not describe VHDX container-file offsets.

## Destination storage

For Ceph/RBD, `controller/proxmox.py` resolves an already mapped PVE block path when possible. Otherwise it maps the specific RBD image temporarily, applies the delta while the VM is stopped, then unmaps only the mapping it created.

## Network safety

The source and destination may share MAC/IP/hostname identity, so a migrated destination is unsafe on production networking while the source is live. `test_vnet` and `production_vnet` are required to be different.

No quarantine/test VNet is assumed by name. One must be deliberately created or selected before lab migration.
