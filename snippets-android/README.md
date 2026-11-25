# Snippets for Android

Pure-Kotlin rebuild of the Android app. Self-contained Gradle project; it does not use the
old Android build in the repository root. The plan is in `docs/PLAN.md`.

## Modules

- `:core` (`core/`): Kotlin/JVM library, package `com.khm.snippets.core`, JVM target 17.
  Model, codecs, crypto, sync. No Android dependency, but it runs on Android, so main
  code may only use JDK APIs that exist on Android API 28. Animal Sniffer enforces that:
  `./gradlew :core:animalsnifferMain` (also part of `:core:check`). Tests are not checked.
- `:app` (`app/`): Android app, Compose + Material 3, namespace `com.khm.snippets.android`.
  Debug builds install as `com.khm.snippets.android.debug`, next to the old app.
  minSdk 28, compileSdk and targetSdk 36.

Versions are in `gradle/libs.versions.toml`. Some libraries are held one release back
because their newer releases require compileSdk 37; the catalog says which.

## Build and test

Run everything from `snippets-android/` with JDK 17:

```sh
export JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home

./gradlew :core:test :app:testDebugUnitTest :app:assembleDebug
./gradlew :app:assembleRelease        # R8, unsigned
scripts/check.sh                      # the tests above, the API 28 check and lint
```

`local.properties` (git-ignored) must hold `sdk.dir=` followed by your Android SDK path
(usually `$HOME/Library/Android/sdk`), unless `ANDROID_HOME` is set.

## Devices

Use the emulator `emulator-5554` only. It is shared: do not wipe or reboot it, change its
settings, or uninstall anything you did not install. Never target the attached phone:
always pass `-s emulator-5554` to adb and set `ANDROID_SERIAL=emulator-5554` for Gradle.

```sh
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

$ADB -s emulator-5554 install -r app/build/outputs/apk/debug/app-debug.apk
$ADB -s emulator-5554 shell am start -W -n com.khm.snippets.android.debug/com.khm.snippets.android.MainActivity

ANDROID_SERIAL=emulator-5554 ./gradlew :app:connectedDebugAndroidTest
```

`connectedDebugAndroidTest` uninstalls the debug app when it finishes, which also deletes
its data. Install it again afterwards if you need it on the emulator.
