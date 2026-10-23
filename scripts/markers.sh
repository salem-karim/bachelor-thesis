#!/usr/bin/env bash

MARKER_LOG="${MARKER_LOG:-marker_log.csv}"

generate_marker() {
    local LABEL="${1:-}"
    local PREFIX="${2:-PW}"
    local HEX_LENGTH="${3:-12}"

    if [[ ! "$LABEL" =~ ^S[1-7]$ ]]; then
        echo "Usage: generate_marker S1-S7 [PREFIX] [HEX_LENGTH]" >&2
        return 1
    fi

    if [[ ! "$PREFIX" =~ ^[A-Za-z][A-Za-z0-9]*$ ]]; then
        echo "Error: invalid prefix" >&2
        return 1
    fi

    if [[ ! "$HEX_LENGTH" =~ ^[0-9]+$ ]] ||
       (( 10#$HEX_LENGTH < 4 || 10#$HEX_LENGTH > 64 )); then
        echo "Error: HEX_LENGTH must be between 4 and 64" >&2
        return 1
    fi

    local HEX_DATA MARKER TIMESTAMP

    HEX_DATA="$(openssl rand -hex "$(( (HEX_LENGTH + 1) / 2 ))")" || return 1
    HEX_DATA="${HEX_DATA:0:$HEX_LENGTH}"

    MARKER="${PREFIX}_${HEX_DATA}_${LABEL}"
    TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if [[ ! -s "$MARKER_LOG" ]]; then
        printf 'timestamp,label,marker\n' >> "$MARKER_LOG" || return 1
    fi

    printf '%s,%s,%s\n' \
        "$TIMESTAMP" "$LABEL" "$MARKER" >> "$MARKER_LOG" || return 1

    printf '%s\n' "$MARKER"
}
