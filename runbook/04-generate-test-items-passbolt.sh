#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="../scripts"
source "$SCRIPT_DIR/markers.sh"

# Generate all values through the marker helper.
name=$(generate_marker "S0" "NAME" "16")
username=$(generate_marker "S0" "USRNAME" "12")
password=$(generate_marker "S0" "PW" "18")
uri="mark-aaaa.example.test"
note=$(generate_marker "S0" "NOTE" "16")

folder_name=$(generate_marker "S0" "FOLDER" "12")

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
card_month="04"
card_year="2023"
# Synthetic 16-digit test number; not a real payment card.
card_number="4111111111111111"

# Generate a UUID for every custom field
id_cardholder=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_number=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_card_code=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_month=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_year=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Field labels: metadata
metadata_fields=$(jq -cn \
  --arg ch "$id_cardholder" \
  --arg n "$id_number" \
  --arg c "$id_card_code" \
  --arg m "$id_month" \
  --arg y "$id_year" '
  [
    {id:$ch, type:"text", metadata_key:"Cardholder Name"},
    {id:$n, type:"text", metadata_key:"Card Number"},
    {id:$c, type:"text", metadata_key:"Card Code"},
    {id:$m, type:"text", metadata_key:"Expiration Month"},
    {id:$y, type:"text", metadata_key:"Expiration Year"},
  ]')

# Field values: encrypted secret
secret_fields=$(jq -cn \
  --arg ch "$id_cardholder" \
  --arg n "$id_number" \
  --arg c "$id_card_code" \
  --arg m "$id_month" \
  --arg y "$id_year" \
  --arg chv "$cardholder" \
  --arg cv "$card_code" \
  --arg nv "$card_number" \
  --arg mv "$card_month" \
  --arg yv "$card_year" '
  [
    {id:$ch, type:"text", secret_value:$chv},
    {id:$ch, type:"text", secret_value:$chv},
    {id:$n, type:"text", secret_value:$nv},
    {id:$m, type:"text", secret_value:$mv},
    {id:$y, type:"text", secret_value:$yv},
  ]')

identity_name=$(generate_marker "S0" "IDNAME" "12")
identity_address=$(generate_marker "S0" "ADDRESS" "16")
identity_ssn=$(generate_marker "S0" "SSN" "9")
identity_phone=$(generate_marker "S0" "PHONE" "12")
identity_email=$(generate_marker "S0" "EMAIL" "16")

# Generate one UUID per field
id_name=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_address=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_phone=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_email=$(uuidgen | tr '[:upper:]' '[:lower:]')
id_ssn=$(uuidgen | tr '[:upper:]' '[:lower:]')

# Labels go in metadata
metadata_fields=$(jq -cn \
  --arg n "$id_name" \
  --arg a "$id_address" \
  --arg p "$id_phone" \
  --arg e "$id_email" \
  --arg s "$id_ssn" '
  [
    {id:$n, type:"text", metadata_key:"Name"},
    {id:$a, type:"text", metadata_key:"Address"},
    {id:$p, type:"text", metadata_key:"Phone"},
    {id:$e, type:"text", metadata_key:"Email"},
    {id:$s, type:"text", metadata_key:"SSN"}
  ]')

# Values go in the encrypted secret
secret_fields=$(jq -cn \
  --arg n "$id_name" \
  --arg a "$id_address" \
  --arg p "$id_phone" \
  --arg e "$id_email" \
  --arg s "$id_ssn" \
  --arg nv "$identity_name" \
  --arg av "$identity_address" \
  --arg pv "$identity_phone" \
  --arg ev "$identity_email" \
  --arg sv "$identity_ssn" '
  [
    {id:$n, type:"text", secret_value:$nv},
    {id:$a, type:"text", secret_value:$av},
    {id:$p, type:"text", secret_value:$pv},
    {id:$e, type:"text", secret_value:$ev},
    {id:$s, type:"text", secret_value:$sv}
  ]')

# 1. Basic login.
item1_id=$(passbolt create resource -n "$name" -u "$username" -p "$password" --uri "$uri" -d "$note" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}')

# 2. Login in a folder, with text and hidden custom fields.
folder_id=$(passbolt create folder -n "$folder_name"| grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}')

item2_id=$(passbolt create resource -f "$folder_id" -n "$name" -u "$username" -p "$password" --uri "$uri" -d "$note" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}')

# 3. Login Item, then change its password.   CHANGED FROM ATTACHEMENT, PASSBOLT DOES NOT HAVE ATTACHEMENTS
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

passbolt update resource --id "$item3_id" -p "$new_password"

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
item6_id=$(
    passbolt create resource \
        --type v5-note \
        --name "$secure_note" \
        --secret-field description="$secure_note" | grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}')

# 7. Payment card
item7_json=$(passbolt create resource \
  --type v5-custom-fields \
  --name "$card_name" \
  --field "custom_fields=$metadata_fields" \
  --secret-field "custom_fields=$secret_fields" \
  --json \
  --yes
)

item7_id=$(jq -er '.id' <<<"$item7_json")

# 8. Identity
item8_json=$(passbolt create resource \
  --type v5-custom-fields \
  --name "$identity_name" \
  --field "custom_fields=$metadata_fields" \
  --secret-field "custom_fields=$secret_fields" \
  --json \
  --yes
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
