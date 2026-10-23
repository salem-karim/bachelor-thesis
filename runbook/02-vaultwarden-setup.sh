#!/usr/bin/env bash

if [ -z "$HOST_USER" ] || [ -z "$HOST_DOMAIN" ]; then
    echo "Please run this Script with HOST_USER & HOST_DOMAIN set"
    exit
fi

WORK_DIR="$HOME/vaultwarden"

mkdir WORK_DIR
cp ../lab/vaultwarden/compose.yml "$WORK_DIR/compose.yml"
cp ../lab/vaultwarden/Caddyfile "$WORK_DIR/Caddyfile"

# Enable binding to Ports lower than 1024 (eg. 80 or 443)
sudo setcap cap_net_bind_service=ep /usr/bin/rootlesskit
systemctl --user restart docker

# Start the containers
cd "$WORK_DIR" || exit
docker compose up -d

sleep 5

CERT_FILE=$WORK_DIR/caddy-data/caddy/pki/authorities/local/root.crt

scp "$CERT_FILE" "$HOST_USER@$HOST_DOMAIN:/tmp/caddy-root.crt"

# Then update your trusted certificates and add a DNS Record with the VMs IP
# This is the example on a Ubuntu Host, find the VMs IP using `ip a`
# echo '192.168.XXX.XXX vaultwarden.lab' | sudo tee -a /etc/hosts 
#
# # Add the Caddy Certificate to the Hosts trusted ones
# sudo cp /tmp/caddy-root.crt /usr/local/share/ca-certificates/caddy-root.crt
# sudo update-ca-certificates

# Bind the domain to localhost on the VM
echo '127.0.0.1 vaultwarden.lab' | sudo tee -a /etc/hosts 

# Install bitwarden cli
sudo apt install unzip
wget -e background=off --output-document=/tmp/bw.zip "https://vault.bitwarden.com/download/?app=cli&platform=linux"
unzip /tmp/bw.zip -d "$WORK_DIR"

# Set the Env Variable to make the CLI Trust the cert and ad it to the Path
echo "export PATH=$WORK_DIR:$PATH" >> ~/.bashrc
echo "export NODE_EXTRA_CA_CERTS=$CERT_FILE" >> ~/.bashrc
source ~/.bashrc

# Configure the CLI to use the server
./bw config server https://vaultwarden.lab
