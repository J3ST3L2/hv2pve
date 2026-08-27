from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 2

VALID_PHASES = {
    "NEW",
    "DISCOVERED",
    "BASELINE_READY",
    "SEEDED",
    "TESTED",
    "SYNCING",
    "CUTOVER_READY",
    "CUTOVER_IN_PROGRESS",
    "CUTOVER_COMPLETE",
    "ROLLBACK_IN_PROGRESS",
    "ROLLED_BACK",
    "CLOSED",
    "FAILED",
}

ALLOWED_TRANSITIONS: dict[str, set[str]] = {
    "NEW": {"DISCOVERED", "BASELINE_READY", "FAILED"},
    "DISCOVERED": {"BASELINE_READY", "FAILED"},
    "BASELINE_READY": {"SEEDED", "FAILED"},
    "SEEDED": {"TESTED", "FAILED"},
    "TESTED": {"SYNCING", "CUTOVER_READY", "FAILED"},
    "SYNCING": {"SYNCING", "CUTOVER_READY", "FAILED"},
    "CUTOVER_READY": {"SYNCING", "CUTOVER_IN_PROGRESS", "FAILED"},
    "CUTOVER_IN_PROGRESS": {"CUTOVER_COMPLETE", "ROLLBACK_IN_PROGRESS", "FAILED"},
    "CUTOVER_COMPLETE": {"ROLLBACK_IN_PROGRESS", "CLOSED", "FAILED"},
    "ROLLBACK_IN_PROGRESS": {"ROLLED_BACK", "FAILED"},
    "ROLLED_BACK": {"CLOSED"},
    "FAILED": {"DISCOVERED", "BASELINE_READY", "SEEDED", "TESTED", "SYNCING", "CUTOVER_READY", "ROLLBACK_IN_PROGRESS", "CLOSED"},
    "CLOSED": set(),
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _default_sync() -> dict[str, Any]:
    return {
        "mode": "reference-point-export",
        "rct_implemented": True,
        "native_rct_acceleration": False,
        "authoritative_reference_point": None,
        "pending_reference_point": None,
        "sequence": 0,
        "last_successful_sync_utc": None,
        "last_bundle": None,
        "disks": {},
    }


def _default_destination() -> dict[str, Any]:
    return {
        "proxmox_node": None,
        "proxmox_vmid": None,
        "production_vnet": None,
        "test_vnet": None,
        "tested": False,
        "powered_on": False,
        "disk_map": {},
    }


def _default_validation() -> dict[str, Any]:
    return {
        "baseline_verified": False,
        "isolated_boot_verified": False,
        "last_sync_verified": False,
        "network_identity_verified": False,
        "guest_boot_verified": False,
        "application_verified": False,
    }


def _default_cutover() -> dict[str, Any]:
    return {
        "authorized": False,
        "authorized_at_utc": None,
        "source_stopped_at_utc": None,
        "final_sync_completed_at_utc": None,
        "destination_started_at_utc": None,
        "rollback_deadline_utc": None,
        "destination_writes_possible": False,
    }


@dataclass
class MigrationState:
    migration_id: str
    phase: str = "NEW"
    source: dict[str, Any] = field(default_factory=dict)
    baseline: dict[str, Any] = field(default_factory=dict)
    destination: dict[str, Any] = field(default_factory=_default_destination)
    sync: dict[str, Any] = field(default_factory=_default_sync)
    validation: dict[str, Any] = field(default_factory=_default_validation)
    cutover: dict[str, Any] = field(default_factory=_default_cutover)
    history: list[dict[str, Any]] = field(default_factory=list)
    created_at_utc: str = field(default_factory=utc_now)
    updated_at_utc: str = field(default_factory=utc_now)
    schema_version: int = SCHEMA_VERSION

    def validate(self) -> None:
        if not self.migration_id:
            raise ValueError("migration_id is required")
        if self.phase not in VALID_PHASES:
            raise ValueError(f"invalid migration phase: {self.phase}")
        if self.schema_version > SCHEMA_VERSION:
            raise ValueError(
                f"state schema {self.schema_version} is newer than supported {SCHEMA_VERSION}"
            )

        if self.phase in {
            "SEEDED",
            "TESTED",
            "SYNCING",
            "CUTOVER_READY",
            "CUTOVER_IN_PROGRESS",
            "CUTOVER_COMPLETE",
            "ROLLBACK_IN_PROGRESS",
        }:
            if not self.destination.get("proxmox_vmid"):
                raise ValueError(f"phase {self.phase} requires destination.proxmox_vmid")

        if self.phase in {
            "TESTED",
            "SYNCING",
            "CUTOVER_READY",
            "CUTOVER_IN_PROGRESS",
            "CUTOVER_COMPLETE",
        }:
            if not self.destination.get("tested"):
                raise ValueError(f"phase {self.phase} requires an isolated destination test")

        if self.phase in {"CUTOVER_IN_PROGRESS", "CUTOVER_COMPLETE"}:
            if not self.cutover.get("authorized"):
                raise ValueError("cutover requires explicit authorization")

        if self.destination.get("tested") and not self.validation.get("isolated_boot_verified"):
            raise ValueError("destination.tested requires validation.isolated_boot_verified")

        prod = self.destination.get("production_vnet")
        test = self.destination.get("test_vnet")
        if prod and test and prod == test:
            raise ValueError("production_vnet and test_vnet must not be identical")

    def record_event(self, event: str, **details: Any) -> None:
        self.history.append({"at_utc": utc_now(), "event": event, "details": details})
        self.updated_at_utc = utc_now()

    def set_phase(self, phase: str, *, reason: str | None = None, force: bool = False) -> None:
        if phase not in VALID_PHASES:
            raise ValueError(f"invalid migration phase: {phase}")
        if not force and phase != self.phase and phase not in ALLOWED_TRANSITIONS[self.phase]:
            raise ValueError(f"illegal migration transition: {self.phase} -> {phase}")
        old = self.phase
        self.phase = phase
        self.updated_at_utc = utc_now()
        try:
            self.validate()
        except Exception:
            self.phase = old
            raise
        if old != phase:
            self.record_event("phase_changed", old=old, new=phase, reason=reason)

    def to_dict(self) -> dict[str, Any]:
        self.updated_at_utc = utc_now()
        self.schema_version = SCHEMA_VERSION
        self.validate()
        return asdict(self)

    def save(self, path: str | Path) -> None:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(self.to_dict(), indent=2, sort_keys=True) + "\n"
        fd, tmp_name = tempfile.mkstemp(prefix=f".{target.name}.", dir=str(target.parent))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp_name, target)
        finally:
            if os.path.exists(tmp_name):
                os.unlink(tmp_name)

    @classmethod
    def _normalize_payload(cls, payload: dict[str, Any]) -> dict[str, Any]:
        normalized = dict(payload)
        normalized.setdefault("destination", {})
        for key, value in _default_destination().items():
            normalized["destination"].setdefault(key, value)
        normalized.setdefault("sync", {})
        for key, value in _default_sync().items():
            normalized["sync"].setdefault(key, value)
        normalized.setdefault("validation", {})
        for key, value in _default_validation().items():
            normalized["validation"].setdefault(key, value)
        normalized.setdefault("cutover", {})
        for key, value in _default_cutover().items():
            normalized["cutover"].setdefault(key, value)
        normalized.setdefault("history", [])
        normalized["schema_version"] = min(
            int(normalized.get("schema_version", 1)), SCHEMA_VERSION
        )
        return normalized

    @classmethod
    def load(cls, path: str | Path) -> "MigrationState":
        payload = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        return cls.from_dict(payload)

    @classmethod
    def from_dict(cls, payload: dict[str, Any]) -> "MigrationState":
        p = cls._normalize_payload(payload)
        state = cls(
            migration_id=p["migration_id"],
            phase=p.get("phase", "NEW"),
            source=p.get("source", {}),
            baseline=p.get("baseline", {}),
            destination=p.get("destination", {}),
            sync=p.get("sync", {}),
            validation=p.get("validation", {}),
            cutover=p.get("cutover", {}),
            history=p.get("history", []),
            created_at_utc=p.get("created_at_utc", utc_now()),
            updated_at_utc=p.get("updated_at_utc", utc_now()),
            schema_version=SCHEMA_VERSION,
        )
        state.validate()
        return state

    @classmethod
    def from_hyperv_baseline(cls, payload: dict[str, Any]) -> "MigrationState":
        state = cls.from_dict(payload)
        if state.phase not in {"BASELINE_READY", "SEEDED", "TESTED", "SYNCING", "CUTOVER_READY"}:
            state.set_phase("BASELINE_READY", reason="Hyper-V baseline ingested", force=True)
        return state
