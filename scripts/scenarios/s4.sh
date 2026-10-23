#!/usr/bin/env bash

source ../utils.sh
source ../markers.sh

initialize_scenario

name=$(generate_marker "S4" "NAME" "16")
username=$(generate_marker "S4" "USRNAME" "12")
password=$(generate_marker "S4" "PW" "18")

template_dir="../../lab/warden-json-templates"

jq --arg name "$name" \
   --arg username "$username" \
   --arg password "$password" \
   '.name = $name
    | .type = 1
    | .login = (input | .username = $username | .password = $password)' \
   "$template_dir/item.json" "$template_dir/login.json" |
  bw encode |
  bw create item

dump_process
cleanup
