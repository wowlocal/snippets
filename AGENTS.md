# Snippets repository guidance

These instructions apply to the whole repository.

## Product and target layout

- `Snippets` is the native AppKit macOS app. Its deployment target is macOS 15.5.
  Debug uses `com.khm.snippets.debug`; Release uses `com.khm.snippets`.
- `Snippets iOS` is the native UIKit universal app in `snippets-ios/`. Its deployment
  target is iOS/iPadOS 26.0 and `TARGETED_DEVICE_FAMILY` is `1,2`. It is not Catalyst
  and it is not a SwiftUI wrapper around the Mac app. iPad keeps the keyboard-oriented
  split-view UI; iPhone uses the touch-first library and editor. Debug uses
  `com.khm.snippets.debug`; Release uses `com.khm.snippets`.
- `snippets-ios-tests/` contains the iOS unit tests and `snippets-ios-uitests/` contains
  the UI smoke tests. The shared scheme is `Snippets iOS`.
- Shared model, persistence, merge, sync, and vault code lives under `snippets/Core/`,
  `snippets/Sync/`, `snippets/Vault/`, and `snippets/SnippetStore.swift`. Keep shared
  files free of unconditional AppKit or macOS-only APIs. Gate unavoidable differences
  with `#if os(macOS)` / `#if os(iOS)` and keep UI code in the platform target.
- CloudKit implementation files remain app-target code. Do not move CloudKit imports
  into `snippets/Core/`: that core also builds in `CorePackage` and in the entitlement-free
  `snippets-cli` executable.
- `SnippetStore(configuration: .iOS)` intentionally starts with an empty library and
  does not run the Mac app's external-filesystem observer. Do not seed sample content on
  iOS; a fresh install must be able to fetch the remote library without looking like it
  authored a local record.
- Both apps use `SnippetStorageLocations`. On macOS the normal root is
  `~/Library/Application Support/SnippetsClone`; on iOS it is the same relative path
  inside the app data container. `SNIPPETS_SUPPORT_DIR` is a test-only override. Never
  point tests at the user's live support directory.

`docs/cloud-sync.md` still contains valuable protocol and safety rationale, but its
phase/status table predates the CloudKit transport and iOS target. The code is now the
authority for implementation status: CloudKit sync and the universal iOS app are implemented.

## Verification commands

Run the checks that cover the layer changed. Before merging cross-platform shared-code
changes, run all of these from the repository root:

```sh
swift test --package-path CorePackage

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme Snippets \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /tmp/snippets-macos-derived \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-ios-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the iOS unit and UI tests on available iPhone and iPad simulators:

```sh
xcrun simctl list devices available

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<IPHONE_SIMULATOR_UDID>' \
  -derivedDataPath /tmp/snippets-iphone-tests-derived \
  CODE_SIGNING_ALLOWED=NO \
  test

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<IPAD_SIMULATOR_UDID>' \
  -derivedDataPath /tmp/snippets-ipad-tests-derived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

The UI test launches with `--ui-testing-reset`; that redirects storage to a temporary
directory and disables sync. Preserve those safeguards in future UI tests.

The iPad MVP has also been smoke-tested on an 11-inch M4 iPad Pro running iPadOS 26.6.
Do not commit a physical device's identifiers; discover them for each installation.

## Signing identities and entitlements

- The Apple development team is `H8QG3CBM96`.
- Both platforms use CloudKit container `iCloud.com.khm.snippets` and keychain access
  group `$(AppIdentifierPrefix)com.khm.snippets`.
- macOS entitlements live in `snippets/Snippets.entitlements`. iOS entitlements live in
  `snippets-ios/Snippets-iOS.entitlements`.
- The iOS entitlement explicitly sets
  `com.apple.developer.icloud-container-environment` to `Production`. Keep it present for
  builds intended to read the user's real library.
- The Mac source entitlement does not name an environment. The supported macOS archive
  and export flow in `Distribution/common.sh` uses `xcodebuild -exportArchive`; that step
  injects the Production environment and embeds the correct Developer ID provisioning
  profile.
- Restricted iCloud and keychain entitlements require a matching provisioning profile.
  `codesign --verify --deep --strict` proves signature integrity but does not prove that
  the embedded profile authorizes the entitlements or contains the signing certificate.
- Do not manually re-sign an archived Mac app. A previous hand-rolled re-sign left an
  Apple Development profile inside a Developer ID-signed bundle; it passed `codesign`
  verification but AMFI killed it at launch. Use the archive/export helpers and retain
  `assert_provisioning_profile` plus the launch check in `Distribution/common.sh`.
- `Distribution/Release` publishes externally and requires a clean worktree and release
  credentials. Run it only when the user explicitly requests a release. Do not expose or
  commit `Distribution/.env`.

Inspect the entitlements of the artifact itself, not only the source plist:

```sh
codesign --verify --deep --strict /path/to/Snippets.app
codesign -d --entitlements :- /path/to/Snippets.app 2>&1
```

For a Production-connected iOS build, the second command must show all of:

- application identifier ending in `com.khm.snippets`;
- `iCloud.com.khm.snippets`;
- `com.apple.developer.icloud-services = CloudKit`;
- `com.apple.developer.icloud-container-environment = Production`;
- keychain group ending in `com.khm.snippets`.

## CloudKit and sync invariants

- `CloudKitTransport` uses the private database, custom zone `SnippetLibrary`, and record
  type `SnippetRecord`. Production schema changes are additive-only. Do not rename,
  remove, or retype the existing `rev`, `deleted`, or `blob` fields after Production has
  records.
- The explicit container identifier is required. `CKContainer.default()` would derive a
  container from the Debug bundle identifier and is not authorized for this app.
- Wire payloads are encrypted before upload. The fixed `SyncKeyStore` account/scope is
  `sync-v1`; its material is stored through the synchronizable shared keychain group so
  Mac and iOS can decrypt the same records. Secure-snippet bodies remain separately
  sealed under their vault record keys.
- Sync is opt-in. The per-bundle UserDefaults key is `SnippetsICloudSyncEnabled`. With the
  preference absent, no CloudKit transport is created and `Sync/base.json` is absent.
- There is currently no APNs entitlement or CloudKit subscription. Remote changes arrive
  through the two-minute polling interval or an explicit **Sync Now** action.
- `Sync/base.json` schema 2 binds every confirmed checkpoint to an opaque hash of the
  explicit container, private-database scope, actual signed CloudKit environment, and
  current `CKContainer.userRecordID()`. The raw user record name is never persisted or
  logged. Resolve that binding before reading local library state or entering the data
  plane, and revalidate it around awaited CloudKit operations.
- A binding mismatch, or a meaningful legacy checkpoint with no binding, must enter the
  sticky account-review halt. The explicit resume path performs the journal-first reset
  that preserves current local intent while discarding old-scope cursors, offers, and CAS
  generations. An unrecognized signed CloudKit environment fails closed; never infer it
  from a scheme, configuration, bundle identifier, or source entitlement file. macOS
  reads the running task's entitlements and iOS device builds inspect the signed Mach-O
  once per transport lifetime. Simulator is the documented exception: its CloudKit
  environment is always Development and CloudKit itself enforces container authorization.

### Production versus Development

This distinction is easy to miss and produces a convincing false success:

- An app signed without
  `com.apple.developer.icloud-container-environment = Production` can address the
  Development database.
- The sync engine can then report **Synced** correctly while showing no snippets, because
  the Development database is empty and the Mac release is using Production.
- Always diagnose this by reading the signed app's actual entitlements. Do not infer the
  environment from scheme name, configuration name, container identifier, or UI status.

Changing an installed app sandbox from Development to Production makes its schema-2
binding mismatch before a Development change token can be used against Production. First
verify the artifact's actual signed entitlements, then use the explicit account-review
resume path; it keeps local intent but clears the old environment's cursor, offers, and CAS
generations. For a legacy unbound base, inspect it structurally before choosing the same
recovery. Before removing any old installation, confirm it contains no local-only snippets
or vault records. Never reset the Production CloudKit environment as a troubleshooting
step.

When diagnosing device data, avoid printing snippet bodies, names, ciphertext, keys, or
stable device identifiers. File sizes and JSON counts are normally enough. Relevant files
inside the app data container are:

```text
Library/Application Support/SnippetsClone/snippets.json
Library/Application Support/SnippetsClone/Sync/base.json
Library/Application Support/SnippetsClone/Sync/state.json
Library/Application Support/SnippetsClone/Vault/vault.json
```

## Persistent diagnostics and logging

The macOS and iOS app targets use CocoaLumberjack 3.9.1 for persistent diagnostics.
Keep that dependency at the app boundary: shared code talks only through the typed,
Foundation-only facade in `snippets/Core/Diagnostics.swift`; the implementation is in
`snippets/Diagnostics/DiagnosticsService.swift`. `CorePackage` and `snippets-cli` must
not import CocoaLumberjack, MetricKit, AppKit, UIKit, or start writing diagnostics. The
facade intentionally does nothing until an app installs a sink.

Use `DiagnosticsService.shared` as the one process-wide production backend. Do not add
another logger graph per store, scene, or `AppEnvironment`; CocoaLumberjack, its OS log
mirror, and MetricKit registration are process-wide. An isolated test may construct a
service with `registerGlobally: false` and `mirrorToOSLog: false`.

Initialization order on macOS is load-bearing. Diagnostics must create `Diagnostics/`
and `Tmp/`, and the usage store must create `Usage/`, before `SnippetStore` installs its
external-filesystem observer. Creating those directories later looks like a library
change. Preserve the declaration order and comment in `AppDelegate`.

Persistent records are structured JSON Lines under:

```text
Library/Application Support/SnippetsClone/Diagnostics/Logs/
```

- Retain at most 14 days, roll at 1 MiB or 24 hours, retain at most 64 log files, and
  cap the directory at 24 MiB. Do not add a second ad-hoc persistent log.
- Keep directories mode `0700` and files mode `0600`, exclude `Diagnostics/` from
  backup, and preserve iOS's `completeUntilFirstUserAuthentication` file protection.
- Safe structured records are also mirrored to unified OS logging. Do not bypass the
  typed facade to send a richer or less-sanitized version to `OSLog`.
- Records use schema version 1 and a closed top-level shape: timestamp, session ID,
  monotonic elapsed time, sequence, level, category, event, and typed event fields.

### Logging privacy contract

Diagnostics files and exports are plaintext and may be handed to an engineer. Every
field therefore has to be safe at the point where `Diagnostics.record` is called.

- By explicit product decision, a secure-snippet **keyword is not private** and may be
  logged. It must still enter through `DiagnosticKeyword`, which applies
  `Snippet.sanitizedKeyword` and bounds the result to 256 UTF-8 bytes. Do not pass the
  keyword through a generic string field.
- Never log snippet bodies, display names, tags, clipboard contents, ciphertext, keys,
  recovery material, record UUIDs, CloudKit record names, filesystem paths, caller
  paths or PIDs, stable device identifiers, or stable hashes derived from them.
- Never persist `localizedDescription`, `String(describing:)` of an error,
  `NSError.userInfo`, reflected values, or arbitrary exception text. Convert errors to
  `DiagnosticFailure`, which retains only an allow-listed family and numeric code.
- Prefer closed enums, booleans, bounded counts, durations, and aggregate outcomes. Do
  not add generic `message`, metadata dictionary, raw JSON, `[String: Any]`, or other
  escape hatch to `DiagnosticEvent`.
- Aggregate batch and per-record failures before logging. Record counts and the first
  sanitized failure when useful; do not emit one event per snippet or include an ID to
  correlate it later.
- MetricKit payloads must stay behind the existing allow-list sanitizer and its size,
  depth, and node limits. Never persist MetricKit's raw JSON or binary names.

### Adding or changing a diagnostic event

Treat the event vocabulary and export validator as one schema. A new event is incomplete
until all of these are done:

1. Add a closed `DiagnosticEvent` case and any narrowly typed supporting enums or value
   types in `snippets/Core/Diagnostics.swift`. Reuse an existing category where it fits.
2. Give it an exact event name, category, default level, bounded field mapping, and only
   if justified, synchronous-write policy. Ordinary and high-frequency events should
   remain asynchronous; reserve synchronous persistence for terminal or high-risk facts
   such as storage/CloudKit failures, halted sync, secure reveal, and MetricKit reports.
3. Add the exact category and required/optional field set to
   `DiagnosticsService.exportEventSchemas`, and update the string, boolean, and numeric
   field allow-lists. Export must fail closed when an unexpected event, field, or type is
   encountered.
4. Instrument the owning boundary once. Avoid duplicate start/end events and avoid hot
   loop logging; prefer a single outcome with duration and aggregate counts.
5. Add privacy/schema tests in `Tests/Core/DiagnosticsTests.swift` and backend tests in
   `snippets-ios-tests/SnippetsIOSTests.swift`. Cover rotation/retention or export when
   changing those mechanisms. Run the CorePackage test and both platform builds from the
   verification section for cross-platform shared changes.
6. Update `docs/diagnostics.md` and Settings privacy copy if retention, exported fields,
   or the approved-data boundary changes.

Do not guess the CloudKit environment for diagnostics. macOS reads the entitlement from
the running signed process. The public iOS SDK cannot do that, so iPhone and iPad device
logs use `unrecognized` and simulator logs use `absent`. Inspect the built app's actual
signed entitlements when diagnosing an iOS environment mismatch.

### Export, collection, and deletion

Use **Settings → Diagnostics → Export Logs** when possible. It creates one portable
JSONL file, prepends a `diagnostics_manifest`, validates the exact schema and field
types, rejects non-regular or linked inputs, and enforces a 25 MiB export limit. Only a
torn final line may be skipped. Preserve the plaintext warning,
including that secure-snippet keywords can be present.

For engineering collection without opening Settings, use:

```sh
./scripts/collect-diagnostics.sh --mac
./scripts/collect-diagnostics.sh --ios --device "My iPhone"
```

Use `--debug` only for the separate Debug iOS bundle. The script copies retained raw
files and must not remove the app, container, or user data; the validated UI export is
preferred for normal sharing. **Delete Logs** must continue deleting retained logs and
an old `Vault/audit.json` if its privacy-preserving migration failed. Legacy audit
migration may retain only timestamp, outcome, and the approved keyword; it must discard
caller paths and PIDs. More operational detail lives in `docs/diagnostics.md`.

## Installing on a connected iPhone or iPad

Use a Release build when the goal is to see the same Production library as the Mac app.
A direct device build may still be signed with an Apple Development identity; that is
expected for a registered development device. What matters for sync is the actual
Production CloudKit entitlement and a profile that permits it.

The preferred workflow is the repository script. It discovers both identifiers, performs
an incremental Release build, validates the signed artifact and embedded profile, installs
in place, and launches the app:

```sh
./scripts/install-ios.sh
```

Use `--device <name>` when more than one paired iOS device is available, `--no-build` to reuse
the existing device artifact, or `--no-launch` to install without launching. The script
does not clean derived data, remove an installed app, or delete its data sandbox.

The underlying manual flow is documented below for troubleshooting.

Discover the Xcode destination and CoreDevice identifiers instead of hardcoding them:

```sh
xcodebuild -project Snippets.xcodeproj -scheme 'Snippets iOS' -showdestinations
xcrun devicectl list devices
```

Build, validate, install, and launch:

```sh
xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iOS' \
  -configuration Release \
  -destination 'platform=iOS,id=<XCODE_DEVICE_UDID>' \
  -derivedDataPath /tmp/snippets-ios-device-derived \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

codesign -d --entitlements :- \
  /tmp/snippets-ios-device-derived/Build/Products/Release-iphoneos/Snippets.app 2>&1

xcrun devicectl device install app \
  --device <COREDEVICE_ID> \
  /tmp/snippets-ios-device-derived/Build/Products/Release-iphoneos/Snippets.app

xcrun devicectl device process launch \
  --device <COREDEVICE_ID> \
  --terminate-existing \
  com.khm.snippets
```

Debug and Release have different bundle identifiers and data sandboxes but the same
display name. Avoid leaving both installed after a device test: two identical icons make
it easy to open the wrong sandbox. A historical or differently signed Debug build may
also still point at Development even though the current iOS entitlement names
Production. Remove an old build only after resolving its exact bundle identifier and
confirming that its sandbox holds no local-only data.
