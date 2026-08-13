#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_package="$repo_root/AndroidCorePackage"
swift_java="$swift_package/.build/checkouts/swift-java"

: "${JAVA_HOME:=/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export JAVA_HOME

command -v swiftly >/dev/null 2>&1 || {
    echo "swiftly is required; install it from https://www.swift.org/swiftly/" >&2
    exit 1
}

swiftly run swift package --package-path "$swift_package" resolve

if [ ! -x "$swift_java/gradlew" ]; then
    echo "swift-java 0.5.1 was not resolved at $swift_java" >&2
    exit 1
fi

(cd "$swift_java" && ./gradlew :SwiftKitCore:publishToMavenLocal \
    -PswiftkitVersion=0.5.1 --no-daemon)

echo "Android Swift/Java runtime is ready."
