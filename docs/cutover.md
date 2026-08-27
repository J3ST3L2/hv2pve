# Cutover and rollback

## Preconditions

`authorize-cutover` refuses unless:

- destination passed an isolated test boot
- latest sync is verified
- an authoritative Hyper-V reference point is recorded
- destination is recorded powered off
- phase is CUTOVER_READY

The operator must also type the exact source VM name.

## Source stop

Run `hyperv/scripts/cutover-source.ps1`. It requests a guest shutdown and waits. If the guest does not shut down, it fails rather than automatically issuing a hard power-off.

## Final synchronization

After source stop:

- record the source stopped in controller state
- create/capture the final sync
- apply/verify final destination data
- mark final sync verified

Only then can production activation occur.

## Production activation

The controller changes `net0` from the isolated test VNet to the production VNet while preserving model/MAC/other options, then starts the destination.

Complete cutover requires explicit validation of:

- network identity
- guest boot
- application behavior

## Rollback

Rollback is deliberately asymmetric because data may have diverged after cutover.

`begin-rollback`:

1. stops Proxmox destination
2. moves its NIC back to test VNet
3. records ROLLBACK_IN_PROGRESS

Only then should `start-source-rollback.ps1` restart the Hyper-V source.

After validation, `mark-rolled-back` records the result. Any writes accepted by the Proxmox VM between cutover and rollback must be treated as divergent data.
