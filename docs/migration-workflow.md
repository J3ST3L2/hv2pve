# Migration workflow

## 1. Discover

Collect and persist:

- VM name and VM ID
- Hyper-V generation
- power state
- CPU and memory
- attached virtual disks
- virtual switches and VLAN configuration
- firmware/secure-boot details
- checkpoint status

No source mutation occurs during discovery.

## 2. Baseline

Create a production checkpoint and export a consistent baseline while the source VM remains online.

The baseline operation records:

- migration ID
- source VM identity
- checkpoint name/ID
- creation timestamp
- source disk paths and sizes
- export path
- source power state

## 3. Seed destination

Inspect the exported VHD/VHDX images, prepare the guest for Proxmox where required, and import the baseline into destination storage.

The destination VM is not placed on the production network at this stage.

## 4. Test boot

Boot the destination using an isolated VNet or disconnected NIC.

Validate:

- firmware boot
- disk enumeration
- OS boot
- storage drivers
- network drivers
- guest agent
- expected services

Power the test instance back down before continuing synchronization.

## 5. Incremental sync

Once RCT/reference-point support is implemented, synchronize changed blocks while the source remains online.

This operation is repeatable and should make the final cutover delta small.

## 6. Cutover

Cutover is explicit and operator initiated.

1. Confirm destination was previously tested.
2. Confirm latest synchronization completed successfully.
3. Quiesce the source where supported.
4. Stop the Hyper-V source VM.
5. Capture/apply the final delta.
6. Attach the destination to the production network.
7. Start the Proxmox VM.
8. Run validation gates.
9. Leave the Hyper-V source powered off but intact.

## 7. Rollback

During the rollback window:

1. Stop/isolate the Proxmox destination.
2. Confirm no conflicting production identity remains online.
3. Start the original Hyper-V VM.
4. Record that the migration rolled back.

Writes made to the destination after cutover create a divergence boundary. Rollback does not automatically merge those writes back into Hyper-V.

## 8. Close

Only after acceptance should the migration be marked closed. Source deletion remains a separate administrative operation and is intentionally outside automatic cutover.
