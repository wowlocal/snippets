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

# export_app <archive_path> <app_path> — runs xcodebuild -exportArchive
function export_app() {
    local archive_path="$1"
    local app_path="$2"
    mkdir -p exported-apps
    xcodebuild -exportArchive \
        -archivePath "$archive_path" \
        -exportOptionsPlist "ExportOptions.plist" \
        -exportPath "exported-apps" \
        -quiet

    local exported_app
    exported_app=$(find exported-apps -name "*.app" -maxdepth 1 -type d | head -1)
    if [ -z "$exported_app" ]; then
        red_text
        echo "Export failed — no .app found in exported-apps/"
        normal_text
        exit 1
    fi

    if [ "$exported_app" != "$app_path" ]; then
        mv "$exported_app" "$app_path"
    fi
}
