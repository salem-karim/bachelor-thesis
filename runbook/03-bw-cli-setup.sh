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
        # TODO: Validate and tune this branch for self-hosted Bitwarden VM setup.
        SERVER_URL="${BW_SERVER_URL:-}"
        if [[ -z "$SERVER_URL" ]]; then
            echo "ERROR: Set BW_SERVER_URL for self-hosted Bitwarden VM (example: https://bitwarden.lab)." >&2
            exit 1
        fi
        WORK_DIR="$HOME/bitwarden"
        echo "Configuring Bitwarden..."
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
sudo apt install -y unzip jq curl

wget -e background=off \
    --output-document=/tmp/bw.zip \
    "https://vault.bitwarden.com/download/?app=cli&platform=linux"

unzip -o /tmp/bw.zip -d "$WORK_DIR"

echo "export PATH=\"$WORK_DIR:\$PATH\"" >> ~/.bashrc

if [[ -n "${CERT_FILE:-}" ]]; then
    echo "export NODE_EXTRA_CA_CERTS=\"$CERT_FILE\"" >> ~/.bashrc
    export NODE_EXTRA_CA_CERTS="$CERT_FILE"
fi

export PATH="$WORK_DIR:$PATH"

bw config server "$SERVER_URL"

session_key="$(bw login --raw)" || exit 1
export BW_SESSION="$session_key"

bw get template item \
  | jq --arg username 'TestName' \
       --arg password 'Te5tPa_55w0rd' \
       '.name = "Test Login"
        | .login = {"username": $username, "password": $password}' \
  | bw encode \
  | bw create item
