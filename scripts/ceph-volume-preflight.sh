#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ceph-volume-preflight.sh <vmid> <disk-slot>

Example:
  PVE_HOST=10.20.99.37 \
  PVE_IDENTITY_FILE=$HOME/.ssh/hv2pve_pve \
  ./scripts/ceph-volume-preflight.sh 104 scsi0

The target VM must be stopped. This script performs read-only inspection only.
EOF
}

if [ "$#" -ne 2 ]; then
  usage >&2
  exit 2
fi

VMID="$1"
SLOT="$2"
PVE_HOST="${PVE_HOST:-10.20.99.37}"
PVE_USER="${PVE_USER:-root}"
PVE_IDENTITY_FILE="${PVE_IDENTITY_FILE:-$HOME/.ssh/hv2pve_pve}"

case "$VMID" in
  ''|*[!0-9]*) echo "ERROR: VMID must be numeric" >&2; exit 2 ;;
esac

case "$SLOT" in
  scsi[0-9]*|sata[0-9]*|virtio[0-9]*|ide[0-9]*) ;;
  *) echo "ERROR: unsupported disk slot '$SLOT'" >&2; exit 2 ;;
esac

ssh_args=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
)
if [ -f "$PVE_IDENTITY_FILE" ]; then
  ssh_args+=( -i "$PVE_IDENTITY_FILE" )
fi

ssh "${ssh_args[@]}" "$PVE_USER@$PVE_HOST" bash -s -- "$VMID" "$SLOT" <<'REMOTE'
set -euo pipefail

VMID="$1"
SLOT="$2"

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 3
}
pass() {
  printf '[PASS] %s\n' "$*"
}

command -v qm >/dev/null || fail 'qm is missing'
command -v pvesm >/dev/null || fail 'pvesm is missing'
command -v rbd >/dev/null || fail 'rbd is missing'

status=$(qm status "$VMID" 2>/dev/null | awk '{print $2}') || fail "VM $VMID does not exist"
[ "$status" = 'stopped' ] || fail "VM $VMID must be stopped for delta validation; status=$status"
pass "VM $VMID is stopped"

mapfile -t lines < <(qm config "$VMID" | grep -E "^${SLOT}:" || true)
[ "${#lines[@]}" -eq 1 ] || fail "expected exactly one ${SLOT} entry, found ${#lines[@]}"
line="${lines[0]}"
value="${line#*: }"
volume="${value%%,*}"

case "$volume" in
  *:*) ;;
  *) fail "could not parse Proxmox volume ID from: $line" ;;
esac

storage="${volume%%:*}"
image="${volume#*:}"
pass "${SLOT} resolves to ${volume}"

cfg=$(pvesm config "$storage") || fail "unable to read storage config for $storage"
type=$(printf '%s\n' "$cfg" | awk 'NR==1 {gsub(":", "", $1); print $1}')
[ "$type" = 'rbd' ] || fail "storage $storage is type '$type', not rbd"
pass "storage $storage is RBD"

pool=$(printf '%s\n' "$cfg" | awk '$1=="pool" {print $2; exit}')
namespace=$(printf '%s\n' "$cfg" | awk '$1=="namespace" {print $2; exit}')
[ -n "$pool" ] || fail "RBD pool is not explicit in pvesm config for $storage"

path_value=$(pvesm path "$volume" 2>/dev/null || true)
pass "pvesm path: ${path_value:-<not directly mapped>}"

rbd_args=(info "$image" -p "$pool")
if [ -n "$namespace" ]; then
  rbd_args+=(--namespace "$namespace")
fi
rbd_info=$(rbd "${rbd_args[@]}" 2>&1) || fail "rbd info failed: $rbd_info"
pass "rbd info succeeded for pool=$pool namespace=${namespace:-<none>} image=$image"

size_line=$(printf '%s\n' "$rbd_info" | grep -m1 -E 'size [0-9]|size [0-9.]+ [KMGT]iB' || true)
features_line=$(printf '%s\n' "$rbd_info" | grep -m1 'features:' || true)

printf '\n============================================================\n'
printf ' hv2pve Ceph/RBD preflight\n'
printf '============================================================\n'
printf 'VMID:       %s\n' "$VMID"
printf 'Disk slot:  %s\n' "$SLOT"
printf 'Volume:     %s\n' "$volume"
printf 'Storage:    %s\n' "$storage"
printf 'Pool:       %s\n' "$pool"
printf 'Namespace:  %s\n' "${namespace:-<none>}"
printf 'Image:      %s\n' "$image"
printf 'Path:       %s\n' "${path_value:-<not directly mapped>}"
printf 'Size:       %s\n' "${size_line:-<see rbd info>}"
printf 'Features:   %s\n' "${features_line:-<see rbd info>}"
printf 'Mutation:   none\n'
printf '============================================================\n'
REMOTE
