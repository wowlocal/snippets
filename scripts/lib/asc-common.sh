#!/bin/bash
# Shared private configuration loader. Caller supplies fail().
function validate_private_file() {
    local path="$1"
    local description="$2"
    local owner
    local mode

    [ -f "$path" ] || fail "$description not found: $path"
    owner="$(stat -f '%Su' "$path")"
    mode="$(stat -f '%OLp' "$path")"
    [ "$owner" = "$(id -un)" ] || fail "$description must be owned by the current user"
    if (( (8#$mode & 8#077) != 0 )); then
        fail "$description has unsafe permissions $mode; expected 600 or stricter"
    fi
}

function load_configuration() {
    validate_private_file "$CONFIG_FILE" "App Store Connect configuration"
    set -a
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    set +a

    : "${ASC_KEY_ID:?Missing ASC_KEY_ID in $CONFIG_FILE}"
    : "${ASC_ISSUER_ID:?Missing ASC_ISSUER_ID in $CONFIG_FILE}"
    : "${ASC_PRIVATE_KEY_PATH:?Missing ASC_PRIVATE_KEY_PATH in $CONFIG_FILE}"
    : "${ASC_APP_ID:?Missing ASC_APP_ID in $CONFIG_FILE}"
    : "${ASC_BUNDLE_ID:?Missing ASC_BUNDLE_ID in $CONFIG_FILE}"

    validate_private_file "$ASC_PRIVATE_KEY_PATH" "App Store Connect private key"
    ASC_KEY_PATH="$ASC_PRIVATE_KEY_PATH"
    export ASC_KEY_PATH
    [ "$ASC_BUNDLE_ID" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
        || fail "Configured bundle ID is $ASC_BUNDLE_ID, expected $EXPECTED_BUNDLE_IDENTIFIER"
    [[ "$ASC_APP_ID" =~ ^[0-9]+$ ]] || fail "ASC_APP_ID must be the numeric Apple ID"
}

function asc_cli() {
    env \
        -u HTTP_PROXY \
        -u HTTPS_PROXY \
        -u ALL_PROXY \
        -u http_proxy \
        -u https_proxy \
        -u all_proxy \
        ASC_STRICT_AUTH=true \
        asc "$@"
}

