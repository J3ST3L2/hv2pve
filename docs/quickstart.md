# First lab quickstart

This is the initial safe test path. It stops before Proxmox import and does not implement RCT yet.

## Hyper-V host prerequisites

Run PowerShell as Administrator on the Hyper-V host.

```powershell
Get-Module -ListAvailable Hyper-V
Get-VM | Select-Object Name, State, Generation, CheckpointType
```

Choose a disposable test VM for the first migration.

## Clone the repository

```powershell
git clone https://github.com/J3ST3L2/hv2pve.git
cd hv2pve
```

If Git is not installed, download the repository ZIP from GitHub for the first lab test. Git is preferable once development becomes iterative.

## Discover a VM

```powershell
.\hyperv\scripts\discover.ps1 `
  -VMName 'TEST-VM' `
  -OutputPath C:\hv2pve\discovery.json
```

Review the JSON before creating any checkpoint.

The discovery output should include:

- VM ID
- generation
- power state
- configured checkpoint type
- virtual disks
- virtual switches/VLAN information
- existing checkpoints

## Check checkpoint policy

`hv2pve` currently requires the VM checkpoint type to be `Production` or `ProductionOnly` before baseline creation.

Inspect it:

```powershell
Get-VM -Name 'TEST-VM' | Select-Object Name, CheckpointType
```

For a lab VM, if you explicitly want production checkpoints to fail rather than fall back to standard checkpoints:

```powershell
Set-VM -Name 'TEST-VM' -CheckpointType ProductionOnly
```

That setting is not changed automatically by hv2pve.

## Create/export the baseline

Choose a disk with enough free capacity for the exported checkpoint.

```powershell
.\hyperv\scripts\baseline.ps1 `
  -VMName 'TEST-VM' `
  -DestinationPath 'D:\hv2pve-exports' `
  -StatePath 'C:\hv2pve\migration-state.json'
```

Expected result:

- source VM remains available
- an `hv2pve-*` production checkpoint exists
- the checkpoint is exported under the migration ID
- migration state is written as JSON
- phase is `BASELINE_READY`

## Stop here for the first test

Do not manually merge/delete the migration checkpoint yet. The next development step consumes the baseline on the Linux migration appliance and builds an isolated Proxmox destination.

## Important

Incremental synchronization is deliberately unavailable at this stage. The project will add proper Hyper-V RCT/reference-point handling after the baseline path is validated.
