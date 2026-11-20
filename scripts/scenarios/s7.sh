#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S7_core_"

initialize_scenario

target_name="EDITNAME_8d4de3c93a70_S0"

if [[ "${SERVICE_CHOICE}" != "3" ]]; then
bw list items --search "$target_name" |
	jq -er --arg name "$target_name" '
		[.[] | select(.name == $name and .type == 1)]
		| if length == 1 then .[0]
			else error("Expected exactly one matching login item")
			end
	'
else
    item_id=$(
      passbolt list resource --json |
          jq -er --arg name "$target_name"
          '.[] | select(.name == "My Resource") | .id'
    )

    passbolt get resource --id "$item_id"
fi

dump_process "" "$prefix"
cleanup
