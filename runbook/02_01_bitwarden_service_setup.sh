#!/usr/bin/env bash

set -Eeuo pipefail

if [[ "$(id -un)" != "bitwarden" ]]; then
    echo "This script must be executed as the bitwarden user." >&2
    exit 1
fi

REPO_ROOT="${REPO_ROOT:-/opt/bitwarden/repo}"

if [[ -z "${HOST_USER:-}" || -z "${HOST_DOMAIN:-}" ]]; then
    echo "Please run this script with HOST_USER and HOST_DOMAIN set." >&2
    exit 1
fi

WORK_DIR="/opt/bitwarden"

echo "Installing Microsoft ODBC Driver 18 for SQL Server..."
curl -fsSL -O "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
sudo dpkg -i packages-microsoft-prod.deb
rm packages-microsoft-prod.deb
sudo apt update
sudo ACCEPT_EULA=Y apt install -y msodbcsql18
sudo apt install -y python3-pyodbc

cd "$WORK_DIR"

# Download Bitwarden
curl -Lso bitwarden.sh \
    "https://func.bitwarden.com/api/dl/?app=self-host&platform=linux"

chmod 700 bitwarden.sh

echo ""
echo "Bitwarden installer will now start."
echo ""
echo "Follow the interactive prompts:"
echo ""
echo "1. Enter your domain:"
echo "   bitwarden.lab"
echo ""
echo "2. When asked about Let's Encrypt, select: n"
echo "   We are not using Let's Encrypt."
echo ""
echo "3. Obtain your installation ID, installation key and region:"
echo "   https://bitwarden.com/host"
echo "   A valid email address is required."
echo ""
echo "4. When asked whether you have an SSL certificate, select: n"
echo ""
echo "5. When asked whether Bitwarden should generate a self-signed"
echo "   certificate, select: y"
echo ""
echo "   The generated certificate must be trusted on both the VM"
echo "   and your host."
echo ""
./bitwarden.sh install

# Install custom Docker Compose configuration
OVERRIDE_SOURCE="$REPO_ROOT/lab/bitwarden/docker-compose.override.yml"
OVERRIDE_DEST="$WORK_DIR/bwdata/docker/docker-compose.override.yml"

if [[ ! -f "$OVERRIDE_SOURCE" ]]; then
    echo "Missing Docker Compose override: $OVERRIDE_SOURCE" >&2
    exit 1
fi

install -m 600 "$OVERRIDE_SOURCE" "$OVERRIDE_DEST"

# Start Bitwarden
./bitwarden.sh start

CERT_FILE="$WORK_DIR/bwdata/ssl/self/bitwarden.lab/certificate.crt"
sudo -u bitwarden cat "$CERT_FILE" | sudo tee /tmp/bitwarden-certificate.crt >/dev/null
scp /tmp/bitwarden-certificate.crt "$HOST_USER@$HOST_DOMAIN:/tmp/bitwarden-certificate.crt"

# Set environment variables to run the scripts later
grep -qxF 'export SERVICE_CHOICE=1' ~/.bashrc ||
    echo 'export SERVICE_CHOICE=1' >> ~/.bashrc
export SERVICE_CHOICE=1

echo ""
echo "Manual configuration required:"
echo ""
echo "1. Add a DNS entry on your Ubuntu host."
echo "   Find your VM's IP address using: ip a"
echo "   Run (replace the IP with your VM's IP):"
echo "   echo '192.168.XXX.XXX bitwarden.lab' | sudo tee -a /etc/hosts"
echo ""
echo "2. Add the Bitwarden certificate to Ubuntu's trusted certificates:"
echo "   sudo cp /tmp/bitwarden-certificate.crt /usr/local/share/ca-certificates/bitwarden-certificate.crt"
echo "   sudo update-ca-certificates"
echo "Now create an account manually, after getting the Certificates from the VM"
echo "Continue the next scripts as the bitwarden user"
