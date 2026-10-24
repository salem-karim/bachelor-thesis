#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
source "$SCRIPT_DIR/../markers.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S5_core_"

initialize_scenario

target_name="Test Login"

item_id=$(
  bw list items |
    jq -er --arg name "$target_name" '
      [.[] | select(.name == $name and .type == 1)]
      | if length == 1 then .[0].id
        else error("Expected exactly one matching login item")
        end
    '
) || exit 1

name=$(generate_marker "S5" "NAME" "16")
username=$(generate_marker "S5" "USRNAME" "12")
password=$(generate_marker "S5" "PW" "18")

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

dump_process "" "$prefix"
cleanup
