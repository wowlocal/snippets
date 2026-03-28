#!/bin/bash
# Shared helpers for Distribution scripts. Source this file, don't run it directly.

function gray_text() {
    echo -e "\033[1;30m"
}

function green_text() {
    echo -e "\033[1;32m"
}

function normal_text() {
    echo -e "\033[0m"
}

function orange_text() {
    echo -e "\033[1;33m"
}

function red_text() {
    echo -e "\033[1;31m"
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
