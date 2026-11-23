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

echo ""
read -r -p "Use 2FA when configuring the Passbolt CLI? [y/N]: " use_2fa

passbolt_config_args=(
    --serverAddress https://passbolt.lab
    --userPrivateKeyFile "$HOME/passbolt/privatekey.asc"
)

if [[ "${use_2fa,,}" == "y" || "${use_2fa,,}" == "yes" ]]; then
    read -rsp "Enter the TOTP secret: " passbolt_mfa_totp_token
    echo ""

    if [[ -z "$passbolt_mfa_totp_token" ]]; then
        echo "ERROR: A TOTP secret is required for non-interactive 2FA." >&2
        exit 1
    fi

    sed -i '/^export PASSBOLT_MFA_MODE=/d; /^export PASSBOLT_MFA_TOTP_TOKEN=/d' ~/.bashrc
    grep -qxF "export PASSBOLT_MFA_MODE=\"non-interactive-totp\"" ~/.bashrc ||
        echo "export PASSBOLT_MFA_MODE=\"non-interactive-totp\"" >> ~/.bashrc
    grep -qxF "export PASSBOLT_MFA_TOTP_TOKEN=\"$passbolt_mfa_totp_token\"" ~/.bashrc ||
        echo "export PASSBOLT_MFA_TOTP_TOKEN=\"$passbolt_mfa_totp_token\"" >> ~/.bashrc

    export PASSBOLT_MFA_MODE="non-interactive-totp"
    export PASSBOLT_MFA_TOTP_TOKEN="$passbolt_mfa_totp_token"

    passbolt_config_args+=(
        --mfaMode "non-interactive-totp"
        --mfaTotpToken "$passbolt_mfa_totp_token"
    )
else
    sed -i '/^export PASSBOLT_MFA_MODE=/d; /^export PASSBOLT_MFA_TOTP_TOKEN=/d' ~/.bashrc
    unset PASSBOLT_MFA_MODE PASSBOLT_MFA_TOTP_TOKEN
fi

passbolt configure "${passbolt_config_args[@]}"
