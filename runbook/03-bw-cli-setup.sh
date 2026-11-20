#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/scripts/utils.sh"

require_command curl wget unzip jq || exit 1
ensure_sudo_session || exit 1

choice="$(prompt_service_choice 2 1 2)"

case "$choice" in
    1)
        SERVER_URL="https://bitwarden.lab"
        WORK_DIR="/opt/bitwarden"
        CERT_FILE="$WORK_DIR/bwdata/ssl/self/bitwarden.lab/certificate.crt"
        echo "Configuring Bitwarden..."

        echo '127.0.0.1 bitwarden.lab' | sudo tee -a /etc/hosts >/dev/null
        ;;
    2)
        SERVER_URL="https://vaultwarden.lab"
        WORK_DIR="$HOME/vaultwarden"
        CERT_FILE="$WORK_DIR/caddy-data/caddy/pki/authorities/local/root.crt"
        echo "Configuring Vaultwarden..."

        echo '127.0.0.1 vaultwarden.lab' | sudo tee -a /etc/hosts >/dev/null
        ;;
    *)
        echo "Invalid choice. Exiting." >&2
        exit 1
        ;;
esac

mkdir -p "$WORK_DIR"

sudo apt update -qq
sudo apt install -y unzip

wget -e background=off \
    --output-document=/tmp/bw.zip \
    "https://vault.bitwarden.com/download/?app=cli&platform=linux"

unzip -o /tmp/bw.zip -d "$WORK_DIR"

echo "export PATH=\"$WORK_DIR:\$PATH\"" >> ~/.bashrc

if [[ -n "${CERT_FILE:-}" ]]; then
    echo "export NODE_EXTRA_CA_CERTS=\"$CERT_FILE\"" >> ~/.bashrc
    export NODE_EXTRA_CA_CERTS="$CERT_FILE"
fi

source "$HOME/.bashrc"

bw config server "$SERVER_URL"
