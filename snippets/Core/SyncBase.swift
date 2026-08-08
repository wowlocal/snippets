import Foundation

// Compiled into the app and the test package — see `Snippet.swift`.

/// The last state this device and the backend agreed on.
///
/// It does double duty, and that is the point of having it:
///
/// - **The merge ancestor.** Three-way merge against the backend needs a common
///   ancestor exactly as the local one does, and this is it.
/// - **The outbox.** What needs pushing is *derived* — `diff(base, current)` — rather
///   than recorded when a change happens. That matters because plenty of changes never
///   pass through code that could record them: a stale CLI, an old app build, `vim`, a
///   Time Machine restore. An outbox would miss every one of those and quietly stop
///   syncing them. A derived diff cannot miss anything, and it survives a crash
///   mid-push for free.
///
/// Losing this file is not data loss. It costs one full reconcile, which is why it
/// carries no recovery machinery of its own.
nonisolated struct SyncBase: Equatable {

    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Every record as last agreed, keyed by lowercase uuid string so the file is
    /// diffable by eye.
    var envelopes: [String: SyncEnvelope]
    /// The backend cursor these envelopes correspond to.
    var cursor: SyncCursor?

    init(
        schemaVersion: Int = SyncBase.currentSchemaVersion,
        envelopes: [String: SyncEnvelope] = [:],
        cursor: SyncCursor? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.envelopes = envelopes
        self.cursor = cursor
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
        case schemaVersion, envelopes, cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? SyncBase.currentSchemaVersion
        cursor = try container.decodeIfPresent(SyncCursor.self, forKey: .cursor)

        let raw = try container.decodeIfPresent([String: String].self, forKey: .envelopes) ?? [:]
        var decoded: [String: SyncEnvelope] = [:]
        for (key, text) in raw {
            // A single unparseable entry drops that record from the ancestor rather than
            // failing the whole file. The cost is one spurious push; failing the load
            // would cost a full reconcile.
            guard let data = Data(base64Encoded: text),
                  let envelope = try? SyncEnvelope.parse(data) else { continue }
            decoded[key] = envelope
        }
        envelopes = decoded
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(cursor, forKey: .cursor)
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
        /// Missing, unreadable, or from a newer build. All three are the same response:
        /// start from nothing and do a full reconcile. There is no user data here to
        /// protect, so there is no reason to refuse.
        case unavailable
    }

    static func load(from url: URL = SnippetStorageLocations.syncBaseFileURL) -> Outcome {
        guard let data = try? Data(contentsOf: url) else { return .unavailable }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion, version > SyncBase.currentSchemaVersion {
            return .unavailable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let base = try? decoder.decode(SyncBase.self, from: data) else { return .unavailable }
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
