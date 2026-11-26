#!/bin/sh
# The Kotlin merge layer against the shipping Swift merge.
#
#   tools/swift-interop/checks/merge-differential/run.sh [--refresh-sample] [<work dir>]
#
# 1. builds this tool (`xcrun swift`, debug: `@testable import` needs -enable-testing),
# 2. has Kotlin generate the inputs (MergeDifferentialTest, MERGE_DIFFERENTIAL_DIR),
# 3. runs the Swift merge over them,
# 4. has Kotlin compare, write report.txt and sample.json, and fail on a disagreement.
#
# --refresh-sample copies the new sample.json over
# core/src/test/resources/fixtures/merge/differential-sample.json.
# MERGE_DIFFERENTIAL_SEED and MERGE_DIFFERENTIAL_COUNT (default 6000 triples) pass through.
# Nothing touches the user's support folder: the engines of the "converge" section get
# temporary directories, and SNIPPETS_SUPPORT_DIR points into the work directory.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
android=$(cd "$here/../../../.." && pwd)
refresh=0
if [ "${1:-}" = "--refresh-sample" ]; then refresh=1; shift; fi
work=${1:-$(mktemp -d "${TMPDIR:-/tmp}/merge-differential.XXXXXX")}
mkdir -p "$work"
rm -f "$work/input.json" "$work/output.json" "$work/report.txt" "$work/sample.json"

: "${JAVA_HOME:=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}"
export JAVA_HOME
export MERGE_DIFFERENTIAL_DIR="$work"

(cd "$here" && xcrun swift build)

gradle_test() {
    (cd "$android" && ./gradlew :core:test --rerun -q \
        --tests 'com.khm.snippets.core.merge.MergeDifferentialTest.liveRunAgainstSwift')
}

gradle_test
test -s "$work/input.json"
SNIPPETS_SUPPORT_DIR="$work/support" "$here/.build/debug/merge-differential" "$work/input.json" "$work/output.json"
status=0
gradle_test || status=$?
cat "$work/report.txt"
if [ "$refresh" = 1 ] && [ "$status" = 0 ]; then
    cp "$work/sample.json" "$android/core/src/test/resources/fixtures/merge/differential-sample.json"
    echo "sample refreshed"
fi
echo "work directory: $work"
exit "$status"
