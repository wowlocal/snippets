# Sync providers and safe switching

## Principle: preserve iCloud, select one writer

iCloud remains the default network option for users who choose it on Apple platforms.
The HTTP service is an additional provider, not its replacement. Provider selection is
per installation/local library and opt-in; no installation contacts any provider when
Local Only is selected.

Exactly one provider may be active and writable for a local library at a time. The app
never runs `CloudKitTransport` and `HTTPTransport` concurrently against the same local
mutation stream. This rule is enforced below the settings UI: constructing a new
transport requires cancellation of platform scheduling and awaiting the old transport's
round/shutdown barrier.

One writer does not mean two incompatible library formats. iCloud and Snippets Cloud are
fully compatible transports for the same logical encrypted library. Switching is a
normal sync operation over another transport, not export/import, format conversion, or
feature migration.

The visible providers are:

```text
local
icloud                         Apple platforms only, existing production behavior
http:snippets-cloud:<instance> hosted service
http:custom:<instance>         same v1 protocol, user-controlled origin
```

Provider identifiers used in files are opaque digests. Raw endpoints, account subjects,
space IDs, and stable hashes derived from user/device/record IDs are not logged.

## Selection and compatibility state

Add a versioned `SyncProviderSelection` containing only:

- provider kind (`local`, `icloud`, `http`);
- opaque provider-instance key;
- display class (`Snippets Cloud` or `Custom Server`), not a secret endpoint string;
- selection generation and transaction/review state.

Secrets, OAuth tokens, raw server origins, space IDs, and keys do not live in this
preference. The Android credential/secret stores and Apple Keychain-backed adapters own
them.

Existing Apple preference migration is deterministic:

- `SnippetsICloudSyncEnabled == true` becomes `.icloud`;
- absent or false becomes `.local`;
- no HTTP account is created and no files are moved during this interpretation.

While Apple builds still support downgrade to the old preference model, the new code
mirrors the compatibility flag:

- selecting iCloud sets `SnippetsICloudSyncEnabled = true`;
- selecting Local or HTTP sets it to false **before** an HTTP transport can start.

Thus an older build may fall back to local-only but cannot accidentally start CloudKit
against a library currently attached to HTTP. Local edits made by that older build are
captured into the active provider's journal by the newer build on next launch. Before
shipping, tests must cover downgrade across every provider-selection state and a future
selection schema. A future selection value is read-only, never interpreted as iCloud.

## Provider-specific protocol state

`Sync/state.json` keeps device-local HLC and library generation. Provider-owned state is
isolated so a cursor, base, CAS generation, quarantine, or checkpoint can never cross a
backend/account/space boundary.

The existing iCloud layout remains mapped to its current paths to avoid a gratuitous
migration for iCloud-only users:

```text
Sync/base.json
Sync/cksync-checkpoint.bin
...existing iCloud journal/inbox/quarantine paths...
```

HTTP providers use:

```text
Sync/Providers/<opaque-provider-key>/
  base.json
  journal...
  quarantine/
  transport.json
  switch-receipts.json
```

Introduce a `SyncProtocolLocations` value and inject it into the core components that
currently use global URLs. No core algorithm reconstructs paths from a transport name.
The opaque key is derived from a canonical provider instance, authenticated account
scope, space, and protocol family, then domain-separated and hashed. The derivation is
centralized and its input is never persisted beside diagnostics.

Returning to a previously used provider may reuse its base/cursor only after the current
account binding is revalidated. A binding mismatch or unreadable meaningful state enters
the same sticky review model used by CloudKit. Resume is journal-first and resets only
the reviewed provider's cursor/offers/CAS state.

## Full compatibility contract

The portable unit is the logical library, not a provider-specific projection. Both
transports carry the same:

- `WireRecord.id`, `rev`, `deleted`, and encrypted `blob` bytes;
- `SyncEnvelope` schema and extension preservation;
- HLC, merge, conflict-copy, deletion-guard and tombstone semantics;
- ordinary and secure snippets, vault `kid`/salt/`K_lib`, recovery metadata and feature
  set;
- record size ceiling required by the shipping wire protocol.

Only backend mechanics differ:

- CloudKit record system fields versus HTTP record generation (`recordVersion`);
- CloudKit/CKSyncEngine checkpoint versus HTTP cursor;
- account/environment/space binding;
- push subscription and background scheduling.

Those values are opaque and provider-specific by design. They are never copied between
providers. To copy an unchanged record, remove its source `recordVersion` and submit the
same `id`, `rev`, `deleted`, and `blob` under the target's create/CAS rules. No plaintext
round trip or re-encryption is required.

The compatibility suite must prove iCloud -> Snippets Cloud -> iCloud round trips for
every supported record kind with identical logical state and identical encrypted blob
bytes, apart from records genuinely changed by merge. A feature cannot ship on one
provider if the other would strip or reject it.

## Portable library key bundle

Wire and vault keys belong to the library:

- An existing iCloud library continues to use its current `SyncKeyStore` `sync-v1`
  material. When the user first enables Snippets Cloud, the Apple client places that
  material—never its raw plaintext at the service—inside an end-to-end encrypted
  `PortableLibraryKeyBundle` for trusted-device pairing/recovery. Creating/publishing
  that bundle is an explicit locally authenticated action; including a vault also
  requires the existing vault authentication gate.
- This is opt-in key portability, not an iCloud migration. An iCloud-only user creates no
  HTTP bundle, account, or request and keeps the current Keychain behavior unchanged.
- A library created on HTTP generates the same kind of provider-neutral wire material.
  Switching it to an empty iCloud scope installs that material into the synchronizable
  `sync-v1` Keychain slot after local authentication and confirmation.
- Local Only needs no wire key until the first remote provider is selected.

The encrypted bundle contains a random portable library identifier, wire key material
and salt, key epoch, and—when a vault exists—`K_lib` plus the shareable vault identity.
The identity excludes records, device-local receipts, and `wrapPass`, following the
existing Keychain publication boundary. The service stores only the encrypted envelope
and cannot test or unwrap it.

For existing wire schema 1, the cryptographic scope remains the shipped `sync-v1`
scope. The new portable identifier binds onboarding/provider state but does not silently
replace AAD and make production CloudKit blobs undecryptable. A future per-library crypto
scope would require an explicitly versioned, journaled rekey rather than being bundled
with Android support.

Android stores the same wire material for background sync and wraps `K_lib` under its
user-authenticated Keystore policy. Reusing the library key across its providers does not
give either provider plaintext; every trusted device already has access to the local
library, while the server receives only ciphertext.

If the target's records cannot be authenticated with the portable key, its Keychain slot
contains different material, or its vault has another `kid`/salt, this is not an ordinary
switch. It halts before writing and offers account/space correction or a separately
reviewed rival-library recovery/re-encryption flow. It never overwrites a Keychain/
Keystore slot or mints a third identity automatically.

## User operation: Switch and Sync

The normal UI has one action, for example **Switch to Snippets Cloud** or **Switch to
iCloud**. It does not ask users to choose between replace, copy, and merge.

The safe default is always loss-preserving:

- if the target is empty, upload the current encrypted records unchanged;
- if the target already represents this portable library, fetch its changes and run the
  ordinary shared merge;
- retain conflicts/tombstones according to existing rules;
- keep the inactive source remote untouched;
- remember per-provider base/cursor so switching back is normally a delta sync.

After a provider has been attached successfully, switching back does not repeat pairing,
recovery-key entry, or a full upload. It reuses the locally wrapped portable bundle and
provider state after binding validation; normal OIDC/iCloud reauthentication may still be
required when the platform account session has expired.

An explicit destructive **Replace target from backup** may exist under advanced recovery,
but it is not part of provider selection. Cancel before commit changes neither local nor
remote state.

## Switch transaction

The transaction is crash-recoverable and moves through durable named phases. The app is
read-only only for the short commit window. Preparation is invalidated if `librarySeq`
or either provider generation changes.

### 1. Resolve target before data-plane access

Authenticate, canonicalize the target origin, resolve the server/container environment,
and account and space binding. Revalidate around awaited operations. Failure or mismatch
stops before reading the primary library into a target sync round.

For iCloud, use the actual signed environment and `CKContainer.userRecordID()` binding
already required by schema 3. For HTTP, bind the canonical server instance, authenticated
membership, space, and protocol major version into one opaque digest. Never infer either
environment from a scheme, build configuration, or display label.

### 2. Establish portable compatibility and stage target state

Acquire/decrypt the portable key bundle, verify it agrees with the current library and
target key store, then fetch the target through a scratch provider directory. Validate
and decrypt every page without changing primary files or advancing the durable active-
provider cursor. A failed, partial, too-new, undecryptable, physically reset, or deletion-
guarded target is not treated as a successful empty snapshot.

The staging area stores ciphertext and protocol state with app-private permissions and
is excluded from backup. It is deleted after commit/cancel; no snippet fields enter logs.

### 3. Classify the switch

The common path needs only destination/account confirmation and progress. Ordinary
record divergence and merge conflicts are handled automatically by the existing engine.

Enter a sticky on-device review only for a typed anomaly: changed account/environment/
space binding, server instance change, incompatible portable key, rival vault identity,
unreadable or too-new format, remote reset/physical loss, deletion-guard threshold, or a
backup that cannot be verified. Local UI may show useful names/counts during that review;
they are never telemetry.

### 4. Establish a recovery point and stop the source

Before commit:

1. enter a durable switch marker containing opaque source/target keys and phase only;
2. cancel source platform scheduling;
3. await the active round and transport shutdown barrier;
4. flush library, vault, journal, and provider state;
5. create and fsync an encrypted local backup and verify it can be opened;
6. revalidate the exact library/target generations, portable identity and binding.

No remote deletion occurs. If backup creation or verification fails, remain on the
source provider.

### 5. Commit the automatic merge

- Before discarding any target-provider state, capture all current local intent in the
  target's durable journal relative to its validated base (or an empty base on first
  use).
- Merge the staged target and current projection using the same HLC, secure conflict,
  tombstone, quarantine, and deletion-guard rules as an ordinary sync round.
- For unchanged/current records, submit the portable encrypted blob without resealing;
  strip only the source provider's opaque `recordVersion`. A genuinely merged record is
  encoded once under the same portable library key.
- Atomically install/fsync the merged primary projection and target base, select the
  target, then allow submissions. A target CAS conflict re-enters the ordinary fetch,
  merge, and retry path; it never overwrites blindly.
- Clear the marker only after selection, primary files, provider state, and required
  journal entries are durable.

### 6. Verify and retain rollback material

Fetch again, confirm no unhandled journal offers, and show the new provider as active.
Retain the encrypted local backup under a bounded, documented policy. Rollback is another
Switch and Sync operation; it is not an automatic dual-write to the source.

On launch, an incomplete switch marker resumes or rolls back based only on fsynced phase
receipts. It never guesses from whichever provider preference happened to be written.

## Important transition cases

| Transition | Required behavior |
| --- | --- |
| Local -> empty HTTP | Create portable bundle, backup, journal all local intent, upload through CAS, verify. |
| iCloud -> new HTTP | Stop CloudKit, preserve iCloud remote, wrap the existing library/vault keys for pairing, upload the same encrypted records, select HTTP. |
| iCloud -> existing compatible HTTP | Revalidate the same portable identity, fetch delta/snapshot, automatically merge, select HTTP. |
| HTTP -> empty iCloud | Resolve the signed CloudKit scope, install the portable key in an empty compatible Keychain slot, upload the same encrypted records, select iCloud. |
| HTTP -> existing compatible iCloud | Revalidate Keychain/vault/account, automatically merge retained iCloud state and current intent, select iCloud. |
| Any -> incompatible target key/vault | Halt before write and require account/space correction or advanced rival-library recovery. |
| HTTP A -> HTTP B | Carry the same encrypted portable bundle and records to the new authorized server; keep provider cursors/CAS isolated. |
| Remote -> Local Only | Stop/shutdown transport and keep current local projection; do not delete remote/provider state or keys. |
| Local Only -> previous provider | Revalidate account/key/base, capture offline edits, fetch and automatically merge. |
| Account changed in active provider | Sticky account-review halt before local data-plane access; never auto-attach the new account. |
| Target physically reset/deleted | Review-required halt; never repopulate it from local cache without an explicit new-space/copy operation. |

## Android/iCloud handoff

Android cannot initiate an iCloud fetch. The supported path is:

1. On an Apple device currently using iCloud, choose **Switch to Snippets Cloud** or
   **Switch to Custom Server**.
2. Complete the automatic compatible sync and keep the iCloud source remote intact.
3. On Android, authenticate to the same HTTP provider.
4. Pair from the trusted Apple device or use the HTTP space recovery key.
5. Android bootstraps the HTTP space into an empty local library.

The Apple device may remain on HTTP to synchronize with Android, or switch back to iCloud
with **Switch and Sync**. It cannot keep both providers live at once. Changes do not reach
the inactive cloud in the background, but the next switch automatically merges them; the
user does not perform an export/import or choose a merge mode.

## Deletion and reset semantics

- Switching providers never deletes remote data at the source.
- Removing a local provider account first stops scheduling and awaits shutdown; deleting
  credentials does not delete the server space.
- Deleting a remote space/account is a separate authenticated destructive operation with
  target identity, counts, cooling period where supported, and explicit recovery limits.
- Tombstones remain record saves, not physical deletes. HTTP v1 retains them; a future GC
  protocol requires authenticated per-device acknowledgements and offline-device policy.
- A CloudKit zone deletion/reset keeps its existing review-required halt and is never
  "fixed" by resetting Production.
- Losing an encryption key is not repaired by minting a replacement over existing
  ciphertext. Pairing/recovery or an explicit unreadable-space reset is required.

## Required tests

- Preference interpretation and downgrade across absent/false/true iCloud state and all
  new selection states.
- No HTTP DNS/socket/key creation for an iCloud-only user; no CloudKit construction for
  Local/HTTP.
- Transport shutdown race with an in-flight fetch/submit and immediate provider change.
- State-path isolation for two HTTP origins/spaces/accounts and iCloud Development versus
  Production.
- Exact `id`/`rev`/`deleted`/`blob` round trips through iCloud -> HTTP -> iCloud while
  only provider-owned cursor/CAS values change.
- Same-library and rival-key/vault switching in both directions, including Android
  Keystore and Apple Keychain publication failure.
- Crash injection after every durable Switch and Sync phase.
- Local edit invalidates preparation; remote change/CAS/account/key change revalidates or
  enters the typed anomaly review.
- Failed/partial fetch never appears as empty; too-new/unreadable record never advances a
  staged or active cursor.
- Source remote remains byte-for-byte untouched after switch/cancel/rollback.
- Deletion guard, tombstone, secure-conflict and account-review behavior during switch.
- Return to a stale previous provider after independent divergence.
