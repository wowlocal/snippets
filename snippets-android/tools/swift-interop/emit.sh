#!/bin/sh
# Builds the Swift interop tool and writes the golden vectors that the Kotlin tests read.
#
#   tools/swift-interop/emit.sh             # into core/src/test/resources/vectors/swift
#   tools/swift-interop/emit.sh <outDir>    # somewhere else
#   tools/swift-interop/emit.sh --only V,G01   # only some vector files (no MANIFEST)
#
# `xcrun swift`, not the swiftly toolchain pinned by the repository's .swift-version:
# that one cannot load CryptoKit from the current Xcode SDK (repository AGENTS.md).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
android=$(cd "$here/../.." && pwd)
repo=$(cd "$android/.." && pwd)

out="$android/core/src/test/resources/vectors/swift"
only=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only) only="$2"; shift 2 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) out="$1"; shift ;;
    esac
done

# Debug configuration on purpose: `@testable import` needs -enable-testing.
xcrun swift build --package-path "$here" --configuration debug

swift_version=$(xcrun swift --version 2>/dev/null | head -n 1 | sed 's/^swift-driver version: [^ ]* //')

set -- emit "$out" --swift-version "$swift_version" --linux-fixtures "$repo/snippets-linux/tests/fixtures"
if [ -n "$only" ]; then set -- "$@" --only "$only"; fi
"$here/.build/debug/swift-interop" "$@"
