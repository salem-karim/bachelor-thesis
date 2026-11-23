#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
source "$SCRIPT_DIR/../markers.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S5_core_"

initialize_scenario

target_name="EDITNAME_8d4de3c93a70_S0"
name=$(generate_marker "S5" "NAME" "16")
username=$(generate_marker "S5" "USRNAME" "12")
password=$(generate_marker "S5" "PW" "18")

if [[ "${SERVICE_CHOICE}" != "3" ]]; then
    item_id=$(
      bw list items |
        jq -er --arg name "$target_name" '
          [.[] | select(.name == $name and .type == 1)]
          | if length == 1 then .[0].id
            else error("Expected exactly one matching login item")
            end
        '
    ) || exit 1

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
    item_id=$(
      passbolt list resource --json |
          jq -er --arg name "$target_name"
          '.[] | select(.name == $target_name) | .id'
    )

    passbolt update resource --id "$item_id" \
        -n "$name" -u "$username" -p "$password"
fi

dump_process "" "$prefix"
cleanup
