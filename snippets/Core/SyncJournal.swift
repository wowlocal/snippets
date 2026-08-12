import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// The durable local side of the sync protocol.
///
/// `SyncBase` says what the backend has confirmed. This journal records the other two
/// states that a request/response transport cannot reconstruct after a crash:
///
/// - `desired` is the latest state observed in the local library, including an explicit
///   tombstone for a deletion;
/// - `offered` is the exact snapshot handed to the transport whose acknowledgement is
///   still ambiguous.
///
/// An unresolved offer is never replaced by a newer desired value. It is either proved
/// confirmed by `SyncBase`, explicitly rejected after a fetch, or submitted again. That
/// fence is what makes create/update/delete safe when the server commits and the process
/// dies before receiving the acknowledgement.
nonisolated struct SyncJournal: Equatable {

    static let currentSchemaVersion = 1

    struct Offered: Equatable {
        var envelope: SyncEnvelope
        /// The desired generation this snapshot came from. A later local edit advances
        /// `Entry.generation` without changing this value.
        var generation: UInt64
        /// The exact backend generation used for this offer. It is inseparable from the
        /// offered bytes: after a fetched B/V2 is persisted, a crash may leave older
        /// offer A in the journal. Retrying A with V2 would pass CAS and overwrite B;
        /// retrying it with its original V1/nil safely conflicts.
        var recordVersion: SyncRecordVersion?

        init(
            envelope: SyncEnvelope,
            generation: UInt64,
            recordVersion: SyncRecordVersion? = nil
        ) {
            self.envelope = envelope
            self.generation = generation
            self.recordVersion = recordVersion
        }
    }

    struct Entry: Equatable {
        var desired: SyncEnvelope
        var offered: Offered?
        var generation: UInt64
        var modifiedAt: Date
    }

    var schemaVersion: Int
    private(set) var entries: [String: Entry]

    init(
        schemaVersion: Int = SyncJournal.currentSchemaVersion,
        entries: [String: Entry] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    func entry(_ id: UUID) -> Entry? {
        entries[SyncBase.key(id)]
    }

    /// Reconciles live local files with confirmed and ambiguous protocol state.
    ///
    /// Absence becomes a deletion only when a live confirmed or offered value proves
    /// that this device has seen the record. Consequently a fresh install creates no
    /// tombstones, and a create removed before it was ever offered simply disappears.
    mutating func reconcile(
        current: [UUID: SyncEnvelope],
        confirmed: SyncBase,
        deviceID: String,
        now: Date
    ) {
        let ids = Set(current.keys)
            .union(confirmed.envelopes.values.map(\.id))
            .union(entries.values.map { $0.desired.id })

        for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
            let key = SyncBase.key(id)
            let previous = entries[key]
            let confirmedEnvelope = confirmed.envelope(id)

            // A crash after base.json was made durable but before the journal was
            // acknowledged leaves this exact shape. The durable base is sufficient
            // proof to finish the acknowledgement idempotently on restart.
            var offered = previous?.offered
            if let snapshot = offered?.envelope,
               Self.sameVersion(snapshot, confirmedEnvelope) {
                offered = nil
            }

            let desired: SyncEnvelope?
            if let local = current[id] {
                desired = Self.restampedIfNeeded(
                    local,
                    previousDesired: previous?.desired,
                    offered: offered?.envelope,
                    confirmed: confirmedEnvelope,
                    deviceID: deviceID,
                    now: now)
            } else if let previousDesired = previous?.desired,
                      previousDesired.deleted {
                // Reconciliation may run repeatedly while an offer is in flight. Reuse
                // the one deletion event rather than minting a new clock every time.
                desired = previousDesired
            } else if let existenceProof = Self.newestLive(
                offered?.envelope, confirmedEnvelope) {
                let evidence = [previous?.desired, offered?.envelope, confirmedEnvelope]
                    .compactMap { $0 }
                // Offered/confirmed state proves that something may exist remotely;
                // once that proof exists, tombstone the newest local representation so
                // a promote/demote or newly learned vault scope is not rolled back.
                let deletionSource = Self.newestLive(
                    previous?.desired, existenceProof) ?? existenceProof
                desired = deletionSource.tombstoned(
                    hlc: Self.clock(after: evidence.map(\.hlc), deviceID: deviceID, now: now),
                    origin: deviceID)
            } else if let offeredEnvelope = offered?.envelope,
                      offeredEnvelope.deleted {
                // A tombstone handed to the transport remains desired until its exact
                // snapshot is either confirmed or rejected.
                desired = offeredEnvelope
            } else {
                // No confirmed/offered live value means an absent local create never
                // escaped this device. There is nothing remote to delete.
                desired = nil
            }

            guard let desired else {
                entries[key] = nil
                continue
            }

            if offered == nil, Self.sameVersion(desired, confirmedEnvelope) {
                entries[key] = nil
                continue
            }

            let desiredChanged = !Self.sameVersion(desired, previous?.desired)
            let generation: UInt64
            if let previous, !desiredChanged {
                generation = previous.generation
            } else {
                generation = Self.nextGeneration(after: previous?.generation)
            }
            let modifiedAt = desiredChanged ? now : (previous?.modifiedAt ?? now)
            entries[key] = Entry(
                desired: desired,
                offered: offered,
                generation: generation,
                modifiedAt: modifiedAt)
        }
    }

    /// Snapshots ready for transport, in deterministic record-id order.
    ///
    /// An ambiguous offer takes precedence over a newer desired state. Advancing to the
    /// newer value before resolving the older one loses the only tentative ancestor
    /// capable of distinguishing our own server echo from an independent remote edit.
    func pending(confirmed: SyncBase) -> [SyncEnvelope] {
        entries.values.compactMap { entry in
            if let offered = entry.offered,
               !Self.sameVersion(offered.envelope, confirmed.envelope(offered.envelope.id)) {
                return offered.envelope
            }
            guard !Self.sameVersion(entry.desired, confirmed.envelope(entry.desired.id)) else {
                return nil
            }
            return entry.desired
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Durably called before the corresponding snapshots are handed to a transport.
    /// Existing unresolved offers are deliberately immutable.
    mutating func markOffered(
        _ envelopes: [SyncEnvelope],
        confirmed: SyncBase? = nil
    ) {
        for envelope in envelopes {
            let key = SyncBase.key(envelope.id)
            guard var entry = entries[key], entry.offered == nil,
                  Self.sameVersion(entry.desired, envelope) else { continue }
            entry.offered = Offered(
                envelope: envelope,
                generation: entry.generation,
                recordVersion: confirmed?.recordVersion(envelope.id))
            entries[key] = entry
        }
    }

    /// Clears only offers whose exact snapshot is already present in the confirmed
    /// base. The caller must persist that base before invoking this method.
    mutating func acknowledge(_ ids: [UUID], confirmed: SyncBase) {
        for id in ids {
            let key = SyncBase.key(id)
            guard var entry = entries[key], let offered = entry.offered,
                  Self.sameVersion(offered.envelope, confirmed.envelope(id)) else { continue }

            entry.offered = nil
            if Self.sameVersion(entry.desired, confirmed.envelope(id)) {
                entries[key] = nil
            } else {
                entries[key] = entry
            }
        }
    }

    /// An authoritative fetch proved that the currently offered snapshot was not the
    /// accepted server value. Keep the latest desired generation and permit it to be
    /// offered on the next round.
    mutating func reject(_ ids: [UUID]) {
        for id in ids {
            let key = SyncBase.key(id)
            guard var entry = entries[key] else { continue }
            entry.offered = nil
            entries[key] = entry
        }
    }

    /// Before a transport-key reset clears the confirmed base, every confirmed envelope
    /// becomes an exact offer to be resealed under the new key. Existing ambiguous offers
    /// and newer desired generations take precedence and are never replaced.
    mutating func stageConfirmedForTransportRekey(
        _ confirmed: SyncBase,
        now: Date
    ) {
        for envelope in confirmed.envelopes.values.sorted(by: {
            $0.id.uuidString < $1.id.uuidString
        }) {
            let key = SyncBase.key(envelope.id)
            if var entry = entries[key] {
                if entry.offered == nil {
                    entry.offered = Offered(
                        envelope: envelope,
                        generation: entry.generation,
                        recordVersion: confirmed.recordVersion(envelope.id))
                    entries[key] = entry
                }
            } else {
                entries[key] = Entry(
                    desired: envelope,
                    offered: Offered(
                        envelope: envelope,
                        generation: 1,
                        recordVersion: confirmed.recordVersion(envelope.id)),
                    generation: 1,
                    modifiedAt: now)
            }
        }
    }

    /// Removes intent owned by a vault deliberately forgotten on this device while
    /// retaining ordinary pending edits. A secure offer followed by an ordinary desired
    /// value is a demotion; only its now-invalid offer is cleared so the ordinary intent
    /// remains pending.
    mutating func forgetSecureIntent() {
        for key in Array(entries.keys) {
            guard var entry = entries[key] else { continue }
            if entry.desired.secure {
                entries[key] = nil
            } else if entry.offered?.envelope.secure == true {
                entry.offered = nil
                entries[key] = entry
            }
        }
    }

    /// Metadata supplied to local projection. Overlaying desired state keeps clocks and
    /// extension fields stable even when the best-effort projection sidecar is missing.
    func projectionKnowledge(over confirmed: SyncBase) -> SyncBase {
        var knowledge = confirmed
        for entry in entries.values {
            // While an offer is ambiguous it is the tentative ancestor: those are the
            // bytes that may already exist remotely. The newer desired value remains in
            // the journal and is overlaid explicitly on the merge's local side.
            knowledge.record(entry.offered?.envelope ?? entry.desired)
        }
        return knowledge
    }

    // MARK: - Reconciliation helpers

    private static func newestLive(
        _ first: SyncEnvelope?, _ second: SyncEnvelope?
    ) -> SyncEnvelope? {
        [first, second].compactMap { $0 }.filter { !$0.deleted }.max { $0.hlc < $1.hlc }
    }

    private static func restampedIfNeeded(
        _ local: SyncEnvelope,
        previousDesired: SyncEnvelope?,
        offered: SyncEnvelope?,
        confirmed: SyncEnvelope?,
        deviceID: String,
        now: Date
    ) -> SyncEnvelope {
        if sameVersion(local, previousDesired)
            || sameVersion(local, offered)
            || sameVersion(local, confirmed) {
            return local
        }

        // The frozen local files cannot store HLC/origin. After a stale recreation is
        // restamped, the next projection can therefore present the same user payload
        // with its old clock again. Preserve the already-restamped desired envelope so
        // reconcile is a fixed point instead of minting a generation every round.
        if let previousDesired,
           local.hlc <= previousDesired.hlc,
           sameRepresentablePayload(local, previousDesired) {
            return previousDesired
        }

        let priorEvidence = [previousDesired, offered, confirmed].compactMap { $0 }
        guard let highest = priorEvidence.map(\.hlc).max(), local.hlc <= highest else {
            return local
        }

        return SyncEnvelope(
            schemaVersion: local.schemaVersion,
            id: local.id,
            hlc: clock(
                after: ([local] + priorEvidence).map(\.hlc),
                deviceID: deviceID,
                now: now),
            origin: deviceID,
            secure: local.secure,
            deleted: local.deleted,
            fields: local.fields,
            x: local.x)
    }

    private static func sameRepresentablePayload(
        _ lhs: SyncEnvelope, _ rhs: SyncEnvelope
    ) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.id == rhs.id
            && lhs.secure == rhs.secure
            && lhs.deleted == rhs.deleted
            && lhs.fields == rhs.fields
            && lhs.x == rhs.x
    }

    private static func clock(after clocks: [HLC], deviceID: String, now: Date) -> HLC {
        let generator = HLCGenerator(
            device: deviceID,
            persisted: clocks.max(),
            physicalNowMs: { now.millisecondsSince1970 })
        return generator.send()
    }

    private static func nextGeneration(after previous: UInt64?) -> UInt64 {
        guard let previous else { return 1 }
        return previous == UInt64.max ? UInt64.max : previous + 1
    }

    private static func sameVersion(_ lhs: SyncEnvelope?, _ rhs: SyncEnvelope?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (.some(let lhs), .some(let rhs)):
            if let left = try? lhs.envelopeHash(), let right = try? rhs.envelopeHash() {
                return left == right
            }
            return lhs == rhs
        case (.some, nil), (nil, .some): return false
        }
    }
}

// MARK: - Persistence

/// Hand-written for the same reason as `SyncBase`: an envelope has one canonical wire
/// representation, and the journal stores those exact bytes rather than inventing a
/// second synthesized representation that can drift.
nonisolated extension SyncJournal: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, entries
    }

    private struct StoredOffered: Codable {
        var envelope: String
        var generation: UInt64
        /// Additive for pre-CAS journal compatibility. Missing means the offer was
        /// created by an older build; nil is the safe conditional-create token.
        var recordVersion: SyncRecordVersion?
    }

    private struct StoredEntry: Codable {
        var desired: String
        var offered: StoredOffered?
        var generation: UInt64
        /// `Date`'s stored `Double`, without ISO-8601's subsecond truncation. Journal
        /// round trips must be value-exact because equality suppresses needless writes.
        var modifiedAt: Double
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...SyncJournal.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-journal schema version")
        }
        // Both fields are required. A syntactically valid truncated write such as `{}`
        // or `{"schemaVersion":1}` must halt, never become an authoritative empty
        // journal that silently discards desired/offered intent.
        let stored = try container.decode([String: StoredEntry].self, forKey: .entries)

        var decoded: [String: Entry] = [:]
        decoded.reserveCapacity(stored.count)
        for (key, value) in stored {
            guard value.generation > 0,
                  let desiredData = Data(base64Encoded: value.desired),
                  let desired = try? SyncEnvelope.parse(desiredData),
                  SyncBase.key(desired.id) == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .entries,
                    in: container,
                    debugDescription: "invalid desired sync-journal entry")
            }

            let offered: Offered?
            if let storedOffered = value.offered {
                guard storedOffered.generation > 0,
                      storedOffered.generation <= value.generation,
                      let offeredData = Data(base64Encoded: storedOffered.envelope),
                      let envelope = try? SyncEnvelope.parse(offeredData),
                      envelope.id == desired.id else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .entries,
                        in: container,
                        debugDescription: "invalid offered sync-journal entry")
                }
                offered = Offered(
                    envelope: envelope,
                    generation: storedOffered.generation,
                    recordVersion: storedOffered.recordVersion)
            } else {
                offered = nil
            }

            decoded[key] = Entry(
                desired: desired,
                offered: offered,
                generation: value.generation,
                modifiedAt: Date(timeIntervalSinceReferenceDate: value.modifiedAt))
        }
        entries = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        var stored: [String: StoredEntry] = [:]
        stored.reserveCapacity(entries.count)
        for (key, entry) in entries {
            let offered = try entry.offered.map {
                StoredOffered(
                    envelope: try $0.envelope.canonicalData().base64EncodedString(),
                    generation: $0.generation,
                    recordVersion: $0.recordVersion)
            }
            stored[key] = StoredEntry(
                desired: try entry.desired.canonicalData().base64EncodedString(),
                offered: offered,
                generation: entry.generation,
                modifiedAt: entry.modifiedAt.timeIntervalSinceReferenceDate)
        }
        try container.encode(stored, forKey: .entries)
    }
}

nonisolated enum SyncJournalFile {

    enum Outcome {
        case missing(SyncJournal)
        case loaded(SyncJournal)
        case tooNew(version: Int)
        case unreadable(String)
    }

    static func load(
        from url: URL = SnippetStorageLocations.syncJournalFileURL
    ) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .missing(SyncJournal())
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable("sync journal could not be read")
        }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion,
           version > SyncJournal.currentSchemaVersion {
            return .tooNew(version: version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(SyncJournal.self, from: data))
        } catch {
            return .unreadable("sync journal is malformed")
        }
    }

    static func write(
        _ journal: SyncJournal,
        to url: URL = SnippetStorageLocations.syncJournalFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(
            encoder.encode(journal), to: url, temporaryDirectory: temporaryDirectory)
    }
}
