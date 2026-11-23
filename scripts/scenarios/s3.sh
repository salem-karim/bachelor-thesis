#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S3_core_"

initialize_scenario

if [[ "${SERVICE_CHOICE}" != "3" ]]; then
    bw lock
else
    # Passbolt does not have a lock command,
    # but after the exec command its connection closes
    target_name="DELNAME_c9ccd5b49beb_S0"
    item_id=$(
      passbolt list resource --json |
          jq -er --arg name "$target_name"
          '.[] | select(.name == $target_name) | .id'
    )
    export TEST_SECRET="passbolt://$item_id"

    passbolt exec -- sh -c 'echo "$TEST_SECRET"'
fi

dump_process "" "$prefix"
cleanup
