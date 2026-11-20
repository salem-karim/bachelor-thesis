#!/usr/bin/env bash

set -Eeuo pipefail

# Initial Server update
sudo apt update -qq
sudo DEBIAN_FRONTEND=noninteractive apt upgrade -y

# [Install Docker on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)

# Add Docker's official GPG key:
sudo apt update -qq
sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update -qq
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version
# Output: Docker version 29.9.2, build a82e528

# [Make it Rootless](https://docs.docker.com/engine/security/rootless/)
sudo apt install -y uidmap
if command -v dockerd-rootless-setuptool.sh >/dev/null 2>&1; then
    dockerd-rootless-setuptool.sh install
    # Enable binding to Ports lower than 1024 (eg. 80 or 443)
    sudo setcap cap_net_bind_service=ep /usr/bin/rootlesskit
    systemctl --user restart docker
else
    echo "WARN: dockerd-rootless-setuptool.sh not found; rootless Docker setup was skipped." >&2
fi



# install gdb, jq and curl
sudo apt install -y gdb jq curl uuid-runtime

