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

service_preflight() {
    case "${SERVICE_CHOICE}" in
        1)
            require_command bw jq docker || return 1
            if [[ ! -f "${BITWARDEN_SCRIPT:-}" || ! -x "${BITWARDEN_SCRIPT:-}" ]]; then
                echo "ERROR: Bitwarden script not found or not executable: ${BITWARDEN_SCRIPT:-}" >&2
                return 1
            fi
            ;;
        2)
            require_command bw jq docker || return 1
            ;;
        3)
            require_command passbolt jq docker || return 1
            ;;
        *)
            echo "ERROR: Unsupported service choice: $SERVICE_CHOICE" >&2
            return 1
            ;;
    esac
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
    if [[ "${SERVICE_CHOICE}" == "1" ]]; then
        require_command sudo || return 1
        echo "Starting Bitwarden from $BITWARDEN_SCRIPT"
        "$BITWARDEN_SCRIPT" restart
        return
    fi

    local work_dir compose_file
    require_command docker || return 1

    work_dir="$(resolve_work_dir)" || return 1

    if ! compose_available; then
        echo "ERROR: No Docker Compose file found in WORK_DIR: $work_dir" >&2
        return 1
    fi

    compose_file="$(resolve_compose_file "$work_dir")" || return 1

    echo "Starting Docker Compose services from WORK_DIR: $work_dir"
    echo "Using compose file: $compose_file"

    running_containers="$(run_docker_compose ps -q --status running)"
    if [[ -n "$running_containers" ]]; then
        echo "Running Compose containers detected; stopping them before startup."
        run_docker_compose down || {
            echo "ERROR: Could not stop existing Docker Compose services." >&2
            return 1
        }
    fi

    run_docker_compose up -d || {
        echo "ERROR: Docker Compose services failed to become ready." >&2
        return 1
    }

    if [[ "${SERVICE_CHOICE}" == "3" ]]; then
        wait_for_passbolt_ready || return 1
        echo "Passbolt is ready."
    else
        echo "Containers are ready."
    fi
}

wait_for_passbolt_ready() {
    local attempt
    local status_output

    require_command curl || return 1

    echo "Waiting for Passbolt readiness..."
    for attempt in {1..60}; do
        if status_output="$(run_docker_compose exec -T passbolt \
            supervisorctl status nginx 2>/dev/null)" &&
            grep -q 'RUNNING' <<< "$status_output" &&
            curl --fail --silent --insecure --noproxy '*' \
                --connect-timeout 2 --max-time 5 \
                https://127.0.0.1/auth/verify.json >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    echo "ERROR: Passbolt did not become ready within 120 seconds." >&2
    run_docker_compose logs --tail=50 passbolt >&2 || true
    return 1
}

initialize_scenario() {
    local email="${1:-testing@example.com}"
    local password="${2:-This24PassMasterW0rd}"
    local session

    if [[ "${SERVICE_CHOICE}" == "3" ]]; then
        docker_startup || return 1
        require_command passbolt || return 1
        for _ in {1..30}; do
            if passbolt verify; then
                return 0
            fi
            sleep 2
        done
        echo "ERROR: Passbolt CLI verification failed after startup." >&2
        return 1
    fi

    require_command bw || return 1

    docker_startup || return 1

    echo "Logging out any existing Bitwarden CLI session..." >&2
    bw logout >/dev/null 2>&1 || true

    login_bitwarden_cli "$email" "$password" || return 1
    session="${BW_SESSION:-}"

    export BW_SESSION="$session"
    unset session

    echo "Bitwarden CLI session initialized." >&2
}

login_bitwarden_cli() {
    local email="${1:-testing@example.com}"
    local password="${2:-This24PassMasterW0rd}"
    local session

    if [[ -f "$HOME/.bashrc" ]]; then
        source "$HOME/.bashrc"
    fi

    require_command bw || return 1
    bw logout >/dev/null 2>&1 || true

    if [[ -n "${BW_CLIENTID:-}" && -n "${BW_CLIENTSECRET:-}" ]]; then
        export BW_PASSWORD="${BW_PASSWORD:-$password}"
        echo "Logging in to Bitwarden CLI with API key..." >&2
        bw login --apikey || {
            echo "ERROR: Bitwarden API-key login failed" >&2
            return 1
        }

        session="$(bw unlock --passwordenv BW_PASSWORD --raw)" || {
            echo "ERROR: Bitwarden unlock failed" >&2
            return 1
        }
    else
        echo "Logging in to Bitwarden CLI with master password..." >&2
        session="$(bw login "$email" "$password" --raw)" || {
            echo "ERROR: Bitwarden login failed" >&2
            return 1
        }
    fi

    export BW_SESSION="$session"
}

dump_process() {
    local container_list="${CONTAINER_NAME:-}"
    local output_prefix="${1:-core}"
    local host_pid
    local container
    local -a containers=()
    local timestamp

    require_command docker sudo || return 1

    if [[ -z "$container_list" ]]; then
        echo "ERROR: CONTAINER_NAME is not set." >&2
        return 1
    fi

    # CONTAINER_NAME accepts space-separated container names.
    read -r -a containers <<< "$container_list"

    ensure_sudo_session || return 1
    ensure_artifact_dir || return 1

    timestamp="$(date -u '+%Y%m%d-%H%M%S')"
    if [[ "$output_prefix" == "core" ]]; then
        output_prefix="${timestamp}_core"
    fi

    output_prefix="$(resolve_artifact_path "$output_prefix")"

    for container in "${containers[@]}"; do
        host_pid="$(docker inspect --type=container \
            --format '{{.State.Pid}}' "$container")" || {
            echo "ERROR: Could not inspect container: $container" >&2
            return 1
        }

        if [[ ! "$host_pid" =~ ^[1-9][0-9]*$ ]]; then
            echo "ERROR: Container is not running: $container" >&2
            return 1
        fi

        echo
        echo "Container: $container"
        echo "Host PID: $host_pid"
        echo "Dumping process memory to: $output_prefix.$container"

        sudo gcore -a -o "$output_prefix.$container" "$host_pid" || {
            echo "ERROR: Failed to dump container: $container" >&2
            return 1
        }
    done
}

cleanup() {
    local suffix_name="${1:-$(date -u '+%Y%m%dT%H%M%SZ')}"
    local work_dir bw_data
    local caddy_log caddy_log_archive

    work_dir="$(resolve_work_dir)" || return 1

    if [[ "${SERVICE_CHOICE}" == "1" ]]; then
        require_command sudo || return 1
        echo "Stopping Bitwarden..."
        "$BITWARDEN_SCRIPT" stop || return 1
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


    if [[ "${SERVICE_CHOICE}" == "2" ]]; then
        caddy_log="${CADDY_LOG_FILE:-$work_dir/caddy-data/access.log}"
        if [[ -f "$caddy_log" ]]; then
            caddy_log_archive="${CADDY_LOG_ARCHIVE:-}"
            if [[ -z "$caddy_log_archive" ]]; then
                caddy_log_archive="$(resolve_artifact_path "caddy/access_${suffix_name}.log")"
            fi
            if [[ -e "$caddy_log_archive" ]]; then
                echo "ERROR: Caddy log archive already exists: $caddy_log_archive" >&2
                return 1
            fi

            cp -a -- "$caddy_log" "$caddy_log_archive" || {
                echo "ERROR: Failed to archive Caddy access log." >&2
                return 1
            }
            : > "$caddy_log"
            echo "Archived and cleared Caddy access log: $caddy_log_archive"
        else
            echo "No Caddy access log found; skipping Caddy log archive."
        fi
    fi

    if [[ "${SERVICE_CHOICE}" == "3" ]]; then

        local archive_dir="$work_dir/passbolt-data/passbolt-volumes_${suffix_name}"
        local cli_config_file="$HOME/.config/go-passbolt-cli/go-passbolt-cli.toml"

        # Verify baseline exists
        [[ -d "$BACKUP_DIR" ]] || {
            echo "ERROR: Missing baseline: $BACKUP_DIR" >&2
            return 1
        }

        # Verify all current and baseline volumes exist
        for volume in \
            passbolt_database_volume \
            passbolt_gpg_volume \
            passbolt_jwt_volume
        do
            [[ -d "$DATA_DIR/$volume" ]] || {
                echo "ERROR: Missing current volume: $DATA_DIR/$volume" >&2
                return 1
            }

            [[ -d "$BACKUP_DIR/$volume" ]] || {
                echo "ERROR: Missing baseline volume: $BACKUP_DIR/$volume" >&2
                return 1
            }
        done

        # Ensure archive doesn't already exist
        [[ ! -e "$archive_dir" ]] || {
            echo "ERROR: Archive already exists: $archive_dir" >&2
            return 1
        }

        mkdir -p "$archive_dir" || return 1

        # Archive current Docker volumes
        for volume in \
            passbolt_database_volume \
            passbolt_gpg_volume \
            passbolt_jwt_volume
        do
            sudo mv -- "$DATA_DIR/$volume" "$archive_dir/" || return 1
        done

        # Restore clean baseline
        for volume in \
            passbolt_database_volume \
            passbolt_gpg_volume \
            passbolt_jwt_volume
        do
            sudo cp -a -- "$BACKUP_DIR/$volume" "$DATA_DIR/" || return 1
        done

        echo "Restored clean Passbolt volumes."
        echo "Previous volumes archived: $archive_dir"

        # Archive current CLI configuration and restore baseline
        if [[ -f "$cli_config_file.bak" ]]; then

            [[ -f "$cli_config_file" ]] || {
                echo "ERROR: Current Passbolt CLI config missing." >&2
                return 1
            }

            [[ ! -e "${cli_config_file}_${suffix_name}" ]] || {
                echo "ERROR: CLI config archive already exists." >&2
                return 1
            }

            mv -- "$cli_config_file" "${cli_config_file}_${suffix_name}" || return 1
            cp -a -- "$cli_config_file.bak" "$cli_config_file" || return 1

            echo "Restored clean Passbolt CLI configuration."
        fi
    fi

    if [[ "${SERVICE_CHOICE}" == "1" || "${SERVICE_CHOICE}" == "2" ]]; then
        require_command bw || return 1
        bw logout >/dev/null 2>&1 || true
        unset BW_SESSION
        if [[ -n "$DATA_DIR" ]]; then
            [[ -d "$DATA_DIR.bak" ]] || {
                echo "ERROR: Missing baseline: $DATA_DIR.bak" >&2
                return 1
            }

            [[ ! -e "${DATA_DIR}_${suffix_name}" ]] || {
                echo "ERROR: Archive already exists." >&2
                return 1
            }

            mv "$DATA_DIR" "${DATA_DIR}_${suffix_name}" || return 1
            cp -a "$DATA_DIR.bak" "$DATA_DIR" || return 1

            echo "Restored service data."
        fi

        bw_data="$HOME/.config/Bitwarden CLI/data.json"

        if [[ -f "$bw_data.bak" ]]; then
            mv "$bw_data" "${bw_data}_${suffix_name}" || return 1
            cp -a "$bw_data.bak" "$bw_data" || return 1

            echo "Restored Bitwarden CLI state."
        fi
    fi

    echo "Cleanup complete."
}
