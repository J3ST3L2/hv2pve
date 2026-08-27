# Lab validation matrix

Do not start with a valuable VM. Build a tiny sacrificial VM with known files and deliberately generated writes.

## Gate 0 - tooling

- [ ] GitHub Python tests pass
- [ ] PowerShell sources parse on Windows
- [ ] native .NET RCT helper builds
- [ ] `hv2pve --help` works on appliance
- [ ] source Hyper-V host is Windows Server 2016+
- [ ] PowerShell session is elevated

## Gate 1 - read-only discovery

- [ ] VM ID/name/generation correct
- [ ] disk count/paths/sizes correct
- [ ] NIC/MAC/VLAN correct
- [ ] existing checkpoints reported without modification

## Gate 2 - baseline reference point

- [ ] application-consistent RCT reference point created
- [ ] VM remains online
- [ ] disk and RCT arrays have equal counts
- [ ] baseline export succeeds
- [ ] baseline state ingests on controller
- [ ] old source data unchanged

## Gate 3 - Proxmox seed

- [ ] isolated VNet created/selected
- [ ] seed plan reviewed
- [ ] VM created stopped
- [ ] all disks mapped to expected volumes
- [ ] destination cannot reach production network
- [ ] isolated boot works
- [ ] destination stopped after test

## Gate 4 - RCT range correctness

On the source test VM:

1. write a known marker file
2. create next reference point
3. query changes with both WMI and native helper
4. compare changed ranges
5. ensure controlled writes fall inside reported ranges

- [ ] native and WMI results are plausible/consistent
- [ ] no direct VHDX-file-offset writes are used

## Gate 5 - delta reproduction

- [ ] create baseline raw destination
- [ ] generate native bundle from a frozen disk view
- [ ] apply bundle to clone
- [ ] boot clone isolated
- [ ] known marker file matches
- [ ] filesystem check clean
- [ ] repeat for at least 3 sequential syncs
- [ ] corrupt payload test is rejected
- [ ] interrupted sync does not advance authoritative RP

## Gate 6 - cutover rehearsal

- [ ] latest online sync verified
- [ ] source shutdown graceful
- [ ] source OFF confirmed
- [ ] final delta applied
- [ ] production VNet switch occurs only after source OFF
- [ ] destination boots
- [ ] production identity and app validated

## Gate 7 - rollback rehearsal

- [ ] destination stopped before source restart
- [ ] destination moved back to isolated VNet
- [ ] source starts and validates
- [ ] split-brain test proves simultaneous production identity is blocked by procedure/state gates

Only after all gates pass should the project be called production-ready for that Hyper-V/PVE/storage combination.
