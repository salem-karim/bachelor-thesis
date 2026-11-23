#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
source "$SCRIPT_DIR/../markers.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S4_core_"

initialize_scenario

name=$(generate_marker "S4" "NAME" "16")
username=$(generate_marker "S4" "USRNAME" "12")
password=$(generate_marker "S4" "PW" "18")

template_dir="$REPO_ROOT/lab/warden-json-templates"

if [[ "${SERVICE_CHOICE}" != "3" ]]; then
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

dump_process "" "$prefix"
cleanup
