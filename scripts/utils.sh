#!/usr/bin/env bash

# Do not alter caller shell options when this file is sourced.
if [[ -n "${BASH_VERSION:-}" && "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    set -Eeuo pipefail
fi

SOURCE_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"

ensure_artifact_dir() {
    mkdir -p -- "$ARTIFACTS_DIR" || return 1
}

resolve_artifact_path() {
    local path="${1:-}"
    local resolved_path="$ARTIFACTS_DIR"

    if [[ -n "$path" ]]; then
        case "$path" in
            /*)
                resolved_path="$path"
                ;;
            *)
                resolved_path="$ARTIFACTS_DIR/$path"
                ;;
        esac
    fi

    mkdir -p -- "$(dirname -- "$resolved_path")" || return 1
    printf '%s\n' "$resolved_path"
}

require_command() {
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "ERROR: Required command not found: $cmd" >&2
            return 1
        fi
    done
}

ensure_sudo_session() {
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        return 0
    fi

    if ! sudo -n true >/dev/null 2>&1; then
        sudo -v >/dev/null 2>&1 || {
            echo "ERROR: sudo authentication required for sensitive actions." >&2
            return 1
        }
    fi
}

prompt_service_choice() {
    local default_choice="${1:-2}"
    local choice

    while :; do
        echo "Which service do you want to configure for the CLI?"
        echo "1) Bitwarden (official cloud)"
        echo "2) Vaultwarden (self-hosted)"
        read -rp "Enter your choice [$default_choice]: " choice || return 1

        choice="${choice:-$default_choice}"
        case "$choice" in
            1|2)
                printf '%s\n' "$choice"
                return 0
                ;;
            *)
                echo "Invalid choice. Please enter 1 or 2." >&2
                ;;
        esac
    done
}

docker_startup() {
    local timeout="${1:-120}"

    require_command docker || return 1

    echo "Starting Docker Compose services..."

    docker compose up -d --wait --wait-timeout "$timeout" || {
        echo "ERROR: Docker Compose services failed to become ready." >&2
        return 1
    }

    echo "Containers are ready."
}

initialize_scenario() {
    local email="${1:-testing@example.com}"
    local password="${2:-This24PassMasterW0rd}"
    local session

    ensure_sudo_session || return 1
    require_command docker bw || return 1

    docker_startup || return 1

    echo "Authenticating Bitwarden CLI..." >&2

    session="$(bw login "$email" "$password" --raw)" || {
        echo "ERROR: Bitwarden login failed" >&2
        return 1
    }

    export BW_SESSION="$session"
    unset session

    echo "Bitwarden CLI session initialized." >&2
}

dump_process() {
    local container="${1:-vaultwarden}"
    local output_prefix="${2:-core}"
    local host_pid

    require_command docker sudo || return 1
    ensure_sudo_session || return 1
    ensure_artifact_dir || return 1

    output_prefix="$(resolve_artifact_path "$output_prefix")"

    host_pid="$(docker inspect --type=container \
        --format '{{.State.Pid}}' "$container")" || {
        echo "ERROR: Could not inspect container: $container" >&2
        return 1
    }

    if [[ ! "$host_pid" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Container is not running: $container" >&2
        return 1
    fi

    echo "Container: $container"
    echo "Host PID: $host_pid"
    echo "Dumping process memory to: $output_prefix"

    sudo gcore -o "$output_prefix" "$host_pid"
}

cleanup() {
    local suffix_name="${1:-$(date -u '+%Y%m%dT%H%M%SZ')}"
    local data_dir="${REPO_ROOT}/lab/vaultwarden/vw-data"
    local data_baseline="${REPO_ROOT}/lab/vaultwarden/vw-data.bak"
    local data_archive="${REPO_ROOT}/lab/vaultwarden/vw-data_${suffix_name}"

    local bw_config_dir="$HOME/.config/Bitwarden CLI"
    local bw_data="$bw_config_dir/data.json"
    local bw_baseline="$bw_config_dir/data.json.bak"
    local bw_archive="${bw_data}_${suffix_name}"

    require_command docker bw || return 1

    if [[ ! -d "$data_baseline" ]]; then
        echo "ERROR: Missing baseline directory: $data_baseline" >&2
        return 1
    fi

    if [[ ! -f "$bw_baseline" ]]; then
        echo "ERROR: Missing baseline file: $bw_baseline" >&2
        return 1
    fi

    if [[ -e "$data_archive" || -e "$bw_archive" ]]; then
        echo "ERROR: An archive already exists for suffix: $suffix_name" >&2
        return 1
    fi

    echo "Stopping Docker Compose services..."
    docker compose down || {
        echo "ERROR: docker compose down failed" >&2
        return 1
    }

    if [[ -e "$data_dir" ]]; then
        mv -- "$data_dir" "$data_archive" || return 1
        echo "Archived Vaultwarden data: $data_archive"
    fi

    cp -a -- "$data_baseline" "$data_dir" || {
        echo "ERROR: Failed to restore Vaultwarden baseline." >&2
        return 1
    }

    echo "Restored Vaultwarden baseline."

    echo "Archiving Bitwarden CLI state..."

    if [[ -f "$bw_data" ]]; then
        cp -a -- "$bw_data" "$bw_archive" || {
            echo "ERROR: Failed to archive Bitwarden CLI state." >&2
            return 1
        }
        echo "Archived Bitwarden CLI state: $bw_archive"
    fi

    bw logout >/dev/null 2>&1 || true
    unset BW_SESSION

    cp -a -- "$bw_baseline" "$bw_data" || {
        echo "ERROR: Failed to restore Bitwarden CLI baseline." >&2
        return 1
    }

    echo "Restored Bitwarden CLI baseline."
    echo "Cleanup complete."
}
