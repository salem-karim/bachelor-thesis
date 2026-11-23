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

export PATH="$WORK_DIR:$PATH"
grep -qxF "export PATH=\"$WORK_DIR:\$PATH\"" ~/.bashrc ||
    echo "export PATH=\"$WORK_DIR:\$PATH\"" >> ~/.bashrc

if [[ -n "${CERT_FILE:-}" ]]; then
    export NODE_EXTRA_CA_CERTS="$CERT_FILE"
    grep -qxF "export NODE_EXTRA_CA_CERTS=\"$CERT_FILE\"" ~/.bashrc ||
        echo "export NODE_EXTRA_CA_CERTS=\"$CERT_FILE\"" >> ~/.bashrc
fi

export SERVICE_CHOICE="$choice"
grep -qxF "export SERVICE_CHOICE=$choice" ~/.bashrc ||
    echo "export SERVICE_CHOICE=$choice" >> ~/.bashrc

if [[ "$choice" == "1" ]]; then
    grep -qxF 'export COMPOSE_FILE=""' ~/.bashrc ||
        echo 'export COMPOSE_FILE=""' >> ~/.bashrc
    export COMPOSE_FILE=""
else
    COMPOSE_FILE="$WORK_DIR/compose.yml"
    export COMPOSE_FILE
    grep -qxF "export COMPOSE_FILE=\"$COMPOSE_FILE\"" ~/.bashrc ||
        echo "export COMPOSE_FILE=\"$COMPOSE_FILE\"" >> ~/.bashrc
fi

"$WORK_DIR/bw" config server "$SERVER_URL"

echo ""
read -r -p "Use 2FA/API-key login with this Bitwarden CLI? [y/N]: " use_2fa
if [[ "${use_2fa,,}" == "y" || "${use_2fa,,}" == "yes" ]]; then
    read -r -p "Enter BW_CLIENTID: " bw_client_id
    read -r -p "Enter BW_CLIENTSECRET: " bw_client_secret
    read -rsp "Enter the Bitwarden account master password: " bw_password
    echo ""

    if [[ -z "$bw_client_id" || -z "$bw_client_secret" || -z "$bw_password" ]]; then
        echo "ERROR: 2FA/API-key configuration requires a client ID, client secret, and master password." >&2
        exit 1
    fi

    sed -i '/^export BW_CLIENTID=/d; /^export BW_CLIENTSECRET=/d; /^export BW_PASSWORD=/d' ~/.bashrc
    grep -qxF "export BW_CLIENTID=\"$bw_client_id\"" ~/.bashrc ||
        echo "export BW_CLIENTID=\"$bw_client_id\"" >> ~/.bashrc
    grep -qxF "export BW_CLIENTSECRET=\"$bw_client_secret\"" ~/.bashrc ||
        echo "export BW_CLIENTSECRET=\"$bw_client_secret\"" >> ~/.bashrc
    grep -qxF "export BW_PASSWORD=\"$bw_password\"" ~/.bashrc ||
        echo "export BW_PASSWORD=\"$bw_password\"" >> ~/.bashrc

    export BW_CLIENTID="$bw_client_id"
    export BW_CLIENTSECRET="$bw_client_secret"
    export BW_PASSWORD="$bw_password"

    bw logout >/dev/null 2>&1 || true
    if ! bw login --apikey; then
        echo "ERROR: Bitwarden API-key login failed." >&2
        exit 1
    fi
    if ! BW_SESSION="$(bw unlock --passwordenv BW_PASSWORD --raw)"; then
        echo "ERROR: Bitwarden unlock failed with the configured API key and master password." >&2
        exit 1
    fi
    export BW_SESSION
    echo "Bitwarden API-key login and unlock succeeded."
else
    sed -i '/^export BW_CLIENTID=/d; /^export BW_CLIENTSECRET=/d; /^export BW_PASSWORD=/d' ~/.bashrc
    unset BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD
fi
