#!/bin/zsh

set -euo pipefail

SNIPPETS_SCRIPT_DIR=${0:A:h}
SNIPPETS_REPOSITORY_ROOT=${SNIPPETS_SCRIPT_DIR:h}
cd "$SNIPPETS_REPOSITORY_ROOT"

if ! command -v uvx >/dev/null 2>&1; then
    print -u2 "uvx is required. Install uv from https://docs.astral.sh/uv/."
    exit 1
fi

if ! command -v asc >/dev/null 2>&1; then
    print -u2 "asc is required to validate the generated App Store assets."
    exit 1
fi

for SNIPPETS_FONT in \
    /Library/Fonts/SF-Pro-Display-Semibold.otf \
    /Library/Fonts/SF-Pro-Text-Regular.otf
do
    if [[ ! -f "$SNIPPETS_FONT" ]]; then
        print -u2 "Required font is missing: $SNIPPETS_FONT"
        exit 1
    fi
done

SNIPPETS_CONFIGS=(
    Distribution/AppStore/screenshots/config/iphone-6.9-en-US.yaml
    Distribution/AppStore/screenshots/config/iphone-6.9-ru.yaml
    Distribution/AppStore/screenshots/config/ipad-13-en-US.yaml
    Distribution/AppStore/screenshots/config/ipad-13-ru.yaml
)

for SNIPPETS_CONFIG in $SNIPPETS_CONFIGS; do
    uvx --from koubou==0.18.1 kou generate "$SNIPPETS_CONFIG"
done

asc screenshots validate \
    --path Distribution/AppStore/screenshots/marketing/en-US/iphone-6.9/iPhone_17_Pro_Max_-_Deep_Blue_-_Portrait \
    --device-type IPHONE_69

asc screenshots validate \
    --path Distribution/AppStore/screenshots/marketing/ru/iphone-6.9/iPhone_17_Pro_Max_-_Deep_Blue_-_Portrait \
    --device-type IPHONE_69

asc screenshots validate \
    --path Distribution/AppStore/screenshots/marketing/en-US/ipad-13/iPad_Pro_13_-_M4_-_Space_Gray_-_Portrait \
    --device-type IPAD_PRO_3GEN_129

asc screenshots validate \
    --path Distribution/AppStore/screenshots/marketing/ru/ipad-13/iPad_Pro_13_-_M4_-_Space_Gray_-_Portrait \
    --device-type IPAD_PRO_3GEN_129

print "Generated and validated 12 App Store screenshots."
