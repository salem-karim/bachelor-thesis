#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/utils.sh"

initialize_service_context || exit 1

usage() {
    cat <<'EOF'
Usage: run-all.sh [scenario ...]

Runs the Vaultwarden scenario scripts in order.
Examples:
  ./scripts/run-all.sh
  ./scripts/run-all.sh s1 s3 s7
  ./scripts/run-all.sh s1 s2
EOF
}

SCENARIOS=()

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
fi

if [[ $# -eq 0 ]]; then
    SCENARIOS=(1 2 3 4 5 6 7)
else
    SCENARIOS=("$@")
fi

for scenario in "${SCENARIOS[@]}"; do
    if [[ ! "$scenario" =~ ^[1-7]$ ]]; then
        echo "ERROR: Unknown scenario: $scenario" >&2
        usage >&2
        exit 1
    fi
done

for scenario in "${SCENARIOS[@]}"; do
    scenario_path="$SCRIPT_DIR/scenarios/s${scenario}.sh"

    if [[ ! -f "$scenario_path" ]]; then
        echo "ERROR: Scenario script not found: $scenario_path" >&2
        exit 1
    fi

    echo "==> Running scenario S${scenario}"

    ensure_sudo_session || exit 1
    "$scenario_path"
    echo "==> Completed scenario S${scenario}"
    echo
done
