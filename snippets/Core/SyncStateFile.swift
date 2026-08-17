import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.

/// A user-visible way out of a sync safety condition.
///
/// Keeping this vocabulary in Core makes recovery an explicit, validated operation
/// rather than letting each UI translate every stop into the same unsafe "Resume".
nonisolated enum SyncRecoveryAction: Equatable, Sendable {
    case applyRemoteDeletions
    /// A schema-3 halt written before exact deletion fingerprints shipped cannot safely
    /// authorize anything. Clear it for one fetch so the engine can persist the exact
    /// batch, then ask for confirmation against those facts.
    case refreshDeletionReview
    case useCurrentAccount
    case repairCheckpoint
    case restoreCloudFromThisDevice
    /// Clears only an orphaned cross-process attempt claim. The underlying safety halt
    /// remains and its original action must be reviewed and confirmed again.
    case reclaimRecovery
    case retrySync
    case checkAgain

    var buttonTitle: String {
        switch self {
        case .applyRemoteDeletions: "Confirm Deletions"
        case .refreshDeletionReview: "Refresh Deletion Details"
        case .useCurrentAccount: "Review Account Change"
        case .repairCheckpoint: "Repair Sync"
        case .restoreCloudFromThisDevice: "Restore Cloud Library"
        case .reclaimRecovery: "Take Over Recovery"
        case .retrySync: "Try Again"
        case .checkAgain: "Check Again"
        }
    }

    var compactButtonTitle: String {
        switch self {
        case .applyRemoteDeletions: "Confirm"
        case .refreshDeletionReview: "Refresh"
        case .useCurrentAccount: "Review"
        case .repairCheckpoint: "Repair"
        case .restoreCloudFromThisDevice: "Restore"
        case .reclaimRecovery: "Take Over"
        case .retrySync: "Retry"
        case .checkAgain: "Check"
        }
    }

    var confirmationTitle: String? {
        switch self {
        case .applyRemoteDeletions: "Apply These Deletions?"
        case .useCurrentAccount: "Use the Current Cloud Account?"
        case .repairCheckpoint: nil
        case .restoreCloudFromThisDevice: "Restore Cloud from This Device?"
        case .reclaimRecovery: "Take Over Interrupted Recovery?"
        case .refreshDeletionReview, .retrySync, .checkAgain: nil
        }
    }

    var confirmationButtonTitle: String? {
        switch self {
        case .applyRemoteDeletions: "Apply Deletions"
        case .useCurrentAccount: "Use This Account"
        case .repairCheckpoint: nil
        case .restoreCloudFromThisDevice: "Restore from This Device"
        case .reclaimRecovery: "Take Over"
        case .refreshDeletionReview, .retrySync, .checkAgain: nil
        }
    }

    /// What the action will do. Settings shows this before a tap; confirmation alerts
    /// repeat it only for actions that cross a consequential trust boundary.
    var explanation: String {
        switch self {
        case .applyRemoteDeletions:
            "This authorizes the exact deletion batch described above and lets sync finish it. "
                + "If an earlier confirmed attempt was interrupted, some records may already "
                + "have been applied. Continue only if the deletion was intentional."
        case .refreshDeletionReview:
            "Fetch this deletion batch again so Snippets can bind a later confirmation "
                + "to the exact records. This check does not delete anything."
        case .useCurrentAccount:
            "This keeps the library on this device, replaces the old account checkpoint, "
                + "and merges it into the cloud account signed in now. If you did not intend "
                + "to switch accounts, cancel and sign back in to the previous account."
        case .repairCheckpoint:
            "This keeps every local snippet, replaces only the unreadable sync scheduler "
                + "checkpoint, and performs a full merge with the cloud library."
        case .restoreCloudFromThisDevice:
            "The remote library was reset. This makes the current library on this device "
                + "the recovery source and uploads it through a fresh cloud checkpoint. "
                + "Use the device with the most complete library."
        case .reclaimRecovery:
            "This clears only the ownership claim left by an interrupted recovery on "
                + "another process or Mac. It does not apply deletions, change accounts, "
                + "or restore cloud data. Close Snippets on the other device first. "
                + "After takeover, review and confirm the original action again."
        case .retrySync:
            "Try syncing again after correcting the condition described above."
        case .checkAgain:
            "Check the local files again. Sync remains stopped if the condition is still present."
        }
    }

    var isDestructiveConfirmation: Bool {
        self == .applyRemoteDeletions
    }
}

/// Everything about *this device's* relationship to the library that is not the
/// library itself: who we are, what clock we are on, which bytes we last saw, and
/// whether sync has halted.
///
/// None of this is user data. Deleting `Sync/state.json` costs a new device identity
/// and one full reconcile. A primary-library quarantine is also fenced independently
/// by `Sync/library-quarantine`, so losing this file cannot reinterpret preserved data
/// as a fresh empty library.
nonisolated struct SyncState: Codable, Equatable {

    /// Schema 4 adds the durable primary-library quarantine marker. Schema 5 adds the
    /// atomic reviewed-action claim. The bump is load-bearing: a schema-4 build would
    /// ignore that optional claim and could execute the same destructive review twice.
    static let currentSchemaVersion = 5

    /// Why sync stopped and refuses to resume without the user looking at it.
    ///
    /// Safety reasons are sticky unless their case documentation says it exists only
    /// to decode a legacy stop. Live backend/authentication failures use the separate
    /// non-persisted needs-attention state: no data decision is involved there. A
    /// persisted mass deletion or integrity failure never auto-heals, because doing so
    /// would mean deleting or trusting the value that just failed validation.
    enum HaltReason: String, Codable {
        /// The remote asked us to delete more than the deletion guard allows.
        case massDeletion
        /// The backend refused a record and will keep refusing it: the container's
        /// schema, the account's quota, the size of one record, a missing entitlement.
        ///
        /// Nothing is wrong with anybody's data, which is exactly why this is separate
        /// from `manifestIntegrityFailed`. New refusals are a non-persisted
        /// `needsAttention` state: the user may safely retry after fixing schema, quota,
        /// entitlement, or record size. This case remains decodable only for sticky
        /// halts written by older builds, and offers a one-time Try Again migration path.
        case backendRefused
        /// The confirmed cursor/system fields belong to another (or, for a legacy
        /// checkpoint, an unknown) cloud account. Continuing would either mix private
        /// libraries or silently suppress every local record as already agreed.
        case accountChanged
        /// Authenticated local CKSyncEngine state is missing, corrupt, or incompatible.
        case checkpointUnreadable
        /// The backend physically reset or purged encrypted data.
        case remoteDataReset
        /// The manifest HMAC did not match — the backend was rolled back, truncated,
        /// or tampered with.
        ///
        /// **Nothing raises this today**, and the honest reading is that it never did:
        /// there is no manifest in this codebase, and until `backendRefused` existed
        /// this case was serving as the catch-all for every non-retryable rejection.
        /// Kept rather than deleted so a `state.json` halted by an older build still
        /// decodes — dropping the case would make that file unreadable, and an
        /// unreadable state file is regenerated fresh, which would silently clear a
        /// sticky halt. Reserved for the integrity check it names, if that is ever built.
        case manifestIntegrityFailed
        /// `snippets.json` was unreadable and had to be quarantined. Pushing now
        /// would propagate the damage to every other device.
        case localLibraryQuarantined
        /// `Vault/vault.json` was unreadable. Secure records must not be touched.
        case vaultUnreadable
        /// The file was written by a newer build. Pull and display, never push.
        case schemaTooNew

        /// What the pane calls this, in words rather than a case name.
        ///
        /// The settings pane used to interpolate the enum straight into a sentence, so a
        /// user read "Stopped for safety (manifestIntegrityFailed)". Naming the thing is
        /// the least a sticky halt can do for the person it is asking to look.
        var title: String {
            switch self {
            case .massDeletion: return "an unusually large deletion arrived"
            case .backendRefused: return "the cloud service refused a snippet"
            case .accountChanged: return "the cloud account changed"
            case .checkpointUnreadable: return "the local sync checkpoint could not be read"
            case .remoteDataReset: return "the remote cloud library was reset"
            case .manifestIntegrityFailed: return "the backend failed an integrity check"
            case .localLibraryQuarantined: return "the snippet library could not be read"
            case .vaultUnreadable: return "the secure vault could not be read"
            case .schemaTooNew: return "a newer version of Snippets wrote this library"
            }
        }

        /// Where to look. Deliberately a list of causes rather than a guess at which one:
        /// the backend hands back its own wording in `Halt.detail`, and inventing a
        /// diagnosis on top of that would eventually be confidently wrong.
        var guidance: String? {
            switch self {
            case .backendRefused:
                return "Usually the cloud service is not configured for this app, the "
                    + "account is out of space, or one snippet is too "
                    + "large. None of them is fixed by waiting."
            case .accountChanged:
                return "If you intended to switch accounts, review the account change. "
                    + "Snippets can keep this device's current library and merge it into "
                    + "the newly signed-in account from a fresh checkpoint."
            case .checkpointUnreadable:
                return "Repair keeps this device's current library, replaces only the "
                    + "unreadable local scheduler checkpoint, and performs a full merge."
            case .remoteDataReset:
                return "No local data was deleted or re-uploaded. Choose Restore only on "
                    + "the device whose current library should repopulate the cloud."
            case .massDeletion:
                return "Review the deletion count before applying it on this device."
            case .schemaTooNew:
                return "Update Snippets on this device."
            case .localLibraryQuarantined:
                return "Restore a valid exported library or quarantined backup, reopen "
                    + "Snippets, then choose Check Again. Snippets will not treat the "
                    + "missing library as an empty one."
            case .vaultUnreadable:
                return "Restore or repair the secure vault, then choose Check Again."
            case .manifestIntegrityFailed:
                return nil
            }
        }

        var recoveryAction: SyncRecoveryAction? {
            switch self {
            case .massDeletion: .applyRemoteDeletions
            case .accountChanged: .useCurrentAccount
            case .checkpointUnreadable: .repairCheckpoint
            case .remoteDataReset: .restoreCloudFromThisDevice
            case .backendRefused: .retrySync
            case .manifestIntegrityFailed, .localLibraryQuarantined, .vaultUnreadable:
                .checkAgain
            case .schemaTooNew: nil
            }
        }
    }

    struct Halt: Codable, Equatable {
        /// Atomic ownership of one reviewed mutation attempt. The claim is written by
        /// compare-and-swap before any transport reset or destructive apply begins.
        /// A second engine therefore observes a different Halt and cannot mint the
        /// same one-shot authority. Process identity makes a claim recoverable after
        /// its owner dies without letting another live window steal it.
        struct RecoveryClaim: Codable, Equatable {
            var id: UUID
            var ownerID: UUID
            var hostName: String
            var processID: Int32
            var processGenerationSeconds: UInt64?
            var processGenerationMicroseconds: UInt64?
        }

        enum RecoveryContext: Codable, Equatable {
            case massDeletion(
                liveCount: Int,
                requestedDeletions: Int,
                batchFingerprint: String)
            /// The unreadable primary was moved aside only after this marker became
            /// durable. Its absence must never be interpreted as an empty library.
            case localLibraryQuarantine
        }

        var reason: HaltReason
        var detail: String
        var at: Date
        /// Binds a confirmation to the facts shown to the user and an opaque fingerprint
        /// of the exact deletion set. It never contains snippet identifiers or content
        /// and is optional for schema-3 files written before typed recovery shipped.
        var recoveryContext: RecoveryContext? = nil
        /// Present only while one engine owns the reviewed mutation attempt. It is a
        /// restart fence, not reusable approval: an abandoned claim must be replaced
        /// by another explicit action using CAS before work can resume.
        var recoveryClaim: RecoveryClaim? = nil
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

/// Durable, state-file-independent evidence for a primary library quarantine.
///
/// Its existence is the quarantine fact; its random UUID also identifies this recovery
/// transaction. It is written and directory-synced before unreadable `snippets.json`
/// bytes move aside, then removed only after `base.json` owns the same review identity.
nonisolated enum LibraryQuarantineMarker {
    static func url(beside stateURL: URL) -> URL {
        stateURL.deletingLastPathComponent()
            .appendingPathComponent("library-quarantine", isDirectory: false)
    }

    static func exists(at url: URL = SnippetStorageLocations.libraryQuarantineMarkerURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    @discardableResult
    static func write(
        reviewID requestedReviewID: UUID? = nil,
        to url: URL = SnippetStorageLocations.libraryQuarantineMarkerURL,
        temporaryDirectory: URL = SnippetStorageLocations.tmpFolderURL
    ) throws -> UUID {
        if let existing = reviewID(at: url) { return existing }
        let identity = requestedReviewID ?? UUID()
        try AtomicFileWriter.write(
            Data((identity.uuidString.lowercased() + "\n").utf8),
            to: url,
            temporaryDirectory: temporaryDirectory)
        return identity
    }

    static func reviewID(
        at url: URL = SnippetStorageLocations.libraryQuarantineMarkerURL
    ) -> UUID? {
        guard let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              let identity = UUID(uuidString: raw),
              identity.uuidString.lowercased() == raw.lowercased() else { return nil }
        return identity
    }

    static func removeDurably(
        at url: URL = SnippetStorageLocations.libraryQuarantineMarkerURL
    ) throws {
        try AtomicFileWriter.removeDurablyIfPresent(url)
    }
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
        var state = state
        state.schemaVersion = SyncState.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFileWriter.write(encoder.encode(state), to: url, temporaryDirectory: temporaryDirectory)
    }
}
