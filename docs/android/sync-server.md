# HTTP sync service and protocol plan

## Service contract

Snippets Cloud and Custom Server run the same versioned HTTP protocol and server code.
The hosted product may add billing, support, and managed operations around it, but it may
not require a private data-plane extension that prevents a conforming self-hosted server
from syncing the apps.

The HTTP data plane is transport-compatible with iCloud. It stores the exact same
`WireRecord.id`, `rev`, `deleted`, and encrypted `blob`; it adds only HTTP-owned CAS and
cursor state. Snippets Cloud must support every record kind and size supported by the
portable/iCloud wire contract so switching providers cannot lose a feature or require a
format conversion.

The server is a blind coordination service. It is responsible for:

- authenticating an account and authorizing a sync space;
- isolating tenants and spaces;
- storing opaque encrypted records;
- enforcing per-record compare-and-swap;
- serving an ordered, at-least-once change feed;
- holding encrypted device/recovery key envelopes it cannot open;
- enforcing quotas/rate limits and sending content-free change hints;
- account/space export and deletion of the opaque service data.

It is not responsible for decrypting, merging, indexing, rendering, or deriving fields
from snippets. It does not have a recovery backdoor. Losing every trusted device and the
space recovery key makes ciphertext unrecoverable, even if account authentication is
restored.

## Technology and repository shape

The planned service is Swift on Linux:

- Hummingbird, pinned to a reviewed stable release, for HTTP/lifecycle/middleware;
- Swift OpenAPI Generator and its Hummingbird transport;
- PostgresNIO with explicit SQL for transactions and PostgreSQL-specific safety;
- Swift Service Lifecycle, `swift-log`, metrics, and tracing through closed sanitized
  wrappers;
- PostgreSQL as the durable source of truth;
- a multi-stage container built from an official Swift image and run as a non-root user.

The exact package versions are selected and locked in the server bootstrap ADR. Raw SQL
is preferred over hiding authorization/CAS behind an ORM: row locks, ordered results,
session-scoped RLS context, partial batch outcomes, and migration ownership must remain
obvious in review.

```text
api/snippets-sync-v1.yaml       normative public request/response schema
server/Package.swift
server/Sources/
  SnippetsServer/               process composition and configuration
  SyncAPI/                      generated protocol conformance and validation
  SyncService/                  transactions, feed, quota, pairing and push
  Persistence/                  SQL repositories and RLS transaction wrapper
server/Migrations/              ordered SQL, checksums, RLS tests
server/Tests/                   unit, integration, conformance and security tests
server/Container/               image/compose and health probes
```

Generated API models are shared by the Swift HTTP client and server where tool support
allows. The server does not link `SyncEnvelope` plaintext parsing or app key stores.

## Threat model and visible metadata

The protocol protects snippet fields from an honest-but-curious or compromised storage
operator using the existing authenticated encrypted wire blob. The service still sees:

- authenticated account and space membership;
- outer record UUID, opaque revision, deletion flag and server generation;
- ciphertext and its padded size;
- request, update, deletion, IP and device/push timing;
- aggregate quota/usage information.

The service does not see names, keywords, tags, snippet bodies, secure-versus-ordinary
classification, HLC/device origin inside the envelope, vault identity, or encryption
keys. The app must disclose the visible metadata; end-to-end encryption is not described
as anonymity.

The current wire AEAD binds record ID, revision and deletion state, so a malicious server
that swaps a blob, changes a tombstone flag, or serves it under another outer identity
causes client authentication/identity failure. Availability attacks, rollback, traffic
analysis, record deletion, and serving stale but previously valid state are not solved by
AEAD alone. CAS, cursor binding, client HLC/base/journal rules, account binding, backups,
and explicit remote-reset review address parts of that threat; the UI must not promise
protection the protocol cannot provide.

## Protocol version and discovery

`api/snippets-sync-v1.yaml` is the source of truth. Requests use HTTPS and a versioned
media type. Unknown required fields, duplicate JSON keys, wrong types, unsupported major
versions, and oversized values fail closed. Additive optional capability fields are
allowed only in declared extension containers.

An unauthenticated discovery resource under `/.well-known/snippets-sync` returns a
bounded document containing:

- protocol major/minor versions and server software version;
- a random immutable server-instance identifier;
- OIDC issuer/client configuration references;
- required portable-record profile plus batch/page/request limits no larger than client
  hard ceilings;
- optional capabilities such as FCM hints;
- public policy/support/deletion URLs.

The app canonicalizes the HTTPS origin and pins the discovered instance to the saved
provider. An instance change is review-required. Discovery cannot ask a client to accept
plaintext, upload keys, raise hard limits, change crypto, or redirect credentials.

The paths below express the intended resource model; final spelling is frozen only in
the reviewed OpenAPI v1 document:

```text
GET    /.well-known/snippets-sync
GET    /v1/spaces
POST   /v1/spaces
GET    /v1/spaces/{space}/scope
GET    /v1/spaces/{space}/changes?cursor=...&limit=...
POST   /v1/spaces/{space}/records:batch
GET    /v1/spaces/{space}/key-envelopes/current
PUT    /v1/spaces/{space}/key-envelopes/recovery
POST   /v1/spaces/{space}/pairings
PUT    /v1/spaces/{space}/pairings/{pairing}/approval
GET    /v1/spaces/{space}/pairings/{pairing}
DELETE /v1/spaces/{space}/devices/{device}
DELETE /v1/spaces/{space}
```

All authenticated responses carry the current opaque scope binding and dataset
generation. `HTTPTransport` revalidates them around awaited operations before applying
records or accepting cursor/CAS progress.

## Outer record API

The HTTP model mirrors `WireRecord` and adds server-owned fields:

```text
record ID              UUID, visible
revision               bounded opaque UTF-8 token, visible
deleted                Boolean, visible
blob                   opaque bytes/base64 in JSON, at most 900,000 raw bytes
record version         opaque server generation, absent only for a create
```

The four application fields are byte-compatible with CloudKit; switching strips only
the source `recordVersion`. A conforming v1 server must accept the required portable
record profile, including the shipping 900,000-byte raw blob ceiling and 256 revision
UTF-8 bytes, rather than advertise a smaller per-record tier. Initial batch/page and
decoded request/response ceilings to validate in the OpenAPI spike are 50 records and
16 MiB. Limits apply while streaming/decompressing, before materializing nested models;
compressed zip bombs cannot bypass them. The server never logs rejected values.

`record version` encodes the server dataset generation plus a monotonically increasing
record generation. Clients treat it as opaque `SyncRecordVersion` bytes. It is distinct
from the application revision: revision says what encrypted value is offered; record
version says which server value was read before a conditional write.

## Fetch and cursor semantics

The change feed is ordered per space by a PostgreSQL sequence. A fetch response contains
records in server order, an opaque authenticated cursor, `hasMore`, and whether this is a
full-resync snapshot. Delivery is at-least-once: pages may repeat records and clients are
already required to be idempotent.

Cursor contents are server-private and integrity-protected. They bind at least the server
instance, dataset generation, space, feed epoch, sequence/page position, and protocol
major. A cursor from another account/space/server is an authorization/protocol error, not
an integer the client is allowed to reinterpret.

Normal change-history compaction may invalidate an old cursor. The service returns a
typed `cursor_invalid` and a full-resync flow; the client marks pages as snapshots and
never infers deletions from absence. Snapshot pagination uses stable record ID order and
a high-water sequence. Writes racing the snapshot are safe as duplicates or subsequent
deltas; tombstones are retained in v1.

A database restore/reset is different from ordinary cursor compaction. Operators must
rotate `dataset_generation` after restoring an older snapshot or losing accepted data.
The transport then reports a review-required remote reset. It must not silently repopulate
the server from whichever device cache happens to connect first. The restore runbook and
drill verify this rotation.

## Compare-and-swap submission

A batch request carries records in a defined order and, for each item, the exact expected
record version or `null` for create-only. The response contains exactly one positional
outcome per input:

- accepted with new record version and application revision;
- conflict with the authoritative current `WireRecord` when it exists;
- rate limited with bounded retry time;
- authentication/authorization required;
- permanent typed rejection such as size/quota/invalid outer value.

The service validates outer shape/limits first, sorts lock acquisition by record ID to
avoid deadlocks, and executes accepted writes plus their change rows in one transaction.
Per-item conflicts/rejections do not prevent independent accepted items from committing,
matching `SyncSubmission.isPartial`. Any transaction-level failure produces no claimed
success; a client retry remains safe.

For each item the transaction:

1. locks the existing `(space_id, record_id)` row if present;
2. verifies create-only or exact dataset/record generation;
3. on mismatch, returns the authoritative current record without writing;
4. on match, allocates the next generation/space change sequence;
5. inserts/updates the record and appends an immutable change snapshot;
6. returns the newly committed opaque version.

Returning the conflict record is load-bearing: a client cursor may already be past that
state. A bare 409 could leave an offer stuck forever.

HTTP v1 does not advance the client's fetch cursor from a submit response. Concurrent
writes could exist before the returned high water, and skipping them would lose data.
The normal fetch observes echoes and other writers idempotently. An idempotency key may
deduplicate whole HTTP retries for load control, but correctness cannot depend on its
cache surviving.

Tombstones are ordinary CAS record saves. There is no physical record delete endpoint in
the sync data plane. V1 retains current tombstone records indefinitely. Safe GC requires
a later protocol with device acknowledgements, expiry/offline-device policy, recovery
semantics, and a proof that an old client cannot resurrect data.

## PostgreSQL model and tenant isolation

The initial logical tables are:

```text
users                 internal account status only
identities            OIDC issuer/subject mapping to internal user
spaces                personal sync spaces and dataset/feed generations
space_memberships     user, role, random scope binding
records               latest opaque record by (space, record ID)
changes               ordered immutable outer record snapshots
devices               membership, revocation and encrypted push routing
key_envelopes          encrypted recovery/device bundles and versions
pairings               short-lived one-use pairing state
idempotency            bounded optional request-result cache
deletion_jobs          cooling-period and verified purge state
```

Every space-owned row carries `space_id`; membership-derived `user_id` is taken from the
validated token mapping, never a request field. Referential integrity, uniqueness,
checks, maximum lengths, and cascading deletion are enforced by PostgreSQL in addition
to request validation.

Tenant isolation is defense in depth:

1. Service repositories require an `AuthorizedSpace` capability created only after
   authentication and membership lookup.
2. Every request transaction uses `SET LOCAL` for the internal user context.
3. Row-level-security policies allow rows only through `space_memberships` for that
   context and required role.
4. `FORCE ROW LEVEL SECURITY` is enabled on protected tables.
5. The runtime database role has no `BYPASSRLS`, does not own protected tables, cannot
   change policies/roles/schema, and cannot run migrations.
6. A separate migration owner runs checksum-pinned migrations, then exits.
7. Connection-pool checkout is always wrapped in a transaction; tests prove context
   cannot leak to the next request after success, error, cancellation, or timeout.

Integration tests create at least two users with overlapping record UUIDs and attempt
every read/write/change/pairing/deletion endpoint across tenants. Direct SQL under the
runtime role must also fail closed without or with the wrong local context.

The service may store a keyed digest/encrypted form of the OIDC `(issuer, subject)` for
lookup; it does not use mutable email as identity. Database dumps, logs and traces never
expose raw subjects, access tokens, space/device/record IDs, blob bytes, or key envelopes.

## Account authentication and authorization

The service accepts standard OIDC access tokens. Hosted Snippets Cloud configures an
identity provider that can offer passkeys and the required platform sign-in methods;
self-hosters configure a trusted OIDC issuer. The sync service itself does not store user
passwords.

Token validation is strict:

- exact HTTPS issuer and audience/client binding;
- allow-listed signature algorithms, verified signature and keyed/JWKS cache rotation;
- expiry, not-before, issued-at/maximum age where applicable;
- no algorithm downgrade or key URL taken from an untrusted token header;
- normalized immutable subject mapping;
- authorization based on current server membership/revocation, not token claims alone.

Native apps use Authorization Code + PKCE; refresh credentials remain in platform secret
storage. Server errors distinguish reauthentication, forbidden membership, rate limit,
quota, conflict, cursor invalidation, and remote reset with closed codes and safe numeric
fields. Arbitrary provider/database exception text never crosses the API.

OIDC authenticates an account; it does not decrypt a space. An identity-provider or email
account takeover is insufficient without a paired device or recovery key.

## End-to-end key bootstrap

### Portable library key bundle

The plaintext bundle exists only inside clients and is versioned/domain-bound. It
contains:

- the provider-neutral library wire key material and salt;
- a random portable library identifier;
- optional vault `kid`, vault salt, `K_lib`, and shareable vault identity without records,
  passphrase wrap, or device-local receipts;
- bundle schema/crypto-suite version and key epoch.

The portable plaintext is provider-neutral. The encrypted envelope—not the bundle
payload—binds the target server instance, membership, space, pairing/recovery purpose and
protocol version as associated data. Moving the same library to another authorized
server creates a new target-bound envelope without changing its library keys.

For an existing iCloud library, the wire material is its current `sync-v1` key. It enters
the service only inside the end-to-end encrypted pairing/recovery envelope after the user
opts into Snippets Cloud; the service never receives the plaintext key. Reusing it lets
iCloud and HTTP carry identical encrypted blobs. A library created on HTTP installs the
same material into an empty compatible Apple synchronizable Keychain slot when the user
switches to iCloud. The bundle never contains OAuth tokens or snippet records.

### Trusted-device pairing

1. The new device authenticates to the same membership and creates a short-lived pairing
   offer with an ephemeral recipient public key.
2. Its QR/deep-link carries canonical server instance, space, pairing ID, recipient key,
   expiry and a short authentication display. It carries no secret key bundle.
3. A trusted device scans it, re-resolves membership/space, displays both endpoints and
   the authentication value, and requires local user authentication.
4. The trusted device encrypts the bundle directly to the scanned recipient key using a
   reviewed RFC 9180 HPKE suite (or a separately reviewed, test-vector-compatible
   implementation), binding server/space/pairing/bundle version as associated data.
5. It uploads only ciphertext. The new device downloads once, verifies/decrypts, stores
   keys through its platform adapters, acknowledges, and the server destroys the offer
   on use/expiry.

The direct QR key prevents a malicious service from silently substituting its own public
key. Pairing IDs are high entropy, one-use, short-lived, membership-bound, rate-limited,
and never logged. Neither device name nor a stable hardware identifier is needed.

### Recovery envelope

At portable-library creation or first HTTP enablement, the client generates a high-
entropy printable recovery secret and
encrypts the same bundle under a domain-separated key. The service may store this
ciphertext because the recovery secret has at least 128 random bits; it is not a
human-chosen password/offline guessing target. The user must confirm saving it before the
app calls the space recoverable.

Recovery requires both current account authorization and the secret by default. An
offline encrypted export remains a second path. Hosted support cannot reveal or reset the
key. Rotating a recovery envelope is explicit and leaves a clear warning that old copies
may still unlock old exported ciphertext.

Use a maintained implementation and published vectors for HPKE/HKDF/AEAD. Do not invent
an ad-hoc ECDH concatenation, derive encryption keys from biometrics, or reuse the vault's
passphrase wrap for server bootstrap.

### Revocation and rotation

Device revocation removes membership device state, pairing eligibility, refresh sessions
where supported, and push token. It prevents future server access but cannot erase keys
or plaintext already held by a compromised device. The UI states this.

Cryptographic revocation needs a new key epoch and re-encryption of every outer record;
revoking access to secure bodies may additionally require vault rekey. This is post-v1
until a journaled, multi-device, crash-safe migration and offline-device policy are
specified. The database schema reserves key epochs but the v1 API cannot pretend server
revocation rotates them.

## Push hints

Push is optional. A device may register an FCM token through an authenticated endpoint;
the token is sensitive operational data, encrypted at rest under a server/KMS key,
accessed only by the push worker, never logged, and deleted on revoke/account deletion.

The payload contains only protocol version and an opaque random routing handle. It has no
record ID, revision, blob, count, user text, or key material. A push is a lossy hint to
schedule a fetch. Duplicate, delayed, forged-at-device, or dropped pushes affect latency,
not correctness. Custom servers without FCM advertise no push capability and clients
poll/manual-sync.

## Quotas, abuse and deletion

Initial limits are per account/space and cover records, raw stored bytes, batch/page
sizes, request rate, concurrent requests, pairing attempts, devices, and key-envelope
size. Rejections are closed codes with safe counts/limits. Quota calculation uses outer
sizes only; the service never decompresses or parses blobs.

Rate limiting is layered at edge and authenticated application scopes. Authentication,
discovery, pairing, oversized bodies, and expensive full snapshots have separate abuse
budgets. Request bodies are bounded before JSON/base64 expansion is materialized.

Account/space deletion is separate from sync tombstones:

- require fresh authentication and exact target confirmation;
- cancel sessions/push/pairings and enter a documented cooling period where promised;
- delete all rows, encrypted envelopes and operational replicas/backups according to the
  published retention policy;
- expose status without returning stable internal IDs in logs;
- test that object/database backups age out as disclosed.

An opaque export contains stored outer records, protocol versions and encrypted key
envelopes so the user can move to a conforming server. It does not claim to be a readable
snippet export; clients already provide encrypted/plain exports under user control.

## Operations and deployment

The first production topology is deliberately simple: stateless service replicas behind
TLS/load balancing, one PostgreSQL primary with managed backups/PITR, and an optional push
worker. Do not add multi-primary writes or an object store before load justifies their
new consistency/failure modes. `bytea` is adequate for the bounded initial records.

Operational requirements:

- separate development/staging/production accounts, databases, OIDC clients, KMS keys
  and push projects;
- migration job with advisory lock, checksums, expand/contract changes, and rollback or
  forward-fix plan;
- TLS to edge and database, secret manager injection, non-root/read-only container,
  minimal egress, dependency/SBOM/image scanning and signed images;
- encrypted backups, restore drills, dataset-generation rotation after rollback/loss,
  and tested client review behavior;
- health/readiness probes that do not touch or expose user data;
- capacity alarms for latency/error/saturation, feed lag, database/storage growth,
  pairing abuse and push failures using aggregates only;
- no request/response body logging; sanitized routes contain no raw resource IDs;
- bounded correlation IDs minted per request, not derived from user/device/space/record;
- administrative tools expose aggregate counts and typed operations, never a blob dump
  in routine support workflows.

Change-history rows retain record snapshots for the configured delta window and may be
compacted after clients fall back to full snapshot. Latest record rows and tombstones are
not compacted in v1. Database backup retention and space deletion retention are distinct
and documented.

## Self-hosting and conformance

Publish a versioned container image, example Docker Compose deployment (service +
PostgreSQL), migration command, health checks, reverse-proxy/TLS guidance, OIDC
configuration, backup/restore runbook, and upgrade compatibility table. Example secrets
are placeholders; no real `.env` is committed.

The public conformance suite runs against hosted and self-hosted endpoints and verifies:

- discovery/version/limit negotiation;
- acceptance and byte-for-byte return of the full portable/CloudKit record profile,
  including secure records, tombstones, extension bags and boundary-size blobs;
- account and cross-tenant isolation;
- fetch pagination, duplicates, cursor binding/invalidation and full snapshot;
- CAS create/update/conflict with authoritative record and partial batches;
- tombstones and no physical-delete shortcut;
- pairing expiry/one-use/key substitution resistance and recovery envelopes;
- auth expiry/revocation and closed error taxonomy;
- oversized/malformed/compressed input and rate/quota behavior;
- dataset reset generation and client review halt;
- export/deletion behavior promised by v1.

Compatibility policy follows semantic protocol versions. Additive optional response
fields/capabilities use the minor version. Any required field meaning, cursor/CAS
contract, crypto bundle format, or authorization change needs a new major/versioned
resource with an overlap window. Production database migrations are additive/expand-
contract until all supported clients have moved.

## Server release gates

The service is ready for external beta only when:

- the OpenAPI v1 document and generated client/server builds are reproducible;
- a model/property test proves accepted CAS writes and change rows are transactionally
  consistent under concurrency and retries;
- the two-tenant RLS/application isolation suite passes under the actual runtime role;
- clients cannot make the server log or reflect submitted bytes/tokens/arbitrary errors;
- E2EE cross-client fixtures and pairing/recovery security review pass;
- an unchanged record survives iCloud -> HTTP -> iCloud with identical application
  fields/blob and only transport-owned CAS/cursor metadata replaced;
- backup restore and dataset reset review are drilled end-to-end;
- deletion/export, retention, subprocessor, incident and privacy documentation match the
  deployed system;
- hosted and clean self-hosted Compose deployments pass the same conformance suite;
- load tests meet budgets for the chosen record/batch limits without disabling safety
  checks or RLS.
