#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
initialize_service_context
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S1_core_"

docker_startup
dump_process "" "$prefix"
cleanup
