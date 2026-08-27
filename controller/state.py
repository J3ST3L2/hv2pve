from __future__ import annotations

import json
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


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
    "ROLLED_BACK",
    "CLOSED",
}


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


@dataclass
class MigrationState:
    migration_id: str
    phase: str = "NEW"
    source: dict[str, Any] = field(default_factory=dict)
    baseline: dict[str, Any] = field(default_factory=dict)
    destination: dict[str, Any] = field(default_factory=dict)
    sync: dict[str, Any] = field(default_factory=lambda: {
        "mode": "baseline-only",
        "rct_implemented": False,
        "last_successful_sync_utc": None,
    })
    validation: dict[str, Any] = field(default_factory=dict)
    created_at_utc: str = field(default_factory=utc_now)
    updated_at_utc: str = field(default_factory=utc_now)
    schema_version: int = 1

    def validate(self) -> None:
        if not self.migration_id:
            raise ValueError("migration_id is required")
        if self.phase not in VALID_PHASES:
            raise ValueError(f"invalid migration phase: {self.phase}")

        if self.phase in {"SEEDED", "TESTED", "SYNCING", "CUTOVER_READY", "CUTOVER_IN_PROGRESS", "CUTOVER_COMPLETE"}:
            if not self.destination.get("proxmox_vmid"):
                raise ValueError(f"phase {self.phase} requires destination.proxmox_vmid")

        if self.phase in {"TESTED", "SYNCING", "CUTOVER_READY", "CUTOVER_IN_PROGRESS", "CUTOVER_COMPLETE"}:
            if not self.destination.get("tested"):
                raise ValueError(f"phase {self.phase} requires an isolated destination test")

    def set_phase(self, phase: str) -> None:
        if phase not in VALID_PHASES:
            raise ValueError(f"invalid migration phase: {phase}")
        self.phase = phase
        self.updated_at_utc = utc_now()
        self.validate()

    def to_dict(self) -> dict[str, Any]:
        self.updated_at_utc = utc_now()
        payload = asdict(self)
        self.validate()
        return payload

    def save(self, path: str | Path) -> None:
        target = Path(path)
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(self.to_dict(), indent=2) + "\n", encoding="utf-8")

    @classmethod
    def load(cls, path: str | Path) -> "MigrationState":
        payload = json.loads(Path(path).read_text(encoding="utf-8-sig"))
        state = cls(
            migration_id=payload["migration_id"],
            phase=payload.get("phase", "NEW"),
            source=payload.get("source", {}),
            baseline=payload.get("baseline", {}),
            destination=payload.get("destination", {}),
            sync=payload.get("sync", {}),
            validation=payload.get("validation", {}),
            created_at_utc=payload.get("created_at_utc", utc_now()),
            updated_at_utc=payload.get("updated_at_utc", utc_now()),
            schema_version=payload.get("schema_version", 1),
        )
        state.validate()
        return state

    @classmethod
    def from_hyperv_baseline(cls, payload: dict[str, Any]) -> "MigrationState":
        state = cls(
            migration_id=payload["migration_id"],
            phase=payload.get("phase", "BASELINE_READY"),
            source=payload.get("source", {}),
            baseline=payload.get("baseline", {}),
            destination=payload.get("destination", {}),
            sync=payload.get("sync", {}),
        )
        state.validate()
        return state
