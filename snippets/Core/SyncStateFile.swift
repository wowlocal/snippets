import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// Everything about *this device's* relationship to the library that is not the
/// library itself: who we are, what clock we are on, which bytes we last saw, and
/// whether sync has halted.
///
/// None of this is user data. Deleting `Sync/state.json` costs a new device
/// identity and one full reconcile; it can never lose a snippet.
nonisolated struct SyncState: Codable, Equatable {

    static let currentSchemaVersion = 1

    /// Why sync stopped and refuses to resume without the user looking at it.
    ///
    /// Every one of these is *sticky*. A halted sync never auto-heals, because every
    /// condition below is one where the safe move is to stop touching data and the
    /// unsafe move is to guess. Auto-healing a mass deletion means deleting; auto-
    /// healing an integrity failure means trusting the thing that just failed.
    enum HaltReason: String, Codable {
        /// The remote asked us to delete more than the deletion guard allows.
        case massDeletion
        /// The manifest HMAC did not match — the backend was rolled back, truncated,
        /// or tampered with.
        case manifestIntegrityFailed
        /// `snippets.json` was unreadable and had to be quarantined. Pushing now
        /// would propagate the damage to every other device.
        case localLibraryQuarantined
        /// `Vault/vault.json` was unreadable. Secure records must not be touched.
        case vaultUnreadable
        /// The file was written by a newer build. Pull and display, never push.
        case schemaTooNew

        var isUserRecoverable: Bool {
            switch self {
            case .massDeletion, .manifestIntegrityFailed, .localLibraryQuarantined, .vaultUnreadable:
                return true
            case .schemaTooNew:
                return false
            }
        }
    }

    struct Halt: Codable, Equatable {
        var reason: HaltReason
        var detail: String
        var at: Date
    }

    /// Which backend this device syncs through. `none` is the shipped default: the
    /// concurrency and merge work below is valuable with no network at all.
    enum Backend: String, Codable {
        case none, icloud, s3, http
    }

    var schemaVersion: Int
    /// Eight hex characters, generated once per install.
    var deviceID: String
    /// The highest clock reading this device has issued or adopted.
    var hlc: HLC
    /// Bumped by every cooperating writer. A gap means somebody wrote without
    /// participating — an old app build, a stale CLI, `vim`.
    var generation: UInt64
    /// SHA-256 of the `snippets.json` bytes that produced `generation`.
    var librarySHA256: String?
    /// Scopes the wire *protocol* — which library this device is talking about.
    ///
    /// **Never use this as crypto scope.** It lives in a file that regenerates itself
    /// whenever it cannot be read (see `fresh`), so binding ciphertext to it would
    /// destroy every secure snippet the first time this file went missing. The crypto
    /// scope is `VaultDocument.kid`, which lives in the same file as the records it
    /// protects. See `SnippetCrypto.RecordContext.scopeID`.
    var scopeID: String
    var backend: Backend
    var cursor: String?
    var lastSyncAt: Date?
    var halt: Halt?
    /// Set for the duration of a promote/demote, so a crash mid-move is repairable
    /// at the next launch rather than silently duplicating or dropping a record.
    var promoting: UUID?
    var demoting: UUID?

    static func fresh(deviceID: String = HLC.makeDeviceID(), now: Date = Date()) -> SyncState {
        SyncState(
            schemaVersion: currentSchemaVersion,
            deviceID: deviceID,
            hlc: HLC(wallMs: now.millisecondsSince1970, counter: 0, device: deviceID),
            generation: 0,
            librarySHA256: nil,
            scopeID: UUID().uuidString.lowercased(),
            backend: .none,
            cursor: nil,
            lastSyncAt: nil,
            halt: nil,
            promoting: nil,
            demoting: nil
        )
    }
}

/// Reads a file's `schemaVersion` without decoding the rest of it.
///
/// The probe runs first, and it exists because decoding a *future* format may fail
/// outright. When it does, the failure has to land in "this build is too old, run
/// read-only" and not in "the file is corrupt, start fresh" — otherwise an older
/// build silently overwrites a newer build's state. Debug and release share this
/// directory, because the app cannot be sandboxed, so this is a routine scenario
/// rather than a hypothetical one. `SnippetUsageStore.loadSynchronously()` learned
/// this the same way.
nonisolated struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int?
}

nonisolated enum SyncStateFile {

    enum Outcome {
        case loaded(SyncState)
        /// The file was written by a newer build. Callers must not write it back.
        case tooNew(version: Int)
        /// No file yet, or one we could not make sense of. Either way a fresh state
        /// is correct: it holds no user data.
        case fresh(SyncState)
    }

    static func load(
        from url: URL = SnippetStorageLocations.syncStateFileURL,
        makeFresh: () -> SyncState = { SyncState.fresh() }
    ) -> Outcome {
        guard let data = try? Data(contentsOf: url) else { return .fresh(makeFresh()) }

        if let probe = try? JSONDecoder().decode(SchemaVersionProbe.self, from: data),
           let version = probe.schemaVersion,
           version > SyncState.currentSchemaVersion {
            return .tooNew(version: version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(SyncState.self, from: data) else {
            return .fresh(makeFresh())
        }
        return .loaded(state)
    }

    /// `temporaryDirectory` must travel with `url`. Staging is not a tidiness
    /// preference: `AtomicFileWriter` falls back to `Data.write(.atomic)` when
    /// `rename(2)` returns EXDEV, and that fallback stages *inside the destination
    /// directory* — the one thing nothing may do to the monitored folder. Defaulting
    /// this to the real `Tmp/` while `url` points somewhere else is how a state file
    /// on another volume, a CLI aimed at an alternate library root, or a test ends up
    /// writing into `~/Library/Application Support/SnippetsClone` regardless.
    static func write(
        _ state: SyncState,
        to url: URL = SnippetStorageLocations.syncStateFileURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(encoder.encode(state), to: url, temporaryDirectory: temporaryDirectory)
    }
}
