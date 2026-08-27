# Architecture

## Objective

`hv2pve` migrates Hyper-V virtual machines into Proxmox VE with a staged workflow intended to minimize outage time and preserve rollback options.

## Components

### Hyper-V side

PowerShell runs on or against the Hyper-V host and is responsible for:

- VM discovery and inventory
- disk and virtual-switch discovery
- production checkpoint creation
- baseline export orchestration
- reference-point/RCT operations once implemented
- source quiesce/stop operations during cutover

The Hyper-V side must never silently delete a source VM or checkpoint that is still part of an active migration state.

### Migration controller

The Linux controller runs on the migration appliance and is responsible for:

- migration state
- invoking Hyper-V operations
- transfer orchestration
- image inspection/conversion
- Proxmox destination creation/import
- isolated test-boot orchestration
- cutover state machine
- validation and rollback guidance

### Proxmox side

Proxmox VE is the destination platform. Initial development targets:

- Q35 machine type
- OVMF/UEFI where appropriate
- VirtIO networking/storage
- Ceph-backed destination disks
- SDN VNets for production and isolated test networking

The generic VM-building mechanics remain in the companion Ansible repository. `hv2pve` should call stable interfaces rather than duplicate every infrastructure primitive.

## Data path

The preferred long-term path is to avoid staging complete copies twice:

```text
Hyper-V source
    │
    │ baseline / changed data
    ▼
hv2pve controller
    │
    │ streaming conversion / controlled staging
    ▼
Proxmox destination storage
```

A local `/migrate` workspace is still useful for manifests, metadata, logs, temporary chunks, and smaller migrations.

## Migration state machine

```text
NEW
 ↓
DISCOVERED
 ↓
BASELINE_READY
 ↓
SEEDED
 ↓
TESTED
 ↓
SYNCING
 ↓
CUTOVER_READY
 ↓
CUTOVER_IN_PROGRESS
 ↓
CUTOVER_COMPLETE
 ↓
CLOSED
```

Failure states do not automatically destroy source or destination assets. The state file records enough information to make cleanup deliberate.

## Network safety

Before cutover, a destination VM may only boot when attached to an explicitly isolated VNet or with its NIC disconnected.

The controller must refuse a test boot on the selected production network while the source VM is still reported as running.

## RCT boundary

Hyper-V Resilient Change Tracking is a separate implementation milestone. A checkpoint differencing disk is not treated as a substitute for proper changed-block tracking. Until RCT/reference-point handling is proven, the controller may perform baseline operations but must report incremental synchronization as unavailable.
