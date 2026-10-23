#!/usr/bin/env bash

resolve_work_dir() {
    local configured_work_dir="${WORK_DIR:-}"

    if [[ -n "$configured_work_dir" ]]; then
        printf '%s\n' "$configured_work_dir"
        return 0
    fi

    if resolve_compose_file "$PWD" >/dev/null 2>&1; then
        printf '%s\n' "$PWD"
        return 0
    fi

    printf '%s\n' "$PWD"
}

resolve_compose_file() {
    local work_dir="${1:-$(resolve_work_dir)}"
    local configured_compose_file="${COMPOSE_FILE:-}"
    local candidate

    if [[ -n "$configured_compose_file" ]]; then
        if [[ "$configured_compose_file" = /* ]]; then
            [[ -f "$configured_compose_file" ]] || return 1
            printf '%s\n' "$configured_compose_file"
            return 0
        fi

        candidate="$work_dir/$configured_compose_file"
        [[ -f "$candidate" ]] || return 1
        printf '%s\n' "$candidate"
        return 0
    fi

    for candidate in \
        "$work_dir/compose.yml" \
        "$work_dir/compose.yaml" \
        "$work_dir/docker-compose.yml" \
        "$work_dir/docker-compose.yaml"; do
        if [[ -f "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

compose_available() {
    local work_dir

    work_dir="$(resolve_work_dir)" || return 1
    resolve_compose_file "$work_dir" >/dev/null 2>&1
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

detect_data_dir() {
    local work_dir="${1:-$(resolve_work_dir)}"
    local entry

    for entry in "$work_dir"/*; do
        if [[ -d "$entry" && -d "$entry.bak" ]]; then
            printf '%s\n' "$entry"
            return 0
        fi
    done

    return 1
}
