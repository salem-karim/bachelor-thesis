#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"

if [[ -z "${HOST_USER:-}" || -z "${HOST_DOMAIN:-}" ]]; then
    echo "Please run this script with HOST_USER and HOST_DOMAIN set." >&2
    exit 1
fi

WORK_DIR="${WORK_DIR:-$HOME/passbolt}"
mkdir -p "$WORK_DIR/certs"
cd "$WORK_DIR" || exit 1

echo "Installing Python MariaDB extraction dependency..."
sudo apt install -y python3-pymysql

if [[ ! -f "$WORK_DIR/certs/cert.pem" || ! -f "$WORK_DIR/certs/key.pem" ]]; then
    echo "Generating Passbolt self-signed certificate..."

    openssl req -newkey rsa:4096 -x509 -sha256 -days 730 -noenc -batch \
        -subj "/CN=passbolt.lab" \
        -addext "subjectAltName=DNS:passbolt.lab" \
        -out "$WORK_DIR/certs/cert.pem" \
        -keyout "$WORK_DIR/certs/key.pem"

    chmod 600 "$WORK_DIR/certs/key.pem"
    chmod 644 "$WORK_DIR/certs/cert.pem"
else
    echo "Existing Passbolt certificate found. Reusing it."
fi

if [[ ! -f "$WORK_DIR/compose.yml" ]]; then
    echo "Copying compose file to $WORK_DIR"
    cp "$REPO_ROOT/lab/passbolt/compose.yml" "$WORK_DIR/compose.yml"
else
    echo "Compose File already exists"
fi

docker compose down --remove-orphans
docker compose up -d

echo "Waiting for Passbolt container..."

for _ in {1..30}; do
    CONTAINER_ID=$(docker compose ps -q passbolt)

    if [[ -n "$CONTAINER_ID" ]]; then
        PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_ID")

        if [[ "$PID" != "0" ]]; then
            break
        fi
    fi

    sleep 2
done

if [[ -z "${PID:-}" || "$PID" == "0" ]]; then
    echo "Passbolt container failed to start." >&2
    exit 1
fi

# Map container UID/GID 33 to host UID/GID
map_id() {
    local container_id="$1"
    local map_file="$2"

    awk -v id="$container_id" '
        $1 <= id && id < $1 + $3 {
            print $2 + id - $1
            exit
        }
    ' "$map_file"
}

HOST_UID=$(map_id 33 "/proc/$PID/uid_map")
HOST_GID=$(map_id 33 "/proc/$PID/gid_map")

if [[ -z "$HOST_UID" || -z "$HOST_GID" ]]; then
    echo "Could not determine Docker UID/GID mapping." >&2
    exit 1
fi

echo "Container www-data (33:33) maps to host $HOST_UID:$HOST_GID"

# Apply ownership to private key
sudo chown "$HOST_UID:$HOST_GID" certs/key.pem
sudo chmod 400 certs/key.pem

# Certificate is public
chmod 644 certs/cert.pem

# Restart so nginx can load the certificate
docker compose restart passbolt

echo "Waiting for nginx..."

NGINX_READY=false

for _ in {1..30}; do
    if docker compose exec -T passbolt \
        supervisorctl status nginx 2>/dev/null |
        grep -q RUNNING; then
        NGINX_READY=true
        break
    fi

    sleep 2
done

if [[ "$NGINX_READY" != true ]]; then
    echo "Nginx failed to start. Check docker compose logs." >&2
    docker compose logs --tail=50 passbolt
    exit 1
fi

echo "Passbolt is running successfully."

CERT_FILE="$WORK_DIR/certs/cert.pem"
sudo cp "$CERT_FILE" /usr/local/share/ca-certificates/passbolt-certificate.crt
sudo update-ca-certificates
scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/passbolt-certificate.crt"

# Set environment variables to run the scripts later
echo "export COMPOSE_FILE=\"$WORK_DIR/compose.yml\"" >> ~/.bashrc
echo "export SERVICE_CHOICE=3" >> ~/.bashrc

# Load the set Environment Variables
source "$HOME/.bashrc"

echo ""
echo "Manual configuration required before registration:"
echo ""
echo "1. Make passbolt.lab resolve to your Passbolt server IP"
echo "   on the machine where you will open the browser."
echo ""
echo "2. Trust the certificate on that same machine:"
echo "   sudo cp /tmp/passbolt-certificate.crt /usr/local/share/ca-certificates/passbolt-certificate.crt"
echo "   sudo update-ca-certificates"
echo ""
echo "3. Open https://passbolt.lab and verify that the browser"
echo "   trusts the certificate."
echo ""
read -r -p "Press Enter once DNS and certificate trust are configured..."

docker compose exec passbolt /usr/share/php/passbolt/bin/cake \
  passbolt register_user \
    -u testing@example.com \
    -f Name \
    -l Lastname \
    -r admin

echo ""
echo "Open the registration URL displayed above and complete registration."


