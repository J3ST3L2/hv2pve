# Hyper-V RCT design

## Why reference points

Windows Server 2016 and later expose a WMI backup model based on virtual-system reference points plus Resilient Change Tracking (RCT). A reference point provides a stable identifier for the VM backup state and per-disk RCT identifiers.

`Msvm_VirtualSystemReferencePoint.VirtualDiskIdentifiers` and `ResilientChangeTrackingIdentifiers` are parallel arrays. hv2pve records them together and refuses to silently invent a disk association when the WMI resource cannot be resolved.

## Reference-point lifecycle

```text
RP0 authoritative
 |
 | VM continues running
 v
create RP1
 |
 +-- export/query RP0 -> RP1 changes
 |
 +-- destination apply
 |
 +-- destination verify
 |
 v
RP1 authoritative
 |
 +-- destroy RP0 only now
```

The source-side `commit-sync.ps1` requires the exact new reference point ID before deleting the previous one.

## Consistency

Application-consistent reference points are preferred. Crash-consistent is an explicit fallback, not an invisible downgrade.

## WMI export path

`ExportReferencePoint` is the conservative data path. Hyper-V compiles reference point data into an export. It is easier to use and supports remote scenarios, but Microsoft's documentation notes that it can create more data to transfer than the Win32 RCT approach.

## Win32 path

The native helper uses `QueryChangesVirtualDisk`. It requires a local VHD handle opened for `VIRTUAL_DISK_ACCESS_GET_INFO` and returns changed logical ranges.

The helper never writes into a VHDX container at those offsets. It attaches a frozen virtual disk read-only and reads the logical disk view instead.

## Validation requirement

Before native RCT is enabled for a production migration, the lab must prove:

- WMI and Win32 query ranges agree for controlled writes
- the frozen disk associated with the target reference point is the data actually read
- a baseline + one or more deltas reproduces exact guest-disk hashes/known files
- repeated syncs survive controller/source restart
- a failed transfer does not advance reference-point state
