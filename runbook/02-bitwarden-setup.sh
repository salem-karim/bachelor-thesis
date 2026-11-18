#!/usr/bin/env bash

set -Eeuo pipefail

if [[ -z "${HOST_USER:-}" || -z "${HOST_DOMAIN:-}" ]]; then
    echo "Please run this script with HOST_USER and HOST_DOMAIN set." >&2
    exit 1
fi

WORK_DIR="/opt/bitwarden"
sudo adduser bitwarden
sudo passwd bitwarden
sudo groupadd docker
sudo usermod -aG docker bitwarden
sudo mkdir -p "$WORK_DIR"
sudo chmod -R 700 /opt/bitwarden
sudo chown -R bitwarden:bitwarden /opt/bitwarden

# Switch to the newly created bitwarden user
sudo -iu bitwarden
cd "$WORK_DIR" || exit 1
curl -Lso bitwarden.sh "https://func.bitwarden.com/api/dl/?app=self-host&platform=linux" && chmod 700 bitwarden.sh

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
"$WORK_DIR"/bitwarden.sh install

CERT_FILE="$WORK_DIR/bwdata/ssl/self/bitwarden.lab/certificate.crt"
scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/bitwarden-certificate.crt"

# Set environment variables to run the scripts later
# echo "export COMPOSE_FILE=\"$WORK_DIR/compose.yml\"" >> ~/.bashrc
echo "export SERVICE_CHOICE=1" >> ~/.bashrc

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
echo ""

echo "Now create an account manually, after getting the Certificates from the VM"
