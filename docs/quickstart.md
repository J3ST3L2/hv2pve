# First lab migration quickstart

This is a proof workflow for a disposable VM. Do not make the first run a domain controller, storage server, or anything whose disappearance would generate a meeting.

## Hyper-V host

Open elevated PowerShell:

```powershell
git clone https://github.com/J3ST3L2/hv2pve.git C:\hv2pve
cd C:\hv2pve

.\hyperv\scripts\discover.ps1 `
  -VMName 'TEST-VM' `
  -OutputPath C:\hv2pve-work\discovery.json
```

Review the JSON. Then create the RCT baseline:

```powershell
.\hyperv\scripts\rct-baseline.ps1 `
  -VMName 'TEST-VM' `
  -DestinationPath C:\hv2pve-work\export `
  -StatePath C:\hv2pve-work\migration-state.json
```

The VM should remain online. Record the `migration_id` and authoritative reference point from the state file.

## Transfer to appliance

Copy the baseline export and state to `/migrate/incoming/<migration-id>/` on hv2pve01. `send-artifact.ps1` is provided when Windows OpenSSH client is available.

## Controller

```bash
STATE=/migrate/state/test-vm.json
hv2pve ingest-baseline \
  --input /migrate/incoming/MIGRATION-ID/migration-state.json \
  --state "$STATE"

hv2pve validate-state --state "$STATE"
hv2pve status --state "$STATE"
```

## Create/select an isolated VNet

Do not use the production VNet. The existing lab `vlan60` is the Servers production network, so a separate test/quarantine VNet is required before destination boot.

## Seed

```bash
hv2pve seed-plan \
  --state "$STATE" \
  --storage ceph-vm \
  --test-vnet YOUR_ISOLATED_VNET
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

Then use `test-start`, validate, `test-stop`, and `mark-tested` as documented in the runbook.
