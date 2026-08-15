#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$PROJECT_DIR/Snippets.xcodeproj"
SCHEME="Snippets iOS"
CONFIGURATION="Release"
BUNDLE_IDENTIFIER="com.khm.snippets"
TEAM_IDENTIFIER="H8QG3CBM96"
ICLOUD_CONTAINER="iCloud.com.khm.snippets"
DERIVED_DATA_PATH="${SNIPPETS_IOS_DERIVED_DATA:-${SNIPPETS_IPAD_DERIVED_DATA:-/tmp/snippets-ios-device-derived}}"

DEVICE_SELECTOR=""
BUILD_APP=1
LAUNCH_APP=1

function usage() {
    cat <<'EOF'
Build, validate, install, and launch Snippets on a connected iPhone or iPad.

Usage:
  ./scripts/install-ios.sh [options]

Options:
  --device <name>       Select a device when more than one iPhone/iPad is paired.
                        A CoreDevice identifier or UDID also works, but is not printed.
  --derived-data <dir>  Override the derived-data directory.
  --no-build            Reuse the existing signed Release app in derived data.
  --no-launch           Install without launching the app.
  -h, --help            Show this help.

Environment:
  SNIPPETS_IOS_DERIVED_DATA  Default derived-data directory override.
  SNIPPETS_IPAD_DERIVED_DATA Legacy derived-data alias.

The script always installs the Release bundle (com.khm.snippets) with Production
CloudKit entitlements. Installation is in place and preserves the app's data sandbox.
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
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "Required command not found: $1"
    fi
}

function redact_identifiers() {
    sed -E \
        -e 's/(id[:=])[[:alnum:]-]+/\1<redacted>/g' \
        -e 's/[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{20,}/<redacted>/g' \
        -e 's/[0-9A-Fa-f]{16,}/<redacted>/g'
}

function run_redacted() {
    local command_status

    set +e
    "$@" 2>&1 | redact_identifiers
    command_status=${PIPESTATUS[0]}
    set -e
    return "$command_status"
}

function plist_value() {
    local plist_path="$1"
    local key_path="$2"
    /usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null
}

function profile_vouches_for_signature() {
    local app_path="$1"
    local profile_plist="$2"
    local certificate_index=0
    local leaf_digest
    local candidate_digest

    if ! codesign -d --extract-certificates="$WORK_DIR/signing-leaf" \
        "$app_path" >/dev/null 2>&1 || [ ! -f "$WORK_DIR/signing-leaf0" ]; then
        return 1
    fi

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

function build_release_app() {
    run_redacted xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "platform=iOS,id=$XCODE_DESTINATION_IDENTIFIER" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -quiet \
        build
}

# Returns 2 when SpringBoard rejected the launch only because the device is locked.
function launch_app_once() {
    local launch_status

    set +e
    xcrun devicectl device process launch \
        --device "$COREDEVICE_IDENTIFIER" \
        --terminate-existing \
        --quiet \
        "$BUNDLE_IDENTIFIER" >"$WORK_DIR/launch-output" 2>&1
    launch_status=$?
    set -e

    if [ "$launch_status" -eq 0 ]; then
        return 0
    fi
    if grep -qE 'reason: Locked|because the device (was not|is not).*unlocked' \
        "$WORK_DIR/launch-output"; then
        return 2
    fi

    redact_identifiers <"$WORK_DIR/launch-output" >&2
    return "$launch_status"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --device)
            [ "$#" -ge 2 ] || fail "--device requires a value"
            DEVICE_SELECTOR="$2"
            shift 2
            ;;
        --derived-data)
            [ "$#" -ge 2 ] || fail "--derived-data requires a directory"
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        --no-build)
            BUILD_APP=0
            shift
            ;;
        --no-launch)
            LAUNCH_APP=0
            shift
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

require_command xcodebuild
require_command xcrun
require_command codesign
require_command security
require_command plutil
require_command shasum

APP_PATH="$DERIVED_DATA_PATH/Build/Products/Release-iphoneos/Snippets.app"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snippets-ios-install.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

info "Discovering paired iOS devices"
if ! run_redacted xcrun devicectl list devices --quiet \
    --json-output "$WORK_DIR/devices.json"; then
    fail "Could not query CoreDevice"
fi

device_index=0
available_count=0
matched_count=0
available_names=""
DEVICE_NAME=""
DEVICE_MODEL=""
DEVICE_OS_VERSION=""
DEVICE_OS_NAME="iOS"
COREDEVICE_IDENTIFIER=""
XCODE_DESTINATION_IDENTIFIER=""

while coredevice_identifier="$(plutil -extract "result.devices.$device_index.identifier" \
    raw -o - "$WORK_DIR/devices.json" 2>/dev/null)"; do
    device_name="$(plutil -extract "result.devices.$device_index.deviceProperties.name" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    device_model="$(plutil -extract "result.devices.$device_index.hardwareProperties.marketingName" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    device_platform="$(plutil -extract "result.devices.$device_index.hardwareProperties.platform" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    device_udid="$(plutil -extract "result.devices.$device_index.hardwareProperties.udid" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    device_os_version="$(plutil -extract "result.devices.$device_index.deviceProperties.osVersionNumber" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    pairing_state="$(plutil -extract "result.devices.$device_index.connectionProperties.pairingState" \
        raw -o - "$WORK_DIR/devices.json" 2>/dev/null || true)"
    device_index=$((device_index + 1))

    if [ "$device_platform" != "iOS" ] \
        || [ "$pairing_state" != "paired" ] \
        || [ -z "$device_udid" ]; then
        continue
    fi
    if [[ "$device_model" != iPad* && "$device_model" != iPhone* ]]; then
        continue
    fi

    available_count=$((available_count + 1))
    available_names="$available_names\n  - $device_name ($device_model)"

    if [ -n "$DEVICE_SELECTOR" ] \
        && [ "$DEVICE_SELECTOR" != "$device_name" ] \
        && [ "$DEVICE_SELECTOR" != "$coredevice_identifier" ] \
        && [ "$DEVICE_SELECTOR" != "$device_udid" ]; then
        continue
    fi

    matched_count=$((matched_count + 1))
    DEVICE_NAME="$device_name"
    DEVICE_MODEL="$device_model"
    DEVICE_OS_VERSION="$device_os_version"
    if [[ "$device_model" == iPad* ]]; then
        DEVICE_OS_NAME="iPadOS"
    else
        DEVICE_OS_NAME="iOS"
    fi
    COREDEVICE_IDENTIFIER="$coredevice_identifier"
    XCODE_DESTINATION_IDENTIFIER="$device_udid"
done

if [ -z "$DEVICE_SELECTOR" ] && [ "$available_count" -gt 1 ]; then
    printf 'More than one paired iOS device is available:%b\n' "$available_names" >&2
    fail "Select one with --device <name>"
fi
if [ "$matched_count" -eq 0 ]; then
    if [ "$available_count" -gt 0 ]; then
        printf 'Available paired iOS devices:%b\n' "$available_names" >&2
    fi
    fail "No matching paired iPhone or iPad is available"
fi
if [ "$matched_count" -gt 1 ]; then
    fail "The device selector matched more than one device; use an exact name"
fi

if [ -n "$DEVICE_OS_VERSION" ]; then
    success "$DEVICE_NAME ($DEVICE_MODEL, $DEVICE_OS_NAME $DEVICE_OS_VERSION)"
else
    success "$DEVICE_NAME ($DEVICE_MODEL)"
fi

info "Checking the Xcode destination"
set +e
xcode_destination_output="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "platform=iOS,id=$XCODE_DESTINATION_IDENTIFIER" \
    -showBuildSettings 2>&1)"
xcode_destination_status=$?
set -e
if [ "$xcode_destination_status" -ne 0 ]; then
    printf '%s\n' "$xcode_destination_output" | redact_identifiers >&2
    fail "The paired device is not an eligible destination for the $SCHEME scheme"
fi
success "Eligible native iOS destination"

if [ "$BUILD_APP" -eq 1 ]; then
    info "Building the signed Release app (incremental)"
    if ! build_release_app; then
        fail "Release device build failed"
    fi
    success "Release build succeeded"
else
    info "Reusing the existing Release app"
fi

[ -d "$APP_PATH" ] || fail "Built app not found at $APP_PATH"
[ -f "$APP_PATH/embedded.mobileprovision" ] \
    || fail "The Release app has no embedded provisioning profile"

info "Validating the signed artifact"
if ! codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    if [ "$BUILD_APP" -ne 1 ]; then
        fail "The app's code signature is invalid; rerun without --no-build"
    fi

    # When one DerivedData directory is reused for a different device family,
    # Xcode can refresh the destination-thinned Assets.car without rerunning the
    # final CodeSign task. Move only the generated product aside so Xcode links
    # the cached intermediates into a fresh bundle and signs it in the correct
    # order. Keep signing under Xcode's control instead of manually re-signing.
    warn "Xcode left a stale signature after switching devices; rebuilding the app bundle"
    info "Rebuilding the signed Release app from cached intermediates"
    stale_app_path="$WORK_DIR/stale-Snippets.app"
    mv "$APP_PATH" "$stale_app_path" \
        || fail "Could not move the stale Release app aside"
    if ! build_release_app; then
        if [ -d "$APP_PATH" ]; then
            mv "$APP_PATH" "$WORK_DIR/failed-Snippets.app" || true
        fi
        mv "$stale_app_path" "$APP_PATH" || true
        fail "Release device app-bundle rebuild failed"
    fi
    codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1 \
        || fail "The app's code signature is invalid after the automatic rebuild"
    success "Release app bundle rebuilt and signed"
fi
codesign -d --entitlements :- "$APP_PATH" \
    >"$WORK_DIR/app-entitlements.plist" 2>/dev/null \
    || fail "Could not read the app's signed entitlements"
security cms -D -i "$APP_PATH/embedded.mobileprovision" \
    >"$WORK_DIR/profile.plist" 2>/dev/null \
    || fail "Could not decode the embedded provisioning profile"
plutil -lint "$WORK_DIR/app-entitlements.plist" >/dev/null \
    || fail "The app's signed entitlements are malformed"
plutil -lint "$WORK_DIR/profile.plist" >/dev/null \
    || fail "The embedded provisioning profile is malformed"

expected_application_identifier="$TEAM_IDENTIFIER.$BUNDLE_IDENTIFIER"
actual_bundle_identifier="$(plist_value "$APP_PATH/Info.plist" CFBundleIdentifier || true)"
actual_application_identifier="$(plist_value "$WORK_DIR/app-entitlements.plist" application-identifier || true)"
actual_environment="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    com.apple.developer.icloud-container-environment || true)"
actual_containers="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    com.apple.developer.icloud-container-identifiers || true)"
actual_services="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    com.apple.developer.icloud-services || true)"
actual_keychain_groups="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    keychain-access-groups || true)"
actual_aps_environment="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    aps-environment || true)"
oauth_callback_host="$(plist_value "$APP_PATH/Info.plist" \
    SnippetsCloudOAuthCallbackHost || true)"
actual_associated_domains="$(plist_value "$WORK_DIR/app-entitlements.plist" \
    com.apple.developer.associated-domains || true)"
actual_background_modes="$(plist_value "$APP_PATH/Info.plist" \
    UIBackgroundModes || true)"

[ "$actual_bundle_identifier" = "$BUNDLE_IDENTIFIER" ] \
    || fail "Unexpected Release bundle identifier: $actual_bundle_identifier"
[ "$actual_application_identifier" = "$expected_application_identifier" ] \
    || fail "The signed application identifier is not the Release App ID"
[ "$actual_environment" = "Production" ] \
    || fail "The signed app does not target the Production CloudKit environment"
[[ "$actual_containers" == *"$ICLOUD_CONTAINER"* ]] \
    || fail "The signed app does not contain the expected CloudKit container"
[[ "$actual_services" == *"CloudKit"* ]] \
    || fail "The signed app does not contain the CloudKit service entitlement"
[[ "$actual_keychain_groups" == *"$expected_application_identifier"* ]] \
    || fail "The signed app does not contain the shared keychain group"
[ -n "$actual_aps_environment" ] \
    || fail "The signed app does not contain the APNs environment entitlement"
[[ "$actual_associated_domains" == *"webcredentials:$oauth_callback_host"* ]] \
    || fail "The signed app does not bind its HTTPS OAuth callback host"
[[ "$actual_background_modes" == *"remote-notification"* ]] \
    || fail "The built app does not permit silent remote-notification background wakes"

profile_application_identifier="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:application-identifier || true)"
profile_environment="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:com.apple.developer.icloud-container-environment || true)"
profile_containers="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:com.apple.developer.icloud-container-identifiers || true)"
profile_services="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:com.apple.developer.icloud-services || true)"
profile_keychain_groups="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:keychain-access-groups || true)"
profile_aps_environment="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:aps-environment || true)"
profile_associated_domains="$(plist_value "$WORK_DIR/profile.plist" \
    Entitlements:com.apple.developer.associated-domains || true)"

[ "$profile_application_identifier" = "$actual_application_identifier" ] \
    || fail "The provisioning profile does not authorize the Release App ID"
[[ "$profile_environment" == *"Production"* ]] \
    || fail "The provisioning profile does not authorize Production CloudKit"
[[ "$profile_containers" == *"$ICLOUD_CONTAINER"* ]] \
    || fail "The provisioning profile does not authorize the CloudKit container"
[[ "$profile_services" == *"CloudKit"* || "$profile_services" = "*" ]] \
    || fail "The provisioning profile does not authorize CloudKit"
[[ "$profile_keychain_groups" == *"$expected_application_identifier"* \
    || "$profile_keychain_groups" == *"$TEAM_IDENTIFIER.*"* ]] \
    || fail "The provisioning profile does not authorize the shared keychain group"
[ "$profile_aps_environment" = "$actual_aps_environment" ] \
    || fail "The signed APNs environment does not match the provisioning profile"
[[ "$profile_associated_domains" == *"webcredentials:$oauth_callback_host"* \
    || "$profile_associated_domains" == *"*"* ]] \
    || fail "The provisioning profile does not authorize the HTTPS OAuth callback domain"

profile_expiry="$(plist_value "$WORK_DIR/profile.plist" ExpirationDate || true)"
profile_expiry_seconds="$(date -j -f '%a %b %d %T %Z %Y' \
    "$profile_expiry" +%s 2>/dev/null || true)"
[ -n "$profile_expiry_seconds" ] \
    || fail "Could not read the provisioning profile expiration date"
[ "$profile_expiry_seconds" -gt "$(date +%s)" ] \
    || fail "The embedded provisioning profile has expired"

provisions_all_devices="$(plist_value "$WORK_DIR/profile.plist" ProvisionsAllDevices || true)"
provisioned_devices="$(plist_value "$WORK_DIR/profile.plist" ProvisionedDevices || true)"
if [ "$provisions_all_devices" != "true" ] \
    && [[ "$provisioned_devices" != *"$XCODE_DESTINATION_IDENTIFIER"* ]]; then
    fail "The provisioning profile does not include the selected device"
fi

profile_vouches_for_signature "$APP_PATH" "$WORK_DIR/profile.plist" \
    || fail "The provisioning profile does not contain the app's signing certificate"
success "Signature, certificate, Production CloudKit, APNs, associated domains, and keychain profile are valid"

info "Installing $BUNDLE_IDENTIFIER in place"
if ! run_redacted xcrun devicectl device install app \
    --device "$COREDEVICE_IDENTIFIER" \
    --quiet \
    "$APP_PATH"; then
    fail "Device installation failed"
fi
success "Installed; the existing app data sandbox was preserved"

if xcrun devicectl device info apps \
    --device "$COREDEVICE_IDENTIFIER" \
    --bundle-id com.khm.snippets.debug 2>/dev/null \
    | grep -Fq com.khm.snippets.debug; then
    warn "A Debug build is also installed with the same display name. It was not removed."
fi

if [ "$LAUNCH_APP" -eq 1 ]; then
    info "Launching Snippets"
    launch_status=0
    launch_app_once || launch_status=$?
    if [ "$launch_status" -eq 2 ] && [ -t 0 ]; then
        warn "The device is locked. Unlock it, then press Return to retry the launch."
        read -r
        launch_status=0
        launch_app_once || launch_status=$?
    fi

    if [ "$launch_status" -eq 0 ]; then
        success "Launched on $DEVICE_NAME"
    elif [ "$launch_status" -eq 2 ]; then
        warn "Installed, but the device is locked. Unlock it and rerun with --no-build."
    else
        fail "The app installed but did not launch"
    fi
fi

app_version="$(plist_value "$APP_PATH/Info.plist" CFBundleShortVersionString || true)"
app_build="$(plist_value "$APP_PATH/Info.plist" CFBundleVersion || true)"
printf '\nSnippets %s (%s) is installed on %s.\n' \
    "${app_version:-unknown}" "${app_build:-unknown}" "$DEVICE_NAME"
