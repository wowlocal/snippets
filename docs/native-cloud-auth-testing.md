# Testing native Snippets Cloud sign-in

The Apple apps use native email and six-digit code screens. The opt-in iOS UI test
exercises the real server and Keychain on both iPhone and iPad. It checks opening
the form before networking, cancelling without an error, code delivery, an incorrect
code, a successful retry, and the explicit provider-switch confirmation. It asserts
that no WebView appears and cancels the provider switch, so it does not upload a
snippet library.

## Isolation and prerequisites

- Use a disposable server with `AUTH_MODE=native`, migrations applied, and SMTP
  delivering only to a local Mailpit instance. See [server setup](../server/README.md)
  and the [integration gateway](../scripts/test-native-cloud-integration.md).
- Pin that server's HTTPS origin in the app. The examples read the current origin
  from the ignored `build/cloud-test/origin` file. A changed tunnel origin requires
  rebuilding the app; changing only the test-runner environment cannot change it.
- Keep Mailpit's HTTP API on loopback, for example `http://127.0.0.1:8027`.
  The UI test refuses a mailbox host other than `localhost` or `127.0.0.1`.
- Create disposable simulators. `--ui-testing-reset` redirects library storage to
  a temporary directory and disables sync, but **does not isolate the cloud
  Keychain**. Do not run this test against an existing physical phone installation
  or a simulator containing an account or library that matters.
- Run iOS XCTest jobs serially. Concurrent runners caused SpringBoard/FBS preflight
  failures and keyboard timeouts during this verification. Shut down only the
  disposable simulator owned by the current run; do not reset CoreSimulator globally.

Run commands below from the repository root on an Apple Silicon Mac with an installed
iOS Simulator runtime. Keep the shell open so its task-specific variables persist.

```sh
umask 077
mkdir -p build/cloud-test
export NATIVE_AUTH_DERIVED=/tmp/snippets-native-e2e-derived
export NATIVE_AUTH_RUN_DIR="$(mktemp -d "$PWD/build/cloud-test/native-ui.XXXXXX")"
export NATIVE_AUTH_ORIGIN="$(cat build/cloud-test/origin)"
xcrun simctl list runtimes available
xcrun simctl list devicetypes
```

Use runtime and device-type identifiers discovered above, without copying an existing
device UUID. Create one phone and one tablet:

```sh
export NATIVE_AUTH_IPHONE_ID="$(xcrun simctl create 'Snippets Native Auth Test iPhone' '<iPhone-device-type-id>' '<iOS-runtime-id>')"
export NATIVE_AUTH_IPAD_ID="$(xcrun simctl create 'Snippets Native Auth Test iPad' '<iPad-device-type-id>' '<iOS-runtime-id>')"
```

## Build and verify the artifact

Real simulator Keychain access needs ad hoc signing and the simulator's application
and Keychain entitlements. `CODE_SIGNING_ALLOWED=NO` is suitable for in-memory unit
tests, but can make this real sign-in flow fail before email entry with unreadable
credential/setup state.

```sh
xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$NATIVE_AUTH_DERIVED" \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- \
  SNIPPETS_CLOUD_ENABLED=YES \
  SNIPPETS_CLOUD_BASE_URL="$NATIVE_AUTH_ORIGIN" \
  build-for-testing > "$NATIVE_AUTH_RUN_DIR/build.log" 2>&1

codesign --verify --deep --strict \
  "$NATIVE_AUTH_DERIVED/Build/Products/Debug-iphonesimulator/Snippets.app"
```

Inspect the artifact, not just the project settings. The following validates the
feature flag, URL pin, and actual arm64 Mach-O `__TEXT,__entitlements` section.
Simulator entitlements can be present there while `codesign -d --entitlements :-`
prints an empty signature entitlement dictionary. Physical devices require their
normal signed entitlements and a matching provisioning profile instead.

```sh
python3 - <<'PY'
import os, pathlib, plistlib, re, subprocess
products = pathlib.Path(os.environ['NATIVE_AUTH_DERIVED']) / 'Build/Products'
app = products / 'Debug-iphonesimulator/Snippets.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
assert str(info['SnippetsCloudEnabled']).lower() in ('yes', 'true', '1')
assert info['SnippetsCloudBaseURL'] == os.environ['NATIVE_AUTH_ORIGIN']
dump = subprocess.check_output([
    'xcrun', 'otool', '-arch', 'arm64', '-s', '__TEXT', '__entitlements',
    str(app / info['CFBundleExecutable'])
], text=True)
words = []
for line in dump.splitlines():
    pieces = line.split()
    if pieces and re.fullmatch(r'[0-9a-fA-F]{16}', pieces[0]):
        words.extend(p for p in pieces[1:] if re.fullmatch(r'[0-9a-fA-F]{2,8}', p))
raw = b''.join(bytes.fromhex(word)[::-1] for word in words).rstrip(b'\0')
entitlements = plistlib.loads(raw)
assert entitlements['application-identifier'].endswith('.' + info['CFBundleIdentifier'])
assert entitlements['keychain-access-groups']
print('Validated cloud configuration and simulator Keychain entitlements.')
PY
```

## Enable the real UI test in the runner

The opt-in flags belong to the **UI test runner**, which polls Mailpit. Set them in
the generated `.xctestrun` file; exporting them in a terminal alone does not reliably
pass them through Xcode. Keep the copied manifest beside the original so its
`__TESTROOT__` and `__TESTHOST__` paths still resolve. This helper supports both Xcode
manifest layouts and does not modify the shipping app configuration.

```sh
python3 - <<'PY'
import os, pathlib, plistlib
products = pathlib.Path(os.environ['NATIVE_AUTH_DERIVED']) / 'Build/Products'
sources = list(products.glob('Snippets iOS_*.xctestrun'))
assert len(sources) == 1, 'Use a dedicated derived-data directory for this build.'
manifest = plistlib.loads(sources[0].read_bytes())
targets = []
if 'TestConfigurations' in manifest:
    for configuration in manifest['TestConfigurations']:
        targets.extend(configuration.get('TestTargets', []))
else:
    targets = [value for key, value in manifest.items()
               if key != '__xctestrun_metadata__' and isinstance(value, dict)]
selected = [target for target in targets if target.get('IsUITestBundle')]
assert selected, 'UI test runner missing from the build-for-testing artifact.'
for target in selected:
    target.setdefault('EnvironmentVariables', {}).update({
        'SNIPPETS_NATIVE_AUTH_E2E': '1',
        'SNIPPETS_NATIVE_AUTH_MAILBOX': 'http://127.0.0.1:8027',
    })
(products / 'Snippets NativeAuthE2E.xctestrun').write_bytes(plistlib.dumps(manifest))
print('Enabled native UI integration in the test runner.')
PY
```

This test's `SNIPPETS_NATIVE_AUTH_E2E` flag is separate from the
`SNIPPETS_CLOUD_E2E` app integration harness used for cross-platform sync.

## Run iPhone, then iPad

Boot and test one simulator at a time. The UI test generates a unique disposable
`@example.test` address and reads its code from Mailpit without printing it.

```sh
xcrun simctl boot "$NATIVE_AUTH_IPHONE_ID"
xcrun simctl bootstatus "$NATIVE_AUTH_IPHONE_ID" -b
xcodebuild \
  -xctestrun "$NATIVE_AUTH_DERIVED/Build/Products/Snippets NativeAuthE2E.xctestrun" \
  -destination "platform=iOS Simulator,id=$NATIVE_AUTH_IPHONE_ID" \
  -parallel-testing-enabled NO \
  -only-testing:'Snippets iOSUITests/SnippetsCloudNativeAuthUITests' \
  -resultBundlePath "$NATIVE_AUTH_RUN_DIR/iphone.xcresult" \
  test-without-building > "$NATIVE_AUTH_RUN_DIR/iphone.log" 2>&1
xcrun simctl shutdown "$NATIVE_AUTH_IPHONE_ID"

xcrun simctl boot "$NATIVE_AUTH_IPAD_ID"
xcrun simctl bootstatus "$NATIVE_AUTH_IPAD_ID" -b
xcodebuild \
  -xctestrun "$NATIVE_AUTH_DERIVED/Build/Products/Snippets NativeAuthE2E.xctestrun" \
  -destination "platform=iOS Simulator,id=$NATIVE_AUTH_IPAD_ID" \
  -parallel-testing-enabled NO \
  -only-testing:'Snippets iOSUITests/SnippetsCloudNativeAuthUITests' \
  -resultBundlePath "$NATIVE_AUTH_RUN_DIR/ipad.xcresult" \
  test-without-building > "$NATIVE_AUTH_RUN_DIR/ipad.log" 2>&1
xcrun simctl shutdown "$NATIVE_AUTH_IPAD_ID"
```

Each `xcodebuild` must exit zero and report `TEST EXECUTE SUCCEEDED`; a build-only
success does not establish that the sign-in test ran. Result bundle paths must be new
for each attempt. If a run fails, inspect its private log before proceeding to the
next platform. After inspection, remove only these disposable devices:

```sh
xcrun simctl delete "$NATIVE_AUTH_IPHONE_ID"
xcrun simctl delete "$NATIVE_AUTH_IPAD_ID"
```

Ordinary full iPhone/iPad unit and smoke suites remain required as described in
[repository guidance](../AGENTS.md). Run them without this custom manifest; the
networked UI test intentionally skips when its opt-in environment is absent.
The [native cloud integration harness](../scripts/test-native-cloud-integration.md)
separately exercises actual encrypted sync across Mac, iPhone, iPad, and Android.

## Mac and real hardware

For manual Mac checks, use an isolated test bundle and `SNIPPETS_SUPPORT_DIR`, with
credentials and defaults separate from installed apps. Verify email/code layout,
cancel, incorrect code, successful sign-in, the provider-switch confirmation,
relaunch, refresh, and disconnect using only disposable records. Do not manually
re-sign an archived distribution app; follow the repository signing guidance.

A physical iPhone requires a separately provisioned test bundle and isolated Keychain
access group. Discover device identifiers at installation time. The simulator result
does not verify real-device email AutoFill, keychain protection after locking, or
Face ID/Touch ID interactions with the vault. Those hardware checks, including the
Mac Touch ID path, must be recorded separately and must preserve the user's library.

## Verification snapshot — 2026-09-06

The final native sync run rebuilt both Apple artifacts after the disconnect-test
injection seam and server revocation/proxy hardening. Earlier full-suite counts
remain separate from that final targeted coverage and include intentional skips.

| Check | Result |
| --- | --- |
| Full iPhone unit suite | 500 tests, 1 skipped, 0 failures |
| Full iPhone UI suite | 13 tests, 6 skipped, 0 failures |
| Full iPad unit suite | 500 tests, 1 skipped, 0 failures |
| Full iPad UI suite | 13 tests, 7 skipped, 0 failures |
| Native UI state and Swift client checkpoint | 20 tests, 0 failures |
| Signed iPhone simulator native GUI sign-in | Passed, 40.050 seconds |
| Signed iPad simulator native GUI sign-in | Passed, 40.500 seconds |
| Mac isolated app manual sign-in, sync, relaunch, refresh | Passed |
| Final vault isolation and bridge regressions | iPhone 30/30; iPad 30/30 passed |
| Final native disconnect and Keychain regression | 46/46 passed (14 native auth, 32 Keychain); logout and durable retry exercised through bootstrap + selection |
| macOS Debug build after disconnect injection seam | Passed |
| Generic iOS Simulator Debug build after disconnect injection seam | Passed |
| Native HTTPS encrypted sync across Mac, iPhone/iPad simulators, Android emulator | 15/15 app phases passed (Mac 4, iPhone 4, iPad 2, Android 5) |
| Native sync failure recovery and consistency | Lost acknowledgement, truncated page, stale cursor, CAS conflict passed; final 2 live records + 1 tombstone |
| Native sync authentication and cleanup | SMTP/email verification, refresh rotation, old-refresh family logout, post-logout denial passed |
| Native server auth hardening | Go race tests/vet and PostgreSQL regression suite passed, including expiry/revocation and trusted-proxy boundaries |
| Physical iPhone and hardware biometrics | Pending separate hardware verification |

Successful local artifacts are under ignored `build/cloud-test/`:
`native-iphone-full-tests`, `native-ipad-full-tests`,
`native-ui-focus-isolated-final`, `native-disconnect-passed`,
`native-iphone-e2e-signed`, and `native-ipad-e2e-signed` (`.log` and `.xcresult`).
The cross-platform aggregate report
is `native-sync-result.json`; `native-sync-pipeline.log` records phase names and the
private temporary directory containing each phase log/result bundle. Bearer fixtures
are removed after successful family revocation. The server smoke report is
`native-e2e-result.json`; server hardening logs are `native-server-unit-final.log`
and `native-server-integration-final.log`. The final platform build logs are
`native-disconnect-macos-build.log` and `native-disconnect-ios-build.log`.

Keep these artifacts private: XCTest screenshots and action logs can contain the
disposable email and typed code. Do not print mailbox bodies, codes, tokens, snippet
bodies, keys, or physical device identifiers when reporting results. Share aggregate
counts and sanitized failures. The test creates disposable server-side account/setup
state; it does not reset the server or delete other accounts.
