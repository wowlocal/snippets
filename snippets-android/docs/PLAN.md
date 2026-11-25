# Snippets Android rebuild: working plan

Orchestrator's running plan. Updated as waves finish.

## Decisions

- Pure Kotlin. No Swift core, no JNI. The Swift sources under `snippets/Core`, `snippets/Sync`,
  `snippets/Vault`, `snippets/SnippetStore.swift` and the iOS app are the behavioural reference;
  `snippets-linux` (Rust) is the second reference for byte formats. Where Swift and Linux differ,
  Android follows Swift.
- New self-contained Gradle project in `snippets-android/`. The old `app/`, `AndroidCorePackage/`,
  `baselineprofile/` and the root Gradle files are not touched until the new app replaces them.
- Modules: `:core` (pure Kotlin/JVM, package `com.khm.snippets.core`, only APIs that exist on
  Android API 28+, checked by `:core:animalsnifferMain`), `:app` (Compose, namespace
  `com.khm.snippets.android`, debug id suffix `.debug`).
- Toolchain: Gradle 9.9.2, AGP 9.5.3, Kotlin 2.4.21, Compose BOM 2026.06.01 (material3 1.4.0,
  adaptive 1.2.0), Navigation 3 1.2.2, JDK 17. compileSdk 36 (android-37 is not installed).
- Feature target: parity with the iPhone/iPad app where Android has an equivalent, plus the
  Android-only text action. Providers: none (local only, the default), Git (HTTPS token and SSH,
  encrypted and plain-text), Snippets Cloud (build flag, off by default). No iCloud.
- Byte compatibility is proven by vectors emitted from the Swift implementation
  (`tools/swift-interop`) and by live interop against `git http-backend`, not by reading code.
- Single process; one in-process mutex per storage root. Local state files (`base.json`,
  journal, `state.json`) are Kotlin-owned: current schema only, no legacy migrations.
  `snippets.json` stays parse-compatible with Swift.
- Timestamps are raw doubles since 2001 end to end. Tag/keyword folding matches Foundation through
  a generated table (`tools/foundation-tables`).
- HTTP: OkHttp in `:core`, redirects and retries off. SSH: `mwiede/jsch` with an Android Keystore
  P-256 key signing through the `Identity` interface.
- Secure copy: clip marked sensitive, cleared after 60 s. Revealed secure bodies stay hidden from
  accessibility services. `FLAG_SECURE` on secure and recovery screens. Cancelled authentication is
  silent. Vault session 5 min idle / 30 min max, locks on background.
- `:core` exposes typed halt/failure codes; the app phrases them.
- Recovery-claim identity: per-launch random owner id.
- Backup payload dates: reader accepts both number and ISO forms; writer follows Swift (numbers).
  Swift and Linux disagree here today; report to the user.

## Documents

- `spec/01-library-and-sync-engine.md`, `spec/02-crypto-vault-backup.md`, `spec/03-git-sync.md`,
  `spec/04-snippets-cloud.md`: porting briefs. The Swift source wins over a brief.
- `ux-inventory.md`: screens, strings, 202-item parity checklist.
- `design/research-*.md`: Mobbin research. `design/DESIGN.md` and friends: the design spec.

## Package ownership in `:core`

| Package | Contents | State |
|---|---|---|
| `core.git` (wire) | objects, pkt-line, pack, smart HTTP, SSH framing, cache, test server | in progress |
| `core.crypto`, `core.canonical` | primitives, SwiftDouble, JsonValue, CanonicalJson | in progress |
| `core.text`, `core.clock`, `core.io`, `core.model`, `core.codec` | foundation layer | in progress |
| `core.wire`, `core.sync.transport`, fake transport | envelope, WireCodec, transport types | next |
| `core.search`, `core.placeholders`, `core.assist`, `core.interchange`, `core.settings` | utilities | next |
| `core.vault`, `core.backup` | vault document, session, store, backups | next |
| `core.state`, `core.sync.base`, `core.merge`, `core.library` | state, base, merge, writer | after wire |
| `core.sync.journal`, `core.projection` | journal, projection, materializer | after merge |
| `core.sync.engine` | engine | after journal |
| `core.store`, `core.sync.app` | store, bridge, coordinator, provider selection | after engine |
| `core.git` (transport, setup, plain text, key files, JSch) | Git provider | after engine types |
| `core.cloud` | Snippets Cloud | last |

## Waves

0. Research and scaffold: done.
1. Design synthesis (running). Swift vector tool (running). Git wire, crypto, foundation (running).
2. Wire + transport types; utilities; vault document + backup; Git layout and key files.
3. Merge; state + base + library writer; Git plain text; vault session and store.
4. Journal; projection.
5. Engine.
6. Store, bridge, coordinator; Git transport and setup; JSch connector.
7. App: storage, keystore, biometrics, navigation, library, editor, secure flows, settings, Git
   settings, import/export, diagnostics, text action, deep links, background flush.
8. Snippets Cloud provider.
9. Review loops, emulator end-to-end runs, interop checks, cleanup, replace the old app.

Every wave ends with: tests green, an independent review agent reading the Kotlin against the
Swift, fixes, re-test.

## To tell the user at the end

- Backup payload date disagreement between Swift and Linux (brief 02, H2).
- Swift placeholder resolver traps on `{date "}` (brief 01).
- Linux tag folding differs from Apple outside Latin/Greek/Cyrillic (brief 01).
- compileSdk 36 holds Compose/Lifecycle/OkHttp one release back.
