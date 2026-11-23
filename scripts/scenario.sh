#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/markers.sh"

find_login_item_id() {
    local target_name="$1"

    bw list items |
        jq -er --arg name "$target_name" '
            [.[] | select(.name == $name and .type == 1)]
            | if length == 1 then .[0].id
              else error("Expected exactly one matching login item")
              end
        '
}

find_passbolt_resource_id() {
    local target_name="$1"

    passbolt list resource --json |
        jq -er --arg name "$target_name" '
            [.[] | select(.name == $name)]
            | if length == 1 then .[0].id
              else error("Expected exactly one matching Passbolt resource")
              end
        '
}

run_scenario_action() {
    local scenario="$1"

    case "$scenario" in
        1)
            docker_startup
            ;;
        2)
            initialize_scenario
            ;;
        3)
            initialize_scenario
            if [[ "$SERVICE_CHOICE" != "3" ]]; then
                bw lock
            else
                local target_name="DELNAME_c9ccd5b49beb_S0"
                local item_id
                item_id="$(find_passbolt_resource_id "$target_name")"
                export TEST_SECRET="passbolt://$item_id"

                passbolt exec -- sh -c 'echo "$TEST_SECRET"'
            fi
            ;;
        4)
            initialize_scenario

            local name username password
            name="$(generate_marker "S4" "NAME" "16")"
            username="$(generate_marker "S4" "USRNAME" "12")"
            password="$(generate_marker "S4" "PW" "18")"

            if [[ "$SERVICE_CHOICE" != "3" ]]; then
                local template_dir="$REPO_ROOT/lab/warden-json-templates"
                jq --arg name "$name" \
                   --arg username "$username" \
                   --arg password "$password" \
                   '.name = $name
                    | .type = 1
                    | .login = (input | .username = $username | .password = $password)' \
                   "$template_dir/item.json" "$template_dir/login.json" |
                    bw encode |
                    bw create item
            else
                passbolt create resource \
                    -n "$name" -u "$username" -p "$password"
            fi
            ;;
        5)
            initialize_scenario

            local target_name="EDITNAME_8d4de3c93a70_S0"
            local name username password
            name="$(generate_marker "S5" "NAME" "16")"
            username="$(generate_marker "S5" "USRNAME" "12")"
            password="$(generate_marker "S5" "PW" "18")"

            if [[ "$SERVICE_CHOICE" != "3" ]]; then
                local item_id
                item_id="$(find_login_item_id "$target_name")"

                bw get item "$item_id" |
                    jq --arg name "$name" \
                       --arg username "$username" \
                       --arg password "$password" \
                       '.name = $name
                        | .type = 1
                        | .login.username = $username
                        | .login.password = $password' |
                    bw encode |
                    bw edit item "$item_id"
            else
                local item_id
                item_id="$(find_passbolt_resource_id "$target_name")"
                passbolt update resource --id "$item_id" \
                    -n "$name" -u "$username" -p "$password"
            fi
            ;;
        6)
            initialize_scenario

            local target_name="DELNAME_c9ccd5b49beb_S0"
            if [[ "$SERVICE_CHOICE" != "3" ]]; then
                local item_id
                item_id="$(find_login_item_id "$target_name")"
                bw delete item "$item_id"
            else
                local item_id
                item_id="$(find_passbolt_resource_id "$target_name")"
                passbolt delete resource --id "$item_id"
            fi
            ;;
        7)
            initialize_scenario

            local target_name="EDITNAME_8d4de3c93a70_S0"
            if [[ "$SERVICE_CHOICE" != "3" ]]; then
                bw list items --search "$target_name" |
                    jq -er --arg name "$target_name" '
                        [.[] | select(.name == $name and .type == 1)]
                        | if length == 1 then .[0]
                          else error("Expected exactly one matching login item")
                          end
                    '
            else
                local item_id
                item_id="$(find_passbolt_resource_id "$target_name")"
                passbolt get resource --id "$item_id"
            fi
            ;;
        *)
            echo "ERROR: Unknown scenario: $scenario" >&2
            return 1
            ;;
    esac
}

run_scenario() {
    local scenario="$1"
    local prefix status=0

    if [[ ! "$scenario" =~ ^[1-7]$ ]]; then
        echo "ERROR: Unknown scenario: $scenario" >&2
        return 1
    fi

    ensure_sudo_session || return 1
    prefix="$(date -u '+%Y%m%d-%H%M%S')_S${scenario}_core"

    if run_scenario_action "$scenario"; then
        if dump_process "$prefix"; then
            :
        else
            status=$?
        fi
    else
        status=$?
    fi

    if cleanup; then
        :
    else
        if [[ "$status" -eq 0 ]]; then
            status=$?
        fi
    fi

    return "$status"
}

usage() {
    cat <<'EOF'
Usage: scenario.sh [scenario ...]

Runs one or more scenarios S1-S7 in order.
No arguments runs all scenarios.
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    if [[ $# -gt 0 ]] && [[ "$1" == "-h" || "$1" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${SERVICE_CHOICE:-}" ]]; then
        SERVICE_CHOICE="$(prompt_service_choice 2 1 2 3)" || exit 1
        export SERVICE_CHOICE
    fi

    initialize_service_context
    service_preflight || exit 1

    scenarios=("$@")
    if [[ ${#scenarios[@]} -eq 0 ]]; then
        scenarios=(1 2 3 4 5 6 7)
    fi

    for scenario_arg in "${scenarios[@]}"; do
        scenario="${scenario_arg#s}"
        echo "==> Running scenario S${scenario}"
        run_scenario "$scenario" || exit 1
        echo "==> Completed scenario S${scenario}"
    done
fi
