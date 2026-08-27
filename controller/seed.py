from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from process import CommandError, run
from proxmox import ProxmoxSSH
from state import MigrationState

VIRTUAL_DISK_EXTENSIONS = {".vhd", ".vhdx", ".avhd", ".avhdx"}


@dataclass(frozen=True)
class ExportedDisk:
    source_path: str
    exported_path: Path
    virtual_size: int | None
    controller_type: str | None
    controller_number: int | None
    controller_location: int | None


def _field(obj: dict[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in obj:
            return obj[name]
    return default


def exported_disk_candidates(export_root: str | Path) -> list[Path]:
    root = Path(export_root)
    if not root.exists():
        raise FileNotFoundError(root)
    return sorted(
        p for p in root.rglob("*")
        if p.is_file() and p.suffix.lower() in VIRTUAL_DISK_EXTENSIONS
    )


def resolve_exported_disks(state: MigrationState, export_root: str | Path | None = None) -> list[ExportedDisk]:
    source_disks = list(state.source.get("disks") or [])
    if not source_disks:
        raise ValueError("source disk inventory is empty")
    root_value = export_root or state.baseline.get("export_root")
    if not root_value:
        raise ValueError("baseline export_root is not recorded")
    root = Path(root_value)
    candidates = exported_disk_candidates(root)
    if not candidates:
        raise ValueError(f"no exported VHD/VHDX files found under {root}")

    resolved: list[ExportedDisk] = []
    used: set[Path] = set()
    for index, disk in enumerate(source_disks):
        source_path = str(_field(disk, "Path", "path", default=""))
        if not source_path:
            raise ValueError(f"source disk {index} has no path")
        source_name = Path(source_path.replace("\\", "/")).name.lower()
        exact = [p for p in candidates if p.name.lower() == source_name and p not in used]
        if len(exact) == 1:
            chosen = exact[0]
        elif len(exact) > 1:
            raise ValueError(f"ambiguous export mapping for {source_path}: {exact}")
        else:
            remaining = [p for p in candidates if p not in used]
            if len(source_disks) == 1 and len(remaining) == 1:
                chosen = remaining[0]
            else:
                # Hyper-V reference-point exports can rename leaf files. As a guarded
                # fallback, match the original stem only when it is unique.
                stem = Path(source_name).stem.lower()
                fuzzy = [p for p in remaining if Path(p.name).stem.lower().startswith(stem)]
                if len(fuzzy) != 1:
                    raise ValueError(
                        f"could not uniquely map source disk {source_path}; candidates={remaining}"
                    )
                chosen = fuzzy[0]
        used.add(chosen)
        resolved.append(
            ExportedDisk(
                source_path=source_path,
                exported_path=chosen,
                virtual_size=_field(disk, "VirtualSizeBytes", "virtual_size_bytes"),
                controller_type=_field(disk, "ControllerType", "controller_type"),
                controller_number=_field(disk, "ControllerNumber", "controller_number"),
                controller_location=_field(disk, "ControllerLocation", "controller_location"),
            )
        )
    return resolved


def inspect_guest_os(disk_path: str | Path) -> str:
    """Best-effort libguestfs inspection. Returns windows, linux, or unknown."""
    try:
        result = run(["virt-inspector", "-a", str(disk_path)], timeout=600)
    except (FileNotFoundError, CommandError):
        return "unknown"
    text = result.stdout.lower()
    if "<distro>windows</distro>" in text or "<osinfo>win" in text:
        return "windows"
    if "<type>linux</type>" in text or "<distro>ubuntu</distro>" in text or "<distro>rhel" in text:
        return "linux"
    return "unknown"


def seed_destination(
    state: MigrationState,
    *,
    pve: ProxmoxSSH,
    storage: str,
    test_vnet: str,
    production_vnet: str,
    export_root: str | Path | None = None,
    vmid: int | None = None,
    guest_os: str = "auto",
    staging_root: str = "/var/lib/vz/hv2pve",
    cleanup_on_failure: bool = True,
) -> dict[str, Any]:
    if test_vnet == production_vnet:
        raise ValueError("test_vnet and production_vnet must be different")
    disks = resolve_exported_disks(state, export_root)
    source = state.source
    name = str(source.get("vm_name") or f"hv2pve-{state.migration_id[:8]}")
    generation = int(source.get("generation") or 2)
    cores = int(source.get("processor_count") or source.get("ProcessorCount") or 2)
    memory_bytes = int(
        source.get("memory_startup_bytes")
        or source.get("MemoryStartupBytes")
        or source.get("memory_assigned_bytes")
        or (4 * 1024**3)
    )
    memory_mb = max(512, memory_bytes // (1024 * 1024))
    first_network = (source.get("networks") or [{}])[0]
    mac = _field(first_network, "MacAddress", "mac_address")
    mac = str(mac) if mac else None
    if mac and len(mac) == 12 and ":" not in mac:
        mac = ":".join(mac[i:i+2] for i in range(0, 12, 2))

    if guest_os == "auto":
        guest_os = inspect_guest_os(disks[0].exported_path)
    if guest_os not in {"windows", "linux", "unknown"}:
        raise ValueError("guest_os must be auto, windows, linux, or unknown")
    # Compatibility-first. A migrated Windows guest already knows AHCI/E1000;
    # it may not have Proxmox VirtIO drivers yet.
    nic_model = "e1000" if guest_os in {"windows", "unknown"} else "virtio"
    disk_bus = "sata" if guest_os in {"windows", "unknown"} else "scsi"
    if disk_bus == "sata" and len(disks) > 6:
        raise ValueError("compatibility SATA seed supports at most 6 disks; install VirtIO first")

    vmid = vmid or pve.next_vmid()
    existing = pve.cluster_vms()
    if any(int(x.get("vmid", -1)) == vmid for x in existing):
        raise ValueError(f"destination VMID {vmid} already exists")
    if any(x.get("name") == name for x in existing):
        raise ValueError(f"destination VM name {name!r} already exists")

    remote_dir = f"{staging_root.rstrip('/')}/{state.migration_id}"
    created = False
    disk_map: dict[str, Any] = {}
    try:
        pve.mkdir(remote_dir)
        pve.create_destination(
            vmid=vmid,
            name=name,
            generation=generation,
            cores=cores,
            memory_mb=memory_mb,
            test_bridge=test_vnet,
            mac_address=mac,
            nic_model=nic_model,
            efi_storage=storage,
        )
        created = True
        for index, disk in enumerate(disks):
            remote_path = f"{remote_dir}/disk-{index}{disk.exported_path.suffix.lower()}"
            pve.copy_to_host(disk.exported_path, remote_path)
            volume = pve.import_disk(vmid, remote_path, storage)
            slot = f"{disk_bus}{index}"
            pve.attach_disk(vmid, slot, volume)
            disk_map[str(index)] = {
                "source_path": disk.source_path,
                "exported_path": str(disk.exported_path),
                "volume": volume,
                "slot": slot,
                "virtual_size": disk.virtual_size,
            }
            pve.remove(remote_path)
        pve.set_boot_order(vmid, f"{disk_bus}0")
        return {
            "proxmox_node": pve.host,
            "proxmox_vmid": vmid,
            "guest_os": guest_os,
            "disk_bus": disk_bus,
            "nic_model": nic_model,
            "test_vnet": test_vnet,
            "production_vnet": production_vnet,
            "disk_map": disk_map,
        }
    except Exception:
        if created and cleanup_on_failure:
            try:
                pve.destroy(vmid)
            except Exception:
                pass
        raise
