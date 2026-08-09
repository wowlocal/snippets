#!/bin/bash
# Shared helpers for Distribution scripts. Source this file, don't run it directly.

COLOR_ENABLED=0
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    COLOR_ENABLED=1
fi

function set_style() {
    if [ "$COLOR_ENABLED" -eq 1 ]; then
        printf '\033[%sm' "$1"
    fi
}

# Keep the palette away from black / dark blue tones so it stays readable in
# both dark and light terminal themes.
function gray_text() {
    set_style "36"
}

function green_text() {
    set_style "32"
}

function normal_text() {
    set_style "0"
}

function orange_text() {
    set_style "33"
}

function red_text() {
    set_style "31"
}

function blue_text() {
    set_style "35"
}

function bold_text() {
    set_style "1"
}

function underline_text() {
    set_style "4"
}

# Compatibility aliases for scripts that still use the older short names.
function gray() {
    gray_text
}

function green() {
    green_text
}

function orange() {
    orange_text
}

function red() {
    red_text
}

function blue() {
    blue_text
}

function bold() {
    bold_text
}

function reset() {
    normal_text
}

function link_text() {
    if [ "$COLOR_ENABLED" -eq 1 ]; then
        printf '\033[4;36m'
    fi
}

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PBXPROJ="$PROJECT_DIR/Snippets.xcodeproj/project.pbxproj"
SCHEME="Snippets"

# read_version — prints the current MARKETING_VERSION from the project file
function read_version() {
    local ver
    ver=$(grep 'MARKETING_VERSION' "$PBXPROJ" | head -1 | sed -E 's/.*= ([^;]+);/\1/')
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        red_text
        echo "Could not read valid version from project: $ver" >&2
        normal_text
        exit 1
    fi
    echo "$ver"
}

# archive_app <archive_path> — runs xcodebuild archive
function archive_app() {
    local archive_path="$1"
    mkdir -p "$(dirname "$archive_path")"
    # -allowProvisioningUpdates because the restricted entitlements mean a profile is now
    # mandatory, and nothing else renews one: the Xcode-managed development profiles carry
    # TimeToLive 365. Without this, the first release cut after they lapse fails somewhere
    # further down, where the cause is much harder to see.
    xcodebuild archive \
        -project "$PROJECT_DIR/Snippets.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$archive_path" \
        -allowProvisioningUpdates \
        -quiet

    if [ ! -d "$archive_path" ]; then
        red_text
        echo "Archive failed"
        normal_text
        exit 1
    fi
}

# export_app <archive_path> <app_path> — exports and signs the archived app
#
# `developer-id` used to be special-cased here to `export_developer_id_app`, which copied
# the archived .app and re-signed it by hand. Measured, that produced a bundle that could
# not launch: `xcodebuild archive` signs with Apple Development and embeds the
# *development* profile, the re-sign swapped in the Developer ID identity and left that
# profile sealed in place, and a profile whose `DeveloperCertificates` do not contain the
# signing leaf fails validation — so AMFI SIGKILLed the app before any of its code ran.
# `codesign --verify --deep --strict` called that bundle "valid on disk", and
# `assert_provisioning_profile` passed it too: the profile was present, parsed, unexpired,
# and did authorise every entitlement. Only the certificate did not match.
#
# `-exportArchive` is the path that gets this right. It embeds the Developer ID Direct
# profile (ProvisionsAllDevices, expiring 2044 rather than in a year) and injects
# `com.apple.developer.icloud-container-environment = Production`, which the hand-rolled
# path silently omitted — so CloudKit would have addressed the Development database even if
# the app had launched.
#
# `export_developer_id_app` and the sign_* helpers below are now unreferenced and can be
# deleted; they are left in place only so this change is easy to revert.
function export_app() {
    local archive_path="$1"
    local app_path="$2"

    mkdir -p exported-apps
    # `find -delete` rather than a glob: an unmatched `exported-apps/*.app` is passed
    # through literally by bash and is a hard error in zsh, and a stale .app left here is
    # what `move_exported_app` would pick up instead of the one just built.
    find exported-apps -maxdepth 1 -name "*.app" -type d -exec rm -rf {} +
    if ! xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportOptionsPlist "ExportOptions.plist" \
        -exportPath "exported-apps" \
        -allowProvisioningUpdates \
        -quiet; then
        red_text
        echo "Export failed"
        normal_text
        exit 1
    fi

    move_exported_app "$app_path"

    assert_provisioning_profile "$app_path"
    assert_app_launches "$app_path"
}

function move_exported_app() {
    local app_path="$1"
    local exported_app
    exported_app=$(find exported-apps -maxdepth 1 -name "*.app" -type d | head -1)
    if [ -z "$exported_app" ]; then
        red_text
        echo "Export failed — no .app found in exported-apps/"
        normal_text
        exit 1
    fi

    if [ "$exported_app" != "$app_path" ]; then
        rm -rf "$app_path"
        mv "$exported_app" "$app_path"
    fi
}

function export_developer_id_app() {
    local archive_path="$1"
    local app_path="$2"
    local archived_app
    archived_app=$(find "$archive_path/Products/Applications" -maxdepth 1 -name "*.app" -type d | head -1)

    if [ -z "$archived_app" ]; then
        red_text
        echo "Export failed — no archived .app found in $archive_path"
        normal_text
        exit 1
    fi

    local identity
    identity=$(developer_id_application_identity)
    if [ -z "$identity" ]; then
        red_text
        echo "Export failed — no Developer ID Application identity found"
        normal_text
        exit 1
    fi

    mkdir -p "$(dirname "$app_path")"
    rm -rf "$app_path"
    /usr/bin/ditto "$archived_app" "$app_path"

    gray_text
    echo "  Signing with $identity"
    normal_text

    sign_app_for_developer_id "$app_path" "$identity"
    codesign --verify --deep --strict --verbose=2 "$app_path"
    assert_provisioning_profile "$app_path"
}

# assert_provisioning_profile <app_path>
#
# Since secure snippets shipped, the app claims keychain-access-groups and iCloud
# entitlements. Those are *restricted*: macOS only honours them if the bundle carries an
# embedded provisioning profile that authorises each one, and Gatekeeper checks that at
# every launch. Get it wrong and the app does not misbehave — it refuses to start, for
# everyone, with nothing in the UI to explain why.
#
# Nothing else in the pipeline catches this. `codesign --verify` checks the signature's
# integrity, not whether the profile backs the entitlements, and notarization does not
# check it either. So this is the only thing standing between a bad export and a release
# that cannot launch.
function assert_provisioning_profile() {
    local app_path="$1"
    local profile="$app_path/Contents/embedded.provisionprofile"

    if [ ! -f "$profile" ]; then
        red_text
        echo "Export failed — no embedded.provisionprofile in $app_path"
        echo "The app claims restricted entitlements, so without a profile it will not launch."
        normal_text
        exit 1
    fi

    local plist
    plist=$(mktemp)
    if ! security cms -D -i "$profile" >"$plist" 2>/dev/null; then
        red_text
        echo "Export failed — embedded.provisionprofile does not parse"
        normal_text
        rm -f "$plist"
        exit 1
    fi

    # A profile that expires takes the app down with it — it stops launching, for
    # everyone, and the failure lands on users rather than here. 90 days is the margin,
    # not a year: a Developer ID profile is issued for ~18 years, but a freshly minted
    # development profile is only good for one, and rejecting that would fail every
    # local Release build for no reason.
    local expiry expiry_seconds now_seconds
    expiry=$(/usr/libexec/PlistBuddy -c "Print :ExpirationDate" "$plist" 2>/dev/null || echo "")
    expiry_seconds=$(date -j -f "%a %b %d %T %Z %Y" "$expiry" +%s 2>/dev/null || echo 0)
    now_seconds=$(date +%s)
    if [ "$expiry_seconds" -lt "$((now_seconds + 7776000))" ]; then
        red_text
        echo "Export failed — provisioning profile expires within 90 days ($expiry)"
        echo "Refresh it before shipping; when it lapses the app stops launching."
        normal_text
        rm -f "$plist"
        exit 1
    fi

    # Every restricted entitlement the binary claims must actually be authorised by the
    # profile. A claim the profile does not back is exactly the case that launches fine
    # here — where a development profile is installed — and fails on the user's Mac.
    local claimed
    claimed=$(mktemp)
    /usr/bin/codesign -d --entitlements :- "$app_path" >"$claimed" 2>/dev/null || true

    local key
    for key in $(/usr/libexec/PlistBuddy -c "Print" "$claimed" 2>/dev/null \
                 | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9.-]*\) = .*/\1/p' | sort -u); do
        case "$key" in
            keychain-access-groups|com.apple.developer.*) ;;
            *) continue ;;
        esac
        if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:$key" "$plist" >/dev/null 2>&1; then
            red_text
            echo "Export failed — the profile does not authorise entitlement: $key"
            echo "Enable the matching capability for this App ID, then refresh the profile."
            normal_text
            rm -f "$plist" "$claimed"
            exit 1
        fi
    done

    # snippets-cli is a bare Mach-O. A bare executable claiming restricted entitlements is
    # SIGKILLed at exec, so this must stay empty rather than inherit the app's.
    local cli="$app_path/Contents/MacOS/snippets-cli"
    if [ -f "$cli" ]; then
        if /usr/bin/codesign -d --entitlements :- "$cli" 2>/dev/null \
           | grep -qE "keychain-access-groups|com\.apple\.developer\."; then
            red_text
            echo "Export failed — snippets-cli must not claim restricted entitlements"
            normal_text
            rm -f "$plist" "$claimed"
            exit 1
        fi
    fi

    # The check the other four miss, and the only one that catches the failure that
    # actually shipped: a profile can be present, parse, be years from expiry, and
    # authorise every entitlement claimed — and still not vouch for the certificate the
    # bundle is signed with. A development profile lists the Apple Development certificate,
    # so a bundle re-signed with Developer ID carries a profile that does not cover its own
    # signature. macOS refuses to start it. Verified: without this check the broken bundle
    # was reported "Provisioning profile OK" and then died with SIGKILL.
    if ! profile_vouches_for_signature "$app_path" "$plist"; then
        red_text
        echo "Export failed — the embedded profile does not list the signing certificate"
        echo "The profile is valid, but it does not vouch for the identity this bundle is"
        echo "signed with, so macOS will kill the app at launch before any code runs."
        echo "Profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist" 2>/dev/null)"
        normal_text
        rm -f "$plist" "$claimed"
        exit 1
    fi

    # A profile scoped to registered devices launches on this Mac and nowhere else, which
    # is the worst way to learn about it — the build tests clean and fails for every user.
    if ! /usr/libexec/PlistBuddy -c "Print :ProvisionsAllDevices" "$plist" >/dev/null 2>&1; then
        red_text
        echo "Export failed — the embedded profile is limited to registered devices"
        echo "It has no ProvisionsAllDevices flag, so it is a development profile."
        echo "Profile: $(/usr/libexec/PlistBuddy -c 'Print :Name' "$plist" 2>/dev/null)"
        normal_text
        rm -f "$plist" "$claimed"
        exit 1
    fi

    gray_text
    echo "  Provisioning profile OK (expires $expiry)"
    normal_text
    rm -f "$plist" "$claimed"
}

# profile_vouches_for_signature <app_path> <decoded_profile_plist>
#
# True when the leaf certificate the bundle is signed with is one of the profile's
# DeveloperCertificates. Compared by digest of the DER, which is exact — a name comparison
# would pass for two different certificates issued to the same team.
function profile_vouches_for_signature() {
    local app_path="$1"
    local plist="$2"
    local work
    work=$(mktemp -d "${TMPDIR:-/tmp}/snippets-certs.XXXXXX")

    if ! codesign -d --extract-certificates="$work/leaf" "$app_path" >/dev/null 2>&1 \
       || [ ! -f "$work/leaf0" ]; then
        rm -rf "$work"
        return 1
    fi

    local leaf_digest
    leaf_digest=$(shasum -a 256 "$work/leaf0" | cut -d' ' -f1)

    local index=0
    while /usr/libexec/PlistBuddy -c "Print :DeveloperCertificates:$index" "$plist" >/dev/null 2>&1; do
        if plutil -extract "DeveloperCertificates.$index" raw -o - "$plist" 2>/dev/null \
           | base64 -d >"$work/candidate" 2>/dev/null; then
            if [ "$(shasum -a 256 "$work/candidate" | cut -d' ' -f1)" = "$leaf_digest" ]; then
                rm -rf "$work"
                return 0
            fi
        fi
        index=$((index + 1))
    done

    rm -rf "$work"
    return 1
}

# assert_app_launches <app_path>
#
# The empirical backstop. Every static check above encodes a rule that Apple can change,
# and the rule that mattered was missing for one release cycle. This one just runs the
# thing — it is the check that cannot be fooled by a bundle that looks correct.
#
# SNIPPETS_SUPPORT_DIR is redirected so a release check can never touch the real snippet
# library. Sync is explicitly disabled in the argument domain: this Production-signed
# process otherwise inherits the user's per-bundle preference, seeds `tp` into the fresh
# support directory, and can upload it to the real CloudKit library before it is killed.
# Set SKIP_LAUNCH_SMOKE_TEST=1 to opt out on a machine where launching is not possible.
function assert_app_launches() {
    local app_path="$1"

    if [ -n "${SKIP_LAUNCH_SMOKE_TEST:-}" ]; then
        orange_text
        echo "  SKIP_LAUNCH_SMOKE_TEST set — not verifying that the app launches."
        normal_text
        return 0
    fi

    local executable_name
    executable_name=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" \
        "$app_path/Contents/Info.plist" 2>/dev/null || true)
    if [ -z "$executable_name" ]; then
        red_text
        echo "Export failed — could not read CFBundleExecutable from $app_path"
        normal_text
        exit 1
    fi

    local scratch output status=0
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/snippets-launch.XXXXXX")
    output="$scratch/launch.log"

    # The launch is confined to a subshell with `set +e` and its stderr discarded. Both
    # halves of that are load-bearing, and each one broke a release on its own:
    #
    #  - Callers run under `set -e`. `kill -9` on a process that has already exited
    #    returns non-zero, so the "it survived, now stop it" path aborted the release
    #    *between* stopping the app and reporting success. The check passed and the
    #    release died anyway, with no failure message — the worst of both.
    #  - Reaping a signalled background job makes the shell print "Terminated: 15" to its
    #    own stderr. That is not this function's output and cannot be redirected from
    #    inside it, and it reads exactly like the crash this check exists to report.
    #
    # The subshell's exit status is the verdict, so `|| status=$?` is also what keeps
    # `set -e` from firing on a genuine failure before it can be explained.
    (
        set +e
        SNIPPETS_SUPPORT_DIR="$scratch/support" \
            "$app_path/Contents/MacOS/$executable_name" \
            -SnippetsICloudSyncEnabled NO >"$output" 2>&1 &
        child=$!
        sleep 3
        if kill -0 "$child" 2>/dev/null; then
            kill -TERM "$child" 2>/dev/null
            sleep 1
            kill -9 "$child" 2>/dev/null
            wait "$child" 2>/dev/null
            exit 0
        fi
        wait "$child" 2>/dev/null
        code=$?
        # A GUI app that exits by itself within three seconds has not passed, even with
        # status 0 — reported as its own case rather than as a crash, because the cause is
        # different and so is the fix.
        [ "$code" -eq 0 ] && exit 111
        exit "$code"
    ) 2>/dev/null || status=$?

    if [ "$status" -eq 0 ]; then
        rm -rf "$scratch"
        gray_text
        echo "  App launches and stays running."
        normal_text
        return 0
    fi

    red_text
    if [ "$status" -eq 111 ]; then
        echo "Export failed — the exported app exited on its own within 3 seconds."
    else
        echo "Export failed — the exported app does not launch (exit code $status)."
    fi
    if [ "$status" -eq 137 ]; then
        echo "137 is SIGKILL: the kernel refused the binary before any code ran, which is"
        echo "almost always the embedded provisioning profile failing to authorise a"
        echo "restricted entitlement the binary claims."
    fi
    if [ -s "$output" ]; then
        echo "--- first lines of output ---"
        head -20 "$output"
    fi
    normal_text
    rm -rf "$scratch"
    exit 1
}

function developer_id_application_identity() {
    if [ -n "${DEVELOPER_ID_APPLICATION:-}" ]; then
        echo "$DEVELOPER_ID_APPLICATION"
        return
    fi

    local team_id
    team_id=$(/usr/libexec/PlistBuddy -c "Print :teamID" "ExportOptions.plist" 2>/dev/null || true)

    local identities
    identities=$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p')
    if [ -n "$team_id" ]; then
        echo "$identities" | grep "($team_id)" | head -1
    else
        echo "$identities" | head -1
    fi
}

function sign_app_for_developer_id() {
    local app_path="$1"
    local identity="$2"
    local app_entitlements
    app_entitlements=$(mktemp "${TMPDIR:-/tmp}/snippets-app-entitlements.XXXXXX")
    if ! extract_entitlements "$app_path" "$app_entitlements"; then
        rm -f "$app_entitlements"
        app_entitlements=""
    fi

    # Sign standalone helper executables before their containing bundles.
    sign_macho_helpers "$app_path/Contents/MacOS" "$identity"
    sign_macho_helpers "$app_path/Contents/Frameworks" "$identity"
    sign_macho_helpers "$app_path/Contents/PlugIns" "$identity"

    sign_bundles_matching "$app_path/Contents" "$identity" "*.xpc"
    sign_bundles_matching "$app_path/Contents" "$identity" "*.app"
    sign_bundles_matching "$app_path/Contents" "$identity" "*.framework"

    sign_code "$app_path" "$identity" "$app_entitlements"
    rm -f "$app_entitlements"
}

function sign_macho_helpers() {
    local root="$1"
    local identity="$2"
    [ -d "$root" ] || return 0

    while IFS= read -r file_path; do
        if is_bundle_main_executable "$file_path"; then
            continue
        fi

        if file "$file_path" | grep -q "Mach-O"; then
            sign_code "$file_path" "$identity"
        fi
    done < <(find "$root" -type f -perm -111 -print)
}

function is_bundle_main_executable() {
    local file_path="$1"
    local contents_dir
    contents_dir=$(dirname "$(dirname "$file_path")")

    if [ "$(basename "$(dirname "$file_path")")" != "MacOS" ]; then
        return 1
    fi

    if [ ! -f "$contents_dir/Info.plist" ]; then
        return 1
    fi

    local bundle_executable
    bundle_executable=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$contents_dir/Info.plist" 2>/dev/null || true)
    [ "$(basename "$file_path")" = "$bundle_executable" ]
}

function sign_bundles_matching() {
    local root="$1"
    local identity="$2"
    local pattern="$3"
    [ -d "$root" ] || return 0

    while IFS= read -r bundle_path; do
        sign_code "$bundle_path" "$identity"
    done < <(find "$root" -name "$pattern" -type d -print | awk '{ print gsub("/", "/"), $0 }' | sort -rn | cut -d' ' -f2-)
}

function sign_code() {
    local code_path="$1"
    local identity="$2"
    local entitlements_path="${3:-}"
    local temporary_entitlements=""
    local entitlements_args=()

    if [ -z "$entitlements_path" ]; then
        temporary_entitlements=$(mktemp "${TMPDIR:-/tmp}/snippets-entitlements.XXXXXX")
        if extract_entitlements "$code_path" "$temporary_entitlements"; then
            entitlements_path="$temporary_entitlements"
        fi
    fi

    if [ -n "$entitlements_path" ] && [ -s "$entitlements_path" ]; then
        entitlements_args=(--entitlements "$entitlements_path")
    fi

    if ! /usr/bin/codesign \
        --force \
        --sign "$identity" \
        --options runtime \
        --timestamp \
        --generate-entitlement-der \
        --preserve-metadata=identifier,flags \
        "${entitlements_args[@]}" \
        "$code_path"; then
        red_text
        echo "Signing failed for $code_path"
        echo "Developer ID signing requires Apple's timestamp service; check network access and retry."
        normal_text
        rm -f "$temporary_entitlements"
        return 1
    fi

    rm -f "$temporary_entitlements"
}

function extract_entitlements() {
    local code_path="$1"
    local output_path="$2"

    if ! /usr/bin/codesign -d --entitlements :- "$code_path" >"$output_path" 2>/dev/null; then
        return 1
    fi

    plutil -lint "$output_path" >/dev/null 2>&1
}
