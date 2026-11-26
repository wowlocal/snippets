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
| `core.git` (wire) | objects, pkt-line, pack, smart HTTP, SSH framing, cache, test server | committed; review fixes in progress (11 findings) |
| `core.crypto`, `core.canonical` | primitives, SwiftDouble, JsonValue, CanonicalJson | committed; not yet reviewed |
| `core.text`, `core.clock`, `core.io`, `core.model`, `core.json`, `core.codec` | foundation layer | committed; review in progress |
| `core.wire`, `core.sync.transport`, `core.sync.testing` | envelope, WireCodec, transport types, fake | in progress |
| `core.search`, `core.placeholders`, `core.assist`, `core.interchange`, `core.settings` | utilities | in progress |
| `core.vault`, `core.backup` | vault document, session, store, backups | in progress |
| `core.state`, `core.sync.base`, `core.merge`, `core.library` | state, base, merge, writer | after wire |
| `core.sync.journal`, `core.projection` | journal, projection, materializer | after merge |
| `core.sync.engine` | engine | after journal |
| `core.store`, `core.sync.app` | store, bridge, coordinator, provider selection | after engine |
| `core.git` (layout, key files, plain text, transport, setup, JSch) | Git provider | after wire and engine types |
| `core.cloud` | Snippets Cloud | last |
| `:app` `ui.theme`, `ui.components`, `ui.gallery` | design system | in progress |

Review queue: crypto + canonical (independent review still owed). Git cache needs the transport
to serialise installs (review finding 11). Android refuses repository paths with non-UTF-8
percent escapes (Swift collapses them to the host root; tell the user).

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
- Confirmed by running Swift: `snippets-linux/tests/fixtures/backup-v1.json` opens in Swift with
  its secure record's dates lost (ISO strings become `distantPast`).
- Swift quirks found by the interop tool: a recovery code pasted with CRLF fails `wrongLength`;
  a changed `backupID` reports `wrongPassphrase`; `SyncEnvelope.parse` accepts schemaVersion <= 0;
  `C:/Users/...` parses as scp-style SSH; trailing `.git/` stays in the SSH canonical identity but
  not the HTTPS one; `{date format="it''s"}` resolves to an empty string.
- `vault.json` timestamps round through whole milliseconds since 1970; Kotlin reproduces the
  arithmetic (vector V14).

- More Swift-side findings from the utilities port: `{date:BBBBBB}` crashes `DateFormatter`
  (SIGSEGV); on iOS one enabled secure snippet without a keyword makes every keyword warn and
  suppresses suggestions; creation links with a raw space or stray `%` are not percent-decoded.
- Swift's merged tag order is nondeterministic for some non-NFC tag pairs (foundation review).
- Android refuses repository addresses whose path has a non-UTF-8 percent escape (Swift collapses
  the identity to the host root).

- Swift sync never converges when two devices both add different tags to the same record (for
  example ancestor `["work"]`, one side adds `urgent`, the other `draft`): each round restamps and
  re-submits both records forever. Reproduced with two real Swift engines (9 of 16 scenarios).
  Smallest fix: standard three-way rule for the tag list (if one side equals the ancestor, take the
  other side's list). It changes synced bytes, so it needs a coordinated protocol change in Swift,
  Linux and Kotlin. Not implemented on Android.

## Working notes

- Commits go to `feature/android-kotlin` (pushed), built without switching the checkout, via the
  orchestrator's helper script. Commit each piece when its agent reports tests green.
- Vectors: `core/src/test/resources/vectors/swift/{sealed,open}`, tool `tools/swift-interop`.
- App UI is built against contracts with fakes first, then wired to `:core`.

## Pause point (2026-11-26)

Paused at the user's request after finishing the interrupted pieces; resume on 2026-11-27 after
the usage limit resets. Agents now run on Opus 5.5.

Finished before the pause (all committed and pushed): crypto review fixes (D1-D7), merge (complete), state/base/library
(complete), vault/backup (audit and complete), app shell + library + editor (complete).

Next on resume, in order: commit what finished; independent reviews of merge, state/base/library,
vault/backup, utilities and wire; then journal + projection, engine, store/bridge/coordinator, Git
layout/key files/plain text/transport/setup/JSch, remaining app screens (secure, settings, Git,
system entry points), integration of fakes with core, Snippets Cloud, on-device core tests,
end-to-end emulator runs, interop with the Mac app's formats, replacing the old app.

## Follow-ups queue (small, do in a consolidation pass)

- FIRST on resume: move `SecureSnippetStore` onto `core.library.LibraryTransaction` (state agent's
  report). Today the promote/demote crash marker is never saved (`MoveMarkerStore.None`), so an
  interrupted demotion would be silently undone, and `LibraryVaultTransaction` can delete a vault
  that still holds records. Then delete `LibraryVaultTransaction`, `MoveMarker*`,
  `RecordingMarkers` and their test; use `transaction.pendingMarker()` in
  `reconcileInterruptedMove`.
- `vault/SecureSnippetStore.kt:743,946` catch `Exception` around `KeyWrap.unwrap` and report
  `IncorrectRecoveryCode`; catch only the wrong-key failures so `CryptoUnavailable` surfaces.
- PBKDF2 is 1.88x faster (317 ms per 600k rounds on this Mac); measure on a device before deciding
  on a hand-written SHA-512 compression.
- Deep-link host with a raw leading BOM keeps it (Swift's `URL.host` drops it).
- App: the one-time library swipe tip snackbar shows up over the editor after navigating; the
  search field still gets IME word suggestions (spec: no autocorrect or suggestions).
- App: date+time placeholders on device join with ", " where Apple writes " at " (148 of the 173
  remaining L05 differences on ICU); Android has no public API for the "at" pattern.
- App: release APK still contains the component library's preview sample text.
- `core.json`: list an object's keys and read a number as written; then fold `core.vault.LenientJson`
  (about 170 duplicated lines) into it.
- `tools/swift-interop/README.md`: the vault millisecond formula rounds halves toward the later
  instant, not `round(...)` (differs only before 1970).

- `core.json`: raw-text accessor on `FoundationJsonNode.Number`; compact mode in
  `FoundationJsonWriter`. Then fix the share-link `version` edge in `core.interchange`.
- Move `core.search.SwiftStrings` (hasPrefix, contains, split) into `core.text`.
- App: `android.icu`-backed `DateRenderer` (ICU pattern semantics, CLDR closer to Apple's) and
  re-run the L05 allow-list on device.
- App: call `FoundationTables.warmUp()` off the main thread at start.
- Git transport must use the cache's atomic install and serialise cache access.
- Utilities review (independent) still owed; wire review still owed.
- On-device (instrumented) runs of core: Inflater, IDN, Normalizer, AES-GCM/PBKDF2 providers,
  fsync/atomic move, PBKDF2 600k timing.
- Crypto review: instrumented tests of `core` crypto on API 28 and API 36 devices/emulators
  (`androidTest`, no app UI), each asserting the provider it ran on:
  - V01-V10 and every `fixtures/review-crypto` fixture (`SwiftDifferentialTest`,
    `HostileInputTest`, `LeadingByteOrderMarkTest`, `ClosedKeyringTest`) under Conscrypt;
    assert `Cipher.getInstance("AES/GCM/NoPadding").provider` and the `Mac`/`MessageDigest`
    providers are `AndroidOpenSSL`, and that a bad tag throws `AEADBadTagException` (not another
    `GeneralSecurityException`, which would now surface as `CryptoUnavailable`).
  - PBKDF2-HMAC-SHA512 at 600,000 rounds for both `MacPbkdf2HmacSha512` (keyed `MessageDigest`
    clones; confirm Conscrypt's SHA-512 clones, else the `Mac` fallback is taken) and
    `macDerive`/`JcaPbkdf2HmacSha512`: wall time and allocations/peak memory per derivation on a
    slow phone; cancellation latency of `PassphraseKdf.deriveSuspending`.
  - UTF-8 encode/decode edge cases on ART: unpaired surrogates, U+FFFD, astral scalars,
    over-long and truncated sequences, a leading U+FEFF (`Utf8.decodeStrict` drops one).
  - Normalisation fixtures on API 28: `fixtures/foundation/precomposed-*` (Foundation's
    precomposition, must be device-independent) and the NFC-based ones (`nfc`, canonical
    equality), whose results follow the runtime's Unicode version.
  - Canonical JSON and `SwiftDouble` fixtures (`canonical.tsv.gz`, `doubles.tsv.gz`,
    `double-digests.txt`) on ART.
  - Recovery-key fixtures (`recovery.tsv.gz`) on ART.
  - HMAC with an empty key (`SecretKeySpec` refuses one; the one-zero-byte substitution and the
    keyed-digest path must agree on Conscrypt).
  - Seal/open of bodies near the 674,815-byte canonical ceiling (`SyncMerge.maximumWireCanonicalBytes`):
    time and memory, padding to the next block, round trip.
