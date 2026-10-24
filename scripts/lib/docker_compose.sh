#!/usr/bin/env bash

resolve_work_dir() {
    : "${WORK_DIR:?WORK_DIR must be set}"
    printf '%s\n' "$WORK_DIR"
}

resolve_compose_file() {
    local work_dir="${1:-$(resolve_work_dir)}"
    : "${COMPOSE_FILE:?COMPOSE_FILE must be set}"

    if [[ "$COMPOSE_FILE" = /* ]]; then
        printf '%s\n' "$COMPOSE_FILE"
    else
        printf '%s\n' "$work_dir/$COMPOSE_FILE"
    fi
}

compose_available() {
    local work_dir

    work_dir="$(resolve_work_dir)" || return 1
    [[ -f "$(resolve_compose_file "$work_dir")" ]]
}

run_docker_compose() {
    local work_dir compose_file

    work_dir="$(resolve_work_dir)" || return 1
    compose_file="$(resolve_compose_file "$work_dir")" || {
        echo "ERROR: Could not find a compose file in WORK_DIR: $work_dir" >&2
        return 1
    }

    docker compose --project-directory "$work_dir" -f "$compose_file" "$@"
}
