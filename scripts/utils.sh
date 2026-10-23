#!/usr/bin/env bash

docker_startup() {
    local timeout="${1:-120}"

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
    echo "Dumping process memory..."

    sudo gcore -o "$output_prefix" "$host_pid"
}

cleanup() {
    local suffix_name="${1:-$(date -u '+%Y%m%dT%H%M%SZ')}"
    local data_dir="./vw-data"
    local data_baseline="./vw-data.bak"
    local data_archive="./vw-data_${suffix_name}"

    local bw_config_dir="$HOME/.config/Bitwarden CLI"
    local bw_data="$bw_config_dir/data.json"
    local bw_baseline="$bw_config_dir/data.json.bak"
    local bw_archive="${bw_data}_${suffix_name}"

    # Validate before making changes.
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

    # Archive current Vaultwarden data.
    if [[ -e "$data_dir" ]]; then
        mv -- "$data_dir" "$data_archive" || return 1
        echo "Archived Vaultwarden data: $data_archive"
    fi

    cp -a -- "$data_baseline" "$data_dir" || {
        echo "ERROR: Failed to restore Vaultwarden baseline." >&2
        return 1
    }

    echo "Restored Vaultwarden baseline."

    # Preserve the exact current CLI state before logout changes it.
    echo "Archiving Bitwarden CLI state..."

    if [[ -f "$bw_data" ]]; then
        cp -a -- "$bw_data" "$bw_archive" || {
            echo "ERROR: Failed to archive Bitwarden CLI state." >&2
            return 1
        }
        echo "Archived Bitwarden CLI state: $bw_archive"
    fi

    # Attempt to invalidate the CLI session, then restore the baseline.
    bw logout >/dev/null 2>&1 || true
    unset BW_SESSION

    cp -a -- "$bw_baseline" "$bw_data" || {
        echo "ERROR: Failed to restore Bitwarden CLI baseline." >&2
        return 1
    }

    echo "Restored Bitwarden CLI baseline."
    echo "Cleanup complete."
}
