import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// Where a backend is in the stream of changes.
///
/// Opaque by contract: a cursor is a page token to iCloud, a continuation token to S3,
/// a sequence number to a plain HTTP backend, and an integer to `InMemoryTransport`.
/// The engine stores it in `SyncState.cursor`, hands it back, and never parses it. The
/// moment anything above this line tries to interpret one, adding a second backend
/// stops being possible.
nonisolated struct SyncCursor: Hashable, Sendable, Codable, CustomStringConvertible {
    var rawValue: String

    init(_ rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var description: String { rawValue }
}

/// Which transport protocol issued a cursor.
///
/// CKServerChangeToken and CKSyncEngine.State.Serialization are unrelated formats even
/// though both ultimately represent CloudKit progress. Persisting this discriminator in
/// a schema-bumped base makes an app downgrade stop instead of alternating protocols and
/// treating each other's opaque values as a recoverable token loss.
nonisolated enum SyncCursorKind: String, Codable, Equatable, Sendable {
    case legacy
    case cloudKitSyncEngine
}

/// An opaque identity for the account/database scope that owns a confirmed checkpoint.
///
/// A change token and per-record generation are meaningful only inside the private
/// database that issued them. Core therefore persists this digest beside those values
/// but never interprets or renders it. In particular this type deliberately has no
/// `description`: stable account identifiers and hashes derived from them must not leak
/// into diagnostics or user-facing error text.
nonisolated struct SyncAccountIdentity: Equatable, Hashable, Sendable, Codable {
    static let currentSchemaVersion = 1
    static let maximumDataBytes = 1_024

    let schemaVersion: Int
    let data: Data

    init(_ data: Data) {
        precondition(!data.isEmpty && data.count <= Self.maximumDataBytes)
        schemaVersion = Self.currentSchemaVersion
        self.data = data
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, data
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard actual == expected else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unexpected sync-account-identity fields"))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-account-identity schema version")
        }
        data = try container.decode(Data.self, forKey: .data)
        guard !data.isEmpty, data.count <= Self.maximumDataBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "invalid sync-account-identity data")
        }
    }

    func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              !data.isEmpty,
              data.count <= Self.maximumDataBytes else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "invalid sync-account-identity value"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(data, forKey: .data)
    }
}

/// Account and transport-private checkpoint are one preflight decision. Returning a
/// typed issue beside the identity (instead of throwing it away) lets an explicitly
/// reviewed reset remain bound to the exact current private-database scope.
nonisolated struct SyncScopePreflight: Sendable, Equatable {
    nonisolated enum CheckpointIssue: Sendable, Equatable {
        case accountChanged
        case unreadable
    }

    var identity: SyncAccountIdentity?
    var checkpointIssue: CheckpointIssue?

    init(
        identity: SyncAccountIdentity?,
        checkpointIssue: CheckpointIssue? = nil
    ) {
        self.identity = identity
        self.checkpointIssue = checkpointIssue
    }
}

/// A backend-owned optimistic-concurrency token for one record.
///
/// `WireRecord.rev` cannot fill this role: it is derived from the encrypted application
/// envelope and therefore says what value we are writing, not which server generation
/// we read before writing it. CloudKit's implementation stores the archived `CKRecord`
/// system fields here; another backend can store an ETag or generation number. Core
/// deliberately treats the bytes as opaque.
///
/// The wrapper has its own small, closed schema because these bytes become part of the
/// durable merge ancestor in `SyncBase`. If a future build changes their representation,
/// an older build must stop instead of silently discarding the compare-and-swap token.
nonisolated struct SyncRecordVersion: Equatable, Hashable, Sendable, Codable {
    static let currentSchemaVersion = 1
    static let maximumDataBytes = 1_048_576

    let schemaVersion: Int
    var data: Data

    init(_ data: Data) {
        schemaVersion = Self.currentSchemaVersion
        self.data = data
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, data
    }

    private struct AnyCodingKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard actual == expected else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unexpected sync-record-version fields"))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-record-version schema version")
        }
        data = try container.decode(Data.self, forKey: .data)
        guard data.count <= Self.maximumDataBytes else {
            throw DecodingError.dataCorruptedError(
                forKey: .data,
                in: container,
                debugDescription: "sync-record-version data is too large")
        }
    }

    func encode(to encoder: Encoder) throws {
        guard schemaVersion == Self.currentSchemaVersion,
              data.count <= Self.maximumDataBytes else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "invalid sync-record-version value"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(data, forKey: .data)
    }
}

/// Something the backend told us out of band.
///
/// Deliberately not "the backend pushed you these records": an event is a *hint* that
/// costs nothing to be wrong about. The engine reacts by scheduling a fetch, which is
/// the same thing the poll timer does, so a duplicated, delayed, or dropped event
/// degrades to polling rather than to a bug.
nonisolated enum SyncTransportEvent: Sendable, Equatable {
    /// Something changed remotely. Fetch when convenient.
    case changesAvailable
    /// The cursor the engine holds is no longer meaningful and the next fetch will be a
    /// full resync. Sent separately from the fetch result so a UI can explain a sudden
    /// burst of traffic.
    case cursorInvalidated(reason: String)
    /// Credentials expired or were revoked. Sync stops until the user re-authorises.
    case authenticationRequired

    // There is deliberately no `reachabilityChanged(isReachable:)`. There was, and
    // nothing emitted it, nothing matched it, and no test covered it — it was a case
    // every future `switch` would have to handle to describe a condition the engine
    // already learns the only way that counts, by a fetch throwing
    // `SyncTransportFailure.unreachable`. A reachability *hint* is worth having the day
    // a transport can actually produce one; adding it back is one line, and it should
    // arrive with its first real producer rather than ahead of it.
}

/// Why the backend would not take a record.
///
/// A typed enum rather than a message string, because every one of these has a
/// different *policy*, and policy chosen by matching on English is policy that breaks
/// when a backend rewords its error. `conflict` means re-merge and retry immediately;
/// `rateLimited` means back off by a stated amount; `authenticationRequired` means stop
/// and ask the user; `permanent` means never retry this record, quarantine it, and get
/// on with the rest of the batch.
nonisolated enum SyncRejection: Error, Sendable, Equatable, CustomStringConvertible {
    /// The backend holds a newer revision than the one this submission was built on.
    /// When the backend discloses its authoritative record, carrying it here is
    /// load-bearing for migration: a legacy cursor may already be past that value, so a
    /// subsequent delta fetch is allowed to be empty. `nil` means the transport could
    /// prove only that a conflict exists; the engine must then retain the offer until an
    /// authoritative record is obtained.
    case conflict(remote: WireRecord?)
    /// Slow down. `retryAfter` is the backend's own number when it gives one.
    case rateLimited(retryAfter: TimeInterval)
    /// Credentials are missing, expired, or insufficient.
    case authenticationRequired(detail: String)
    /// Retrying will never work: a record larger than the backend accepts, a malformed
    /// id, a quota that is not time-based.
    case permanent(detail: String)

    /// Whether the engine should try this record again on its own.
    ///
    /// `authenticationRequired` is deliberately **not** retryable even though a
    /// successful re-auth makes it succeed: the retry has to be triggered by the user
    /// getting involved, not by a timer, or the app spins on a locked account.
    var isRetryable: Bool {
        switch self {
        case .conflict, .rateLimited: return true
        case .authenticationRequired, .permanent: return false
        }
    }

    var description: String {
        switch self {
        case .conflict(let remote):
            return "the backend has a newer version of this snippet"
                + (remote.map { " (\($0.rev))" } ?? "")
        case .rateLimited(let after):
            return "the backend is rate-limiting; retry in \(Int(after.rounded()))s"
        case .authenticationRequired(let detail):
            return "the backend needs you to sign in again: \(detail)"
        case .permanent(let detail):
            return "the backend permanently refused this snippet: \(detail)"
        }
    }
}

/// A failure of the call itself, as opposed to a per-record rejection.
nonisolated enum SyncTransportFailure: Error, Sendable, Equatable, CustomStringConvertible {
    /// No usable network, or the backend did not answer.
    case unreachable(detail: String)
    /// The whole call was refused. Same taxonomy as a per-record rejection.
    case rejected(SyncRejection)
    /// The backend does not accept pushes and one was attempted anyway. A programming
    /// error, surfaced rather than silently ignored.
    case pushUnsupported
    /// The backend account changed after the round established its scope. Any response
    /// may belong to a different private database and must be ignored wholesale.
    case accountChanged
    /// The encrypted transport-private scheduler checkpoint cannot be authenticated or
    /// decoded. Unlike a backend refusal, this has one safe recovery: after explicit
    /// review, durably capture local intent and replace only that checkpoint.
    case checkpointUnreadable(detail: String)
    /// CloudKit reported physical record/zone loss. Automatically uploading the local
    /// cache would violate CloudKit's purge/reset contract, so this stop has no Resume.
    case remoteDataReset(detail: String)

    var description: String {
        switch self {
        case .unreachable(let detail): return "the sync backend could not be reached: \(detail)"
        case .rejected(let rejection): return rejection.description
        case .pushUnsupported: return "this sync backend does not accept pushes"
        case .accountChanged: return "the sync backend account changed during the operation"
        case .checkpointUnreadable(let detail):
            return "the sync scheduler checkpoint could not be read: \(detail)"
        case .remoteDataReset(let detail):
            return "the remote sync data was reset: \(detail)"
        }
    }
}

/// One page of remote changes.
nonisolated struct SyncFetch: Sendable, Equatable {
    /// In backend order, which is the order the engine must apply them in. May contain
    /// the same id more than once: every real backend is at-least-once, and the engine
    /// is required to be idempotent rather than the transport being required to be
    /// exactly-once.
    var records: [WireRecord]
    /// Where to resume. Persist this only after the page has been applied and durably
    /// written; persisting it first turns a crash into permanent data loss.
    var cursor: SyncCursor?
    /// Protocol family that issued `cursor`. A nil/default value is interpreted as the
    /// transport-agnostic legacy family for existing backends.
    var cursorKind: SyncCursorKind?
    /// More pages are waiting. The engine loops rather than waiting for the next poll.
    var hasMore: Bool
    /// The backend could not honour the cursor it was given and restarted the stream.
    /// The engine must treat this page as a *snapshot*, not a delta — in particular it
    /// must not infer deletions from absence, which is the fastest known way to wipe a
    /// library.
    var isFullResync: Bool
    /// Account scope that produced this page. For an account-scoped round this must
    /// match the identity resolved before any data-plane call; otherwise the engine
    /// discards the response before applying records or advancing its cursor.
    var accountIdentity: SyncAccountIdentity?

    init(
        records: [WireRecord],
        cursor: SyncCursor?,
        cursorKind: SyncCursorKind? = nil,
        hasMore: Bool = false,
        isFullResync: Bool = false,
        accountIdentity: SyncAccountIdentity? = nil
    ) {
        self.records = records
        self.cursor = cursor
        self.cursorKind = cursor == nil ? nil : (cursorKind ?? .legacy)
        self.hasMore = hasMore
        self.isFullResync = isFullResync
        self.accountIdentity = accountIdentity
    }
}

/// What happened to one submitted record.
nonisolated enum SyncSubmitOutcome: Sendable, Equatable {
    /// Stored. `rev` is what the backend now holds, which may differ from the rev that
    /// was submitted if the backend assigns its own. `recordVersion` is mandatory: an
    /// adapter that did not receive the saved generation cannot distinguish success
    /// from an ambiguous acknowledgement and must report a retryable rejection instead.
    case accepted(rev: String, recordVersion: SyncRecordVersion)
    case rejected(SyncRejection)
}

nonisolated struct SyncSubmitResult: Sendable, Equatable {
    var id: UUID
    var outcome: SyncSubmitOutcome
}

/// The result of one `submit`.
///
/// An ordered array rather than a dictionary, and parallel to the submitted batch: a
/// dictionary silently collapses a batch that contains the same id twice, and losing
/// half of a partially accepted batch is precisely the bug this type exists to make
/// visible.
nonisolated struct SyncSubmission: Sendable, Equatable {
    var results: [SyncSubmitResult]
    /// The cursor after this submission. A backend that echoes our own writes back on
    /// the next fetch uses this to let us skip them.
    var cursor: SyncCursor?
    /// Account scope that accepted/rejected this batch. See `SyncFetch.accountIdentity`.
    var accountIdentity: SyncAccountIdentity?

    init(
        results: [SyncSubmitResult],
        cursor: SyncCursor?,
        accountIdentity: SyncAccountIdentity? = nil
    ) {
        self.results = results
        self.cursor = cursor
        self.accountIdentity = accountIdentity
    }

    var acceptedIDs: [UUID] {
        results.compactMap { if case .accepted = $0.outcome { return $0.id } else { return nil } }
    }

    var rejections: [(id: UUID, rejection: SyncRejection)] {
        results.compactMap {
            if case .rejected(let rejection) = $0.outcome { return ($0.id, rejection) } else { return nil }
        }
    }

    /// True when the backend took some of the batch and refused the rest — the case an
    /// engine that only checks "did submit throw" gets wrong.
    var isPartial: Bool { !acceptedIDs.isEmpty && !rejections.isEmpty }
}

/// Everything the engine needs from a backend, and nothing else.
///
/// The point of this protocol is that iCloud, an S3 bucket, a self-hosted HTTP
/// endpoint, and the in-memory fake are interchangeable behind it — and, more to the
/// point, that the engine can be developed and proven against the fake. A transport
/// deals in `WireRecord`s, so it cannot see a name, a keyword, a tag, or a body even
/// if it wants to; it cannot be handed a `Snippet` by accident, because it has no API
/// that accepts one.
nonisolated protocol SyncTransport: Sendable {

    /// Stable, human-readable, and used in `SyncState` and in log lines: `"icloud"`,
    /// `"s3"`, `"memory"`. Changing one strands every device that stored it.
    var identifier: String { get }

    /// Whether the backend can tell us something changed. `false` means poll-only, and
    /// the engine leans on `pollInterval` instead.
    var supportsPush: Bool { get }

    /// How often to fetch when nothing else prompts us. A push-capable backend still
    /// sets a sane value: a missed notification must degrade to "slow" rather than to
    /// "never".
    var pollInterval: TimeInterval { get }

    /// Out-of-band hints. One long-lived stream per transport, with one consumer —
    /// `AsyncStream` has a single continuation, so a second iteration would steal
    /// events rather than duplicate them.
    var events: AsyncStream<SyncTransportEvent> { get }

    /// Resolves and establishes the account/database scope for the next round.
    ///
    /// `nil` is reserved for transports whose data is not user-account scoped. An
    /// account-aware transport must return a stable opaque identity and must scope each
    /// subsequent data-plane response to it. Authentication/availability failures
    /// throw; they are never represented as a different or missing identity.
    func resolveAccountIdentity() async throws -> SyncAccountIdentity?

    /// Resolves account scope and inspects transport-private checkpoint binding before
    /// Core reads/project local user data. Stateful transports override this; the
    /// default preserves the existing account-resolution contract.
    func preflightScope() async throws -> SyncScopePreflight

    /// Changes since `cursor`; everything the backend has when `cursor` is `nil`.
    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch

    /// Pushes records.
    ///
    /// Every update carries the `recordVersion` returned by the corresponding prior
    /// fetch/save; a create carries nil. The backend must condition the write on that
    /// exact generation and return `.conflict` rather than overwrite a different one.
    ///
    /// - Parameter cursor: what the engine had last read when it built this batch. A
    ///   backend may use it as an additional feed-level precondition, but it is not a
    ///   substitute for the per-record version and CloudKit intentionally ignores it.
    ///
    /// Throwing means the whole call failed. A batch where some records were stored and
    /// others were not comes back as a normal `SyncSubmission` with mixed outcomes,
    /// because that is not an error — it is the common case under a rate limit.
    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission

    /// One-shot destructive transport reset after Core has durably journaled all local
    /// intent from the old account. Accountless/stateless transports need no work.
    func resetAfterAccountReview() async throws

    /// One-shot replacement of an unreadable transport-private checkpoint. Core calls
    /// this only after a human review and after the latest local intent is durable.
    func resetAfterCheckpointReview() async throws

    /// Resets transport-private scheduler progress after a local crypto/projection
    /// migration already staged every surviving record in the durable journal.
    func resetForLocalFullResync() async throws

    /// Confirms that a transport-owned inbox cursor is now durable in Core's base. A
    /// stateless transport needs no work; CKSyncEngine uses it to compact only the
    /// generation prefix already applied and fsynced by the domain reducer.
    func acknowledgeFetched(through cursor: SyncCursor?) async throws

    /// Stops backend-owned work and returns only after it can no longer mutate local
    /// protocol state or retain an active connection/scheduler for this scope.
    ///
    /// The coordinator awaits this barrier before constructing a replacement
    /// transport. Stateful backends must override it; the default keeps inert and
    /// request-scoped transports source compatible.
    func shutdown() async
}

nonisolated extension SyncTransport {
    func resolveAccountIdentity() async throws -> SyncAccountIdentity? { nil }
    func preflightScope() async throws -> SyncScopePreflight {
        SyncScopePreflight(identity: try await resolveAccountIdentity())
    }
    func resetAfterAccountReview() async throws {}
    func resetAfterCheckpointReview() async throws {}
    func resetForLocalFullResync() async throws {}
    func acknowledgeFetched(through cursor: SyncCursor?) async throws {}
    func shutdown() async {}
}
