# Cutover safety model

Cutover is the only phase in which the source VM is intentionally stopped and the destination is allowed onto the production network.

## Preconditions

A future automated cutover command must refuse to run unless all of the following are true:

- migration state is at least `TESTED`
- the destination VM ID is recorded
- an isolated destination boot has completed successfully
- disk mappings are unambiguous
- the latest synchronization completed successfully
- source and destination network identities are known
- an operator explicitly confirms source shutdown

## Sequence

```text
validate preconditions
        ↓
quiesce source guest
        ↓
stop Hyper-V VM
        ↓
confirm source is OFF
        ↓
final changed-block synchronization
        ↓
validate destination disks
        ↓
move/connect destination NIC to production VNet
        ↓
start Proxmox VM
        ↓
service validation
```

## Failure before destination start

If any operation fails before the destination is started on the production network, the default recovery action is to keep the destination isolated and return the source VM to service.

## Failure after destination start

If validation fails after the destination has accepted production writes, rollback becomes a divergence decision. The tool must make this explicit rather than quietly starting the old VM and creating split brain.

## Source retention

The source VM is never deleted automatically. After successful cutover it remains powered off for the operator-defined rollback window.
