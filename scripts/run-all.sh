#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/scenario.sh"

usage() {
    cat <<'EOF'
Usage: run-all.sh [--repeat COUNT] [scenario ...]

Runs the selected scenario scripts in order. The complete list is repeated COUNT times.
Examples:
  ./scripts/run-all.sh
  ./scripts/run-all.sh --repeat 3 1 2 3
  ./scripts/run-all.sh -n 5 s4
EOF
}

SCENARIOS=()
repeat_count=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -n|--repeat)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: $1 requires a positive repeat count." >&2
                exit 1
            fi
            repeat_count="$2"
            shift 2
            ;;
        --repeat=*)
            repeat_count="${1#*=}"
            shift
            ;;
        *)
            scenario="${1#s}"
            if [[ ! "$scenario" =~ ^[1-7]$ ]]; then
                echo "ERROR: Unknown scenario: $1" >&2
                usage >&2
                exit 1
            fi
            SCENARIOS+=("$scenario")
            shift
            ;;
    esac
done

if [[ ! "$repeat_count" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: Repeat count must be a positive integer: $repeat_count" >&2
    exit 1
fi

if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    SCENARIOS=(1 2 3 4 5 6 7)
fi

if [[ -z "${SERVICE_CHOICE:-}" ]]; then
    SERVICE_CHOICE="$(prompt_service_choice 2 1 2 3)" || exit 1
    export SERVICE_CHOICE
fi

initialize_service_context
service_preflight || exit 1

for ((attempt = 1; attempt <= repeat_count; attempt++)); do
    for scenario in "${SCENARIOS[@]}"; do
        echo "==> Running scenario S${scenario} (run ${attempt}/${repeat_count})"
        run_scenario "$scenario" || exit 1
        echo "==> Completed scenario S${scenario}"
        echo
    done
done
