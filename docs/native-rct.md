# Native RCT data plane

`native/Hv2Pve.Rct` is a .NET 8 Windows executable wrapping `VirtDisk.dll`.

## Commands

```text
Hv2Pve.Rct info   --disk disk.vhdx
Hv2Pve.Rct query  --disk disk.vhdx --rct-id ID --output ranges.json
Hv2Pve.Rct attach --disk frozen.vhdx
Hv2Pve.Rct detach --disk frozen.vhdx
Hv2Pve.Rct pack   --source-raw \\.\PhysicalDriveN ...
```

## Why attach the disk

`QueryChangesVirtualDisk` returns offsets relative to the logical virtual disk. VHDX is a container format with headers, metadata, allocation tables and payload blocks; logical guest offset 1 GiB is not VHDX file offset 1 GiB.

`pack` reads from the `\\.\PhysicalDriveN` object created by a read-only/no-drive-letter virtual disk attachment. Each logical range gets its own SHA-256 and the complete payload gets a SHA-256.

## Delta bundle

Metadata contains:

```json
{
  "format_version": 1,
  "migration_id": "...",
  "disk_id": "...",
  "virtual_size": 68719476736,
  "sequence": 4,
  "reference_from": "...",
  "reference_to": "...",
  "ranges": [
    {
      "offset": 1048576,
      "length": 2097152,
      "payload_offset": 0,
      "sha256": "..."
    }
  ],
  "payload_size": 2097152,
  "payload_sha256": "..."
}
```

The Linux writer validates the payload hash, range order/bounds, per-range hashes, writes with `pwrite`, and calls `fsync` before success.

## Experimental boundary

The Windows API helper compiles in CI, but the exact pairing between an RCT reference point and the frozen disk image supplied to `native-delta.ps1` must be proven on the target Hyper-V versions. The helper therefore requires an explicit `FrozenDiskPath`; it does not guess that the live VM's VHDX is safe to read as a point-in-time backup.
