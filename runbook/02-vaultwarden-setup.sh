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

cd "$WORK_DIR" || exit 1
docker compose down --remove-orphans
docker compose up -d

sleep 5

CERT_FILE="$WORK_DIR/caddy-data/caddy/pki/authorities/local/root.crt"
scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/caddy-root.crt"

# Set environment variables to run the scripts later
echo "export COMPOSE_FILE=\"$WORK_DIR/compose.yml\"" >> ~/.bashrc
echo "export SERVICE_CHOICE=2" >> ~/.bashrc

echo ""
echo "Manual configuration required:"
echo ""
echo "1. Add a DNS entry on your Ubuntu host."
echo "   Find your VM's IP address using: ip a"
echo "   Run (replace the IP with your VM's IP):"
echo "   echo '192.168.XXX.XXX vaultwarden.lab' | sudo tee -a /etc/hosts"
echo ""
echo "2. Add the Vaultwarden certificate to Ubuntu's trusted certificates:"
echo "   sudo cp /tmp/vaultwarden-certificate.crt /usr/local/share/ca-certificates/vaultwarden-certificate.crt"
echo "   sudo update-ca-certificates"
echo ""

echo "Now create an account manually, after getting the Caddy Certificates from the VM"
