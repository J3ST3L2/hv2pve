# Operational runbook

## Baseline on Hyper-V

```powershell
$repo = 'C:\hv2pve'
$work = 'D:\hv2pve-export'
$vm = 'TEST-VM'

& "$repo\hyperv\scripts\discover.ps1" -VMName $vm -OutputPath "$work\discovery.json"
& "$repo\hyperv\scripts\rct-baseline.ps1" -VMName $vm -DestinationPath $work -StatePath "$work\migration-state.json"
```

Transfer the state and export directory to `/migrate/incoming` on the controller.

## Ingest and seed

```bash
STATE=/migrate/state/test-vm.json
hv2pve ingest-baseline --input /migrate/incoming/migration-state.json --state "$STATE"
hv2pve validate-state --state "$STATE"
hv2pve status --state "$STATE"

hv2pve seed-plan --state "$STATE" --storage ceph-vm --test-vnet YOUR_ISOLATED_VNET
```

After review:

```bash
hv2pve seed \
  --state "$STATE" \
  --storage ceph-vm \
  --test-vnet YOUR_ISOLATED_VNET \
  --production-vnet SOURCE_PRODUCTION_VNET \
  --pve-host 10.20.99.37 \
  --identity-file ~/.ssh/hv2pve_pve
```

## Isolated test

```bash
hv2pve test-start --state "$STATE" --pve-host 10.20.99.37 --identity-file ~/.ssh/hv2pve_pve
# validate VM manually / with service-specific tests
hv2pve test-stop --state "$STATE" --pve-host 10.20.99.37 --identity-file ~/.ssh/hv2pve_pve
hv2pve mark-tested --state "$STATE" --guest-boot-verified --application-verified
```

## Online sync

Create a new source sync export:

```powershell
& C:\hv2pve\hyperv\scripts\rct-sync.ps1 `
  -VMName 'TEST-VM' `
  -MigrationId 'MIGRATION-ID' `
  -BaseReferencePointInstanceID 'CURRENT-RP-ID' `
  -DestinationPath 'D:\hv2pve-export' `
  -Sequence 1 `
  -OutputPath 'D:\hv2pve-export\sync-000001.json'
```

Ingest pending sync metadata on controller. Apply/verify its data path. Only then:

```bash
hv2pve register-sync --state "$STATE" --sequence 1 --reference-point NEW_RP --verified
```

On source, commit old reference point cleanup:

```powershell
.\hyperv\scripts\commit-sync.ps1 -VMName 'TEST-VM' -OldReferencePointInstanceID OLD_RP -NewReferencePointInstanceID NEW_RP -ConfirmNewReferencePoint NEW_RP
```

## Cutover

```bash
hv2pve register-sync --state "$STATE" --sequence N --reference-point RP_N --verified --cutover-ready
hv2pve cutover-plan --state "$STATE"
hv2pve authorize-cutover --state "$STATE" --confirm 'TEST-VM'
```

Stop source with `cutover-source.ps1`, then:

```bash
hv2pve mark-source-stopped --state "$STATE" --confirm 'TEST-VM'
# capture/apply final delta
hv2pve mark-final-sync --state "$STATE" --verified
hv2pve activate-production --state "$STATE" --pve-host 10.20.99.37 --identity-file ~/.ssh/hv2pve_pve
# validate production services
hv2pve mark-cutover-complete --state "$STATE" --network-verified --guest-verified --application-verified
```

## Rollback

```bash
hv2pve rollback-plan --state "$STATE"
hv2pve begin-rollback --state "$STATE" --confirm 'TEST-VM' --pve-host 10.20.99.37 --identity-file ~/.ssh/hv2pve_pve
```

Then start Hyper-V source using `start-source-rollback.ps1`, validate it, and run:

```bash
hv2pve mark-rolled-back --state "$STATE" --confirm 'TEST-VM'
```
