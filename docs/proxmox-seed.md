# Proxmox baseline seed

## Compatibility-first device model

A migrated Windows VM may not have VirtIO drivers before its first Proxmox boot. The seed logic therefore uses:

- Windows/unknown guest: SATA disks + E1000 NIC
- Linux guest: SCSI/VirtIO disk + VirtIO NIC

This optimizes for the first successful boot. VirtIO conversion can be performed later after drivers are installed and validated.

## Generation mapping

- Hyper-V Generation 2 -> q35 + OVMF + EFI disk
- Hyper-V Generation 1 -> pc/i440fx + SeaBIOS

## Disk mapping

Source disk paths are matched to exported VHD/VHDX files by exact basename first. Ambiguous mappings are refused. The controller records each imported Proxmox volume ID and slot in `destination.disk_map` for subsequent delta application.

## Test network

The seed command requires both `--test-vnet` and `--production-vnet` and rejects identical values. The VM is created with the test VNet and remains stopped.

## Ceph/RBD delta application

For an RBD volume, delta application:

1. verifies the VM is stopped
2. transfers bundle metadata/payload to the PVE node
3. resolves or temporarily maps the RBD image
4. applies logical ranges to the block device
5. flushes writes
6. unmaps only a mapping created by hv2pve
7. removes temporary bundle files

A live destination is never modified by the delta writer.
