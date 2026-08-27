from __future__ import annotations

from state import MigrationState


class SafetyError(RuntimeError):
    pass


def require_isolated_test(state: MigrationState) -> None:
    if not state.destination.get("tested"):
        raise SafetyError("destination has not passed isolated test boot")
    if not state.validation.get("isolated_boot_verified"):
        raise SafetyError("isolated boot validation flag is not set")


def require_cutover_ready(state: MigrationState) -> None:
    require_isolated_test(state)
    if not state.validation.get("last_sync_verified"):
        raise SafetyError("latest synchronization has not been verified")
    if not state.sync.get("authoritative_reference_point"):
        raise SafetyError("no authoritative Hyper-V reference point is recorded")
    if state.destination.get("powered_on"):
        raise SafetyError("destination must be powered off before cutover begins")


def require_production_network_safe(state: MigrationState, source_running: bool) -> None:
    if source_running and state.destination.get("powered_on"):
        raise SafetyError("source and destination cannot both be live on production identity")
