from __future__ import annotations

import json
import re
import shlex
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from process import run

_UNUSED_RE = re.compile(r"^(unused\d+):\s*(.+)$")


@dataclass
class ProxmoxSSH:
    host: str
    user: str = "root"
    identity_file: str | None = None
    strict_host_key_checking: str = "accept-new"

    def _ssh_base(self) -> list[str]:
        argv = ["ssh"]
        if self.identity_file:
            argv += ["-i", self.identity_file]
        argv += ["-o", f"StrictHostKeyChecking={self.strict_host_key_checking}"]
        return argv

    def _ssh_argv(self, remote: list[str]) -> list[str]:
        argv = self._ssh_base()
        argv.append(f"{self.user}@{self.host}")
        argv.append(" ".join(shlex.quote(x) for x in remote))
        return argv

    def command(self, remote: list[str], *, timeout: int | None = None) -> str:
        return run(self._ssh_argv(remote), timeout=timeout).stdout

    def shell(self, script: str, *, timeout: int | None = None) -> str:
        return run(self._ssh_argv(["bash", "-lc", script]), timeout=timeout).stdout

    def next_vmid(self) -> int:
        raw = self.command(["pvesh", "get", "/cluster/nextid", "--output-format", "json"])
        return int(json.loads(raw))

    def cluster_vms(self) -> list[dict[str, Any]]:
        raw = self.command(
            ["pvesh", "get", "/cluster/resources", "--type", "vm", "--output-format", "json"]
        )
        return list(json.loads(raw))

    def config(self, vmid: int) -> dict[str, str]:
        text = self.command(["qm", "config", str(vmid)])
        result: dict[str, str] = {}
        for line in text.splitlines():
            if ":" not in line:
                continue
            key, value = line.split(":", 1)
            result[key.strip()] = value.strip()
        return result

    def status(self, vmid: int) -> str:
        text = self.command(["qm", "status", str(vmid)])
        return text.strip().split()[-1]

    def require_stopped(self, vmid: int) -> None:
        status = self.status(vmid)
        if status != "stopped":
            raise RuntimeError(f"VM {vmid} must be stopped, current status={status}")

    def stop(self, vmid: int, *, timeout: int = 120) -> None:
        if self.status(vmid) == "stopped":
            return
        self.command(["qm", "shutdown", str(vmid), "--timeout", str(timeout)], timeout=timeout + 30)
        self.require_stopped(vmid)

    def start(self, vmid: int) -> None:
        if self.status(vmid) == "running":
            return
        self.command(["qm", "start", str(vmid)])

    def mkdir(self, path: str) -> None:
        self.command(["mkdir", "-p", path])

    def remove(self, path: str) -> None:
        self.command(["rm", "-f", path])

    def set_network(self, vmid: int, net_key: str, value: str) -> None:
        self.command(["qm", "set", str(vmid), f"--{net_key}", value])

    @staticmethod
    def with_bridge(net_value: str, bridge: str) -> str:
        parts = [x for x in net_value.split(",") if not x.startswith("bridge=")]
        parts.append(f"bridge={bridge}")
        return ",".join(parts)

    def import_disk(self, vmid: int, source_path: str, storage: str) -> str:
        before = self.config(vmid)
        before_unused = {k for k in before if k.startswith("unused")}
        self.command(["qm", "disk", "import", str(vmid), source_path, storage], timeout=24 * 3600)
        cfg = self.config(vmid)
        unused = [(key, value) for key, value in cfg.items() if key.startswith("unused") and key not in before_unused]
        if len(unused) != 1:
            raise RuntimeError(f"expected exactly one new unused disk after import, found {unused}")
        return unused[0][1]

    def create_destination(
        self,
        *,
        vmid: int,
        name: str,
        generation: int,
        cores: int,
        memory_mb: int,
        test_bridge: str,
        mac_address: str | None = None,
        nic_model: str = "e1000",
        efi_storage: str | None = None,
    ) -> None:
        if generation == 2:
            machine = "q35"
            bios = "ovmf"
        else:
            machine = "pc"
            bios = "seabios"
        net = nic_model
        if mac_address:
            net += f"={mac_address}"
        net += f",bridge={test_bridge}"
        self.command(
            [
                "qm", "create", str(vmid),
                "--name", name,
                "--machine", machine,
                "--bios", bios,
                "--cores", str(cores),
                "--memory", str(memory_mb),
                "--scsihw", "virtio-scsi-single",
                "--net0", net,
                "--agent", "1",
                "--onboot", "0",
            ]
        )
        if generation == 2:
            if not efi_storage:
                raise ValueError("generation 2 destination requires efi_storage")
            self.command(
                ["qm", "set", str(vmid), "--efidisk0", f"{efi_storage}:0,efitype=4m,pre-enrolled-keys=1"]
            )

    def attach_disk(self, vmid: int, slot: str, volume: str) -> None:
        self.command(["qm", "set", str(vmid), f"--{slot}", volume])

    def set_boot_order(self, vmid: int, slot: str) -> None:
        self.command(["qm", "set", str(vmid), "--boot", f"order={slot}"])

    def destroy(self, vmid: int) -> None:
        if self.status(vmid) == "running":
            self.stop(vmid)
        self.command(["qm", "destroy", str(vmid), "--purge", "1"])

    def storage_path(self, volume: str) -> str:
        return self.command(["pvesm", "path", volume]).strip()

    def copy_to_host(self, local_path: str | Path, remote_path: str) -> None:
        source = str(local_path)
        target = f"{self.user}@{self.host}:{remote_path}"
        if shutil.which("rsync"):
            ssh_parts = self._ssh_base()
            ssh_command = " ".join(shlex.quote(x) for x in ssh_parts)
            run(
                ["rsync", "--partial", "--inplace", "--human-readable", "--progress", "-e", ssh_command, source, target],
                timeout=24 * 3600,
            )
            return
        argv = ["scp"]
        if self.identity_file:
            argv += ["-i", self.identity_file]
        argv += ["-o", f"StrictHostKeyChecking={self.strict_host_key_checking}", source, target]
        run(argv, timeout=24 * 3600)

    def _rbd_map_script(self, volume: str) -> str:
        if ":" not in volume:
            raise ValueError(f"invalid Proxmox volume ID: {volume}")
        storage, image = volume.split(":", 1)
        # pvesm path may already resolve to an existing block device. Otherwise,
        # use the storage's own Ceph pool/namespace configuration.
        return f"""
set -euo pipefail
VOL={shlex.quote(volume)}
STORAGE={shlex.quote(storage)}
IMAGE={shlex.quote(image)}
PATH_VALUE=$(pvesm path "$VOL" 2>/dev/null || true)
if [ -n "$PATH_VALUE" ] && [ -b "$PATH_VALUE" ]; then
    printf 'EXISTING\\t%s\\n' "$PATH_VALUE"
    exit 0
fi
CFG=$(pvesm config "$STORAGE")
TYPE=$(printf '%s\\n' "$CFG" | awk 'NR==1 {{gsub(":", "", $1); print $1}}')
[ "$TYPE" = "rbd" ] || {{ echo "storage $STORAGE is not an already-addressable block device and is not RBD" >&2; exit 40; }}
POOL=$(printf '%s\\n' "$CFG" | awk '$1=="pool" {{print $2; exit}}')
NAMESPACE=$(printf '%s\\n' "$CFG" | awk '$1=="namespace" {{print $2; exit}}')
[ -n "$POOL" ] || POOL=rbd
ARGS=(map "$IMAGE" -p "$POOL")
if [ -n "$NAMESPACE" ]; then ARGS+=(--namespace "$NAMESPACE"); fi
DEVICE=$(rbd "${{ARGS[@]}}")
printf 'CREATED\\t%s\\n' "$DEVICE"
"""

    def map_volume(self, volume: str) -> tuple[str, bool]:
        line = self.shell(self._rbd_map_script(volume)).strip().splitlines()[-1]
        mode, device = line.split("\t", 1)
        if mode not in {"EXISTING", "CREATED"}:
            raise RuntimeError(f"unexpected volume mapping response: {line}")
        return device, mode == "CREATED"

    def unmap_device(self, device: str) -> None:
        if device.startswith("/dev/rbd"):
            self.command(["rbd", "unmap", device])

    def apply_delta_to_volume(
        self,
        *,
        vmid: int,
        volume: str,
        metadata_path: str | Path,
        payload_path: str | Path,
        remote_script_path: str | Path,
        work_root: str = "/var/lib/vz/hv2pve-delta",
    ) -> str:
        self.require_stopped(vmid)
        remote_dir = f"{work_root.rstrip('/')}/{vmid}"
        self.mkdir(remote_dir)
        remote_meta = f"{remote_dir}/delta.json"
        remote_payload = f"{remote_dir}/delta.bin"
        remote_script = f"{remote_dir}/remote_apply_delta.py"
        self.copy_to_host(metadata_path, remote_meta)
        self.copy_to_host(payload_path, remote_payload)
        self.copy_to_host(remote_script_path, remote_script)

        device, created_mapping = self.map_volume(volume)
        try:
            return self.command(
                ["python3", remote_script, "--metadata", remote_meta, "--payload", remote_payload, "--target", device],
                timeout=24 * 3600,
            )
        finally:
            if created_mapping:
                try:
                    self.unmap_device(device)
                except Exception:
                    pass
            self.remove(remote_meta)
            self.remove(remote_payload)
            self.remove(remote_script)
