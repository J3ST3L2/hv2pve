# hv2pve

`hv2pve` is a staged Hyper-V to Proxmox VE migration toolkit designed for low-downtime cutovers with a rollback window.

The project intentionally treats migration as a state machine rather than a one-shot VHDX conversion:

```text
LIVE HYPER-V VM
      |
      +--> RCT reference point / application-consistent baseline
      |            |
      |            +--> seed Proxmox destination
      |                       |
      |                       +--> isolated test boot
      |
      +--> online sync 1
      +--> online sync 2
      +--> ...
      |
      +--> controlled source shutdown
                   |
                   +--> final delta
                   +--> production network handoff
                   +--> Proxmox start + validation
                   +--> Hyper-V source retained OFF for rollback
```

## Status

**Engineering/lab MVP, not production-certified.**

The repository now contains the control-plane skeleton and both supported RCT data-plane approaches:

- Hyper-V discovery and Production/RCT reference-point creation.
- WMI reference-point full and base-relative export.
- RCT disk/reference mapping and change-range query helpers.
- Native Windows `QueryChangesVirtualDisk` helper for efficient changed-range discovery.
- A WMI-vs-native RCT comparison harness that normalizes range segmentation before comparing logical changed-block coverage.
- A delta bundle format that reads logical guest-disk ranges from a read-only attached virtual disk, hashes them, transports them, and applies them to the destination logical block device.
- Proxmox baseline seed, isolated test start/stop, Ceph/RBD delta application, production-network activation, rollback isolation, and migration state tracking.
- Appliance and Hyper-V preflight harnesses for the live validation gates.
- Python unit tests, shell syntax CI, PowerShell parser CI, and native .NET build CI.

What is **not** claimed yet is production validation. The WMI reference-point method shapes and native RCT capture semantics must be validated on a sacrificial Windows Server 2016+ Hyper-V VM before any irreplaceable workload is migrated. See [`docs/live-validation.md`](docs/live-validation.md) and [`docs/lab-validation.md`](docs/lab-validation.md).

## Safety model

The defaults are intentionally annoying in the places where automation can create outages:

- The source VM is never deleted automatically.
- The destination may not use the production VNet during test boot.
- The destination must be stopped before delta application.
- A successful isolated test is required before cutover.
- A verified sync and authoritative reference point are required before cutover.
- `authorize-cutover` requires the exact source VM name as confirmation.
- Source shutdown is graceful only; hv2pve does not force power-off automatically.
- Production activation is refused until the source is recorded stopped and the final sync is verified.
- Rollback first stops and re-isolates the Proxmox destination before the Hyper-V source is restarted.
- The old Hyper-V reference point is not destroyed until a new sync is verified at the destination.

## Repository layout

```text
hv2pve/
├── controller/
│   ├── hv2pve.py              controller CLI / state transitions
│   ├── state.py               atomic migration-state store
│   ├── seed.py                exported-disk mapping + baseline seed
│   ├── proxmox.py             SSH Proxmox backend
│   ├── delta.py               delta bundle build/apply
│   ├── remote_apply_delta.py  standalone PVE block-device writer
│   ├── safety.py              cutover/test safety gates
│   ├── plan.py                human-readable plans
│   └── process.py             subprocess wrapper
├── hyperv/
│   ├── HyperV2PVE.psm1        Hyper-V/RCT PowerShell module
│   ├── HyperV2PVE.psd1
│   └── scripts/
│       ├── discover.ps1
│       ├── lab-preflight.ps1
│       ├── rct-baseline.ps1
│       ├── rct-sync.ps1
│       ├── rct-disk-map.ps1
│       ├── rct-query.ps1
│       ├── rct-compare.ps1
│       ├── native-delta.ps1
│       ├── commit-sync.ps1
│       ├── cutover-source.ps1
│       ├── start-source-rollback.ps1
│       └── send-artifact.ps1
├── native/Hv2Pve.Rct/         .NET 8 Win32 RCT helper
├── install/                    appliance/source build helpers
├── scripts/                    appliance validation helpers
├── config/                     configuration example
├── schemas/                    migration-state schema
├── docs/                       design + operational runbooks
└── tests/                      controller unit tests
```

## RCT data planes

### 1. WMI reference-point export: correctness-first

Hyper-V's WMI backup API can create an RCT reference point and export either a baseline or a new reference point relative to a base reference point. Hyper-V compiles the backup data into virtual-disk data for transport. This is the first path to validate because Hyper-V owns the consistency semantics.

### 2. Native changed-range bundles: efficient path

`native/Hv2Pve.Rct` wraps the Windows Virtual Disk API:

- `GetVirtualDiskInformation`
- `QueryChangesVirtualDisk`
- `AttachVirtualDisk`
- `GetVirtualDiskPhysicalPath`

The RCT offsets are **logical virtual-disk offsets**, not offsets in the VHDX container file. `native-delta.ps1` therefore attaches a frozen VHD/VHDX read-only and reads the returned ranges from `\\.\PhysicalDriveN`. Writing RCT ranges directly into VHDX file offsets corrupts the image.

`rct-compare.ps1` runs both the WMI and native query paths against the same disk/RCT ID, merges adjacent/overlapping ranges, and fails when the resulting logical coverage differs. Raw range counts do not need to match because the two APIs may segment equivalent changed regions differently.

This native path remains experimental until its exact frozen-disk/reference-point pairing is proven in the lab.

## Controller quick start

On the migration appliance:

```bash
git clone https://github.com/J3ST3L2/hv2pve.git
cd hv2pve
sudo ./install/install-appliance.sh
bash scripts/appliance-preflight.sh
```

Import source baseline state:

```bash
hv2pve ingest-baseline \
  --input /migrate/incoming/migration-state.json \
  --state /migrate/state/testvm.json

hv2pve status --state /migrate/state/testvm.json
```

Create a destination plan before touching Proxmox:

```bash
hv2pve seed-plan \
  --state /migrate/state/testvm.json \
  --storage ceph-vm \
  --test-vnet REQUIRED_ISOLATED_VNET
```

Seed the destination:

```bash
hv2pve seed \
  --state /migrate/state/testvm.json \
  --storage ceph-vm \
  --test-vnet REQUIRED_ISOLATED_VNET \
  --production-vnet vlan60 \
  --pve-host 10.20.99.37 \
  --identity-file ~/.ssh/hv2pve_pve
```

The `vlan60` value above is only an example. Each migration must use the source VM's real production network.

Read-only Ceph/RBD validation for a stopped disposable destination:

```bash
PVE_HOST=10.20.99.37 \
PVE_IDENTITY_FILE=$HOME/.ssh/hv2pve_pve \
bash scripts/ceph-volume-preflight.sh 104 scsi0
```

## Hyper-V baseline quick start

Run PowerShell elevated on the Hyper-V host:

```powershell
.\hyperv\scripts\lab-preflight.ps1 `
    -VMName 'TEST-VM' `
    -OutputPath C:\hv2pve\preflight.json

.\hyperv\scripts\discover.ps1 `
    -VMName 'TEST-VM' `
    -OutputPath C:\hv2pve\discovery.json

.\hyperv\scripts\rct-baseline.ps1 `
    -VMName 'TEST-VM' `
    -DestinationPath D:\hv2pve-export `
    -StatePath D:\hv2pve-export\migration-state.json
```

After a controlled source change and a new reference point, compare WMI and native changed-range coverage:

```powershell
.\hyperv\scripts\rct-compare.ps1 `
    -DiskPath 'D:\VMs\TEST-VM\disk.vhdx' `
    -RctId 'RCT-ID-FROM-REFERENCE-POINT' `
    -OutputPath C:\hv2pve\rct-compare.json
```

Do all of this first on a disposable test VM.

## Documentation

- [Architecture](docs/architecture.md)
- [Migration workflow](docs/migration-workflow.md)
- [Hyper-V RCT design](docs/rct-design.md)
- [Native RCT data plane](docs/native-rct.md)
- [Proxmox seed/import](docs/proxmox-seed.md)
- [Cutover and rollback](docs/cutover.md)
- [Live validation gates](docs/live-validation.md)
- [Lab validation matrix](docs/lab-validation.md)
- [Operational runbook](docs/runbook.md)

## Companion infrastructure

The `J3ST3L2/ansible` repository owns infrastructure lifecycle for the migration appliance and now includes:

- the generic Proxmox VM builder;
- a dedicated `hv2pve - Create Appliance VM` Semaphore manifest with a 64 GiB OS disk and 128 GiB starting workspace disk;
- `playbooks/proxmox-expand-vm-disk.yml` for grow-only disk expansion;
- `playbooks/hv2pve-appliance.yml` for package installation, `/migrate` provisioning, and optional private-repository deployment;
- `playbooks/hv2pve-check-test-vlan.yml` for read-only candidate isolated-VLAN validation;
- Semaphore manifests for the appliance, disk expansion, and VLAN preflight;
- `tools/semaphore_login_and_sync_hv2pve.sh` for interactive one-command Semaphore login and template reconciliation;
- CI that syntax-checks the hv2pve Ansible playbooks, manifests, and reconciliation helpers.

The isolated test VNet itself is deliberately **not** hardcoded until a VLAN has been checked against the broader physical network. `vlan60` remains production/server networking and is refused as the current isolated-test choice.

## References

Primary implementation references are Microsoft Hyper-V WMI and Virtual Disk API documentation, especially:

- Hyper-V Backup Approaches
- `Msvm_VirtualSystemReferencePointService`
- `Msvm_VirtualSystemReferencePoint`
- `Msvm_ImageManagementService.GetVirtualDiskChanges`
- `QueryChangesVirtualDisk`

## License

No public license has been selected. The repository is private during development and validation.
