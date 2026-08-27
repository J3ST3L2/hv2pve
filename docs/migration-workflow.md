# Migration workflow

## 1. Discover

Run read-only discovery on the Hyper-V host and record:

- VM ID/name/generation
- CPU and memory
- all virtual disk paths/sizes/controller positions
- network adapters, MACs, switch/VLAN data
- existing checkpoints
- checkpoint policy

## 2. Baseline

Create an application-consistent RCT reference point when supported. Export the baseline and write migration state. The source remains online.

The baseline reference point becomes the first authoritative sync point.

## 3. Transfer and seed

Transfer the baseline export to the migration appliance. The controller:

- refuses ambiguous exported-disk mapping
- allocates a free Proxmox VMID unless one was requested
- creates generation-compatible firmware
- uses compatibility-first disk/NIC devices for unknown/Windows guests
- imports disks
- records exact Proxmox volume IDs
- attaches only the isolated test network

## 4. Test boot

Start only on the isolated VNet. Validate:

- firmware/boot
- filesystems
- network stack
- applications/services
- required driver changes

Stop the destination when testing is done and explicitly mark the test successful.

## 5. Online synchronization

For each cycle:

1. Create a new RCT reference point.
2. Capture changes from the old authoritative point.
3. Keep the new point pending.
4. Apply and verify the data at the destination while destination is stopped.
5. Mark the new point authoritative in controller state.
6. Commit source reference-point cleanup with `commit-sync.ps1`.

A failed sync never advances the authoritative point.

## 6. Cutover

1. Verify isolated test and most recent online sync.
2. Mark state CUTOVER_READY.
3. Print/review cutover plan.
4. Explicitly authorize with exact VM name.
5. Gracefully shut down source VM.
6. Record source stopped.
7. Perform final sync.
8. Verify final sync.
9. Switch destination NIC from isolated VNet to production VNet.
10. Start Proxmox destination.
11. Validate network identity, guest boot and application behavior.
12. Mark cutover complete.

## 7. Rollback window

Do not delete the source VM. If rollback is required:

1. Stop Proxmox destination.
2. Move its NIC back to isolated VNet.
3. Verify destination is stopped.
4. Restart Hyper-V source.
5. Validate source.
6. Record rollback.

Writes accepted by the Proxmox destination after cutover are divergent data and must be reconciled if rollback occurs.
