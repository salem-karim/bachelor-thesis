#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/scripts/utils.sh"

require_command wget unzip jq || exit 1
ensure_sudo_session || exit 1

wget -e background=off \
    --output-document=/tmp/passbolt-cli.deb \
    "https://github.com/passbolt/go-passbolt-cli/releases/download/v0.5.3/go-passbolt-cli_0.5.3_linux_amd64.deb"

sudo dpkg -i /tmp/passbolt-cli.deb

echo "Please download the private key from your profile on the passbolt site"
echo "and place it on the VM at ~/passbolt/privatekey.asc"
echo ""
read -r -p "Press ENTER once you have completed the registration to continue..."

passbolt configure --serverAddress https://passbolt.lab \
    --userPrivateKeyFile "$HOME/passbolt/privatekey.asc" \
    --userPassword "This24PassMasterW0rd"
