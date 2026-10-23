#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/../utils.sh"
prefix="$(date -u '+%Y%m%dT%H%M%SZ')_S3_core_"

initialize_scenario

bw lock

dump_process "" "$prefix"
cleanup
