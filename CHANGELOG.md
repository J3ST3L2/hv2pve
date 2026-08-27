# Changelog

## 0.2.0 - engineering/lab MVP

- Added schema-v2 migration state machine with atomic writes and explicit safety transitions.
- Added RCT reference-point creation/export and guarded reference-point cleanup.
- Added WMI disk/RCT mapping and change-range query helpers.
- Added native .NET 8 `QueryChangesVirtualDisk` helper and logical delta-bundle packer.
- Added SHA-256 verified Linux delta writer.
- Added Proxmox SSH backend, baseline seed, isolated test workflow, Ceph/RBD delta application, production activation, rollback isolation and closure workflow.
- Added appliance/source install helpers.
- Added Python tests, PowerShell parse CI, and native Windows build CI.
- Added lab validation and operational documentation.

This release is intentionally labeled lab MVP until live Hyper-V RCT/reference-point and native capture semantics pass the documented validation gates.
