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

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Every record as last agreed, keyed by lowercase uuid string so the file is
    /// diffable by eye.
    var envelopes: [String: SyncEnvelope]
    /// The backend cursor these envelopes correspond to.
    var cursor: SyncCursor?
    /// Once true, a missing journal is evidence of lost protocol state rather than a
    /// pre-journal installation. The engine sets it only after journal.json is durable
    /// and before the first network operation that can create an ambiguous offer.
    var journalEstablished: Bool

    init(
        schemaVersion: Int = SyncBase.currentSchemaVersion,
        envelopes: [String: SyncEnvelope] = [:],
        cursor: SyncCursor? = nil,
        journalEstablished: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.envelopes = envelopes
        self.cursor = cursor
        self.journalEstablished = journalEstablished
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    func envelope(_ id: UUID) -> SyncEnvelope? { envelopes[Self.key(id)] }

    mutating func record(_ envelope: SyncEnvelope) {
        envelopes[Self.key(envelope.id)] = envelope
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
        case schemaVersion, envelopes, cursor, journalEstablished
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
        // Additive and optional for downgrade safety. Shipped builds decoding schema 1
        // ignore this unknown key; bumping the version would make them discard the base
        // as too new and destroy the ancestor semantics this marker exists to protect.
        // Absence therefore means a genuinely legacy base and is upgraded before network.
        journalEstablished = if container.contains(.journalEstablished) {
            try container.decode(Bool.self, forKey: .journalEstablished)
        } else {
            false
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
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        try container.encode(journalEstablished, forKey: .journalEstablished)
        var raw: [String: String] = [:]
        for (key, envelope) in envelopes {
            raw[key] = try envelope.canonicalData().base64EncodedString()
        }
        try container.encode(raw, forKey: .envelopes)
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
