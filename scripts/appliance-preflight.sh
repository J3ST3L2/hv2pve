#!/usr/bin/env bash
set -u

PVE_HOST="${PVE_HOST:-10.20.99.37}"
PVE_USER="${PVE_USER:-root}"
PVE_IDENTITY_FILE="${PVE_IDENTITY_FILE:-$HOME/.ssh/hv2pve_pve}"
WORKSPACE="${HV2PVE_WORKSPACE:-/migrate}"
REPO_DIR="${HV2PVE_REPO_DIR:-/opt/hv2pve}"

failures=0
warnings=0

pass() { printf '[PASS] %-28s %s\n' "$1" "$2"; }
warn() { printf '[WARN] %-28s %s\n' "$1" "$2"; warnings=$((warnings + 1)); }
fail() { printf '[FAIL] %-28s %s\n' "$1" "$2"; failures=$((failures + 1)); }

printf '============================================================\n'
printf ' hv2pve appliance preflight\n'
printf '============================================================\n'
printf 'PVE host:  %s@%s\n' "$PVE_USER" "$PVE_HOST"
printf 'Workspace: %s\n' "$WORKSPACE"
printf 'Repo:      %s\n' "$REPO_DIR"
printf '\n'

if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    pass 'Operating system' "${PRETTY_NAME:-unknown}"
else
    fail 'Operating system' '/etc/os-release is missing'
fi

required_tools=(
    qemu-img
    virt-v2v
    virt-filesystems
    guestfish
    nbdkit
    rsync
    jq
    ssh
    scp
    python3
)

for tool in "${required_tools[@]}"; do
    if path=$(command -v "$tool" 2>/dev/null); then
        pass "tool:$tool" "$path"
    else
        fail "tool:$tool" 'missing'
    fi
done

if systemctl is-enabled qemu-guest-agent >/dev/null 2>&1; then
    if systemctl is-active qemu-guest-agent >/dev/null 2>&1; then
        pass 'QEMU guest agent' 'enabled and active'
    else
        warn 'QEMU guest agent' 'enabled but not active'
    fi
else
    warn 'QEMU guest agent' 'not enabled'
fi

if mountpoint -q "$WORKSPACE"; then
    source_dev=$(findmnt -n -o SOURCE "$WORKSPACE" 2>/dev/null || true)
    fstype=$(findmnt -n -o FSTYPE "$WORKSPACE" 2>/dev/null || true)
    pass 'Migration workspace' "$WORKSPACE mounted from $source_dev ($fstype)"

    avail_bytes=$(df -PB1 "$WORKSPACE" | awk 'NR==2 {print $4}')
    if [ -n "$avail_bytes" ] && [ "$avail_bytes" -gt $((20 * 1024 * 1024 * 1024)) ]; then
        avail_gib=$((avail_bytes / 1024 / 1024 / 1024))
        pass 'Workspace free space' "${avail_gib} GiB available"
    else
        warn 'Workspace free space' 'less than 20 GiB available; larger migrations may require expansion'
    fi
else
    fail 'Migration workspace' "$WORKSPACE is not a mountpoint"
fi

for dir in incoming working converted exports deltas state logs; do
    if [ -d "$WORKSPACE/$dir" ]; then
        pass "workspace:$dir" "$WORKSPACE/$dir"
    else
        warn "workspace:$dir" 'directory missing'
    fi
done

if [ -d "$REPO_DIR/.git" ]; then
    branch=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || true)
    commit=$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)
    pass 'hv2pve repository' "$REPO_DIR branch=${branch:-detached} commit=${commit:-unknown}"

    if python3 -m py_compile "$REPO_DIR"/controller/*.py >/dev/null 2>&1; then
        pass 'Controller compile' 'Python sources compile'
    else
        fail 'Controller compile' 'Python source compilation failed'
    fi

    if python3 -m unittest discover -s "$REPO_DIR/tests" >/dev/null 2>&1; then
        pass 'Controller unit tests' 'passed'
    else
        fail 'Controller unit tests' 'failed'
    fi
else
    warn 'hv2pve repository' "$REPO_DIR is not deployed yet"
fi

ssh_args=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new)
if [ -f "$PVE_IDENTITY_FILE" ]; then
    ssh_args+=(-i "$PVE_IDENTITY_FILE")
    pass 'Proxmox SSH identity' "$PVE_IDENTITY_FILE"
else
    warn 'Proxmox SSH identity' "$PVE_IDENTITY_FILE is missing; trying default SSH identities"
fi

if ssh "${ssh_args[@]}" "$PVE_USER@$PVE_HOST" 'command -v qm >/dev/null && command -v pvesh >/dev/null && command -v rbd >/dev/null' >/dev/null 2>&1; then
    pass 'Proxmox SSH' 'qm, pvesh, and rbd reachable'

    storage_json=$(ssh "${ssh_args[@]}" "$PVE_USER@$PVE_HOST" 'pvesh get /nodes/$(hostname -s)/storage --output-format json' 2>/dev/null || true)
    if printf '%s' "$storage_json" | jq -e '.[] | select(.storage == "ceph-vm" and .active == 1)' >/dev/null 2>&1; then
        pass 'ceph-vm storage' 'active on target node'
    else
        warn 'ceph-vm storage' 'could not confirm active ceph-vm storage through pvesh'
    fi

    vnets_json=$(ssh "${ssh_args[@]}" "$PVE_USER@$PVE_HOST" 'pvesh get /cluster/sdn/vnets --output-format json' 2>/dev/null || true)
    if [ -n "$vnets_json" ]; then
        pass 'Proxmox SDN' "$(printf '%s' "$vnets_json" | jq 'length') VNet(s) discovered"
        if printf '%s' "$vnets_json" | jq -e '.[] | select(.vnet == "vlan60")' >/dev/null 2>&1; then
            pass 'Production VNet example' 'vlan60 exists'
        fi
    else
        warn 'Proxmox SDN' 'unable to enumerate VNets'
    fi
else
    warn 'Proxmox SSH' "unable to run noninteractive preflight against $PVE_USER@$PVE_HOST"
fi

printf '\n============================================================\n'
printf ' failures: %d\n' "$failures"
printf ' warnings: %d\n' "$warnings"
printf '============================================================\n'

if [ "$failures" -ne 0 ]; then
    exit 2
fi

exit 0
