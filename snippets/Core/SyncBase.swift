import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// The last state this device and the backend agreed on.
///
/// This is the confirmed merge ancestor. Local changes are still discovered by deriving
/// `diff(base, current)`, so a stale CLI, an old app build, `vim`, or a Time Machine
/// restore cannot bypass sync. The derived difference is then recorded in
/// `SyncJournal` before transport begins; that separate desired/offered state closes the
/// acknowledgement ambiguity which a base-only outbox cannot represent.
///
/// Once a journal offer is acknowledged, this file is its durability fence: base.json
/// must reach disk before the exact offer can be removed from journal.json.
nonisolated struct SyncBase: Equatable {

    /// Schema 2 makes the account binding downgrade-safe. A schema-1 reader must not
    /// ignore that field, reuse this cursor under another private database, and then
    /// write the checkpoint back without the only evidence that detects the switch.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    /// Every record as last agreed, keyed by lowercase uuid string so the file is
    /// diffable by eye.
    var envelopes: [String: SyncEnvelope]
    /// The backend generation paired with each confirmed envelope. Entries are allowed
    /// to outlive `envelopes` during a transport-key reset: the application payload must
    /// be re-sealed, while the CloudKit change tag is exactly what prevents that rekey
    /// from overwriting an independent remote edit.
    var recordVersions: [String: SyncRecordVersion]
    /// The backend cursor these envelopes correspond to.
    var cursor: SyncCursor?
    /// Once true, a missing journal is evidence of lost protocol state rather than a
    /// pre-journal installation. The engine sets it only after journal.json is durable
    /// and before the first network operation that can create an ambiguous offer.
    var journalEstablished: Bool
    /// The account/database scope that issued `cursor` and `recordVersions`.
    /// `nil` is valid for an accountless backend and identifies a legacy CloudKit base
    /// that requires migration before any data-plane operation.
    var accountIdentity: SyncAccountIdentity?

    init(
        schemaVersion: Int = SyncBase.currentSchemaVersion,
        envelopes: [String: SyncEnvelope] = [:],
        recordVersions: [String: SyncRecordVersion] = [:],
        cursor: SyncCursor? = nil,
        journalEstablished: Bool = false,
        accountIdentity: SyncAccountIdentity? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.envelopes = envelopes
        self.recordVersions = recordVersions
        self.cursor = cursor
        self.journalEstablished = journalEstablished
        self.accountIdentity = accountIdentity
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    func envelope(_ id: UUID) -> SyncEnvelope? { envelopes[Self.key(id)] }

    func recordVersion(_ id: UUID) -> SyncRecordVersion? {
        recordVersions[Self.key(id)]
    }

    /// Updates application ancestry without disturbing its transport generation. This
    /// is used by projection overlays and old call sites whose operation is not a server
    /// acknowledgement.
    mutating func record(_ envelope: SyncEnvelope) {
        envelopes[Self.key(envelope.id)] = envelope
    }

    /// Atomically pairs the exact server payload with the generation returned by the
    /// same fetch/save. Passing `nil` deliberately removes a stale token; transports
    /// that enforce CAS never confirm a record without supplying one.
    mutating func recordConfirmed(
        _ envelope: SyncEnvelope,
        recordVersion: SyncRecordVersion?
    ) {
        let key = Self.key(envelope.id)
        envelopes[key] = envelope
        recordVersions[key] = recordVersion
    }

    mutating func removeRecordVersion(_ id: UUID) {
        recordVersions.removeValue(forKey: Self.key(id))
    }

    /// What this device has that the backend has not seen.
    ///
    /// Compares by `hash`, not by clock: a record whose content is byte-identical to the
    /// base needs no push however many times it has been re-saved, and suppressing those
    /// is what stops two devices trading writes forever.
    func pendingChanges(from current: [UUID: SyncEnvelope]) -> [SyncEnvelope] {
        var pending: [SyncEnvelope] = []

        for (id, candidate) in current {
            guard let known = envelope(id) else {
                pending.append(candidate)
                continue
            }
            if (try? known.envelopeHash()) != (try? candidate.envelopeHash()) {
                pending.append(candidate)
            }
        }

        // Anything the base knows about that is no longer here has been deleted locally.
        // Expressed as an explicit tombstone rather than as an omission, because absence
        // is never a delete — the whole merge rests on that.
        for (key, known) in envelopes where !known.deleted {
            guard let id = UUID(uuidString: key), current[id] == nil else { continue }
            pending.append(known.tombstoned(hlc: known.hlc, origin: known.origin))
        }

        // Deterministic order, so two runs push the same batch and a test can assert it.
        return pending.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

/// Hand-written rather than synthesized.
///
/// `SyncEnvelope` is deliberately not `Codable`: its serialization is canonical JSON,
/// because those exact bytes are what gets hashed and sealed, and a synthesized encoder
/// would be free to reorder keys. Storing each envelope as its canonical bytes keeps one
/// definition of "what an envelope looks like" instead of two that can drift.
nonisolated extension SyncBase: Codable {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, envelopes, recordVersions, cursor, journalEstablished
        case accountIdentity
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...SyncBase.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-base schema version")
        }
        cursor = try container.decodeIfPresent(SyncCursor.self, forKey: .cursor)
        // Missing only on a pre-journal schema-1 checkpoint. Schema 2 is intentionally
        // a downgrade fence: an older build must stop on the version before it can
        // erase either this marker or the account binding added beside it.
        journalEstablished = if container.contains(.journalEstablished) {
            try container.decode(Bool.self, forKey: .journalEstablished)
        } else {
            false
        }

        // Missing is either the pre-binding schema-1 migration shape or a deliberately
        // accountless backend. Explicit null is not equivalent: our encoder omits nil,
        // so null can only be a damaged or foreign rewrite and must fail closed.
        accountIdentity = if container.contains(.accountIdentity) {
            try container.decode(SyncAccountIdentity.self, forKey: .accountIdentity)
        } else {
            nil
        }
        if schemaVersion < 2, accountIdentity != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .accountIdentity,
                in: container,
                debugDescription: "sync account identity requires sync-base schema 2")
        }

        let raw = try container.decode([String: String].self, forKey: .envelopes)
        var decoded: [String: SyncEnvelope] = [:]
        for (key, text) in raw {
            // Confirmation is now the durability fence for journal acknowledgements.
            // Dropping one malformed entry would turn a known remote record into an
            // unknown one and can reinterpret local absence as a fresh install.
            guard let data = Data(base64Encoded: text),
                  let envelope = try? SyncEnvelope.parse(data),
                  SyncBase.key(envelope.id) == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .envelopes,
                    in: container,
                    debugDescription: "invalid confirmed sync-base envelope")
            }
            decoded[key] = envelope
        }
        envelopes = decoded

        // Additive and optional for upgrades from the pre-CAS base. Explicit `null` is
        // not absence: it is a damaged/truncated value and must fail the entire ancestor
        // file closed. A record-version entry may legitimately exist without an
        // envelope while a transport-key rekey is staged.
        recordVersions = if container.contains(.recordVersions) {
            try container.decode(
                [String: SyncRecordVersion].self,
                forKey: .recordVersions)
        } else {
            [:]
        }
        for key in recordVersions.keys {
            guard let id = UUID(uuidString: key), Self.key(id) == key else {
                throw DecodingError.dataCorruptedError(
                    forKey: .recordVersions,
                    in: container,
                    debugDescription: "invalid sync-record-version key")
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(journalEstablished, forKey: .journalEstablished)
        try container.encodeIfPresent(accountIdentity, forKey: .accountIdentity)
        var raw: [String: String] = [:]
        for (key, envelope) in envelopes {
            raw[key] = try envelope.canonicalData().base64EncodedString()
        }
        try container.encode(raw, forKey: .envelopes)
        try container.encode(recordVersions, forKey: .recordVersions)
    }
}

nonisolated enum SyncBaseFile {

    enum Outcome {
        case loaded(SyncBase)
        case missing
        case tooNew(version: Int)
        case unreadable
    }

    static func load(from url: URL = SnippetStorageLocations.syncBaseFileURL) -> Outcome {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .unreadable
        }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion, version > SyncBase.currentSchemaVersion {
            return .tooNew(version: version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let base = try? decoder.decode(SyncBase.self, from: data) else {
            return .unreadable
        }
        return .loaded(base)
    }

    static func write(
        _ base: SyncBase,
        to url: URL = SnippetStorageLocations.syncBaseFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(try encoder.encode(base), to: url, temporaryDirectory: temporaryDirectory)
    }
}
