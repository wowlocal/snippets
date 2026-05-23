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
    xcodebuild archive \
        -project "$PROJECT_DIR/Snippets.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$archive_path" \
        -quiet

    if [ ! -d "$archive_path" ]; then
        red_text
        echo "Archive failed"
        normal_text
        exit 1
    fi
}

# export_app <archive_path> <app_path> — exports and signs the archived app
function export_app() {
    local archive_path="$1"
    local app_path="$2"
    local export_method
    export_method=$(/usr/libexec/PlistBuddy -c "Print :method" "ExportOptions.plist" 2>/dev/null || true)

    if [ "$export_method" = "developer-id" ]; then
        export_developer_id_app "$archive_path" "$app_path"
        return
    fi

    mkdir -p exported-apps
    if ! xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportOptionsPlist "ExportOptions.plist" \
        -exportPath "exported-apps" \
        -quiet; then
        red_text
        echo "Export failed"
        normal_text
        exit 1
    fi

    move_exported_app "$app_path"
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
