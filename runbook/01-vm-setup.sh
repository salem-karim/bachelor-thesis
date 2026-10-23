#!/usr/bin/env bash

# Initial Server update
sudo apt update
sudo apt upgrade

# [Install Docker on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)

# Add Docker's official GPG key:
sudo apt update
sudo apt install ca-certificates curl
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

sudo apt update

sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version
# Output: Docker version 29.9.2, build a82e528

# [Make it Rootless](https://docs.docker.com/engine/security/rootless/)
sudo apt install uidmap
dockerd-rootless-setuptool.sh install

# install gdb 
sudo apt install gdb
