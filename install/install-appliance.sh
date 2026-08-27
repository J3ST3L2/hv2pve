#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/opt/hv2pve}"
WORKSPACE="${WORKSPACE:-/migrate}"
USER_NAME="${SUDO_USER:-${USER:-ubuntu}}"

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  SUDO=""
else
  SUDO="sudo"
fi

echo "Installing hv2pve controller prerequisites..."
$SUDO apt-get update
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip \
  qemu-utils libguestfs-tools virt-v2v nbdkit libvirt-clients \
  rsync jq curl wget unzip git openssh-client qemu-guest-agent \
  cloud-guest-utils

$SUDO systemctl enable --now qemu-guest-agent || true

if ! mountpoint -q "$WORKSPACE"; then
  echo "WARNING: $WORKSPACE is not a separate mountpoint." >&2
  echo "The Ansible appliance playbook can safely format a blank work disk and mount it here." >&2
fi

$SUDO mkdir -p "$PREFIX"
$SUDO mkdir -p \
  "$WORKSPACE/incoming" \
  "$WORKSPACE/working" \
  "$WORKSPACE/converted" \
  "$WORKSPACE/exports" \
  "$WORKSPACE/deltas" \
  "$WORKSPACE/sync" \
  "$WORKSPACE/state" \
  "$WORKSPACE/logs" \
  "$WORKSPACE/tmp"

$SUDO rsync -a --delete \
  --exclude '.git' \
  --exclude '__pycache__' \
  --exclude '.pytest_cache' \
  ./ "$PREFIX/"

$SUDO chown -R "$USER_NAME":"$USER_NAME" "$WORKSPACE"

$SUDO tee /usr/local/bin/hv2pve >/dev/null <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
exec python3 "$PREFIX/controller/hv2pve.py" "\$@"
WRAPPER
$SUDO chmod 0755 /usr/local/bin/hv2pve

echo
printf '%-24s %s\n' "Installed:" "$PREFIX"
printf '%-24s %s\n' "Workspace:" "$WORKSPACE"
printf '%-24s %s\n' "CLI:" "/usr/local/bin/hv2pve"

echo
for tool in qemu-img virt-v2v virt-filesystems guestfish nbdkit rsync jq; do
  printf '%-24s %s\n' "$tool" "$(command -v "$tool")"
done

python3 -m py_compile "$PREFIX"/controller/*.py
python3 -m unittest discover -s "$PREFIX/tests" -v
hv2pve --help >/dev/null

echo
if [ -x "$PREFIX/scripts/appliance-preflight.sh" ]; then
  echo "Next validation command:"
  echo "  $PREFIX/scripts/appliance-preflight.sh"
fi
