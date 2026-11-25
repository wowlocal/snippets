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

Use the dedicated emulator `emulator-5556` (AVD `snippets-api35`, API 35, 192 MB app heap) and
nothing else. Start it when it is not running:

```sh
"$HOME/Library/Android/sdk/emulator/emulator" -avd snippets-api35 -port 5556 -no-window -no-audio -no-boot-anim &
```

It is a tablet image. For phone layouts it is set to `wm size 1080x2400` and `wm density 420`;
`wm size reset` and `wm density reset` give the 2560x1600 tablet. Put it back to the phone size
when you finish. `emulator-5554` belongs to other projects and the attached phone is personal:
never target either. Always pass `-s emulator-5556` to adb and set `ANDROID_SERIAL=emulator-5556`
for Gradle.

```sh
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

$ADB -s emulator-5556 install -r app/build/outputs/apk/debug/app-debug.apk
$ADB -s emulator-5556 shell am start -W -n com.khm.snippets.android.debug/com.khm.snippets.android.MainActivity

ANDROID_SERIAL=emulator-5556 ./gradlew :app:connectedDebugAndroidTest
```

`connectedDebugAndroidTest` uninstalls the debug app when it finishes, which also deletes
its data. Install it again afterwards if you need it on the emulator.
