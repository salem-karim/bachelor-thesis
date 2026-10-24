#!/usr/bin/env bash

service_choice_label() {
    case "$1" in
        1) printf '%s\n' 'Bitwarden' ;;
        2) printf '%s\n' 'Vaultwarden' ;;
        3) printf '%s\n' 'Passbolt' ;;
        *) return 1 ;;
    esac
}

prompt_service_choice() {
    local default_choice="${1:-2}"
    shift || true
    local allowed_choices=("$@")
    local choice
    local valid_choice

    if [[ ${#allowed_choices[@]} -eq 0 ]]; then
        allowed_choices=(1 2 3)
    fi

    while :; do
        echo "Which service VM are you targeting?" >&2
        for valid_choice in "${allowed_choices[@]}"; do
            printf '%s) %s\n' "$valid_choice" "$(service_choice_label "$valid_choice")" >&2
        done
        read -rp "Enter your choice [$default_choice]: " choice || return 1

        choice="${choice:-$default_choice}"
        for valid_choice in "${allowed_choices[@]}"; do
            if [[ "$choice" == "$valid_choice" ]]; then
                printf '%s\n' "$choice"
                return 0
            fi
        done

        echo "Invalid choice. Allowed values: ${allowed_choices[*]}" >&2
    done
}

apply_service_profile() {
    case "${SERVICE_CHOICE}" in
        1)
            WORK_DIR="${WORK_DIR:-$HOME/bitwarden}"
            USE_DOCKER_COMPOSE="${USE_DOCKER_COMPOSE:-auto}"
            CONTAINER_NAME="${CONTAINER_NAME:-bitwarden}"
            RESET_BW_STATE="${RESET_BW_STATE:-auto}"
            # TODO: Tune DATA_DIR defaults for self-hosted Bitwarden layout.
            ;;
        2)
            WORK_DIR="${WORK_DIR:-$HOME/vaultwarden}"
            USE_DOCKER_COMPOSE="${USE_DOCKER_COMPOSE:-true}"
            CONTAINER_NAME="${CONTAINER_NAME:-vaultwarden}"
            RESET_BW_STATE="${RESET_BW_STATE:-auto}"
            DATA_DIR="${DATA_DIR:-$WORK_DIR/vw-data}"
            ;;
        3)
            WORK_DIR="${WORK_DIR:-$HOME/passbolt}"
            USE_DOCKER_COMPOSE="${USE_DOCKER_COMPOSE:-auto}"
            CONTAINER_NAME="${CONTAINER_NAME:-passbolt}"
            RESET_BW_STATE="${RESET_BW_STATE:-false}"
            # TODO: Implement passbolt-specific data baseline/archive defaults.
            ;;
        *)
            echo "ERROR: Unsupported service choice: ${SERVICE_CHOICE}" >&2
            return 1
            ;;
    esac

    export WORK_DIR USE_DOCKER_COMPOSE CONTAINER_NAME RESET_BW_STATE
    export DATA_DIR
}

initialize_service_context() {
    if [[ -n "${SERVICE_CONTEXT_READY:-}" ]]; then
        return 0
    fi

    if [[ -z "${SERVICE_CHOICE:-}" ]]; then
        echo "ERROR: SERVICE_CHOICE must be set to 1 (Bitwarden), 2 (Vaultwarden), or 3 (Passbolt)." >&2
        return 1
    fi

    apply_service_profile || return 1

    SERVICE_CONTEXT_READY=1
    export SERVICE_CONTEXT_READY
}
