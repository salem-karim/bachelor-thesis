#!/usr/bin/env bash

source ../utils.sh

initialize_scenario

target_name=Hello

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

dump_process
cleanup
