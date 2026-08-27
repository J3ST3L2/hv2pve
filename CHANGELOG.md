# Changelog

## Unreleased

### Added

- Staged Hyper-V to Proxmox migration controller and atomic migration-state model.
- Hyper-V discovery, production/RCT reference-point creation, baseline and incremental reference-point export tooling.
- Native .NET 8 RCT helper wrapping `QueryChangesVirtualDisk`, read-only virtual-disk attachment, logical-range packing, and SHA-256 metadata.
- WMI-vs-native RCT comparison harness for validating equivalent logical changed-range coverage on real Hyper-V hosts.
- Proxmox baseline seed/import, isolated test workflow, Ceph/RBD logical delta application, production VNet activation, and rollback isolation.
- Appliance, Hyper-V source, and read-only Ceph/RBD preflight scripts.
- Live validation gate documentation covering baseline, three online delta cycles, cutover, and rollback rehearsal.
- CI for Python, shell syntax, PowerShell parsing, and the native .NET RCT helper.

### Safety

- Source VMs are never automatically deleted.
- Destination test boot is refused on the production VNet.
- Delta application requires a stopped Proxmox destination.
- Cutover requires isolated test validation, verified synchronization, exact-name authorization, and source shutdown.
- Rollback stops and re-isolates the destination before the Hyper-V source can restart.
- RCT logical offsets are never treated as VHDX container-file offsets.
