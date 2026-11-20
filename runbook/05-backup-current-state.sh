#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/scripts/utils.sh"

SERVICE_CHOICE="$(prompt_service_choice 2 1 2 3)"
export SERVICE_CHOICE

case "$SERVICE_CHOICE" in
    1)
        WORK_DIR="/opt/bitwarden"
        BITWARDEN_SCRIPT="${BITWARDEN_SCRIPT:-$WORK_DIR/bitwarden.sh}"
        DATA_DIR="$WORK_DIR/bwdata"
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
        DATA_DIR="$HOME/.local/share/docker/volumes"
        BACKUP_DIR="$WORK_DIR/passbolt-data/passbolt-volumes.bak"
        bitwarden_variant=false
        ;;
    *)
        echo "Invalid choice. Exiting." >&2
        exit 1
        ;;
esac

stop_service() {
    if [[ "${SERVICE_CHOICE}" == "1" ]]; then
        require_command sudo || return 1
        echo "Stopping Bitwarden..."
        sudo "$BITWARDEN_SCRIPT" stop || return 1
    fi

    if [[ "${SERVICE_CHOICE}" != "1" ]]; then
        require_command docker || return 1

        if ! compose_available; then
            echo "ERROR: No Docker Compose file found in WORK_DIR: $work_dir" >&2
            return 1
        fi

        echo "Stopping Docker Compose services in: $work_dir"
        run_docker_compose down || {
            echo "ERROR: docker compose down failed" >&2
            return 1
        }
    fi
}


if [[ "$SERVICE_CHOICE" == "3" ]]; then
    PASSBOLT_USER_PASSWORD="${PASSBOLT_USER_PASSWORD:-This24PassMasterW0rd}"

    # Backup Passbolt CLI configuration
    cli_config_file="$HOME/.config/go-passbolt-cli/go-passbolt-cli.toml"
    cp -a -- "$cli_config_file" "$cli_config_file.bak" || exit 1

    # Generate CLI configuration with user password 
    passbolt configure --userPassword "$PASSBOLT_USER_PASSWORD" || exit 1
    cp -a -- "$cli_config_file" "$cli_config_file.password.bak" || exit 1

    stop_service

    mkdir -p "$BACKUP_DIR" || exit 1

    for volume in \
        passbolt_database_volume \
        passbolt_gpg_volume \
        passbolt_jwt_volume
    do
        [[ -d "$DATA_DIR/$volume" ]] || {
            echo "ERROR: Missing Docker volume: $DATA_DIR/$volume" >&2
            exit 1
        }

        # Remove previous baseline to avoid stale files
        rm -rf -- "${BACKUP_DIR:?BACKUP_DIR is not set}/$volume"

        cp -a -- "$DATA_DIR/$volume" "$BACKUP_DIR/" || exit 1
    done
fi

if [[ "$bitwarden_variant" = true ]]; then
    rm -rf "$HOME/.config/Bitwarden CLI"
    mkdir -p "$HOME/.config/Bitwarden CLI"
    bw config server "$SERVER_URL"
    bw logout >/dev/null 2>&1 || true

    bw_cli_data="$HOME/.config/Bitwarden CLI/data.json"
    cp -a "$bw_cli_data" "$bw_cli_data.bak"

    stop_service

    # Replace previous baseline completely
    mkdir -p "$DATA_DIR"
    rm -rf -- "${DATA_DIR:?DATA_DIR is not set}.bak"
    mkdir -p "$DATA_DIR.bak"
    cp -a -- "$DATA_DIR/." "$DATA_DIR.bak/" || exit 1
fi

