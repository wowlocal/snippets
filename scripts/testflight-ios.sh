#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$PROJECT_DIR/Snippets.xcodeproj"
SCHEME="Snippets iOS"
CONFIGURATION="Release"
TEAM_IDENTIFIER="H8QG3CBM96"
EXPECTED_BUNDLE_IDENTIFIER="com.khm.snippets"
EXPECTED_ICLOUD_CONTAINER="iCloud.com.khm.snippets"
CONFIG_FILE="${SNIPPETS_ASC_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/snippets/app-store-connect.env}"

ACTION="check"
GROUP_NAME=""
CREATE_GROUP=0
ALLOW_DIRTY=0
SKIP_TESTS=0
KEEP_ARTIFACTS=0
BUILD_NUMBER=""
MARKETING_VERSION_OVERRIDE=""
USES_NON_EXEMPT_ENCRYPTION=""
WORK_DIR=""
RUN_SUCCEEDED=0

function usage() {
    cat <<'EOF'
Validate, archive, and upload the universal Snippets iPhone/iPad app to TestFlight.

Usage:
  ./scripts/testflight-ios.sh [action] [options]

Actions (choose one; default is --check):
  --check                 Verify local credentials and the App Store Connect app record.
  --archive               Run preflight checks, archive, export, and validate an IPA with Apple.
  --upload                Archive, validate, upload, and wait for App Store processing.

Options:
  --group <name>          Add the processed build to an existing internal TestFlight group.
  --create-group          Create --group as an internal group if it does not exist.
  --build-number <n>      Use an explicit positive integer CFBundleVersion.
                          Default: the project value or the next unused value, whichever is newer.
  --marketing-version <v> Archive and upload with this CFBundleShortVersionString
                          without editing the project. Use only to replace a build
                          on an existing App Store version.
  --uses-non-exempt-encryption <true|false>
                          Record the confirmed export-compliance answer after upload.
  --skip-tests            Skip Core, macOS build, and iPhone/iPad simulator tests.
  --allow-dirty           Allow --upload from a dirty Git worktree.
  --keep-artifacts        Keep temporary archive, IPA, and validation files after success.
  --config <path>         Override the local App Store Connect environment file.
  -h, --help              Show this help.

Examples:
  ./scripts/testflight-ios.sh --check
  ./scripts/testflight-ios.sh --archive --skip-tests
  ./scripts/testflight-ios.sh --upload --group "Internal Testers" --create-group

The script never reads a private key from the repository. Expected local configuration:
  ~/.config/snippets/app-store-connect.env

Install the App Store Connect CLI once with: brew install asc

The build is App Store eligible. It is not marked TestFlight Internal Only, so the same
binary may later be used for external TestFlight or an App Store submission.
EOF
}

function info() {
    printf '==> %s\n' "$1"
}

function success() {
    printf '  ✓ %s\n' "$1"
}

function warn() {
    printf '  ! %s\n' "$1" >&2
}

function fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

function require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

function cleanup() {
    local status=$?
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        if [ "$status" -eq 0 ] && [ "$RUN_SUCCEEDED" -eq 1 ] && [ "$KEEP_ARTIFACTS" -eq 0 ]; then
            rm -rf "$WORK_DIR"
        else
            printf 'Artifacts retained at: %s\n' "$WORK_DIR" >&2
        fi
    fi
}

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

function verify_app_record() {
    local app_json
    local actual_id
    local actual_bundle_id
    local actual_name

    info "Authenticating with App Store Connect"
    app_json="$(asc_cli apps list --bundle-id "$ASC_BUNDLE_ID" --output json)"
    actual_id="$(jq -r --arg app_id "$ASC_APP_ID" \
        '.data[] | select(.id == $app_id) | .id' <<<"$app_json" | head -1)"
    actual_bundle_id="$(jq -r --arg app_id "$ASC_APP_ID" \
        '.data[] | select(.id == $app_id) | .attributes.bundleId' <<<"$app_json" | head -1)"
    actual_name="$(jq -r --arg app_id "$ASC_APP_ID" \
        '.data[] | select(.id == $app_id) | .attributes.name' <<<"$app_json" | head -1)"

    [ "$actual_id" = "$ASC_APP_ID" ] || fail "App Store Connect returned an unexpected app ID"
    [ "$actual_bundle_id" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
        || fail "App Store Connect bundle ID is $actual_bundle_id"
    success "$actual_name ($actual_bundle_id, Apple ID $actual_id)"
}

function read_build_settings() {
    local settings_json
    local settings_args=(
        -project "$PROJECT_PATH"
        -scheme "$SCHEME"
        -configuration "$CONFIGURATION"
        -destination 'generic/platform=iOS'
        -showBuildSettings
        -json
    )
    if [ -n "$MARKETING_VERSION_OVERRIDE" ]; then
        settings_args+=("MARKETING_VERSION=$MARKETING_VERSION_OVERRIDE")
    fi
    settings_json="$(xcodebuild "${settings_args[@]}")"
    MARKETING_VERSION="$(jq -r 'map(select(.target == "Snippets iOS"))[0].buildSettings.MARKETING_VERSION // empty' \
        <<<"$settings_json")"
    PROJECT_BUILD_NUMBER="$(jq -r 'map(select(.target == "Snippets iOS"))[0].buildSettings.CURRENT_PROJECT_VERSION // empty' \
        <<<"$settings_json")"
    PROJECT_BUNDLE_IDENTIFIER="$(jq -r 'map(select(.target == "Snippets iOS"))[0].buildSettings.PRODUCT_BUNDLE_IDENTIFIER // empty' \
        <<<"$settings_json")"

    [ -n "$MARKETING_VERSION" ] || fail "Could not read MARKETING_VERSION"
    [[ "$PROJECT_BUILD_NUMBER" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION must be a positive integer"
    [ "$PROJECT_BUNDLE_IDENTIFIER" = "$EXPECTED_BUNDLE_IDENTIFIER" ] \
        || fail "Release bundle ID is $PROJECT_BUNDLE_IDENTIFIER"
}

function resolve_build_number() {
    local build_numbers_json
    local latest_observed_build
    local next_build

    build_numbers_json="$(asc_cli builds next-build-number \
        --app "$ASC_APP_ID" \
        --version "$MARKETING_VERSION" \
        --platform IOS \
        --initial-build-number "$PROJECT_BUILD_NUMBER" \
        --output json)"
    latest_observed_build="$(jq -r '.latestObservedBuildNumber // "0"' <<<"$build_numbers_json")"
    next_build="$(jq -r '.nextBuildNumber // empty' <<<"$build_numbers_json")"
    [[ "$latest_observed_build" =~ ^[0-9]+$ ]] || fail "App Store Connect returned an invalid latest build number"
    [[ "$next_build" =~ ^[1-9][0-9]*$ ]] || fail "App Store Connect returned an invalid next build number"

    if [ -n "$BUILD_NUMBER" ]; then
        [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "--build-number must be a positive integer"
        if [ "$BUILD_NUMBER" -le "$latest_observed_build" ]; then
            fail "Build $BUILD_NUMBER is not newer than observed build $latest_observed_build for version $MARKETING_VERSION"
        fi
    else
        BUILD_NUMBER="$PROJECT_BUILD_NUMBER"
        if [ "$BUILD_NUMBER" -lt "$next_build" ]; then
            BUILD_NUMBER="$next_build"
        fi
    fi

    success "Version $MARKETING_VERSION, build $BUILD_NUMBER (latest observed: $latest_observed_build)"
}

function verify_worktree() {
    local status
    status="$(git -C "$PROJECT_DIR" status --porcelain)"
    if [ -n "$status" ]; then
        if [ "$ACTION" = "upload" ] && [ "$ALLOW_DIRTY" -eq 0 ]; then
            fail "Git worktree is dirty; commit changes or pass --allow-dirty explicitly"
        fi
        warn "Building from a dirty Git worktree"
    fi
}

function simulator_id() {
    local family="$1"
    local devices_json="$2"
    jq -r --arg family "$family" '
        [
            .devices | to_entries[]
            | select(.key | contains(".iOS-26-"))
            | .key as $runtime
            | .value[]
            | select(.isAvailable == true)
            | select(.deviceTypeIdentifier | contains("SimDeviceType." + $family + "-"))
            | { udid, name, state, runtime: $runtime }
        ]
        | sort_by(if .state == "Booted" then 0 else 1 end, .runtime)
        | first.udid // empty
    ' <<<"$devices_json"
}

function run_preflight_tests() {
    local devices_json
    local iphone_id
    local ipad_id

    if [ "$SKIP_TESTS" -eq 1 ]; then
        warn "Preflight tests skipped explicitly"
        return
    fi

    info "Running CorePackage tests"
    swift test --package-path "$PROJECT_DIR/CorePackage"

    info "Building the shared macOS target"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme Snippets \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$WORK_DIR/macos-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        build

    devices_json="$(xcrun simctl list devices available --json)"
    iphone_id="$(simulator_id iPhone "$devices_json")"
    ipad_id="$(simulator_id iPad "$devices_json")"
    [ -n "$iphone_id" ] || fail "No available iOS 26 iPhone simulator; use --skip-tests only after testing elsewhere"
    [ -n "$ipad_id" ] || fail "No available iOS 26 iPad simulator; use --skip-tests only after testing elsewhere"

    info "Running iPhone unit and UI tests"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$iphone_id" \
        -derivedDataPath "$WORK_DIR/iphone-tests-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        test

    info "Running iPad unit and UI tests"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$ipad_id" \
        -derivedDataPath "$WORK_DIR/ipad-tests-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        test
    success "Preflight tests passed"
}

function local_distribution_certificate() {
    local identity
    identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+[0-9A-F]+[[:space:]]+"(Apple Distribution:.*\(H8QG3CBM96\))"$/\1/p' \
        | head -1)"
    [ -n "$identity" ] || fail "No local Apple Distribution identity for team $TEAM_IDENTIFIER"

    LOCAL_DISTRIBUTION_SERIAL="$(security find-certificate -c "$identity" -p \
        | openssl x509 -noout -serial \
        | sed -E 's/^serial=//' \
        | tr '[:lower:]' '[:upper:]')"
    [ -n "$LOCAL_DISTRIBUTION_SERIAL" ] || fail "Could not read the Apple Distribution certificate serial"
}

function install_profile_by_id() {
    local profile_id="$1"
    local profile_json
    local profile_uuid
    local decoded_profile="$WORK_DIR/app-store-profile.mobileprovision"
    local decoded_plist="$WORK_DIR/app-store-profile.plist"
    local profile_destination_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

    profile_json="$(asc_cli profiles view --id "$profile_id" --output json)"
    APP_STORE_PROFILE_NAME="$(jq -r '.data.attributes.name // empty' <<<"$profile_json")"
    profile_uuid="$(jq -r '.data.attributes.uuid // empty' <<<"$profile_json")"
    [ -n "$APP_STORE_PROFILE_NAME" ] || fail "Provisioning profile has no name"
    [ -n "$profile_uuid" ] || fail "Provisioning profile has no UUID"

    asc_cli profiles download --id "$profile_id" --output "$decoded_profile" >/dev/null
    security cms -D -i "$decoded_profile" >"$decoded_plist"
    [ "$(plutil -extract UUID raw -o - "$decoded_plist")" = "$profile_uuid" ] \
        || fail "Downloaded provisioning profile UUID mismatch"
    install -d -m 700 "$profile_destination_dir"
    install -m 600 "$decoded_profile" "$profile_destination_dir/$profile_uuid.mobileprovision"
    success "Installed provisioning profile: $APP_STORE_PROFILE_NAME"
}

function ensure_app_store_profile() {
    local bundle_ids_json
    local profiles_json
    local profile
    local profile_id
    local profile_json
    local profile_matches
    local profile_response
    local certificates_json
    local certificate_resource_id

    info "Resolving iOS App Store signing assets"
    local_distribution_certificate
    bundle_ids_json="$(asc_cli bundle-ids list --paginate --output json)"
    BUNDLE_RESOURCE_ID="$(jq -r --arg identifier "$EXPECTED_BUNDLE_IDENTIFIER" \
        '.data[] | select(.attributes.identifier == $identifier) | .id' \
        <<<"$bundle_ids_json" | head -1)"
    [ -n "$BUNDLE_RESOURCE_ID" ] || fail "Registered bundle ID not found in the Developer portal"

    profiles_json="$(asc_cli profiles list \
        --profile-type IOS_APP_STORE \
        --profile-state ACTIVE \
        --paginate \
        --output json)"
    profile="$(jq -c '
        [
            .data[]
            | select(.attributes.profileType == "IOS_APP_STORE")
            | select(.attributes.profileState == "ACTIVE")
        ]
        | sort_by(.attributes.expirationDate)
        | reverse[]
    ' <<<"$profiles_json")"

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        profile_id="$(jq -r '.id' <<<"$candidate")"
        profile_json="$(asc_cli profiles view \
            --id "$profile_id" \
            --include bundleId,certificates \
            --output json)"
        profile_matches="$(jq -r \
            --arg bundle_id "$BUNDLE_RESOURCE_ID" \
            --arg serial "$LOCAL_DISTRIBUTION_SERIAL" '
                (.data.relationships.bundleId.data.id == $bundle_id)
                and any(
                    .included[]?;
                    .type == "certificates"
                    and ((.attributes.serialNumber // "") | ascii_upcase) == $serial
                )
            ' <<<"$profile_json")"
        if [ "$profile_matches" = "true" ]; then
            install_profile_by_id "$profile_id"
            return
        fi
    done <<<"$profile"

    certificates_json="$(asc_cli certificates list \
        --certificate-type DISTRIBUTION \
        --paginate \
        --output json)"
    certificate_resource_id="$(jq -r --arg serial "$LOCAL_DISTRIBUTION_SERIAL" '
        .data[]
        | select((.attributes.serialNumber | ascii_upcase) == $serial)
        | .id
    ' <<<"$certificates_json" | head -1)"
    [ -n "$certificate_resource_id" ] \
        || fail "The local Apple Distribution certificate is not active in the Developer portal"

    info "Creating an iOS App Store provisioning profile for the local Distribution certificate"
    profile_response="$(asc_cli profiles create \
        --name "Snippets iOS App Store $(date -u '+%Y%m%d-%H%M%S')" \
        --profile-type IOS_APP_STORE \
        --bundle "$BUNDLE_RESOURCE_ID" \
        --certificate "$certificate_resource_id" \
        --output json)"
    profile_id="$(jq -r '.data.id // empty' <<<"$profile_response")"
    [ -n "$profile_id" ] || fail "App Store Connect did not return the created profile ID"
    install_profile_by_id "$profile_id"
}

function create_export_options() {
    EXPORT_OPTIONS_PATH="$WORK_DIR/ExportOptions.plist"
    plutil -create xml1 "$EXPORT_OPTIONS_PATH"
    plutil -insert method -string app-store-connect "$EXPORT_OPTIONS_PATH"
    plutil -insert destination -string export "$EXPORT_OPTIONS_PATH"
    plutil -insert signingStyle -string manual "$EXPORT_OPTIONS_PATH"
    plutil -insert signingCertificate -string 'Apple Distribution' "$EXPORT_OPTIONS_PATH"
    plutil -insert teamID -string "$TEAM_IDENTIFIER" "$EXPORT_OPTIONS_PATH"
    plutil -insert iCloudContainerEnvironment -string Production "$EXPORT_OPTIONS_PATH"
    plutil -insert manageAppVersionAndBuildNumber -bool NO "$EXPORT_OPTIONS_PATH"
    plutil -insert stripSwiftSymbols -bool YES "$EXPORT_OPTIONS_PATH"
    plutil -insert uploadSymbols -bool YES "$EXPORT_OPTIONS_PATH"
    plutil -insert testFlightInternalTestingOnly -bool NO "$EXPORT_OPTIONS_PATH"
    /usr/libexec/PlistBuddy -c 'Add :provisioningProfiles dict' "$EXPORT_OPTIONS_PATH"
    /usr/libexec/PlistBuddy \
        -c "Add :provisioningProfiles:$EXPECTED_BUNDLE_IDENTIFIER string $APP_STORE_PROFILE_NAME" \
        "$EXPORT_OPTIONS_PATH"
}

function archive_and_export() {
    ARCHIVE_PATH="$WORK_DIR/Snippets-iOS.xcarchive"
    EXPORT_PATH="$WORK_DIR/export"
    DERIVED_DATA_PATH="$WORK_DIR/archive-derived"

    info "Archiving Snippets iOS $MARKETING_VERSION ($BUILD_NUMBER)"
    xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -archivePath "$ARCHIVE_PATH" \
        -allowProvisioningUpdates \
        -authenticationKeyPath "$ASC_KEY_PATH" \
        -authenticationKeyID "$ASC_KEY_ID" \
        -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
        MARKETING_VERSION="$MARKETING_VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        -quiet
    [ -d "$ARCHIVE_PATH" ] || fail "Xcode did not create the archive"

    ensure_app_store_profile
    create_export_options
    mkdir -p "$EXPORT_PATH"
    info "Exporting App Store Connect IPA"
    xcodebuild -exportArchive \
        -archivePath "$ARCHIVE_PATH" \
        -exportPath "$EXPORT_PATH" \
        -exportOptionsPlist "$EXPORT_OPTIONS_PATH" \
        -quiet

    IPA_PATH="$(find "$EXPORT_PATH" -maxdepth 1 -type f -name '*.ipa' -print -quit)"
    [ -n "$IPA_PATH" ] || fail "Xcode did not export an IPA"
    success "Exported $(basename "$IPA_PATH")"
}

function json_array_contains() {
    local json="$1"
    local key="$2"
    local expected="$3"
    jq -e --arg key "$key" --arg expected "$expected" \
        '.[$key] | type == "array" and index($expected) != null' <<<"$json" >/dev/null
}

function verify_profile_certificate() {
    local app_path="$1"
    local profile_plist="$2"
    local certificate_index=0
    local leaf_digest
    local candidate_digest

    codesign -d --extract-certificates="$WORK_DIR/signing-leaf" \
        "$app_path" >/dev/null 2>&1 || return 1
    [ -f "$WORK_DIR/signing-leaf0" ] || return 1
    leaf_digest="$(shasum -a 256 "$WORK_DIR/signing-leaf0" | cut -d' ' -f1)"

    while plutil -extract "DeveloperCertificates.$certificate_index" raw -o - \
        "$profile_plist" 2>/dev/null \
        | base64 -d >"$WORK_DIR/profile-certificate" 2>/dev/null; do
        candidate_digest="$(shasum -a 256 "$WORK_DIR/profile-certificate" | cut -d' ' -f1)"
        if [ "$candidate_digest" = "$leaf_digest" ]; then
            return 0
        fi
        certificate_index=$((certificate_index + 1))
    done
    return 1
}

function verify_exported_ipa() {
    local unpacked_path="$WORK_DIR/unpacked-ipa"
    local app_path
    local info_plist
    local entitlements_plist="$WORK_DIR/exported-entitlements.plist"
    local profile_plist="$WORK_DIR/exported-profile.plist"
    local entitlements_json
    local actual_bundle_id
    local actual_version
    local actual_build
    local app_identifier
    local profile_app_identifier
    local profile_cloud_environment
    local profile_cloud_services
    local profile_cloud_containers
    local profile_keychain_groups
    local expiration_epoch
    local now_epoch

    info "Inspecting the exported artifact"
    mkdir -p "$unpacked_path"
    ditto -x -k "$IPA_PATH" "$unpacked_path"
    app_path="$(find "$unpacked_path/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
    [ -n "$app_path" ] || fail "The IPA contains no top-level app"
    info_plist="$app_path/Info.plist"

    actual_bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$info_plist")"
    actual_version="$(plutil -extract CFBundleShortVersionString raw -o - "$info_plist")"
    actual_build="$(plutil -extract CFBundleVersion raw -o - "$info_plist")"
    [ "$actual_bundle_id" = "$EXPECTED_BUNDLE_IDENTIFIER" ] || fail "IPA bundle ID is $actual_bundle_id"
    [ "$actual_version" = "$MARKETING_VERSION" ] || fail "IPA version is $actual_version"
    [ "$actual_build" = "$BUILD_NUMBER" ] || fail "IPA build is $actual_build"

    codesign --verify --deep --strict "$app_path"
    codesign -d --entitlements :- "$app_path" >"$entitlements_plist" 2>/dev/null
    plutil -lint "$entitlements_plist" >/dev/null
    entitlements_json="$(plutil -convert json -o - "$entitlements_plist")"

    app_identifier="$(jq -r '.["application-identifier"] // empty' <<<"$entitlements_json")"
    [[ "$app_identifier" == *".$EXPECTED_BUNDLE_IDENTIFIER" ]] \
        || fail "Signed application identifier does not end in $EXPECTED_BUNDLE_IDENTIFIER"
    [ "$(jq -r '.["com.apple.developer.icloud-container-environment"] // empty' <<<"$entitlements_json")" = "Production" ] \
        || fail "Signed IPA does not use the Production CloudKit environment"
    json_array_contains "$entitlements_json" "com.apple.developer.icloud-container-identifiers" "$EXPECTED_ICLOUD_CONTAINER" \
        || fail "Signed IPA is missing the CloudKit container"
    json_array_contains "$entitlements_json" "com.apple.developer.icloud-services" "CloudKit" \
        || fail "Signed IPA is missing the CloudKit service"
    json_array_contains "$entitlements_json" "keychain-access-groups" "${app_identifier%%.*}.$EXPECTED_BUNDLE_IDENTIFIER" \
        || fail "Signed IPA is missing the shared keychain group"

    [ -f "$app_path/embedded.mobileprovision" ] || fail "Exported IPA has no embedded provisioning profile"
    security cms -D -i "$app_path/embedded.mobileprovision" >"$profile_plist"
    profile_app_identifier="$(plutil -extract Entitlements.application-identifier raw -o - "$profile_plist")"
    [ "$profile_app_identifier" = "$app_identifier" ] || fail "Provisioning profile application identifier mismatch"
    profile_cloud_environment="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.developer.icloud-container-environment' \
        "$profile_plist")"
    grep -qE '(^|[[:space:]])Production($|[[:space:]])' <<<"$profile_cloud_environment" \
        || fail "Provisioning profile does not authorize Production CloudKit"
    profile_cloud_services="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.developer.icloud-services' \
        "$profile_plist")"
    grep -qE '(^|[[:space:]])(CloudKit|\*)($|[[:space:]])' <<<"$profile_cloud_services" \
        || fail "Provisioning profile does not authorize CloudKit"
    profile_cloud_containers="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:com.apple.developer.icloud-container-identifiers' \
        "$profile_plist")"
    grep -Fq "$EXPECTED_ICLOUD_CONTAINER" <<<"$profile_cloud_containers" \
        || fail "Provisioning profile does not authorize the CloudKit container"
    profile_keychain_groups="$(/usr/libexec/PlistBuddy \
        -c 'Print :Entitlements:keychain-access-groups' \
        "$profile_plist")"
    if ! grep -Fq "${app_identifier%%.*}.$EXPECTED_BUNDLE_IDENTIFIER" <<<"$profile_keychain_groups" \
        && ! grep -Fq "${app_identifier%%.*}.*" <<<"$profile_keychain_groups"; then
        fail "Provisioning profile does not authorize the keychain group"
    fi
    verify_profile_certificate "$app_path" "$profile_plist" \
        || fail "Provisioning profile does not contain the signing certificate"

    expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' \
        "$(plutil -extract ExpirationDate raw -o - "$profile_plist")" '+%s' 2>/dev/null || true)"
    now_epoch="$(date '+%s')"
    [ -n "$expiration_epoch" ] && [ "$expiration_epoch" -gt "$now_epoch" ] \
        || fail "Provisioning profile is expired or has an unreadable expiration date"
    success "Signed IPA entitlements and provisioning profile are valid"
}

function validate_with_apple() {
    info "Validating IPA with App Store Connect"
    xcrun altool \
        --validate-app "$IPA_PATH" \
        --api-key "$ASC_KEY_ID" \
        --api-issuer "$ASC_ISSUER_ID" \
        --p8-file-path "$ASC_KEY_PATH" \
        --output-format json
    success "App Store Connect validation passed"
}

function upload_to_apple() {
    info "Uploading IPA to App Store Connect"
    asc_cli builds upload \
        --app "$ASC_APP_ID" \
        --ipa "$IPA_PATH" \
        --version "$MARKETING_VERSION" \
        --build-number "$BUILD_NUMBER" \
        --wait \
        --output json
    success "Upload processed by App Store Connect"
}

function load_processed_build() {
    local response
    local state

    response="$(asc_cli builds info \
        --app "$ASC_APP_ID" \
        --build-number "$BUILD_NUMBER" \
        --version "$MARKETING_VERSION" \
        --platform IOS \
        --output json)"
    BUILD_RESOURCE_ID="$(jq -r '.data.id // empty' <<<"$response")"
    state="$(jq -r '.data.attributes.processingState // empty' <<<"$response")"
    [ -n "$BUILD_RESOURCE_ID" ] || fail "Could not resolve the processed build in App Store Connect"
    [ "$state" = "VALID" ] || fail "App Store Connect processing ended with state ${state:-unknown}"
    BUILD_USES_NON_EXEMPT_ENCRYPTION="$(jq -r \
        '.data.attributes.usesNonExemptEncryption // "unset"' <<<"$response")"
    if [ "$BUILD_USES_NON_EXEMPT_ENCRYPTION" = "unset" ] \
        && [ -n "$USES_NON_EXEMPT_ENCRYPTION" ]; then
        info "Recording the confirmed export-compliance answer"
        asc_cli builds update \
            --build-id "$BUILD_RESOURCE_ID" \
            "--uses-non-exempt-encryption=$USES_NON_EXEMPT_ENCRYPTION" \
            --output json >/dev/null
        BUILD_USES_NON_EXEMPT_ENCRYPTION="$USES_NON_EXEMPT_ENCRYPTION"
        success "Export compliance recorded"
    fi
}

function add_build_to_group() {
    local groups_json
    local matching_count
    local group_id
    local create_response

    [ "$BUILD_USES_NON_EXEMPT_ENCRYPTION" != "unset" ] || fail \
        "Export compliance is unresolved. Answer it in App Store Connect before assigning this build to testers."

    groups_json="$(asc_cli testflight groups list \
        --app "$ASC_APP_ID" \
        --internal \
        --paginate \
        --output json)"
    matching_count="$(jq --arg name "$GROUP_NAME" \
        '[.data[] | select(.attributes.name == $name)] | length' <<<"$groups_json")"
    if [ "$matching_count" -eq 0 ]; then
        [ "$CREATE_GROUP" -eq 1 ] || fail "Internal TestFlight group not found: $GROUP_NAME"
        info "Creating internal TestFlight group: $GROUP_NAME"
        create_response="$(asc_cli testflight groups create \
            --app "$ASC_APP_ID" \
            --name "$GROUP_NAME" \
            --internal \
            --output json)"
        group_id="$(jq -r '.data.id // empty' <<<"$create_response")"
        [ -n "$group_id" ] || fail "App Store Connect did not return the created group ID"
    elif [ "$matching_count" -eq 1 ]; then
        group_id="$(jq -r --arg name "$GROUP_NAME" \
            '.data[] | select(.attributes.name == $name) | .id' <<<"$groups_json")"
    else
        fail "More than one internal TestFlight group is named $GROUP_NAME"
    fi

    info "Adding build to internal TestFlight group: $GROUP_NAME"
    asc_cli builds add-groups \
        --build-id "$BUILD_RESOURCE_ID" \
        --group "$group_id" \
        --output json >/dev/null
    success "Build is available to group $GROUP_NAME"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check)
            ACTION="check"
            shift
            ;;
        --archive)
            ACTION="archive"
            shift
            ;;
        --upload)
            ACTION="upload"
            shift
            ;;
        --group)
            [ "$#" -ge 2 ] || fail "--group requires a value"
            GROUP_NAME="$2"
            shift 2
            ;;
        --create-group)
            CREATE_GROUP=1
            shift
            ;;
        --build-number)
            [ "$#" -ge 2 ] || fail "--build-number requires a value"
            BUILD_NUMBER="$2"
            shift 2
            ;;
        --marketing-version)
            [ "$#" -ge 2 ] || fail "--marketing-version requires a value"
            [[ "$2" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] \
                || fail "--marketing-version must contain two or three numeric components"
            MARKETING_VERSION_OVERRIDE="$2"
            shift 2
            ;;
        --uses-non-exempt-encryption)
            [ "$#" -ge 2 ] || fail "--uses-non-exempt-encryption requires true or false"
            case "$2" in
                true|false)
                    USES_NON_EXEMPT_ENCRYPTION="$2"
                    ;;
                *)
                    fail "--uses-non-exempt-encryption requires true or false"
                    ;;
            esac
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift
            ;;
        --allow-dirty)
            ALLOW_DIRTY=1
            shift
            ;;
        --keep-artifacts)
            KEEP_ARTIFACTS=1
            shift
            ;;
        --config)
            [ "$#" -ge 2 ] || fail "--config requires a path"
            CONFIG_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1 (run with --help for usage)"
            ;;
    esac
done

[ -z "$GROUP_NAME" ] || [ "$ACTION" = "upload" ] || fail "--group is only valid with --upload"
[ "$CREATE_GROUP" -eq 0 ] || [ -n "$GROUP_NAME" ] || fail "--create-group requires --group"
[ -z "$USES_NON_EXEMPT_ENCRYPTION" ] || [ "$ACTION" = "upload" ] \
    || fail "--uses-non-exempt-encryption is only valid with --upload"

require_command xcodebuild
require_command xcrun
require_command swift
require_command asc
require_command jq
require_command plutil
require_command codesign
require_command security
require_command shasum
require_command ditto
require_command git
require_command stat
require_command openssl
require_command base64
require_command install

load_configuration
verify_app_record
read_build_settings
resolve_build_number

if [ "$ACTION" = "check" ]; then
    success "CLI credentials and project identity are ready"
    RUN_SUCCEEDED=1
    exit 0
fi

verify_worktree
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snippets-testflight.XXXXXX")"
trap cleanup EXIT
run_preflight_tests
archive_and_export
verify_exported_ipa

if [ "$ACTION" = "archive" ]; then
    validate_with_apple
    success "TestFlight archive validation completed"
    RUN_SUCCEEDED=1
    exit 0
fi

upload_to_apple
load_processed_build
if [ -n "$GROUP_NAME" ]; then
    add_build_to_group
fi

success "TestFlight upload completed: $MARKETING_VERSION ($BUILD_NUMBER)"
RUN_SUCCEEDED=1
