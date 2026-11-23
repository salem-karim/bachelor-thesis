#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S6_core_"

initialize_scenario

target_name="DELNAME_c9ccd5b49beb_S0"

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

    bw delete item "$item_id"
else
    item_id=$(
      passbolt list resource --json |
          jq -er --arg name "$target_name"
          '.[] | select(.name == $target_name) | .id'
    )

    passbolt delete resource --id "$item_id"
fi

dump_process "" "$prefix"
cleanup
