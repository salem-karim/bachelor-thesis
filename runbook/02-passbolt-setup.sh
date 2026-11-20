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
cp "$REPO_ROOT/lab/passbolt/compose.yaml" "$WORK_DIR/compose.yaml"
openssl req -newkey rsa:4096 -x509 -sha256 -days 730 -noenc -batch \
    -subj "/CN=passbolt.lab" -addext "subjectAltName=DNS:passbolt.lab"\
    -out "$WORK_DIR/certs/cert.pem" -keyout "$WORK_DIR/certs/key.pem"
chmod 600 certs/key.pem
chmod 644 certs/cert.pem


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

docker compose exec passbolt su -m -c "/usr/share/php/passbolt/bin/cake \
  passbolt register_user \
    -u testing@example.com \
    -f Name \
    -l Lastname \
    -r admin" -s /bin/sh www-data

echo "Please open the registration URL displayed above"
echo "and complete the Passbolt account registration."
echo "The scripts default to the Password This24PassMasterW0rd"
echo ""
read -r -p "Press ENTER once you have completed the registration to continue..."

CERT_FILE="$WORK_DIR/certs/cert.pem"
scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/passbolt-certificate.crt"

# Set environment variables to run the scripts later
echo "export COMPOSE_FILE=\"$WORK_DIR/compose.yaml\"" >> ~/.bashrc
echo "export SERVICE_CHOICE=3" >> ~/.bashrc

# Load the set Environment Variables
source "$HOME/.bashrc"

echo ""
echo "Manual configuration required:"
echo ""
echo "1. Add a DNS entry on your Ubuntu host."
echo "   Find your VM's IP address using: ip a"
echo "   Run (replace the IP with your VM's IP):"
echo "   echo '192.168.XXX.XXX passbolt.lab' | sudo tee -a /etc/hosts"
echo ""
echo "2. Add the Passbolt certificate to Ubuntu's trusted certificates:"
echo "   sudo cp /tmp/passbolt-certificate.crt /usr/local/share/ca-certificates/passbolt-certificate.crt"
echo "   sudo update-ca-certificates"
echo ""

