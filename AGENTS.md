# Snippets repository guidance

These instructions apply to the whole repository.

## Product and target layout

- `Snippets` is the native AppKit macOS app. Its deployment target is macOS 15.5.
  Debug uses `com.khm.snippets.debug`; Release uses `com.khm.snippets`.
- `Snippets iPad` is the native UIKit, iPad-only app in `snippets-ipad/`. Its deployment
  target is iPadOS 26.0 and `TARGETED_DEVICE_FAMILY` is `2`. It is not Catalyst and it
  is not a SwiftUI wrapper around the Mac app. Debug uses `com.khm.snippets.debug`;
  Release uses `com.khm.snippets`.
- `snippets-ipad-tests/` contains the iPad unit tests and `snippets-ipad-uitests/`
  contains the UI smoke test. The shared scheme is `Snippets iPad`.
- Shared model, persistence, merge, sync, and vault code lives under `snippets/Core/`,
  `snippets/Sync/`, `snippets/Vault/`, and `snippets/SnippetStore.swift`. Keep shared
  files free of unconditional AppKit or macOS-only APIs. Gate unavoidable differences
  with `#if os(macOS)` / `#if os(iOS)` and keep UI code in the platform target.
- CloudKit implementation files remain app-target code. Do not move CloudKit imports
  into `snippets/Core/`: that core also builds in `CorePackage` and in the entitlement-free
  `snippets-cli` executable.
- `SnippetStore(configuration: .iPad)` intentionally starts with an empty library and
  does not run the Mac app's external-filesystem observer. Do not seed sample content on
  iPad; a fresh install must be able to fetch the remote library without looking like it
  authored a local record.
- Both apps use `SnippetStorageLocations`. On macOS the normal root is
  `~/Library/Application Support/SnippetsClone`; on iPad it is the same relative path
  inside the app data container. `SNIPPETS_SUPPORT_DIR` is a test-only override. Never
  point tests at the user's live support directory.

`docs/cloud-sync.md` still contains valuable protocol and safety rationale, but its
phase/status table predates the CloudKit transport and iPad target. The code is now the
authority for implementation status: CloudKit sync and the iPad app are implemented.

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
  -scheme 'Snippets iPad' \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/snippets-ipad-derived \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the iPad unit and UI tests on an available iPad simulator:

```sh
xcrun simctl list devices available

xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iPad' \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' \
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
- macOS entitlements live in `snippets/Snippets.entitlements`. iPad entitlements live in
  `snippets-ipad/Snippets-iPad.entitlements`.
- The iPad entitlement explicitly sets
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

For a Production-connected iPad build, the second command must show all of:

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
  Mac and iPad can decrypt the same records. Secure-snippet bodies remain separately
  sealed under their vault record keys.
- Sync is opt-in. The per-bundle UserDefaults key is `SnippetsICloudSyncEnabled`. With the
  preference absent, no CloudKit transport is created and `Sync/base.json` is absent.
- There is currently no APNs entitlement or CloudKit subscription. Remote changes arrive
  through the two-minute polling interval or an explicit **Sync Now** action.
- A switched iCloud account is a known edge case: the current base does not record the
  CloudKit user record name. Do not claim account-switch handling is complete without
  adding and testing that binding.

### Production versus Development

This distinction is easy to miss and produces a convincing false success:

- An app signed without
  `com.apple.developer.icloud-container-environment = Production` can address the
  Development database.
- The sync engine can then report **Synced** correctly while showing no snippets, because
  the Development database is empty and the Mac release is using Production.
- Always diagnose this by reading the signed app's actual entitlements. Do not infer the
  environment from scheme name, configuration name, container identifier, or UI status.

Do not switch an installed app sandbox from Development to Production while reusing its
`Sync/base.json`: that file can contain a Development change token. The safe recovery is
a fresh Production Release sandbox, followed by a first fetch. Before removing any old
installation, inspect it structurally and confirm it contains no local-only snippets or
vault records. Never reset the Production CloudKit environment as a troubleshooting step.

When diagnosing device data, avoid printing snippet bodies, names, ciphertext, keys, or
stable device identifiers. File sizes and JSON counts are normally enough. Relevant files
inside the app data container are:

```text
Library/Application Support/SnippetsClone/snippets.json
Library/Application Support/SnippetsClone/Sync/base.json
Library/Application Support/SnippetsClone/Sync/state.json
Library/Application Support/SnippetsClone/Vault/vault.json
```

## Installing on a connected iPad

Use a Release build when the goal is to see the same Production library as the Mac app.
A direct device build may still be signed with an Apple Development identity; that is
expected for a registered development device. What matters for sync is the actual
Production CloudKit entitlement and a profile that permits it.

The preferred workflow is the repository script. It discovers both identifiers, performs
an incremental Release build, validates the signed artifact and embedded profile, installs
in place, and launches the app:

```sh
./scripts/install-ipad.sh
```

Use `--device <name>` when more than one paired iPad is available, `--no-build` to reuse
the existing device artifact, or `--no-launch` to install without launching. The script
does not clean derived data, remove an installed app, or delete its data sandbox.

The underlying manual flow is documented below for troubleshooting.

Discover the Xcode destination and CoreDevice identifiers instead of hardcoding them:

```sh
xcodebuild -project Snippets.xcodeproj -scheme 'Snippets iPad' -showdestinations
xcrun devicectl list devices
```

Build, validate, install, and launch:

```sh
xcodebuild \
  -project Snippets.xcodeproj \
  -scheme 'Snippets iPad' \
  -configuration Release \
  -destination 'platform=iOS,id=<XCODE_DEVICE_UDID>' \
  -derivedDataPath /tmp/snippets-ipad-device-derived \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  build

codesign -d --entitlements :- \
  /tmp/snippets-ipad-device-derived/Build/Products/Release-iphoneos/Snippets.app 2>&1

xcrun devicectl device install app \
  --device <COREDEVICE_ID> \
  /tmp/snippets-ipad-device-derived/Build/Products/Release-iphoneos/Snippets.app

xcrun devicectl device process launch \
  --device <COREDEVICE_ID> \
  --terminate-existing \
  com.khm.snippets
```

Debug and Release have different bundle identifiers and data sandboxes but the same
display name. Avoid leaving both installed after a device test: two identical icons make
it easy to open the wrong sandbox. A historical or differently signed Debug build may
also still point at Development even though the current iPad entitlement names
Production. Remove an old build only after resolving its exact bundle identifier and
confirming that its sandbox holds no local-only data.
