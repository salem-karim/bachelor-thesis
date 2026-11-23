#!/usr/bin/env bash

set -Eeuo pipefail

WORK_DIR="/opt/bitwarden"
REPO_ROOT="$WORK_DIR/repo"
if ! id bitwarden >/dev/null 2>&1; then
    sudo adduser --disabled-password --gecos "" bitwarden
fi

sudo usermod -aG sudo bitwarden

if ! getent group docker >/dev/null 2>&1; then
    sudo groupadd docker
fi
sudo usermod -aG docker bitwarden
sudo mkdir -p "$WORK_DIR"
sudo chmod -R 700 /opt/bitwarden
sudo chown -R bitwarden:bitwarden /opt/bitwarden

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    sudo -u bitwarden -H git clone \
        https://github.com/salem-karim/bachelor-thesis.git \
        "$REPO_ROOT"
fi

echo "Bitwarden user successfully configured."
echo "Set a password for the bitwarden user: sudo passwd bitwarden"
echo "Continue with: sudo -iu bitwarden"
