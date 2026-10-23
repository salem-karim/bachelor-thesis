#!/usr/bin/env bash

source ../utils.sh
source ../markers.sh

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

dump_process
cleanup
