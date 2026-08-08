import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// Proof that a record was deleted, and when.
///
/// The `hlc` is the deletion's position in the fleet's causal order — it is what lets
/// `SyncMerge` decide between "deleted here, edited there" without consulting a wall
/// clock. `deletedAt` is wall time and is used for exactly one thing: deciding when
/// the tombstone may be collected. The two are kept separate because they answer
/// different questions and because a device with a wrong clock must be able to poison
/// the second without poisoning the first.
nonisolated struct Tombstone: Equatable, Sendable, Codable {
    var hlc: HLC
    var deletedAt: Date
}

/// Every deletion this device knows about, and how far back that knowledge is
/// trustworthy.
///
/// ## Why tombstones exist at all
///
/// `SyncMerge` already has the rule that matters — absence is only a deletion if the
/// ancestor proves the record was there and left. That works for a two-way file merge
/// where the ancestor is a complete snapshot. It does not work across a network, where
/// what arrives is a *delta*: a device that has been offline for a week sends the
/// records it changed and says nothing about the ones it deleted. Without an explicit
/// deletion marker, the only signal is absence, and absence over a delta channel means
/// nothing at all.
///
/// ## The horizon, and what it is actually for
///
/// Tombstones cannot be kept forever — a library churned daily would accumulate more
/// tombstones than snippets — so they are collected after 90 days. The horizon is not
/// a cleanup interval; it is **a contract with the rest of the fleet**: every device
/// promises to reconcile at least once every 90 days, and in exchange every other
/// device promises to remember its deletions for that long.
///
/// A device that breaks its half of the contract — a Mac closed for a sabbatical, a
/// clone restored from a two-year-old Time Machine backup — will offer records whose
/// tombstones we have already collected. The failure mode we must not have is the
/// obvious one: no tombstone found, therefore this is a new record, therefore write it
/// back into the library. That is a resurrection, it is silent, and it is
/// self-propagating — the resurrected record now looks new to every device.
///
/// So the ledger records `collectedThrough`: the newest `deletedAt` it has ever
/// discarded. Anything older than that is *unknowable* from the ledger alone, and
/// `recognize(id:hlc:)` says so rather than guessing. The engine's rule for
/// `.indeterminate` is spelled out on that method.
nonisolated struct TombstoneLedger: Equatable, Sendable, Codable {

    static let currentSchemaVersion = 1

    /// 90 days. Chosen to be longer than any plausible "my laptop was in a drawer"
    /// story and shorter than the point at which the ledger rivals the library in size.
    /// A shorter horizon makes silent-resurrection windows more common; a longer one
    /// costs disk and nothing else, so when in doubt this number goes up, never down.
    static let defaultHorizon: TimeInterval = 90 * 24 * 60 * 60

    var schemaVersion: Int

    /// Keyed by lowercased `uuidString` rather than by `UUID`.
    ///
    /// A Swift dictionary with a non-`String` key encodes as a flat *array* of
    /// alternating keys and values, which is unreadable, unmergeable by hand, and
    /// unstable in order. A string key gives `tombstones.json` an object a human can
    /// read and `jq` can query.
    private(set) var entries: [String: Tombstone]

    /// The newest `deletedAt` this ledger has ever collected. `nil` until the first GC:
    /// before that, the ledger is complete for all time and absence really does mean
    /// "never deleted".
    private(set) var collectedThrough: Date?

    init(
        schemaVersion: Int = TombstoneLedger.currentSchemaVersion,
        entries: [String: Tombstone] = [:],
        collectedThrough: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
        self.collectedThrough = collectedThrough
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    var count: Int { entries.count }

    /// Ids in a deterministic order, so a diagnostic dump of two devices' ledgers can
    /// be compared line by line.
    var ids: [UUID] { entries.keys.sorted().compactMap(UUID.init(uuidString:)) }

    subscript(id: UUID) -> Tombstone? { entries[Self.key(id)] }

    func contains(_ id: UUID) -> Bool { entries[Self.key(id)] != nil }

    /// Records a deletion, keeping the *later* of two markers for the same id.
    ///
    /// Two devices can delete the same record independently; the fleet needs one
    /// answer, and `HLC` already provides a total order that every device computes
    /// identically. Taking the max rather than overwriting also makes this idempotent,
    /// which matters because an at-least-once transport will deliver the same tombstone
    /// more than once.
    mutating func record(_ id: UUID, hlc: HLC, deletedAt: Date) {
        let key = Self.key(id)
        if let existing = entries[key], existing.hlc >= hlc { return }
        entries[key] = Tombstone(hlc: hlc, deletedAt: deletedAt)
    }

    mutating func record(_ envelope: SyncEnvelope, deletedAt: Date) {
        guard envelope.deleted else { return }
        record(envelope.id, hlc: envelope.hlc, deletedAt: deletedAt)
    }

    /// Drops a tombstone because the user deliberately brought the record back — an
    /// undo, or a restore from a backup.
    ///
    /// The only sanctioned way for a record to return from the dead. It is a local,
    /// explicit act, which is exactly what a silent resurrection is not.
    mutating func forget(_ id: UUID) {
        entries.removeValue(forKey: Self.key(id))
    }

    /// Collects everything older than the horizon and advances `collectedThrough`.
    ///
    /// - Returns: the ids collected, sorted, so a caller can log precisely what it can
    ///   no longer prove.
    @discardableResult
    mutating func collect(
        now: Date,
        horizon: TimeInterval = TombstoneLedger.defaultHorizon
    ) -> [UUID] {
        let cutoff = now.addingTimeInterval(-horizon)
        var collected: [UUID] = []
        var newestCollected = collectedThrough

        for (key, tombstone) in entries where tombstone.deletedAt < cutoff {
            entries.removeValue(forKey: key)
            if let id = UUID(uuidString: key) { collected.append(id) }
            newestCollected = newestCollected.map { max($0, tombstone.deletedAt) } ?? tombstone.deletedAt
        }

        // Advanced only by an actual collection, never by the passage of time. If
        // nothing was old enough to drop, the ledger is still complete back to wherever
        // it was complete before, and moving the floor forward would manufacture
        // `.indeterminate` verdicts for records we can in fact account for.
        collectedThrough = newestCollected
        return collected.sorted { $0.uuidString < $1.uuidString }
    }

    /// What we can honestly say about a record the remote is offering us.
    enum Recognition: Equatable {
        /// We hold the proof: this id was deleted, at this point in the causal order.
        /// The caller compares `tombstone.hlc` against the incoming record's clock —
        /// a later edit still beats an earlier delete, exactly as in `SyncMerge`.
        case deleted(Tombstone)

        /// No tombstone, and the ledger is complete far enough back to be sure there
        /// never was one. The record is genuinely new to this device.
        case unseen

        /// No tombstone, but the record's clock predates our collection floor, so its
        /// tombstone may simply have been collected. **We cannot tell, and must not
        /// guess.**
        ///
        /// The engine's rule, and the reason this case exists rather than a `Bool`:
        ///
        /// 1. Do not apply it as an addition. That is the silent resurrection.
        /// 2. Do not apply it as a deletion either. Deleting a record we cannot account
        ///    for is how a stale backend wipes a library, and `DeletionGuard` exists
        ///    because that has to be impossible.
        /// 3. Fall back to the thing that does not need a tombstone: a **full
        ///    reconcile** against `Sync/base.json`, the last-synced snapshot. If base
        ///    holds the record unchanged, it left this device deliberately and stays
        ///    gone. If base does not hold it, we have never seen it and it is an
        ///    addition after all.
        /// 4. If there is no usable base — a fresh install, a wiped `Sync/` — surface
        ///    it to the user as a restored record rather than resolving it silently.
        ///    Being asked once is cheap; the two silent answers are both data loss in
        ///    one direction or the other.
        case indeterminate(collectedThrough: Date)
    }

    func recognize(id: UUID, hlc: HLC) -> Recognition {
        if let tombstone = self[id] { return .deleted(tombstone) }
        guard let floor = collectedThrough else { return .unseen }
        // The comparison is against the record's own clock, not against `now`: what
        // matters is whether the record is old enough that its deletion *could* have
        // been collected, not how long ago we last ran a GC.
        return hlc.wallMs <= floor.millisecondsSince1970
            ? .indeterminate(collectedThrough: floor)
            : .unseen
    }
}

/// `Sync/tombstones.json`, read and written with the same version-probe discipline as
/// `Sync/state.json`.
///
/// Unlike `state.json`, this file is **not** freely regenerable. Deleting it does not
/// cost a reconcile; it costs the proof that a set of records were deliberately
/// removed, which is the one thing that stops them coming back. `load` therefore
/// distinguishes "no file yet" from "a file we could not read": the first is an empty
/// ledger, the second is a reason to halt sync rather than to start over.
nonisolated enum TombstoneFile {

    enum Outcome {
        case loaded(TombstoneLedger)
        /// Written by a newer build. Do not write it back — an older build's idea of
        /// this file has fewer deletions in it, and writing that back is a fleet-wide
        /// resurrection.
        case tooNew(version: Int)
        /// No file. A genuinely empty ledger.
        case empty(TombstoneLedger)
        /// A file that exists and could not be read. Distinct from `empty` on purpose.
        case unreadable(String)
    }

    static func load(from url: URL = SnippetStorageLocations.tombstonesFileURL) -> Outcome {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as NSError).isFileNotFound { return .empty(TombstoneLedger()) }
            return .unreadable(
                "tombstone ledger at '\(url.path)' could not be read: \(error.localizedDescription)")
        }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion,
           version > TombstoneLedger.currentSchemaVersion {
            return .tooNew(version: version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let ledger = try? decoder.decode(TombstoneLedger.self, from: data) else {
            return .unreadable("tombstone ledger at '\(url.path)' exists but could not be decoded")
        }
        return .loaded(ledger)
    }

    /// `temporaryDirectory` travels with `url` for the reason spelled out on
    /// `SyncStateFile.write`.
    static func write(
        _ ledger: TombstoneLedger,
        to url: URL = SnippetStorageLocations.tombstonesFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(encoder.encode(ledger), to: url, temporaryDirectory: temporaryDirectory)
    }
}
