# Testing native Snippets Cloud sign-in

The Apple apps use a native account-key sheet (server
[ADR 0006](../server/ADR/0006-generated-account-key-authentication.md)): **Create
Account** or **Sign In with Account Key**. There is no email, code, or mailbox. The
opt-in iOS UI test exercises the real server and Keychain on both iPhone and iPad. It
checks that the choice opens before networking, that cancelling shows no error, that a
locally mistyped key is rejected inline without a request, that **Create Account**
shows **Save Your Account Key** with no way out except **I’ve Saved It**, the short
Account ID and **Show account key** on the signed-in page, signing in again with the
displayed key through **Change account**, and the explicit provider-switch
confirmation after each grant. It asserts that no WebView appears and cancels both
provider switches, so it does not upload a snippet library.

### Device-approved sign-in (ADR 0007)

A signed-out device can also choose **Sign In with Another Device** (shown only when
discovery advertises `native-device-sign-in-v1`). It shows a QR code, copyable request
text and a confirmation code, and polls until an already-approved device scans or pastes
the request, compares the code, and approves with device-owner authentication. The
in-process unit tests in `snippets-ios-tests/SnippetsCloudDeviceSignInTests.swift` and
`Tests/Core/DeviceSignInCodecTests.swift` cover the payload codec, claim shapes, polling
back-off, keyless session commit, approved-library selection, pairing reuse after an
interrupted approval, and the retried request binding. A real two-device run needs a
second signed-in simulator or Mac holding the library; the opt-in UI test below does not
yet drive that second device. For a manual check, sign in on device A, then on device B
choose Sign In with Another Device; on A use **Scan a New Device Invitation** (iPhone/iPad)
or paste the copied request text (Mac), confirm both show the same code, approve, and
check that B reaches the provider-switch confirmation without typing a key, and that
B's **Show account key** explains that the key lives on another device.

## Isolation and prerequisites

- Use a disposable server with `AUTH_MODE=native` and migrations applied. No SMTP
  or mailbox is involved. See [server setup](../server/README.md) and the
  [integration gateway](../scripts/test-native-cloud-integration.md). Account
  creation is rate limited per source IP (10 per hour), so repeated runs from one
  host may need a fresh server or a wait.
- Pin that server's HTTPS origin in the app. The examples read the current origin
  from the ignored `build/cloud-test/origin` file. A changed tunnel origin requires
  rebuilding the app; changing only the test-runner environment cannot change it.
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
tests, but can make this real sign-in flow fail before account creation with unreadable
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

The opt-in flag belongs to the **UI test runner**. Set it in the generated
`.xctestrun` file; exporting it in a terminal alone does not reliably pass it
through Xcode. Keep the copied manifest beside the original so its
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
    })
(products / 'Snippets NativeAuthE2E.xctestrun').write_bytes(plistlib.dumps(manifest))
print('Enabled native UI integration in the test runner.')
PY
```

This test's `SNIPPETS_NATIVE_AUTH_E2E` flag is separate from the
`SNIPPETS_CLOUD_E2E` app integration harness used for cross-platform sync.

## Run iPhone, then iPad

Boot and test one simulator at a time. Each run creates one disposable account. The
UI test reads the generated key from the save screen into memory and types it back
to sign in; it never writes the key to a fixture or file, and it does not print it.

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
credentials and defaults separate from installed apps. Verify the account choice
sheet, cancel, a locally mistyped key, a rejected key, **Create Account** and its
**Save Your Account Key** step (Copy clears after two minutes; **I’ve Saved It** is
the only way forward), **Show Account Key…** behind Touch ID or the Mac password,
the provider-switch confirmation, relaunch, refresh, and disconnect (its
confirmation reminds you that the account key is needed to sign in again) using only
disposable records. Do not manually
re-sign an archived distribution app; follow the repository signing guidance.

A physical iPhone requires a separately provisioned test bundle and isolated Keychain
access group. Discover device identifiers at installation time. The simulator result
does not verify real-device password-manager AutoFill of the key, keychain protection after locking, or
Face ID/Touch ID interactions with the vault. Those hardware checks, including the
Mac Touch ID path, must be recorded separately and must preserve the user's library.

## Verification snapshot — 2026-10-03 (account keys and device-approved sign-in)

| Check | Result |
| --- | --- |
| Core Swift tests (Core, Pasteboard, AX), including ADR 0006 key vectors and ADR 0007 codec | 935 + 81 + 22 Swift Testing and 28 XCTest, 0 failures |
| macOS Debug build and macOS test target build-for-testing | Passed |
| Generic iOS Simulator Debug build | Passed |
| Full iPhone 17 Pro (iOS 26.5) unit / UI suites | 544 tests, 1 skipped, 0 failures / 13 tests, 6 skipped, 0 failures |
| Full iPad Pro 11-inch M4 (iOS 26.5) unit / UI suites | 544 tests, 1 skipped, 0 failures / 13 tests, 7 skipped, 0 failures |
| Opt-in real-server account-key UI test | Not run (needs a disposable server); compiles and skips by default |
| Real two-device ADR 0007 approval | Not run; covered by in-process unit tests only |

`swift test --package-path CorePackage` itself currently stops at an unrelated
`SnippetsSecureEditor` compile error (`EditorInputSurface` is defined outside the
overlay); the Core, Pasteboard, and AX targets above were run from an equivalent
overlay that omits only that target.

## Historical verification snapshot — 2026-09-06 (email-code flow)

This snapshot predates ADR 0006 and records the superseded email/code sign-in. It is
kept for its sync, recovery, and disconnect coverage; its email/SMTP rows no longer
describe the shipping flow. The final native sync run rebuilt both Apple artifacts after the disconnect-test
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
disposable account key, which the UI test displays and types. Do not print account
keys, tokens, snippet bodies, library keys, or physical device identifiers when
reporting results. Share aggregate
counts and sanitized failures. The test creates disposable server-side account/setup
state; it does not reset the server or delete other accounts.
