#!/bin/bash

set -euo pipefail
umask 077

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$PROJECT_DIR/Snippets.xcodeproj"
GATEWAY_SCRIPT="$PROJECT_DIR/scripts/share-ios-gateway.rb"
SCHEME="Snippets iOS"
CONFIGURATION="Release"
BUNDLE_IDENTIFIER="com.khm.snippets"
TEAM_IDENTIFIER="H8QG3CBM96"
ICLOUD_CONTAINER="iCloud.com.khm.snippets"
CACHE_ROOT="${SNIPPETS_IOS_SHARE_DIR:-${XDG_CACHE_HOME:-$HOME/Library/Caches}/com.khm.snippets/ios-share}"
STATE_PATH="$CACHE_ROOT/state.plist"
LOCK_PATH="$CACHE_ROOT/operation.lock"

ACTION="share"
IPA_SOURCE=""
TTL_INPUT="2h"
TTL_SECONDS=7200
RUN_TESTS=0
COPY_TO_CLIPBOARD=1
WORK_DIR=""
SESSION_DIR=""
GATEWAY_PID=""
GATEWAY_PORT=""
NGROK_API=""
NGROK_PID=""
OWNS_NGROK=0
TUNNEL_NAME=""
PUBLIC_URL=""
ORIGINAL_ADDR=""
TUNNEL_RETARGETED=0
RUN_SUCCEEDED=0
GATEWAY_LABEL="com.khm.snippets.ios-share.gateway"
NGROK_LABEL="com.khm.snippets.ios-share.ngrok"
GATEWAY_STARTED=0
NGROK_STARTED=0

function usage() {
    cat <<'EOF'
Build, validate, and share a signed Snippets iOS IPA through a time-limited ngrok link.

Usage:
  ./scripts/share-ios.sh [options]
  ./scripts/share-ios.sh --status
  ./scripts/share-ios.sh --stop

Options:
  --ttl <duration>      Link lifetime. Use minutes or suffix m/h (default: 2h,
                        examples: 30, 30m, 4h; maximum: 24h).
  --reuse-ipa <path>   Validate and share an existing signed IPA without building.
  --run-tests          Run Core, macOS build, and iPhone/iPad simulator tests first.
  --no-clipboard       Do not copy the Safari install URL to the clipboard.
  --status             Show the active link and its expiry.
  --stop               Revoke the link, restore the previous ngrok backend, and
                        delete the private cached sharing session.
  -h, --help           Show this help.

Environment:
  SNIPPETS_IOS_SHARE_DIR  Private state/artifact directory override.

The default build is the Release app (com.khm.snippets) with Production CloudKit.
Only devices registered in the embedded provisioning profile can install the IPA.
The Mac, gateway, and ngrok process must remain online while installation downloads.
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

function state_value() {
    plist_value "$STATE_PATH" "$1"
}

function safe_session_path() {
    local path="$1"
    local sessions_root
    local resolved_path

    [ -d "$CACHE_ROOT/sessions" ] && [ -d "$path" ] || return 1
    sessions_root="$(cd "$CACHE_ROOT/sessions" && pwd -P)"
    resolved_path="$(cd "$path" && pwd -P)"
    case "$resolved_path" in
        "$sessions_root"/*) [ "$resolved_path" != "$sessions_root" ] ;;
        *) return 1 ;;
    esac
}

function acquire_lock() {
    install -d -m 700 "$CACHE_ROOT"
    chmod 700 "$CACHE_ROOT"
    if ! mkdir "$LOCK_PATH" 2>/dev/null; then
        fail "Another share-ios operation is already running"
    fi
}

function release_lock() {
    rmdir "$LOCK_PATH" 2>/dev/null || true
}

function cleanup() {
    local status=$?

    release_lock
    if [ "$status" -ne 0 ] && [ "$RUN_SUCCEEDED" -eq 0 ]; then
        if [ "$TUNNEL_RETARGETED" -eq 1 ]; then
            restore_tunnel || true
        fi
        if [ "$GATEWAY_STARTED" -eq 1 ]; then
            stop_launch_service "$GATEWAY_LABEL" || true
        fi
        stop_owned_process "$GATEWAY_PID" "share-ios-gateway.rb" || true
        if [ "$OWNS_NGROK" -eq 1 ]; then
            if [ "$NGROK_STARTED" -eq 1 ]; then
                stop_launch_service "$NGROK_LABEL" || true
            fi
            stop_owned_process "$NGROK_PID" "ngrok" || true
        fi
        if [ -n "$SESSION_DIR" ] && safe_session_path "$SESSION_DIR"; then
            rm -rf "$SESSION_DIR"
        fi
    fi
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}

trap cleanup EXIT

function parse_ttl() {
    local value="$1"
    local amount
    local unit

    if [[ "$value" =~ ^([1-9][0-9]*)([mh]?)$ ]]; then
        amount="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        fail "Invalid --ttl value: $value (use 30m or 4h)"
    fi

    case "$unit" in
        ""|m) TTL_SECONDS=$((amount * 60)) ;;
        h) TTL_SECONDS=$((amount * 3600)) ;;
    esac
    [ "$TTL_SECONDS" -le 86400 ] || fail "--ttl cannot exceed 24h"
}

function format_epoch() {
    date -r "$1" '+%Y-%m-%d %H:%M:%S %Z'
}

function human_remaining() {
    local seconds="$1"
    if [ "$seconds" -le 0 ]; then
        printf 'expired'
    elif [ "$seconds" -ge 3600 ]; then
        printf '%dh %dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
    else
        printf '%dm' "$((seconds / 60))"
    fi
}

function process_matches() {
    local pid="$1"
    local marker="$2"
    [ -n "$pid" ] && [[ "$pid" =~ ^[0-9]+$ ]] \
        && ps -p "$pid" -o command= 2>/dev/null | grep -Fq "$marker"
}

function launch_service_target() {
    printf 'gui/%s/%s' "$(id -u)" "$1"
}

function launch_service_pid() {
    launchctl print "$(launch_service_target "$1")" 2>/dev/null \
        | awk '$1 == "pid" && $2 == "=" { print $3; exit }'
}

function launch_service_alive() {
    launchctl print "$(launch_service_target "$1")" >/dev/null 2>&1
}

function stop_launch_service() {
    local label="$1"
    local target
    local attempt=0

    target="$(launch_service_target "$label")"
    launch_service_alive "$label" || return 0
    launchctl bootout "$target" >/dev/null 2>&1 || return 1
    while launch_service_alive "$label" && [ "$attempt" -lt 20 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    ! launch_service_alive "$label"
}

function create_launch_service_plist() {
    local plist_path="$1"
    local label="$2"
    local stdout_path="$3"
    local stderr_path="$4"
    local arguments_json
    local environment_json
    shift 4

    arguments_json="$(ruby -rjson -e 'print JSON.generate(ARGV)' "$@")"
    environment_json="$(ruby -rjson -e '
      print JSON.generate({ "HOME" => ARGV.fetch(0), "PATH" => ARGV.fetch(1) })
    ' "$HOME" "$PATH")"
    plutil -create xml1 "$plist_path"
    plutil -insert Label -string "$label" "$plist_path"
    plutil -insert ProgramArguments -json "$arguments_json" "$plist_path"
    plutil -insert EnvironmentVariables -json "$environment_json" "$plist_path"
    plutil -insert RunAtLoad -bool true "$plist_path"
    plutil -insert KeepAlive -bool true "$plist_path"
    plutil -insert ProcessType -string Background "$plist_path"
    plutil -insert StandardOutPath -string "$stdout_path" "$plist_path"
    plutil -insert StandardErrorPath -string "$stderr_path" "$plist_path"
    plutil -insert WorkingDirectory -string "$PROJECT_DIR" "$plist_path"
    chmod 600 "$plist_path"
}

function stop_owned_process() {
    local pid="$1"
    local marker="$2"
    local attempt=0

    process_matches "$pid" "$marker" || return 0
    kill "$pid" 2>/dev/null || true
    while process_matches "$pid" "$marker" && [ "$attempt" -lt 20 ]; do
        sleep 0.1
        attempt=$((attempt + 1))
    done
    if process_matches "$pid" "$marker"; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
}

function url_encode() {
    ruby -ruri -e 'puts URI.encode_www_form_component(ARGV.fetch(0))' "$1"
}

function json_escape() {
    ruby -rjson -e 'print JSON.generate(ARGV.fetch(0))' "$1"
}

function tunnel_record() {
    local api="$1"
    curl --silent --show-error --fail --max-time 2 "$api/api/tunnels" \
        | ruby -rjson -e '
            tunnels = JSON.parse(STDIN.read).fetch("tunnels", [])
            tunnel = tunnels.find { |item| item["proto"] == "https" }
            exit 1 unless tunnel
            values = [tunnel["name"], tunnel["public_url"], tunnel.dig("config", "addr")]
            exit 1 if values.any? { |value| value.to_s.empty? || value.to_s.include?("\t") }
            puts values.join("\t")
          '
}

function discover_ngrok() {
    local port
    local record

    for port in $(jot 10 4040); do
        if record="$(tunnel_record "http://127.0.0.1:$port" 2>/dev/null)"; then
            NGROK_API="http://127.0.0.1:$port"
            IFS=$'\t' read -r TUNNEL_NAME PUBLIC_URL ORIGINAL_ADDR <<<"$record"
            return 0
        fi
    done
    return 1
}

function free_port() {
    ruby -rsocket -e 'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; server.close'
}

function wait_for_url() {
    local url="$1"
    local expected="$2"
    local attempt=0
    local status

    while [ "$attempt" -lt 80 ]; do
        status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 1 "$url" || true)"
        if [ "$status" = "$expected" ]; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    return 1
}

function retarget_tunnel() {
    local target_addr="$1"
    local encoded_name
    local payload
    local response
    local actual_url

    encoded_name="$(url_encode "$TUNNEL_NAME")"
    curl --silent --show-error --fail --max-time 5 \
        -X DELETE "$NGROK_API/api/tunnels/$encoded_name" >/dev/null
    payload="{\"name\":$(json_escape "$TUNNEL_NAME"),\"addr\":$(json_escape "$target_addr"),\"proto\":\"http\"}"
    response="$(curl --silent --show-error --fail --max-time 10 \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "$payload" \
        "$NGROK_API/api/tunnels")"
    actual_url="$(ruby -rjson -e 'print JSON.parse(STDIN.read).fetch("public_url")' <<<"$response")"
    [ "$actual_url" = "$PUBLIC_URL" ] \
        || fail "ngrok returned a different public URL while attaching the share gateway"
}

function restore_tunnel() {
    local current_record
    local current_addr
    local expected_addr="http://127.0.0.1:$GATEWAY_PORT"

    [ -n "$ORIGINAL_ADDR" ] || return 0
    current_record="$(tunnel_record "$NGROK_API" 2>/dev/null || true)"
    current_addr="$(cut -f3 <<<"$current_record")"
    if [ -n "$current_addr" ] \
        && [ "$current_addr" != "$expected_addr" ] \
        && [ "$current_addr" != "http://localhost:$GATEWAY_PORT" ]; then
        warn "ngrok now points elsewhere; leaving its newer configuration untouched"
        return 0
    fi
    retarget_tunnel "$ORIGINAL_ADDR"
    TUNNEL_RETARGETED=0
}

function start_ngrok() {
    local api_port
    local log_path="$SESSION_DIR/ngrok.log"
    local service_plist="$SESSION_DIR/ngrok-launchd.plist"
    local ngrok_path
    local attempt=0
    local record

    require_command ngrok
    require_command launchctl
    api_port="$(free_port)"
    NGROK_API="http://127.0.0.1:$api_port"
    ngrok_path="$(command -v ngrok)"
    : >"$log_path"
    chmod 600 "$log_path"
    create_launch_service_plist \
        "$service_plist" \
        "$NGROK_LABEL" \
        "$log_path" \
        "$log_path" \
        "$ngrok_path" http "$GATEWAY_PORT" \
        --web-addr "127.0.0.1:$api_port" \
        --log stdout \
        --log-format json
    stop_launch_service "$NGROK_LABEL"
    launchctl bootstrap "gui/$(id -u)" "$service_plist"
    NGROK_STARTED=1
    OWNS_NGROK=1

    while [ "$attempt" -lt 120 ]; do
        NGROK_PID="$(launch_service_pid "$NGROK_LABEL" || true)"
        if record="$(tunnel_record "$NGROK_API" 2>/dev/null)"; then
            IFS=$'\t' read -r TUNNEL_NAME PUBLIC_URL ORIGINAL_ADDR <<<"$record"
            ORIGINAL_ADDR=""
            return 0
        fi
        launch_service_alive "$NGROK_LABEL" || break
        sleep 0.25
        attempt=$((attempt + 1))
    done
    fail "ngrok did not start; see $log_path"
}

function restore_from_state() {
    local current_record
    local current_addr
    local encoded_name
    local payload
    local expected_addr

    [ -f "$STATE_PATH" ] || return 0
    NGROK_API="$(state_value ngrok_api || true)"
    TUNNEL_NAME="$(state_value tunnel_name || true)"
    PUBLIC_URL="$(state_value public_url || true)"
    ORIGINAL_ADDR="$(state_value original_addr || true)"
    GATEWAY_PORT="$(state_value gateway_port || true)"
    [ -n "$ORIGINAL_ADDR" ] || return 0
    [ -n "$NGROK_API" ] && [ -n "$TUNNEL_NAME" ] && [ -n "$GATEWAY_PORT" ] || return 0

    current_record="$(tunnel_record "$NGROK_API" 2>/dev/null || true)"
    current_addr="$(cut -f3 <<<"$current_record")"
    expected_addr="http://127.0.0.1:$GATEWAY_PORT"
    if [ "$current_addr" != "$expected_addr" ] \
        && [ "$current_addr" != "http://localhost:$GATEWAY_PORT" ]; then
        [ -n "$current_addr" ] \
            && warn "ngrok now points elsewhere; leaving its newer configuration untouched"
        return 0
    fi

    encoded_name="$(url_encode "$TUNNEL_NAME")"
    curl --silent --show-error --fail --max-time 5 \
        -X DELETE "$NGROK_API/api/tunnels/$encoded_name" >/dev/null
    payload="{\"name\":$(json_escape "$TUNNEL_NAME"),\"addr\":$(json_escape "$ORIGINAL_ADDR"),\"proto\":\"http\"}"
    curl --silent --show-error --fail --max-time 10 \
        -H 'Content-Type: application/json' \
        -X POST \
        -d "$payload" \
        "$NGROK_API/api/tunnels" >/dev/null
}

function stop_from_state() {
    local gateway_pid
    local gateway_label
    local ngrok_pid
    local ngrok_label
    local owns_ngrok
    local session_dir

    if [ ! -f "$STATE_PATH" ]; then
        info "No active iOS share"
        return 0
    fi

    gateway_pid="$(state_value gateway_pid || true)"
    gateway_label="$(state_value gateway_label || true)"
    ngrok_pid="$(state_value ngrok_pid || true)"
    ngrok_label="$(state_value ngrok_label || true)"
    owns_ngrok="$(state_value owns_ngrok || true)"
    session_dir="$(state_value session_dir || true)"

    restore_from_state \
        || fail "Could not restore the previous ngrok backend; the share was left running so existing routes remain available"
    if [ -n "$gateway_label" ]; then
        stop_launch_service "$gateway_label"
    fi
    stop_owned_process "$gateway_pid" "share-ios-gateway.rb"
    if [ "$owns_ngrok" = "true" ]; then
        if [ -n "$ngrok_label" ]; then
            stop_launch_service "$ngrok_label"
        fi
        stop_owned_process "$ngrok_pid" "ngrok"
    fi
    rm -f "$STATE_PATH"
    if [ -n "$session_dir" ] && safe_session_path "$session_dir"; then
        rm -rf "$session_dir"
    elif [ -n "$session_dir" ]; then
        warn "Refusing to delete unexpected session path"
    fi
    success "Install link revoked"
}

function show_status() {
    local expires_at
    local now
    local install_url
    local gateway_port

    if [ ! -f "$STATE_PATH" ]; then
        printf 'No active iOS share.\n'
        return 0
    fi
    expires_at="$(state_value expires_at)"
    install_url="$(state_value install_url)"
    gateway_port="$(state_value gateway_port)"
    now="$(date '+%s')"

    if [ "$now" -ge "$expires_at" ]; then
        printf 'Status: expired\n'
    elif [ "$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 1 "http://127.0.0.1:$gateway_port/__snippets_ios_share_health" || true)" != "200" ]; then
        printf 'Status: unavailable (gateway is not running)\n'
    else
        printf 'Status: active (%s remaining)\n' "$(human_remaining "$((expires_at - now))")"
    fi
    printf 'Expires: %s\n' "$(format_epoch "$expires_at")"
    printf 'Safari:  %s\n' "$install_url"
}

function simulator_id() {
    local family="$1"
    local devices_json="$2"
    ruby -rjson -e '
      family = ARGV.fetch(0)
      data = JSON.parse(STDIN.read).fetch("devices", {})
      devices = data.flat_map do |runtime, values|
        next [] unless runtime.include?(".iOS-26-")
        values.filter_map do |device|
          next unless device["isAvailable"]
          next unless device.fetch("deviceTypeIdentifier", "").include?("SimDeviceType.#{family}-")
          [device["state"] == "Booted" ? 0 : 1, runtime, device["udid"]]
        end
      end
      value = devices.sort.first
      print value[2] if value
    ' "$family" <<<"$devices_json"
}

function run_preflight_tests() {
    local devices_json
    local iphone_id
    local ipad_id

    [ "$RUN_TESTS" -eq 1 ] || return 0
    info "Running CorePackage tests"
    swift test --package-path "$PROJECT_DIR/CorePackage"

    info "Building the shared macOS target"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme Snippets \
        -configuration Debug \
        -destination 'platform=macOS,arch=arm64' \
        -derivedDataPath "$SESSION_DIR/macos-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        build

    devices_json="$(xcrun simctl list devices available --json)"
    iphone_id="$(simulator_id iPhone "$devices_json")"
    ipad_id="$(simulator_id iPad "$devices_json")"
    [ -n "$iphone_id" ] || fail "No available iOS 26 iPhone simulator"
    [ -n "$ipad_id" ] || fail "No available iOS 26 iPad simulator"

    info "Running iPhone unit and UI tests"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$iphone_id" \
        -derivedDataPath "$SESSION_DIR/iphone-tests-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        test

    info "Running iPad unit and UI tests"
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration Debug \
        -destination "platform=iOS Simulator,id=$ipad_id" \
        -derivedDataPath "$SESSION_DIR/ipad-tests-derived" \
        CODE_SIGNING_ALLOWED=NO \
        -quiet \
        test
    success "Preflight tests passed"
}

function build_ipa() {
    local archive_path="$SESSION_DIR/Snippets-iOS.xcarchive"
    local app_path
    local staging_path="$SESSION_DIR/ipa-staging"

    if [ -n "$(git -C "$PROJECT_DIR" status --porcelain)" ]; then
        warn "Building from a dirty Git worktree"
    fi
    run_preflight_tests

    info "Archiving the signed Release app"
    if ! run_redacted xcodebuild archive \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$SESSION_DIR/derived" \
        -archivePath "$archive_path" \
        -allowProvisioningUpdates \
        -allowProvisioningDeviceRegistration \
        -quiet; then
        fail "Xcode archive failed; make sure the login keychain is unlocked and signing is configured"
    fi

    app_path="$archive_path/Products/Applications/Snippets.app"
    [ -d "$app_path" ] || fail "Xcode did not create Snippets.app in the archive"
    install -d -m 700 "$staging_path/Payload"
    ditto "$app_path" "$staging_path/Payload/Snippets.app"
    IPA_PATH="$SESSION_DIR/Snippets.ipa"
    (cd "$staging_path" && ditto -c -k --sequesterRsrc --keepParent Payload "$IPA_PATH")
    rm -rf "$staging_path"
}

function plist_array_contains() {
    local plist_path="$1"
    local key_path="$2"
    local expected="$3"
    local values

    values="$(/usr/libexec/PlistBuddy -c "Print :$key_path" "$plist_path" 2>/dev/null || true)"
    grep -Fq "$expected" <<<"$values"
}

function verify_profile_certificate() {
    local app_path="$1"
    local profile_plist="$2"
    local certificate_index=0
    local leaf_digest
    local candidate_digest
    local prefix="$WORK_DIR/signing-leaf"

    rm -f "$prefix"* "$WORK_DIR/profile-certificate"
    codesign -d --extract-certificates="$prefix" "$app_path" >/dev/null 2>&1 || return 1
    [ -f "${prefix}0" ] || return 1
    leaf_digest="$(shasum -a 256 "${prefix}0" | cut -d' ' -f1)"

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

function verify_ipa() {
    local unpacked_path="$WORK_DIR/unpacked-ipa"
    local app_count
    local app_path
    local info_plist
    local entitlements_plist="$WORK_DIR/entitlements.plist"
    local profile_plist="$WORK_DIR/profile.plist"
    local app_identifier
    local profile_app_identifier
    local profile_cloud_environment
    local profile_aps_environment
    local signed_aps_environment
    local expiration_epoch
    local now_epoch
    local family_index=0
    local family_value
    local has_iphone=0
    local has_ipad=0
    local device_index=0
    local provisioned_device_count=0

    info "Validating the signed IPA"
    rm -rf "$unpacked_path"
    install -d -m 700 "$unpacked_path"
    ditto -x -k "$IPA_PATH" "$unpacked_path"
    app_count="$(find "$unpacked_path/Payload" -maxdepth 1 -type d -name '*.app' | wc -l | tr -d ' ')"
    [ "$app_count" = "1" ] || fail "IPA must contain exactly one top-level app"
    app_path="$(find "$unpacked_path/Payload" -maxdepth 1 -type d -name '*.app' -print -quit)"
    info_plist="$app_path/Info.plist"

    [ "$(plist_value "$info_plist" CFBundleIdentifier)" = "$BUNDLE_IDENTIFIER" ] \
        || fail "IPA has an unexpected bundle identifier"
    [ "$(plist_value "$info_plist" MinimumOSVersion)" = "26.0" ] \
        || fail "IPA has an unexpected deployment target"
    while family_value="$(plutil -extract "UIDeviceFamily.$family_index" raw -o - "$info_plist" 2>/dev/null)"; do
        [ "$family_value" = "1" ] && has_iphone=1
        [ "$family_value" = "2" ] && has_ipad=1
        family_index=$((family_index + 1))
    done
    [ "$has_iphone" -eq 1 ] && [ "$has_ipad" -eq 1 ] \
        || fail "IPA is not universal for both iPhone and iPad"

    codesign --verify --deep --strict "$app_path"
    codesign -d --entitlements :- "$app_path" >"$entitlements_plist" 2>/dev/null
    plutil -lint "$entitlements_plist" >/dev/null
    app_identifier="$(plist_value "$entitlements_plist" application-identifier)"
    [ "$app_identifier" = "$TEAM_IDENTIFIER.$BUNDLE_IDENTIFIER" ] \
        || fail "Signed application identifier is unexpected"
    [ "$(plist_value "$entitlements_plist" com.apple.developer.icloud-container-environment)" = "Production" ] \
        || fail "Signed IPA does not use the Production CloudKit environment"
    plist_array_contains "$entitlements_plist" com.apple.developer.icloud-container-identifiers "$ICLOUD_CONTAINER" \
        || fail "Signed IPA is missing the CloudKit container"
    plist_array_contains "$entitlements_plist" com.apple.developer.icloud-services CloudKit \
        || fail "Signed IPA is missing the CloudKit service"
    plist_array_contains "$entitlements_plist" keychain-access-groups "$TEAM_IDENTIFIER.$BUNDLE_IDENTIFIER" \
        || fail "Signed IPA is missing the shared keychain group"

    [ -f "$app_path/embedded.mobileprovision" ] \
        || fail "IPA has no embedded provisioning profile"
    security cms -D -i "$app_path/embedded.mobileprovision" >"$profile_plist"
    profile_app_identifier="$(plist_value "$profile_plist" Entitlements:application-identifier)"
    [ "$profile_app_identifier" = "$app_identifier" ] \
        || fail "Provisioning profile application identifier mismatch"
    profile_cloud_environment="$(plist_value "$profile_plist" Entitlements:com.apple.developer.icloud-container-environment)"
    grep -qE '(^|[[:space:]])Production($|[[:space:]])' <<<"$profile_cloud_environment" \
        || fail "Provisioning profile does not authorize Production CloudKit"
    plist_array_contains "$profile_plist" Entitlements:com.apple.developer.icloud-services CloudKit \
        || plist_array_contains "$profile_plist" Entitlements:com.apple.developer.icloud-services '*' \
        || fail "Provisioning profile does not authorize CloudKit"
    plist_array_contains "$profile_plist" Entitlements:com.apple.developer.icloud-container-identifiers "$ICLOUD_CONTAINER" \
        || fail "Provisioning profile does not authorize the CloudKit container"
    if ! plist_array_contains "$profile_plist" Entitlements:keychain-access-groups "$TEAM_IDENTIFIER.$BUNDLE_IDENTIFIER" \
        && ! plist_array_contains "$profile_plist" Entitlements:keychain-access-groups "$TEAM_IDENTIFIER.*"; then
        fail "Provisioning profile does not authorize the keychain group"
    fi
    signed_aps_environment="$(plist_value "$entitlements_plist" aps-environment || true)"
    profile_aps_environment="$(plist_value "$profile_plist" Entitlements:aps-environment || true)"
    [ "$signed_aps_environment" = "$profile_aps_environment" ] \
        || fail "Provisioning profile APNs environment does not match the signed app"
    verify_profile_certificate "$app_path" "$profile_plist" \
        || fail "Provisioning profile does not contain the signing certificate"

    while plutil -extract "ProvisionedDevices.$device_index" raw -o - "$profile_plist" >/dev/null 2>&1; do
        provisioned_device_count=$((provisioned_device_count + 1))
        device_index=$((device_index + 1))
    done
    [ "$provisioned_device_count" -gt 0 ] \
        || fail "Provisioning profile contains no registered devices and cannot be installed over the air"

    expiration_epoch="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' \
        "$(plutil -extract ExpirationDate raw -o - "$profile_plist")" '+%s' 2>/dev/null || true)"
    now_epoch="$(date '+%s')"
    [ -n "$expiration_epoch" ] && [ "$expiration_epoch" -gt "$now_epoch" ] \
        || fail "Provisioning profile is expired or has an unreadable expiration date"

    APP_VERSION="$(plist_value "$info_plist" CFBundleShortVersionString)"
    APP_BUILD="$(plist_value "$info_plist" CFBundleVersion)"
    success "Snippets $APP_VERSION ($APP_BUILD), Production CloudKit, $provisioned_device_count registered device(s)"
}

function generate_artifacts() {
    local artifact_root="$SESSION_DIR/public"
    local icon_source
    local ipa_name="Snippets-$APP_VERSION-$APP_BUILD.ipa"
    local ipa_url="$PUBLIC_URL/snippets-ios/$TOKEN/$ipa_name"
    local manifest_url="$PUBLIC_URL/snippets-ios/$TOKEN/manifest.plist"
    local encoded_manifest_url
    local install_action
    local expires_display

    install -d -m 700 "$artifact_root"
    install -m 600 "$IPA_PATH" "$artifact_root/$ipa_name"

    icon_source="$(find "$PROJECT_DIR/snippets/Snippet.icon/Assets" -maxdepth 1 -type f -name '*.png' -print -quit)"
    [ -n "$icon_source" ] || fail "Could not find the Snippets app icon source"
    sips -z 57 57 "$icon_source" --out "$artifact_root/icon-57.png" >/dev/null
    sips -z 512 512 "$icon_source" --out "$artifact_root/icon-512.png" >/dev/null
    chmod 600 "$artifact_root/icon-57.png" "$artifact_root/icon-512.png"

    MANIFEST_PATH="$artifact_root/manifest.plist"
    plutil -create xml1 "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items array' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0 dict' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets array' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:0 dict' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:0:kind string software-package' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:assets:0:url string $ipa_url" "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:1 dict' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:1:kind string display-image' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:assets:1:url string $PUBLIC_URL/snippets-ios/$TOKEN/icon-57.png" "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:2 dict' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:assets:2:kind string full-size-image' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:assets:2:url string $PUBLIC_URL/snippets-ios/$TOKEN/icon-512.png" "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:metadata dict' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:metadata:bundle-identifier string $BUNDLE_IDENTIFIER" "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:metadata:bundle-version string $APP_BUILD" "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c 'Add :items:0:metadata:kind string software' "$MANIFEST_PATH"
    /usr/libexec/PlistBuddy -c "Add :items:0:metadata:title string Snippets $APP_VERSION" "$MANIFEST_PATH"
    chmod 600 "$MANIFEST_PATH"

    encoded_manifest_url="$(url_encode "$manifest_url")"
    install_action="itms-services://?action=download-manifest&url=$encoded_manifest_url"
    expires_display="$(format_epoch "$EXPIRES_AT")"
    INSTALL_URL="$PUBLIC_URL/snippets-ios/$TOKEN/install.html"

    ruby -rcgi -e '
      path, action, version, build, expiry = ARGV
      html = <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta name="robots" content="noindex, nofollow, noarchive">
          <title>Install Snippets</title>
          <style>
            :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: #11131a; color: #f7f7fa; }
            main { width: min(30rem, calc(100% - 3rem)); text-align: center; }
            img { width: 7rem; height: 7rem; border-radius: 1.6rem; box-shadow: 0 1rem 3rem #0008; }
            h1 { margin: 1.4rem 0 .35rem; font-size: 2rem; }
            p { color: #b9bdca; line-height: 1.45; }
            a { display: block; margin: 1.6rem 0; padding: 1rem; border-radius: .9rem; background: #6b6ff5; color: white; text-decoration: none; font-weight: 650; }
            small { color: #858b9d; }
          </style>
        </head>
        <body><main>
          <img src="icon-512.png" alt="Snippets">
          <h1>Snippets</h1>
          <p>Version #{CGI.escapeHTML(version)} (#{CGI.escapeHTML(build)})</p>
          <a href="#{CGI.escapeHTML(action)}">Install on this device</a>
          <small>Link expires #{CGI.escapeHTML(expiry)}. Only registered devices can install this build.</small>
        </main></body>
        </html>
      HTML
      File.open(path, "w", 0o600) { |file| file.write(html) }
    ' "$artifact_root/install.html" "$install_action" "$APP_VERSION" "$APP_BUILD" "$expires_display"
}

function start_gateway() {
    local log_path="$SESSION_DIR/gateway.log"
    local service_plist="$SESSION_DIR/gateway-launchd.plist"
    local ruby_path

    : >"$log_path"
    chmod 600 "$log_path"
    ruby_path="$(command -v ruby)"
    gateway_args=(
        "$ruby_path" "$GATEWAY_SCRIPT"
        --root "$SESSION_DIR/public"
        --token "$TOKEN"
        --expires-at "$EXPIRES_AT"
        --port "$GATEWAY_PORT"
    )
    if [ -n "$ORIGINAL_ADDR" ]; then
        gateway_args+=(--fallback "$ORIGINAL_ADDR")
    fi
    create_launch_service_plist \
        "$service_plist" \
        "$GATEWAY_LABEL" \
        "$log_path" \
        "$log_path" \
        "${gateway_args[@]}"
    stop_launch_service "$GATEWAY_LABEL"
    launchctl bootstrap "gui/$(id -u)" "$service_plist"
    GATEWAY_STARTED=1
    if ! wait_for_url "http://127.0.0.1:$GATEWAY_PORT/__snippets_ios_share_health" 200; then
        fail "Share gateway did not start; see $log_path"
    fi
    GATEWAY_PID="$(launch_service_pid "$GATEWAY_LABEL")"
    [ -n "$GATEWAY_PID" ] || fail "Could not resolve the share gateway process"
}

function save_state() {
    local temporary_state="$SESSION_DIR/state.plist"

    plutil -create xml1 "$temporary_state"
    plutil -insert version -integer 1 "$temporary_state"
    plutil -insert gateway_pid -integer "$GATEWAY_PID" "$temporary_state"
    plutil -insert gateway_port -integer "$GATEWAY_PORT" "$temporary_state"
    plutil -insert gateway_label -string "$GATEWAY_LABEL" "$temporary_state"
    plutil -insert ngrok_api -string "$NGROK_API" "$temporary_state"
    plutil -insert ngrok_pid -integer "${NGROK_PID:-0}" "$temporary_state"
    plutil -insert ngrok_label -string "$NGROK_LABEL" "$temporary_state"
    plutil -insert owns_ngrok -bool "$OWNS_NGROK" "$temporary_state"
    plutil -insert tunnel_name -string "$TUNNEL_NAME" "$temporary_state"
    plutil -insert public_url -string "$PUBLIC_URL" "$temporary_state"
    plutil -insert original_addr -string "$ORIGINAL_ADDR" "$temporary_state"
    plutil -insert session_dir -string "$SESSION_DIR" "$temporary_state"
    plutil -insert expires_at -integer "$EXPIRES_AT" "$temporary_state"
    plutil -insert install_url -string "$INSTALL_URL" "$temporary_state"
    chmod 600 "$temporary_state"
    mv "$temporary_state" "$STATE_PATH"
    chmod 600 "$STATE_PATH"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ttl)
            [ "$#" -ge 2 ] || fail "--ttl requires a duration"
            TTL_INPUT="$2"
            shift 2
            ;;
        --reuse-ipa)
            [ "$#" -ge 2 ] || fail "--reuse-ipa requires a path"
            IPA_SOURCE="$2"
            shift 2
            ;;
        --run-tests)
            RUN_TESTS=1
            shift
            ;;
        --no-clipboard)
            COPY_TO_CLIPBOARD=0
            shift
            ;;
        --status)
            ACTION="status"
            shift
            ;;
        --stop)
            ACTION="stop"
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

require_command ruby
require_command curl
require_command plutil
require_command openssl
require_command install
require_command ps
require_command launchctl
acquire_lock

if [ "$ACTION" = "status" ]; then
    show_status
    RUN_SUCCEEDED=1
    exit 0
fi
if [ "$ACTION" = "stop" ]; then
    stop_from_state
    RUN_SUCCEEDED=1
    exit 0
fi

parse_ttl "$TTL_INPUT"
require_command codesign
require_command security
require_command shasum
require_command ditto
require_command sips
[ -x "$GATEWAY_SCRIPT" ] || [ -f "$GATEWAY_SCRIPT" ] \
    || fail "Gateway helper not found: $GATEWAY_SCRIPT"

if [ -f "$STATE_PATH" ]; then
    info "Replacing the previous iOS share"
    stop_from_state
fi

TOKEN="$(openssl rand -hex 24)"
CREATED_AT="$(date '+%s')"
EXPIRES_AT=$((CREATED_AT + TTL_SECONDS))
SESSION_DIR="$CACHE_ROOT/sessions/$(date -u '+%Y%m%dT%H%M%SZ')-$TOKEN"
install -d -m 700 "$CACHE_ROOT/sessions" "$SESSION_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/snippets-ios-share.XXXXXX")"

if [ -n "$IPA_SOURCE" ]; then
    [ -f "$IPA_SOURCE" ] || fail "IPA not found: $IPA_SOURCE"
    IPA_PATH="$SESSION_DIR/source.ipa"
    install -m 600 "$IPA_SOURCE" "$IPA_PATH"
else
    require_command xcodebuild
    require_command xcrun
    build_ipa
fi
verify_ipa

GATEWAY_PORT="$(free_port)"
if discover_ngrok; then
    info "Reusing ngrok endpoint $PUBLIC_URL"
    [ "$ORIGINAL_ADDR" != "http://127.0.0.1:$GATEWAY_PORT" ] \
        || fail "Unexpected ngrok gateway loop"
    generate_artifacts
    start_gateway
    TUNNEL_RETARGETED=1
    retarget_tunnel "http://127.0.0.1:$GATEWAY_PORT"
else
    info "Starting ngrok"
    ORIGINAL_ADDR=""
    # The public URL is needed in the OTA manifest, so ngrok starts before the gateway.
    # Its first health requests can briefly receive a connection error until generation finishes.
    start_ngrok
    generate_artifacts
    start_gateway
fi

if ! wait_for_url "$PUBLIC_URL/snippets-ios/$TOKEN/manifest.plist" 200; then
    fail "The manifest is not reachable through ngrok"
fi
save_state
RUN_SUCCEEDED=1

if [ "$COPY_TO_CLIPBOARD" -eq 1 ] && command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$INSTALL_URL" | pbcopy
    success "Safari link copied to the clipboard"
fi

printf '\nInstall from Safari:\n%s\n\n' "$INSTALL_URL"
printf 'Expires: %s (%s)\n' "$(format_epoch "$EXPIRES_AT")" "$(human_remaining "$TTL_SECONDS")"
printf 'Revoke now: ./scripts/share-ios.sh --stop\n'
if command -v qrencode >/dev/null 2>&1; then
    printf '\n'
    qrencode -t ANSIUTF8 "$INSTALL_URL"
fi
