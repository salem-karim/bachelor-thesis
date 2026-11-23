#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$REPO_ROOT/scripts/utils.sh"

choice="$(prompt_service_choice 2 1 2 3)" || exit 1

case "$choice" in
    1)
        require_command bw jq || exit 1
        generate_items="generate_bitwarden_items"
        ;;
    2)
        require_command bw jq || exit 1
        generate_items="generate_vaultwarden_items"
        ;;
    3)
        require_command passbolt grep jq uuidgen || exit 1
        generate_items="generate_passbolt_items"
        ;;
esac

source "$REPO_ROOT/scripts/markers.sh"

template_dir="$REPO_ROOT/lab/warden-json-templates"
attachment_file=""

name=$(generate_marker "S0" "NAME" "16")
username=$(generate_marker "S0" "USRNAME" "12")
password=$(generate_marker "S0" "PW" "18")
uri="mark-aaaa.example.test"
note=$(generate_marker "S0" "NOTE" "16")

folder_name=$(generate_marker "S0" "FOLDER" "12")
field_text=$(generate_marker "S0" "TEXT" "12")
field_hidden=$(generate_marker "S0" "HIDDEN" "16")
old_password=$(generate_marker "S0" "OLDPW" "18")
new_password=$(generate_marker "S0" "NEWPW" "18")

edit_name="EDITNAME_8d4de3c93a70_S0"
edit_username=$(generate_marker "S0" "EDITUSR" "12")
edit_password=$(generate_marker "S0" "EDITPW" "18")
delete_name="DELNAME_c9ccd5b49beb_S0"
delete_username=$(generate_marker "S0" "DELUSR" "12")
delete_password=$(generate_marker "S0" "DELPW" "18")

secure_note=$(generate_marker "S0" "SECNOTE" "16")
card_name=$(generate_marker "S0" "CARDNAME" "12")
cardholder=$(generate_marker "S0" "CARDHOLDER" "12")
card_code="123"
card_number="4111111111111111"
card_month="04"
card_year="2023"

identity_name=$(generate_marker "S0" "IDNAME" "12")
identity_address=$(generate_marker "S0" "ADDRESS" "16")
identity_ssn=$(generate_marker "S0" "SSN" "9")
identity_phone=$(generate_marker "S0" "PHONE" "12")
identity_email=$(generate_marker "S0" "EMAIL" "16")

create_bw_login() {
    local item_name="$1"
    local item_username="$2"
    local item_password="$3"
    local folder_id="${4:-}"
    local extra_text="${5:-}"
    local extra_hidden="${6:-}"

    jq --arg name "$item_name" \
       --arg username "$item_username" \
       --arg password "$item_password" \
       --arg uri "$uri" \
       --arg note "$note" \
       --arg folder_id "$folder_id" \
       --arg extra_text "$extra_text" \
       --arg extra_hidden "$extra_hidden" \
       --slurpfile login "$template_dir/login.json" '
        .name = $name
        | .type = 1
        | .notes = $note
        | .folderId = (if $folder_id == "" then null else $folder_id end)
        | .login = ($login[0]
            | .username = $username
            | .password = $password
            | .uris = [{"match": null, "uri": $uri}])
        | if $extra_text == "" and $extra_hidden == "" then . else
            .fields = [
                {"name": "text-marker", "value": $extra_text, "type": 0},
                {"name": "hidden-marker", "value": $extra_hidden, "type": 1}
            ]
          end
    ' "$template_dir/item.json" |
        bw encode | bw create item
}

extract_resource_id() {
    grep -oE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}'
}

log_item_ids() {
    printf '%s\n' \
        "item1_id=$item1_id" \
        "item2_id=$item2_id" \
        "item3_id=$item3_id" \
        "item4_id=$item4_id" \
        "item5_id=$item5_id" \
        "item6_id=$item6_id" \
        "item7_id=$item7_id" \
        "item8_id=$item8_id"
}

generate_vaultwarden_items() {
    attachment_file="$(mktemp)"
    trap 'rm -f -- "$attachment_file"' EXIT
    generate_bw_items true
}

generate_bitwarden_items() {
    generate_bw_items false
}

generate_bw_items() {
    local with_attachment="$1"

    echo "Logging in to Bitwarden CLI..." >&2
    bw logout >/dev/null 2>&1 || true
    session="$(bw login --raw)" || {
        echo "ERROR: Bitwarden login failed" >&2
        return 1
    }

    export BW_SESSION="$session"
    unset session


    item1_json="$(create_bw_login "$name" "$username" "$password")"
    item1_id=$(jq -er '.id' <<<"$item1_json")

    folder_json=$(
        jq --arg name "$folder_name" '.name = $name' "$template_dir/folder.json" |
            bw encode | bw create folder
    )
    folder_id=$(jq -er '.id' <<<"$folder_json")

    item2_json="$(create_bw_login "$folder_name" "$username" "$password" "$folder_id" "$field_text" "$field_hidden")"
    item2_id=$(jq -er '.id' <<<"$item2_json")

    item3_json="$(create_bw_login "$name" "$username" "$old_password")"
    item3_id=$(jq -er '.id' <<<"$item3_json")

    if [[ "$with_attachment" == true ]]; then
        printf '%s\n\n%s\n' \
            'Lorem ipsum dolor sit amet, consectetur adipiscing elit.' \
            'Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.' \
            > "$attachment_file"
        bw create attachment \
            --file "$attachment_file" \
            --itemid "$item3_id"
        item3_name="$name attachment"
    else
        item3_name="$name password-change"
    fi

    bw get item "$item3_id" |
        jq --arg name "$item3_name" --arg password "$new_password" \
           '.name = $name | .login.password = $password' |
        bw encode |
        bw edit item "$item3_id" >/dev/null

    item4_json="$(create_bw_login "$edit_name" "$edit_username" "$edit_password")"
    item4_id=$(jq -er '.id' <<<"$item4_json")
    item5_json="$(create_bw_login "$delete_name" "$delete_username" "$delete_password")"
    item5_id=$(jq -er '.id' <<<"$item5_json")

    item6_json=$(
        jq --arg name "$secure_note" --arg notes "$secure_note" \
           '.name = $name | .type = 2 | .secureNote.type = 0 | .notes = $notes' \
           "$template_dir/item.json" |
            bw encode | bw create item
    )
    item6_id=$(jq -er '.id' <<<"$item6_json")

    item7_json=$(
        jq --arg name "$card_name" --arg cardholder "$cardholder" \
           --arg number "$card_number" --arg code "$card_code" \
           --slurpfile card "$template_dir/card.json" \
           '.name = $name | .type = 3
            | .card = ($card[0]
                | .cardholderName = $cardholder
                | .number = $number
                | .code = $code)' \
           "$template_dir/item.json" |
            bw encode | bw create item
    )
    item7_id=$(jq -er '.id' <<<"$item7_json")

    item8_json=$(
        jq --arg name "$identity_name" --arg address "$identity_address" \
           --arg ssn "$identity_ssn" --arg phone "$identity_phone" \
           --arg email "$identity_email" \
           --slurpfile identity "$template_dir/identity.json" \
           '.name = $name | .type = 4
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

    log_item_ids
}

generate_passbolt_items() {
    local card_metadata card_secret identity_metadata identity_secret
    local id_cardholder id_number id_card_code id_month id_year
    local id_name id_address id_phone id_email id_ssn

    item1_id=$(passbolt create resource -n "$name" -u "$username" -p "$password" --uri "$uri" -d "$note" | extract_resource_id)

    folder_id=$(passbolt create folder -n "$folder_name" | extract_resource_id)
    item2_id=$(passbolt create resource -f "$folder_id" -n "$name" -u "$username" -p "$password" --uri "$uri" -d "$note" | extract_resource_id)

    item3_id=$(passbolt create resource -n "$name password-change" -u "$username" -p "$old_password" --uri "$uri" -d "$note" | extract_resource_id)
    passbolt update resource --id "$item3_id" -p "$new_password"

    item4_id=$(passbolt create resource -n "$edit_name" -u "$edit_username" -p "$edit_password" | extract_resource_id)
    item5_id=$(passbolt create resource -n "$delete_name" -u "$delete_username" -p "$delete_password" | extract_resource_id)

    item6_id=$(
        passbolt create resource --type v5-note --name "$secure_note" \
            --secret-field "description=$secure_note" | extract_resource_id
    )

    id_cardholder=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_number=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_card_code=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_month=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_year=$(uuidgen | tr '[:upper:]' '[:lower:]')
    card_metadata=$(jq -cn \
        --arg ch "$id_cardholder" --arg n "$id_number" --arg c "$id_card_code" \
        --arg m "$id_month" --arg y "$id_year" '
        [
          {id:$ch,type:"text",metadata_key:"Cardholder Name"},
          {id:$n,type:"text",metadata_key:"Card Number"},
          {id:$c,type:"text",metadata_key:"Card Code"},
          {id:$m,type:"text",metadata_key:"Expiration Month"},
          {id:$y,type:"text",metadata_key:"Expiration Year"}
        ]')
    card_secret=$(jq -cn \
        --arg ch "$id_cardholder" --arg n "$id_number" --arg c "$id_card_code" \
        --arg m "$id_month" --arg y "$id_year" --arg chv "$cardholder" \
        --arg cv "$card_code" --arg nv "$card_number" --arg mv "$card_month" --arg yv "$card_year" '
        [
          {id:$ch,type:"text",secret_value:$chv},
          {id:$n,type:"text",secret_value:$nv},
          {id:$c,type:"text",secret_value:$cv},
          {id:$m,type:"text",secret_value:$mv},
          {id:$y,type:"text",secret_value:$yv}
        ]')

    item7_id=$(
        passbolt create resource --type v5-custom-fields --name "$card_name" \
            --field "custom_fields=$card_metadata" \
            --secret-field "custom_fields=$card_secret" --yes |
            extract_resource_id
    )

    id_name=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_address=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_phone=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_email=$(uuidgen | tr '[:upper:]' '[:lower:]')
    id_ssn=$(uuidgen | tr '[:upper:]' '[:lower:]')
    identity_metadata=$(jq -cn \
        --arg n "$id_name" --arg a "$id_address" --arg p "$id_phone" \
        --arg e "$id_email" --arg s "$id_ssn" '
        [
          {id:$n,type:"text",metadata_key:"Name"},
          {id:$a,type:"text",metadata_key:"Address"},
          {id:$p,type:"text",metadata_key:"Phone"},
          {id:$e,type:"text",metadata_key:"Email"},
          {id:$s,type:"text",metadata_key:"SSN"}
        ]')
    identity_secret=$(jq -cn \
        --arg n "$id_name" --arg a "$id_address" --arg p "$id_phone" \
        --arg e "$id_email" --arg s "$id_ssn" --arg nv "$identity_name" \
        --arg av "$identity_address" --arg pv "$identity_phone" \
        --arg ev "$identity_email" --arg sv "$identity_ssn" '
        [
          {id:$n,type:"text",secret_value:$nv},
          {id:$a,type:"text",secret_value:$av},
          {id:$p,type:"text",secret_value:$pv},
          {id:$e,type:"text",secret_value:$ev},
          {id:$s,type:"text",secret_value:$sv}
        ]')

    item8_id=$(
        passbolt create resource --type v5-custom-fields --name "$identity_name" \
            --field "custom_fields=$identity_metadata" \
            --secret-field "custom_fields=$identity_secret" --yes |
            extract_resource_id
    )

    log_item_ids
}

"$generate_items"
