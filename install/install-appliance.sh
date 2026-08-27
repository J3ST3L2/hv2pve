#!/usr/bin/env bash
set -euo pipefail

PREFIX="${PREFIX:-/opt/hv2pve}"
WORKSPACE="${WORKSPACE:-/migrate}"
USER_NAME="${SUDO_USER:-${USER:-ubuntu}}"

echo "Installing hv2pve controller prerequisites..."
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  python3 python3-venv python3-pip \
  qemu-utils libguestfs-tools virt-v2v nbdkit \
  rsync jq openssh-client qemu-guest-agent

sudo systemctl enable --now qemu-guest-agent || true

sudo mkdir -p "$PREFIX" "$WORKSPACE"/{incoming,sync,state,logs,converted,tmp}
sudo rsync -a --delete \
  --exclude '.git' --exclude '__pycache__' \
  ./ "$PREFIX/"
sudo chown -R "$USER_NAME":"$USER_NAME" "$WORKSPACE"

sudo tee /usr/local/bin/hv2pve >/dev/null <<WRAPPER
#!/usr/bin/env bash
exec python3 "$PREFIX/controller/hv2pve.py" "\$@"
WRAPPER
sudo chmod 0755 /usr/local/bin/hv2pve

echo "Installed hv2pve into $PREFIX"
echo "Workspace: $WORKSPACE"
hv2pve --help >/dev/null
