# Live validation gates

The implementation is not production-certified until these gates pass on disposable workloads using the actual Hyper-V and Proxmox/Ceph environment.

## Gate 0 - appliance

On `hv2pve01`:

```bash
./scripts/appliance-preflight.sh
```

Required:

- migration toolchain present;
- `/migrate` is a separate mounted filesystem;
- controller Python compiles and unit tests pass when the repository is deployed;
- noninteractive SSH to the selected Proxmox node works;
- `ceph-vm` is active;
- Proxmox SDN VNets can be enumerated.

Warnings are allowed only when explicitly understood. Failures block the rehearsal.

## Gate 1 - Hyper-V source

On the source Hyper-V host in elevated PowerShell:

```powershell
.\hyperv\scripts\lab-preflight.ps1 `
  -VMName 'HV2PVE-LAB01' `
  -OutputPath C:\hv2pve-state\preflight.json
```

Required:

- Windows build supports RCT-era APIs;
- Hyper-V module present;
- VM discovered;
- checkpoint policy is `Production` or `ProductionOnly`;
- VHDX disks identified;
- `Msvm_VirtualSystemReferencePointService.CreateReferencePoint` exists;
- `Msvm_ImageManagementService.GetVirtualDiskChanges` exists.

The Win32 `QueryChangesVirtualDisk` helper is validated separately against the same RCT IDs.

## Gate 2 - isolated network

A dedicated Proxmox SDN VNet must exist for migrated test boots.

Rules:

- it must not equal the source production VNet;
- it must not be `vlan60` in the current lab design;
- the destination may boot there while the source remains live;
- production routing should be absent unless deliberately permitted for a test dependency.

No test VNet means no destination test boot. This is a safety gate, not an inconvenience to be clicked through.

## Gate 3 - baseline

Create an application-consistent RCT reference point and baseline export while the source VM remains online.

Record:

- source VM ID;
- reference point instance ID;
- per-disk RCT IDs;
- source VHDX paths and virtual sizes;
- export paths and hashes/metadata;
- baseline start/end timestamps.

The source must remain usable during the operation.

## Gate 4 - seed and isolated boot

Seed the destination to Proxmox/Ceph and attach it only to the isolated test VNet.

Verify:

- firmware/generation mapping;
- disk count/order/capacity;
- guest boots;
- filesystem is consistent;
- expected services exist;
- no production IP/MAC conflict occurs.

Stop the destination after validation before online synchronization begins.

## Gate 5 - three sequential online deltas

For each cycle:

1. make a known change inside the source guest;
2. create the next RCT reference point;
3. query changed logical ranges;
4. package and checksum the logical-range bundle;
5. apply it while the Proxmox destination is stopped;
6. verify the destination bytes/filesystem/data;
7. only then commit the new reference point as authoritative.

Perform at least three successful cycles.

Inject one deliberate bad checksum/interrupted bundle. The destination must reject it and the authoritative reference point must not advance.

## Gate 6 - cutover

Required sequence:

1. destination stopped and last online sync verified;
2. explicit operator authorization;
3. graceful source VM shutdown;
4. verify Hyper-V source is off;
5. create/apply final delta;
6. verify final delta;
7. move destination NIC from isolated VNet to production VNet;
8. start destination;
9. validate network identity, guest boot, and application.

Record observed downtime.

## Gate 7 - rollback rehearsal

Before production certification, intentionally rehearse rollback:

1. stop destination;
2. move destination NIC back to isolated VNet;
3. verify destination is stopped;
4. restart original Hyper-V source;
5. validate source services and production identity;
6. record data-divergence warning if the Proxmox destination accepted writes after cutover.

The source VM is never automatically deleted.

## Production certification

A production workload is eligible only after:

- Gates 0-7 pass on disposable workloads;
- Hyper-V and Proxmox/Ceph versions used in validation are recorded;
- workload-specific boot/service checks are defined;
- backup/recovery posture is understood;
- rollback ownership and maximum rollback window are documented.
