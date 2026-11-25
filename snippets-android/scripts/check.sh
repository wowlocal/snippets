#!/usr/bin/env bash
# Builds and tests everything that does not need a device.
# Extra arguments are passed to Gradle, e.g. scripts/check.sh --offline
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -z "${JAVA_HOME:-}" ]]; then
    export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home
fi

./gradlew \
    :core:test \
    :core:animalsnifferMain \
    :app:testDebugUnitTest \
    :app:assembleDebug \
    :app:lintDebug \
    "$@"
