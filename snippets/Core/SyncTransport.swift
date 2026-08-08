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
    /// `remoteRev` is supplied when the backend discloses it, which turns a
    /// fetch-merge-resubmit round trip into a single fetch.
    case conflict(remoteRev: String?)
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
        case .conflict(let rev):
            return "the backend has a newer version of this snippet\(rev.map { " (\($0))" } ?? "")"
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

    var description: String {
        switch self {
        case .unreachable(let detail): return "the sync backend could not be reached: \(detail)"
        case .rejected(let rejection): return rejection.description
        case .pushUnsupported: return "this sync backend does not accept pushes"
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
    /// More pages are waiting. The engine loops rather than waiting for the next poll.
    var hasMore: Bool
    /// The backend could not honour the cursor it was given and restarted the stream.
    /// The engine must treat this page as a *snapshot*, not a delta — in particular it
    /// must not infer deletions from absence, which is the fastest known way to wipe a
    /// library.
    var isFullResync: Bool

    init(records: [WireRecord], cursor: SyncCursor?, hasMore: Bool = false, isFullResync: Bool = false) {
        self.records = records
        self.cursor = cursor
        self.hasMore = hasMore
        self.isFullResync = isFullResync
    }
}

/// What happened to one submitted record.
nonisolated enum SyncSubmitOutcome: Sendable, Equatable {
    /// Stored. `rev` is what the backend now holds, which may differ from the rev that
    /// was submitted if the backend assigns its own.
    case accepted(rev: String)
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

    init(results: [SyncSubmitResult], cursor: SyncCursor?) {
        self.results = results
        self.cursor = cursor
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

    /// Changes since `cursor`; everything the backend has when `cursor` is `nil`.
    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch

    /// Pushes records.
    ///
    /// - Parameter cursor: what the engine had last read when it built this batch. It
    ///   is the only thing that lets a backend detect "you wrote this from a stale
    ///   view" for a record it has never seen before, where a per-record revision
    ///   check has nothing to compare against.
    ///
    /// Throwing means the whole call failed. A batch where some records were stored and
    /// others were not comes back as a normal `SyncSubmission` with mixed outcomes,
    /// because that is not an error — it is the common case under a rate limit.
    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission
}
