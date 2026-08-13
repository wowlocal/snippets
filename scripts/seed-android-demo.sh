#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SERIAL="${1:-}"

if ! command -v adb >/dev/null 2>&1; then
  echo "adb is not available; start Android Studio and add its platform-tools to PATH." >&2
  exit 1
fi

if [[ -z "$SERIAL" ]]; then
  DEVICES=()
  while IFS= read -r device; do
    DEVICES+=("$device")
  done < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  if [[ ${#DEVICES[@]} -ne 1 ]]; then
    echo "Expected one running Android device; pass its adb serial as the first argument." >&2
    exit 1
  fi
  SERIAL="${DEVICES[0]}"
fi

cd "$REPOSITORY_DIR"
./gradlew :app:assembleDebug :app:assembleDebugAndroidTest

ADB=(adb -s "$SERIAL")
TARGET_APK="app/build/outputs/apk/debug/app-debug.apk"
TEST_APK="app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk"

"${ADB[@]}" install -r "$TARGET_APK"
"${ADB[@]}" install -r "$TEST_APK"
cleanup() {
  "${ADB[@]}" uninstall com.khm.snippets.android.test >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${ADB[@]}" shell am instrument -w \
  -e class com.khm.snippets.android.DemoLibrarySeedTest \
  -e snippetsSeedDemo true \
  com.khm.snippets.android.test/androidx.test.runner.AndroidJUnitRunner
"${ADB[@]}" shell am start -n com.khm.snippets.android/.MainActivity

echo "Installed Snippets and added any missing demo snippets on $SERIAL."
