#!/usr/bin/env bash

# Do not alter caller shell options when this file is sourced.
if [[ -n "${BASH_VERSION:-}" && "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    set -Eeuo pipefail
fi

SOURCE_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SOURCE_PATH")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
ARTIFACTS_DIR="${ARTIFACTS_DIR:-${REPO_ROOT}/artifacts}"

source "$SCRIPT_DIR/lib/docker_compose.sh"
source "$SCRIPT_DIR/lib/service_profile.sh"

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

docker_startup() {
    local use_docker="${USE_DOCKER_COMPOSE:-auto}"
    local work_dir compose_file

    if [[ "$use_docker" == "0" || "$use_docker" == "false" ]]; then
        echo "Skipping Docker startup (USE_DOCKER_COMPOSE=$use_docker)."
        return 0
    fi

    require_command docker || return 1

    work_dir="$(resolve_work_dir)" || return 1
    compose_file="$(resolve_compose_file "$work_dir" || true)"

    if ! compose_available; then
        if [[ "$use_docker" == "1" || "$use_docker" == "true" ]]; then
            echo "ERROR: Docker Compose requested but no compose file was found in WORK_DIR: $work_dir" >&2
            return 1
        fi

        echo "Skipping Docker startup (no compose file found in WORK_DIR)."
        return 0
    fi

    echo "Starting Docker Compose services from WORK_DIR: $work_dir"
    echo "Using compose file: $compose_file"

    run_docker_compose up -d || {
        echo "ERROR: Docker Compose services failed to become ready." >&2
        return 1
    }

    echo "Containers are ready."
}

initialize_scenario() {
    local email="${1:-testing@example.com}"
    local password="${2:-This24PassMasterW0rd}"
    local session

    if [[ "${SERVICE_CHOICE}" == "3" ]]; then
        echo "TODO: passbolt scenario flow is not implemented yet." >&2
        return 1
    fi

    require_command bw || return 1

    docker_startup || return 1

    echo "Logging out any existing Bitwarden CLI session..." >&2
    bw logout >/dev/null 2>&1 || true

    echo "Logging in to Bitwarden CLI..." >&2
    session="$(bw login "$email" "$password" --raw)" || {
        echo "ERROR: Bitwarden login failed" >&2
        return 1
    }

    export BW_SESSION="$session"
    unset session

    echo "Bitwarden CLI session initialized." >&2
}

dump_process() {
    local container="${1:-${CONTAINER_NAME:-}}"
    local output_prefix="${2:-core}"
    local host_pid
    local use_docker="${USE_DOCKER_COMPOSE:-auto}"

    if [[ "$use_docker" == "0" || "$use_docker" == "false" ]]; then
        echo "Skipping process dump (USE_DOCKER_COMPOSE=$use_docker)."
        return 0
    fi

    require_command docker sudo || return 1

    if [[ -z "$container" ]]; then
        if compose_available; then
            container="$(run_docker_compose ps -q | head -n1)"
        fi
    fi

    if [[ -z "$container" ]]; then
        if [[ "$use_docker" == "1" || "$use_docker" == "true" ]]; then
            echo "ERROR: No container target provided for process dump." >&2
            return 1
        fi

        echo "Skipping process dump (no running compose container detected)."
        return 0
    fi

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
    echo "Dumping process memory to: $output_prefix.$host_pid"

    sudo gcore -o "$output_prefix" "$host_pid"
}

cleanup() {
    local suffix_name="${1:-$(date -u '+%Y%m%dT%H%M%SZ')}"
    local work_dir data_dir data_baseline data_archive
    local bw_config_dir bw_data bw_baseline bw_archive
    local use_docker="${USE_DOCKER_COMPOSE:-auto}"
    local should_reset_bw="${RESET_BW_STATE:-auto}"

    work_dir="$(resolve_work_dir)" || return 1

    if [[ "${SERVICE_CHOICE}" == "1" || "${SERVICE_CHOICE}" == "2" ]]; then
        require_command bw || return 1
        bw logout >/dev/null 2>&1 || true
        unset BW_SESSION
    fi

    data_dir="${DATA_DIR:-}"

    if [[ -n "$data_dir" ]]; then
        data_baseline="${DATA_BASELINE:-$data_dir.bak}"
        data_archive="${DATA_ARCHIVE:-${data_dir}_${suffix_name}}"
    fi

    bw_config_dir="${BW_CONFIG_DIR:-$HOME/.config/Bitwarden CLI}"
    bw_data="${BW_DATA_FILE:-$bw_config_dir/data.json}"
    bw_baseline="${BW_BASELINE_FILE:-$bw_data.bak}"
    bw_archive="${BW_ARCHIVE_FILE:-${bw_data}_${suffix_name}}"

    if [[ -n "$data_dir" ]]; then
        if [[ ! -d "$data_baseline" ]]; then
            echo "ERROR: Missing baseline directory: $data_baseline" >&2
            return 1
        fi

        if [[ -e "$data_archive" ]]; then
            echo "ERROR: Data archive already exists: $data_archive" >&2
            return 1
        fi

        if [[ -e "$data_dir" ]]; then
            mv -- "$data_dir" "$data_archive" || return 1
            echo "Archived service data: $data_archive"
        fi

        cp -a -- "$data_baseline" "$data_dir" || {
            echo "ERROR: Failed to restore baseline directory: $data_baseline" >&2
            return 1
        }

        echo "Restored service baseline data."
    else
        echo "No DATA_DIR detected; skipping service data restore."
    fi

    if [[ "$should_reset_bw" == "1" || "$should_reset_bw" == "true" ]] ||
       [[ "$should_reset_bw" == "auto" && -f "$bw_baseline" ]]; then
        if [[ -e "$bw_archive" ]]; then
            echo "ERROR: Bitwarden CLI archive already exists: $bw_archive" >&2
            return 1
        fi

        echo "Archiving Bitwarden CLI state..."

        if [[ -f "$bw_data" ]]; then
            cp -a -- "$bw_data" "$bw_archive" || {
                echo "ERROR: Failed to archive Bitwarden CLI state." >&2
                return 1
            }
            echo "Archived Bitwarden CLI state: $bw_archive"
        fi

        cp -a -- "$bw_baseline" "$bw_data" || {
            echo "ERROR: Failed to restore Bitwarden CLI baseline." >&2
            return 1
        }

        echo "Restored Bitwarden CLI baseline."
    else
        echo "No Bitwarden CLI baseline configured; skipping CLI state restore."
    fi

    if [[ "$use_docker" != "0" && "$use_docker" != "false" ]] && compose_available; then
        require_command docker || return 1
        echo "Stopping Docker Compose services in: $work_dir"
        run_docker_compose down || {
            echo "ERROR: docker compose down failed" >&2
            return 1
        }
    fi

    echo "Cleanup complete."
}
