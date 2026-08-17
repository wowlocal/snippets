import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

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

    /// Schema 2 made account binding downgrade-safe. Schema 3 additionally fences the
    /// switch from CKServerChangeToken to CKSyncEngine's synthetic durable-inbox cursor.
    /// Schema 4 separates stable account membership from physical dataset generation and
    /// adds a crash-safe non-destructive merge marker for primary-library recovery.
    /// Schema 5 distinguishes a legacy/incomplete restore from an exact reviewed local
    /// snapshot. The latter is a durable ancestor for edits and deletions made while the
    /// full cloud fetch is still pending; without that distinction, a post-review delete
    /// could be silently resurrected by the conservative union.
    /// Schema 6 optionally retains the readable confirmed ancestor which preceded a
    /// checkpoint Repair. It is separate from the reviewed primary snapshot: unchanged
    /// pre-review intent merges against the former, while later user intent merges
    /// against the latter. Primary-file recovery omits it because old absences are not
    /// trustworthy there.
    /// Schema 7 gives every explicit reviewed recovery a random durable identity. Two
    /// reviews of byte-identical backups are still separate authority epochs, while a
    /// crash retry of one committed review retains the same identity.
    static let currentSchemaVersion = 7

    enum NonDestructiveMergeMode: String, Codable, Equatable {
        /// Legacy schema-4 semantics: every absence is uncertain and must be recovered
        /// from the journal/cloud rather than interpreted as a new local deletion.
        case incompletePrimary
        /// `envelopes` is the exact primary snapshot accepted by Repair/Check Again.
        /// Later primary changes are authoritative local intent even before first fetch.
        case reviewedLocalSnapshot
    }

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
    /// Protocol family that issued `cursor`. Schema 1/2 cursors migrate as `.legacy`;
    /// schema 3 requires an explicit value whenever a cursor exists.
    var cursorKind: SyncCursorKind?
    /// Once true, a missing journal is evidence of lost protocol state rather than a
    /// pre-journal installation. The engine sets it only after journal.json is durable
    /// and before the first network operation that can create an ambiguous offer.
    var journalEstablished: Bool
    /// The account/database scope that issued `cursor` and `recordVersions`.
    /// `nil` is valid for an accountless backend and identifies a legacy CloudKit base
    /// that requires migration before any data-plane operation.
    var accountIdentity: SyncAccountIdentity?
    /// Physical generation of the remote dataset. This is deliberately not folded into
    /// `accountIdentity`: routine feed rotation must not look like an account switch, but
    /// a dataset replacement must survive relaunch and stop before push-first sync.
    var datasetIdentity: SyncDatasetIdentity?
    /// A crash-safe request to replace transport-private scheduler progress before the
    /// next data-plane call. Local maintenance writes this only after surviving intent
    /// is durable; Core clears it only after the transport reset succeeds.
    var requiresTransportFullResync: Bool
    /// A restored primary file is readable but may be incomplete. While this marker is
    /// true, Core must reset to a full merge and must never infer deletion from absence
    /// against the old base. It is written before clearing the durable quarantine halt.
    var requiresNonDestructiveLibraryMerge: Bool
    /// Present exactly while `requiresNonDestructiveLibraryMerge` is true in schema 5+.
    /// Schema-4 recovery fences migrate conservatively as `.incompletePrimary`.
    var nonDestructiveMergeMode: NonDestructiveMergeMode?
    /// Readable backend-confirmed ancestor from immediately before checkpoint Repair.
    /// `nil` means recovery cannot trust old primary absences. An empty dictionary is a
    /// known-empty ancestor and is therefore distinct from nil.
    var preRecoveryConfirmedEnvelopes: [String: SyncEnvelope]?
    /// Random identity of this exact explicit Repair/Check Again transaction. Required
    /// only for schema-7 reviewed recovery; legacy reviewed fences have no identity and
    /// are handled conservatively until upgraded.
    var nonDestructiveReviewID: UUID?

    init(
        schemaVersion: Int = SyncBase.currentSchemaVersion,
        envelopes: [String: SyncEnvelope] = [:],
        recordVersions: [String: SyncRecordVersion] = [:],
        cursor: SyncCursor? = nil,
        cursorKind: SyncCursorKind? = nil,
        journalEstablished: Bool = false,
        accountIdentity: SyncAccountIdentity? = nil,
        datasetIdentity: SyncDatasetIdentity? = nil,
        requiresTransportFullResync: Bool = false,
        requiresNonDestructiveLibraryMerge: Bool = false,
        nonDestructiveMergeMode: NonDestructiveMergeMode? = nil,
        preRecoveryConfirmedEnvelopes: [String: SyncEnvelope]? = nil,
        nonDestructiveReviewID: UUID? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.envelopes = envelopes
        self.recordVersions = recordVersions
        self.cursor = cursor
        self.cursorKind = cursor == nil ? nil : (cursorKind ?? .legacy)
        self.journalEstablished = journalEstablished
        self.accountIdentity = accountIdentity
        self.datasetIdentity = datasetIdentity
        self.requiresTransportFullResync = requiresTransportFullResync
        self.requiresNonDestructiveLibraryMerge = requiresNonDestructiveLibraryMerge
        self.nonDestructiveMergeMode = requiresNonDestructiveLibraryMerge
            ? (nonDestructiveMergeMode ?? .incompletePrimary)
            : nil
        self.preRecoveryConfirmedEnvelopes = preRecoveryConfirmedEnvelopes
        self.nonDestructiveReviewID = if schemaVersion >= 7,
            requiresNonDestructiveLibraryMerge,
            self.nonDestructiveMergeMode == .reviewedLocalSnapshot {
            nonDestructiveReviewID ?? UUID()
        } else {
            nil
        }
    }

    static func key(_ id: UUID) -> String { id.uuidString.lowercased() }

    func envelope(_ id: UUID) -> SyncEnvelope? { envelopes[Self.key(id)] }

    func recordVersion(_ id: UUID) -> SyncRecordVersion? {
        recordVersions[Self.key(id)]
    }

    /// Stable local transaction identity for an exact reviewed recovery snapshot. It
    /// contains no user text. Schema 7 includes a random review transaction id, so two
    /// explicit reviews of identical bytes cannot share causal authority. Legacy fences
    /// retain their content identity only until the current writer upgrades them.
    func nonDestructiveReviewFingerprint() -> String? {
        guard requiresNonDestructiveLibraryMerge,
              nonDestructiveMergeMode == .reviewedLocalSnapshot else { return nil }
        func component(_ values: [String: SyncEnvelope]) -> String {
            values.keys.sorted().map { key in
                let hash = (try? values[key]?.envelopeHash()) ?? "invalid"
                return "\(key.utf8.count):\(key)\(hash.utf8.count):\(hash)"
            }.joined(separator: "|")
        }
        let prior = preRecoveryConfirmedEnvelopes.map(component) ?? "unknown"
        let snapshotMaterial = "reviewed:\(component(envelopes))|prior:\(prior)"
        let material = nonDestructiveReviewID.map {
            "review-id:\($0.uuidString.lowercased())|\(snapshotMaterial)"
        } ?? snapshotMaterial
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// Makes a legacy value writable by this version without dropping an active review
    /// fence. Minting once before the upgraded base is persisted gives all crash retries
    /// the same durable epoch.
    mutating func upgradeToCurrentSchema() {
        if schemaVersion < 7,
           requiresNonDestructiveLibraryMerge,
           nonDestructiveMergeMode == .reviewedLocalSnapshot,
           nonDestructiveReviewID == nil {
            nonDestructiveReviewID = UUID()
        }
        schemaVersion = Self.currentSchemaVersion
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

    mutating func adoptCursor(_ cursor: SyncCursor?, kind: SyncCursorKind?) {
        schemaVersion = Self.currentSchemaVersion
        self.cursor = cursor
        cursorKind = cursor == nil ? nil : (kind ?? .legacy)
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
            // The only copy of a losing secure body can still live inside this live
            // envelope. A tombstone deliberately carries no content or arbitrary `x`,
            // so deleting now would discard that ciphertext. Hold the record until the
            // key-aware vault layer materialises or resolves every pending variant.
            if SyncMerge.hasUnresolvedContentConflict(known) { continue }
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
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, envelopes, recordVersions, cursor, cursorKind, journalEstablished
        case accountIdentity, datasetIdentity
        case requiresTransportFullResync, requiresNonDestructiveLibraryMerge
        case nonDestructiveMergeMode, preRecoveryConfirmedEnvelopes
        case nonDestructiveReviewID
    }

    init(from decoder: Decoder) throws {
        let allFields = try decoder.container(keyedBy: AnyCodingKey.self)
        let actual = Set(allFields.allKeys.map(\.stringValue))
        let expected = Set(CodingKeys.allCases.map(\.rawValue))
        guard actual.isSubset(of: expected) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath,
                      debugDescription: "unexpected sync-base fields"))
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard (1...SyncBase.currentSchemaVersion).contains(schemaVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "unsupported sync-base schema version")
        }
        cursor = try container.decodeIfPresent(SyncCursor.self, forKey: .cursor)
        if schemaVersion >= 3 {
            cursorKind = try container.decodeIfPresent(
                SyncCursorKind.self, forKey: .cursorKind)
            guard (cursor == nil) == (cursorKind == nil) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cursorKind,
                    in: container,
                    debugDescription: "sync cursor and cursor kind must be paired")
            }
        } else {
            guard !container.contains(.cursorKind) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .cursorKind,
                    in: container,
                    debugDescription: "sync cursor kind requires sync-base schema 3")
            }
            cursorKind = cursor == nil ? nil : .legacy
        }
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
        datasetIdentity = if container.contains(.datasetIdentity) {
            try container.decode(SyncDatasetIdentity.self, forKey: .datasetIdentity)
        } else {
            nil
        }
        if schemaVersion < 4, datasetIdentity != nil {
            throw DecodingError.dataCorruptedError(
                forKey: .datasetIdentity,
                in: container,
                debugDescription: "sync dataset identity requires sync-base schema 4")
        }
        requiresTransportFullResync = if container.contains(.requiresTransportFullResync) {
            try container.decode(Bool.self, forKey: .requiresTransportFullResync)
        } else {
            false
        }
        if schemaVersion < 3, requiresTransportFullResync {
            throw DecodingError.dataCorruptedError(
                forKey: .requiresTransportFullResync,
                in: container,
                debugDescription: "transport full-resync marker requires sync-base schema 3")
        }
        let containsLibraryRecoveryMarker = container.contains(
            .requiresNonDestructiveLibraryMerge)
        if schemaVersion >= 4, !containsLibraryRecoveryMarker {
            throw DecodingError.keyNotFound(
                CodingKeys.requiresNonDestructiveLibraryMerge,
                .init(
                    codingPath: container.codingPath,
                    debugDescription: "sync-base schema 4 requires the library-recovery fence"))
        }
        requiresNonDestructiveLibraryMerge = if containsLibraryRecoveryMarker {
            try container.decode(Bool.self, forKey: .requiresNonDestructiveLibraryMerge)
        } else {
            false
        }
        if schemaVersion < 4, requiresNonDestructiveLibraryMerge {
            throw DecodingError.dataCorruptedError(
                forKey: .requiresNonDestructiveLibraryMerge,
                in: container,
                debugDescription: "library-recovery marker requires sync-base schema 4")
        }
        if schemaVersion >= 5 {
            let containsMode = container.contains(.nonDestructiveMergeMode)
            guard containsMode == requiresNonDestructiveLibraryMerge else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nonDestructiveMergeMode,
                    in: container,
                    debugDescription: "sync-base recovery mode must match its merge fence")
            }
            nonDestructiveMergeMode = containsMode
                ? try container.decode(
                    NonDestructiveMergeMode.self, forKey: .nonDestructiveMergeMode)
                : nil
        } else {
            guard !container.contains(.nonDestructiveMergeMode) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nonDestructiveMergeMode,
                    in: container,
                    debugDescription: "sync-base recovery mode requires schema 5")
            }
            nonDestructiveMergeMode = requiresNonDestructiveLibraryMerge
                ? .incompletePrimary
                : nil
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

        if schemaVersion >= 6, container.contains(.preRecoveryConfirmedEnvelopes) {
            guard requiresNonDestructiveLibraryMerge,
                  nonDestructiveMergeMode == .reviewedLocalSnapshot else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preRecoveryConfirmedEnvelopes,
                    in: container,
                    debugDescription: "pre-recovery ancestor requires reviewed recovery")
            }
            let rawPreRecovery = try container.decode(
                [String: String].self, forKey: .preRecoveryConfirmedEnvelopes)
            var decodedPreRecovery: [String: SyncEnvelope] = [:]
            for (key, text) in rawPreRecovery {
                guard let data = Data(base64Encoded: text),
                      let envelope = try? SyncEnvelope.parse(data),
                      SyncBase.key(envelope.id) == key else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .preRecoveryConfirmedEnvelopes,
                        in: container,
                        debugDescription: "invalid pre-recovery confirmed envelope")
                }
                decodedPreRecovery[key] = envelope
            }
            preRecoveryConfirmedEnvelopes = decodedPreRecovery
        } else {
            guard schemaVersion >= 6
                    || !container.contains(.preRecoveryConfirmedEnvelopes) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .preRecoveryConfirmedEnvelopes,
                    in: container,
                    debugDescription: "pre-recovery ancestor requires sync-base schema 6")
            }
            preRecoveryConfirmedEnvelopes = nil
        }

        if schemaVersion >= 7 {
            nonDestructiveReviewID = try container.decodeIfPresent(
                UUID.self, forKey: .nonDestructiveReviewID)
            let requiresReviewID = requiresNonDestructiveLibraryMerge
                && nonDestructiveMergeMode == .reviewedLocalSnapshot
            guard (nonDestructiveReviewID != nil) == requiresReviewID else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nonDestructiveReviewID,
                    in: container,
                    debugDescription: "sync-base review id must match reviewed recovery")
            }
        } else {
            guard !container.contains(.nonDestructiveReviewID) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .nonDestructiveReviewID,
                    in: container,
                    debugDescription: "review id requires sync-base schema 7")
            }
            nonDestructiveReviewID = nil
        }

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

    func encode(to encoder: Encoder) throws {
        guard (cursor == nil) == (cursorKind == nil) else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "sync cursor and cursor kind must be paired"))
        }
        if schemaVersion < 3, cursorKind != nil, cursorKind != .legacy {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "CKSyncEngine cursor requires sync-base schema 3"))
        }
        guard (nonDestructiveMergeMode != nil) == requiresNonDestructiveLibraryMerge else {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "sync recovery mode must match its merge fence"))
        }
        if schemaVersion < 5, nonDestructiveMergeMode == .reviewedLocalSnapshot {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "reviewed local snapshot requires sync-base schema 5"))
        }
        if preRecoveryConfirmedEnvelopes != nil,
           (schemaVersion < 6 || !requiresNonDestructiveLibraryMerge
                || nonDestructiveMergeMode != .reviewedLocalSnapshot) {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "pre-recovery ancestor requires schema-6 reviewed recovery"))
        }
        let requiresReviewID = requiresNonDestructiveLibraryMerge
            && nonDestructiveMergeMode == .reviewedLocalSnapshot
        if schemaVersion >= 7 {
            guard (nonDestructiveReviewID != nil) == requiresReviewID else {
                throw EncodingError.invalidValue(
                    self,
                    .init(codingPath: encoder.codingPath,
                          debugDescription: "sync-base review id must match reviewed recovery"))
            }
        } else if nonDestructiveReviewID != nil {
            throw EncodingError.invalidValue(
                self,
                .init(codingPath: encoder.codingPath,
                      debugDescription: "review id requires sync-base schema 7"))
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encodeIfPresent(cursor, forKey: .cursor)
        if schemaVersion >= 3 {
            try container.encodeIfPresent(cursorKind, forKey: .cursorKind)
        }
        try container.encode(journalEstablished, forKey: .journalEstablished)
        try container.encodeIfPresent(accountIdentity, forKey: .accountIdentity)
        if schemaVersion >= 4 {
            try container.encodeIfPresent(datasetIdentity, forKey: .datasetIdentity)
        }
        if schemaVersion >= 3 {
            try container.encode(requiresTransportFullResync,
                                 forKey: .requiresTransportFullResync)
        }
        if schemaVersion >= 4 {
            try container.encode(requiresNonDestructiveLibraryMerge,
                                 forKey: .requiresNonDestructiveLibraryMerge)
        }
        if schemaVersion >= 5 {
            try container.encodeIfPresent(
                nonDestructiveMergeMode, forKey: .nonDestructiveMergeMode)
        }
        if schemaVersion >= 7 {
            try container.encodeIfPresent(
                nonDestructiveReviewID, forKey: .nonDestructiveReviewID)
        }
        var raw: [String: String] = [:]
        for (key, envelope) in envelopes {
            raw[key] = try envelope.canonicalData().base64EncodedString()
        }
        try container.encode(raw, forKey: .envelopes)
        if schemaVersion >= 6, let preRecoveryConfirmedEnvelopes {
            var rawPreRecovery: [String: String] = [:]
            for (key, envelope) in preRecoveryConfirmedEnvelopes {
                rawPreRecovery[key] = try envelope.canonicalData().base64EncodedString()
            }
            try container.encode(
                rawPreRecovery, forKey: .preRecoveryConfirmedEnvelopes)
        }
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
