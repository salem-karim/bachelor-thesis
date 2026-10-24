#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

if [[ -z "${HOST_USER:-}" || -z "${HOST_DOMAIN:-}" ]]; then
    echo "Please run this script with HOST_USER and HOST_DOMAIN set." >&2
    exit 1
fi

WORK_DIR="${WORK_DIR:-$HOME/vaultwarden}"
mkdir -p "$WORK_DIR"
cp "$REPO_ROOT/lab/vaultwarden/compose.yml" "$WORK_DIR/compose.yml"
cp "$REPO_ROOT/lab/vaultwarden/Caddyfile" "$WORK_DIR/Caddyfile"

# Enable binding to Ports lower than 1024 (eg. 80 or 443)
sudo setcap cap_net_bind_service=ep /usr/bin/rootlesskit
systemctl --user restart docker

cd "$WORK_DIR" || exit 1
docker compose down --remove-orphans
docker compose up -d

sleep 5

CERT_FILE="$WORK_DIR/caddy-data/caddy/pki/authorities/local/root.crt"
scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/caddy-root.crt"

# Set environment variables to run the scripts later
echo "export COMPOSE_FILE=\"$WORK_DIR/compose.yml\"" >> ~/.bashrc
echo "export SERVICE_CHOICE=2" >> ~/.bashrc

# Then update your trusted certificates and add a DNS Record with the VMs IP
# This is the example on a Ubuntu Host, find the VMs IP using `ip a`
# echo '192.168.XXX.XXX vaultwarden.lab' | sudo tee -a /etc/hosts
#
# # Add the Caddy Certificate to the Hosts trusted ones
# sudo cp /tmp/caddy-root.crt /usr/local/share/ca-certificates/caddy-root.crt
# sudo update-ca-certificates

echo "Now create an account manually, after getting the Caddy Certificates from the VM"
