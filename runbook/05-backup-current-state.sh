#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/scripts/utils.sh"

choice="$(prompt_service_choice 2 1 2 3)"

case "$choice" in
    1)
        # TODO: Confirm data directory layout for self-hosted Bitwarden VM.
        WORK_DIR="$HOME/bitwarden"
        DATA_DIR="$WORK_DIR/bw-data"
        bitwarden_variant=true
        echo "Configuring Bitwarden..."
        ;;
    2)
        SERVER_URL="https://vaultwarden.lab"
        WORK_DIR="$HOME/vaultwarden"
        DATA_DIR="$WORK_DIR/vw-data"
        bitwarden_variant=true
        echo "Configuring Vaultwarden..."

        echo '127.0.0.1 vaultwarden.lab' | sudo tee -a /etc/hosts >/dev/null
        ;;
    3)
        WORK_DIR="$HOME/passbolt"
        DATA_DIR="$WORK_DIR/passbolt-data"
        bitwarden_variant=false
        # TODO: Implement passbolt-specific CLI/session backup strategy.
        ;;
    *)
        echo "Invalid choice. Exiting." >&2
        exit 1
        ;;
esac

if [[ "$bitwarden_variant" = true ]]; then
    rm -rf "$HOME/.config/Bitwarden CLI"
    mkdir -p "$HOME/.config/Bitwarden CLI"
    bw config server "$SERVER_URL"
    bw logout >/dev/null 2>&1 || true
    cp -a "$HOME/.config/Bitwarden CLI/data.json" "$HOME/.config/Bitwarden CLI/data.json.bak"
fi

mkdir -p "$DATA_DIR"
cp -a "$DATA_DIR" "$DATA_DIR.bak"
