#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="../scripts"
source "$SCRIPT_DIR/markers.sh"

template_dir="../lab/warden-json-templates"
attachment_dir="$(mktemp -d)"
trap 'rm -rf -- "$attachment_dir"' EXIT

# Generate all values through the marker helper.
name=$(generate_marker "S0" "NAME" "16")
username=$(generate_marker "S0" "USRNAME" "12")
password=$(generate_marker "S0" "PW" "18")
uri="mark-aaaa.example.test"
note=$(generate_marker "S0" "NOTE" "16")

folder_name=$(generate_marker "S0" "FOLDER" "12")
field_text=$(generate_marker "S0" "TEXT" "12")
field_hidden=$(generate_marker "S0" "HIDDEN" "16")

attachment_name="s0-lorem-ipsum.txt"
old_password=$(generate_marker "S0" "OLDPW" "18")
new_password=$(generate_marker "S0" "NEWPW" "18")

# Hard code name for the scenario script to find item id
edit_name="EDITNAME_8d4de3c93a70_S0"
edit_username=$(generate_marker "S0" "EDITUSR" "12")
edit_password=$(generate_marker "S0" "EDITPW" "18")

# Hard code name for the scenario script to find item id
delete_name="DELNAME_c9ccd5b49beb_S0"
delete_username=$(generate_marker "S0" "DELUSR" "12")
delete_password=$(generate_marker "S0" "DELPW" "18")

secure_note=$(generate_marker "S0" "SECNOTE" "16")

card_name=$(generate_marker "S0" "CARDNAME" "12")
cardholder=$(generate_marker "S0" "CARDHOLDER" "12")
card_code="123"
# Synthetic 16-digit test number; not a real payment card.
card_number="4111111111111111"

identity_name=$(generate_marker "S0" "IDNAME" "12")
identity_address=$(generate_marker "S0" "ADDRESS" "16")
identity_ssn=$(generate_marker "S0" "SSN" "9")
identity_phone=$(generate_marker "S0" "PHONE" "12")
identity_email=$(generate_marker "S0" "EMAIL" "16")

# Helper: create an item from the base template and a sub-template.
create_item() {
    local subtemplate="$1"
    shift

    jq "$@" \
        --slurpfile sub "$template_dir/$subtemplate.json" \
        '. as $item | $item' \
        "$template_dir/item.json"
}

# 1. Basic login.
item1_json=$(
    jq --arg name "$name" \
       --arg username "$username" \
       --arg password "$password" \
       --arg uri "$uri" \
       --arg note "$note" \
       --slurpfile login "$template_dir/login.json" \
       '.name = $name
        | .type = 1
        | .notes = $note
        | .login = ($login[0]
            | .username = $username
            | .password = $password
            | .uris = [{"match": null, "uri": $uri}])' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item1_id=$(jq -er '.id' <<<"$item1_json")

# 2. Login in a folder, with text and hidden custom fields.
folder_json=$(
    jq --arg name "$folder_name" \
       '.name = $name' "$template_dir/folder.json" |
       bw encode | bw create folder
)
folder_id=$(jq -er '.id' <<<"$folder_json")

item2_json=$(
    jq --arg name "$folder_name" \
       --arg username "$username" \
       --arg password "$password" \
       --arg text "$field_text" \
       --arg hidden "$field_hidden" \
       --arg folder_id "$folder_id" \
       --slurpfile login "$template_dir/login.json" \
       '.name = $name
        | .type = 1
        | .folderId = $folder_id
        | .login = ($login[0]
            | .username = $username
            | .password = $password)
        | .fields = [
            {"name": "text-marker", "value": $text, "type": 0},
            {"name": "hidden-marker", "value": $hidden, "type": 1}
          ]' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item2_id=$(jq -er '.id' <<<"$item2_json")

# 3. Login with a text attachment, then change its password.
printf '%s\n\n%s\n' \
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit.' \
    'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.' \
    > "$attachment_dir/$attachment_name"

item3_json=$(
    jq --arg name "$name" \
       --arg username "$username" \
       --arg password "$old_password" \
       --slurpfile login "$template_dir/login.json" \
       '.name = ($name + " attachment")
        | .type = 1
        | .login = ($login[0]
            | .username = $username
            | .password = $password)' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item3_id=$(jq -er '.id' <<<"$item3_json")

bw create attachment \
    --file "$attachment_dir/$attachment_name" \
    --itemid "$item3_id"

bw get item "$item3_id" |
    jq --arg password "$new_password" \
       '.login.password = $password' |
    bw encode |
    bw edit item "$item3_id" >/dev/null

# 4. Login used as the S5 edit target.
item4_json=$(
    jq --arg name "$edit_name" \
       --arg username "$edit_username" \
       --arg password "$edit_password" \
       --slurpfile login "$template_dir/login.json" \
       '.name = $name
        | .type = 1
        | .login = ($login[0]
            | .username = $username
            | .password = $password)' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item4_id=$(jq -er '.id' <<<"$item4_json")

# 5. Login used as the S6 delete target.
item5_json=$(
    jq --arg name "$delete_name" \
       --arg username "$delete_username" \
       --arg password "$delete_password" \
       --slurpfile login "$template_dir/login.json" \
       '.name = $name
        | .type = 1
        | .login = ($login[0]
            | .username = $username
            | .password = $password)' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item5_id=$(jq -er '.id' <<<"$item5_json")

# 6. Secure note.
item6_json=$(
    jq --arg name "$secure_note" \
       --arg notes "$secure_note" \
       '.name = $name
        | .type = 2
        | .secureNote.type = 0
        | .notes = $notes' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item6_id=$(jq -er '.id' <<<"$item6_json")

# 7. Payment card.
item7_json=$(
    jq --arg name "$card_name" \
       --arg cardholder "$cardholder" \
       --arg number "$card_number" \
       --arg code "$card_code" \
       --slurpfile card "$template_dir/card.json" \
       '.name = $name
        | .type = 3
        | .card = ($card[0]
            | .cardholderName = $cardholder
            | .number = $number
            | .code = $code)' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item7_id=$(jq -er '.id' <<<"$item7_json")

# 8. Identity.
item8_json=$(
    jq --arg name "$identity_name" \
       --arg address "$identity_address" \
       --arg ssn "$identity_ssn" \
       --arg phone "$identity_phone" \
       --arg email "$identity_email" \
       --slurpfile identity "$template_dir/identity.json" \
       '.name = $name
        | .type = 4
        | .identity = ($identity[0]
            | .firstName = $name
            | .address1 = $address
            | .ssn = $ssn
            | .phone = $phone
            | .email = $email)' \
       "$template_dir/item.json" |
       bw encode | bw create item
)
item8_id=$(jq -er '.id' <<<"$item8_json")

# Log the created IDs for subsequent edit/delete scenarios.
printf '%s\n' \
    "item1_id=$item1_id" \
    "item2_id=$item2_id" \
    "item3_id=$item3_id" \
    "item4_id=$item4_id" \
    "item5_id=$item5_id" \
    "item6_id=$item6_id" \
    "item7_id=$item7_id" \
    "item8_id=$item8_id"
