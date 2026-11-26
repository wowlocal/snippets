#!/bin/sh
# Cross-check: files written by the Kotlin vault and backup code, judged by the Swift readers.
#
#   tools/swift-interop/checks/vault-backup.sh            # from snippets-android/
#   tools/swift-interop/checks/vault-backup.sh --no-gradle   # reuse the files already in core/build/interop
#
# 1. Runs the Kotlin test `SwiftInteropArtifactsTest`, which writes `vault.json` files,
#    a `snippets.json` and encrypted backups (with and without a vault) to
#    core/build/interop/vault-backup/, plus expected.json: for each file, the
#    `swift-interop check` arguments and the values Swift must report.
# 2. Builds the Swift interop tool (unmodified Swift sources) and runs
#    `check vault-document`, `check backup` and `check library-json` on those files:
#    VaultFile.decode / encode and SnippetCrypto.open for every record,
#    EncryptedSnippetBackup.open, SnippetLibraryCodec.decode.
# 3. Compares every expected value with what Swift printed.
#
# Exit status 0 only when every value agrees. Needs JDK 17, `xcrun swift` and python3.
# All keys, codes and passwords involved are fictional public test data.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
tool=$(cd "$here/.." && pwd)
android=$(cd "$tool/../.." && pwd)
artifacts="$android/core/build/interop/vault-backup"

run_gradle=1
for argument in "$@"; do
    case "$argument" in
        --no-gradle) run_gradle=0 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

if [ "$run_gradle" -eq 1 ]; then
    : "${JAVA_HOME:=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
    export JAVA_HOME
    # cleanTest makes the test task run again without recompiling anything.
    (cd "$android" && ./gradlew -q :core:cleanTest :core:test --tests 'com.khm.snippets.core.backup.SwiftInteropArtifactsTest')
fi
[ -f "$artifacts/expected.json" ] || { echo "no artifacts in $artifacts; run without --no-gradle" >&2; exit 2; }

# Debug configuration on purpose: the tool uses `@testable import`.
xcrun swift build --package-path "$tool" --configuration debug >/dev/null
binary="$tool/.build/debug/swift-interop"

python3 -I - "$binary" "$artifacts" <<'PYTHON'
import json
import subprocess
import sys

binary, artifacts = sys.argv[1], sys.argv[2]
with open(artifacts + "/expected.json", encoding="utf-8") as handle:
    expectations = json.load(handle)

failures = 0
for item in expectations:
    command = [binary, "check", item["kind"], *item["arguments"], artifacts + "/" + item["file"]]
    result = subprocess.run(command, capture_output=True, text=True)
    label = item["kind"] + " " + item["file"] + (" " + " ".join(a for a in item["arguments"] if a.startswith("--")) if item["arguments"] else "")
    try:
        reported = json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, ValueError):
        print("FAIL  " + label + ": no JSON from the Swift tool (exit " + str(result.returncode) + ") " + result.stderr.strip())
        failures += 1
        continue
    expected = dict(item["expect"])
    expected.setdefault("ok", True)
    wrong = {key: (value, reported.get(key, "<absent>")) for key, value in expected.items() if reported.get(key, "<absent>") != value}
    if wrong:
        failures += 1
        print("FAIL  " + label)
        for key, (want, got) in wrong.items():
            print("        " + key + ": Kotlin expects " + json.dumps(want) + ", Swift reports " + json.dumps(got))
        if not reported.get("ok", False):
            print("        Swift error: " + str(reported.get("error")) + " " + str(reported.get("detail", "")))
    else:
        checked = ", ".join(sorted(expected))
        print("ok    " + label + "  [" + checked + "]")

print(("%d of %d checks failed" % (failures, len(expectations))) if failures else ("all %d checks passed" % len(expectations)))
sys.exit(1 if failures else 0)
PYTHON
