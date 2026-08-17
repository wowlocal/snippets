import Darwin
import Foundation

/// An immutable persistence transaction captured from `SnippetStore` on MainActor.
///
/// The worker must never reach back into the store: a write can outlive the debounce
/// that created it, and waiting for a worker that in turn needs MainActor deadlocks
/// backgrounding and termination. Everything the locked read/merge/write needs is
/// therefore carried by value here.
nonisolated struct SnippetPersistenceRequest: Sendable {
    enum Disposition: Equatable, Sendable {
        case merge
        /// A full-file recovery candidate explicitly chosen while the primary is
        /// quarantined. The selected file is the complete replacement, not one side
        /// of a three-way merge with unreadable or superseded bytes.
        case authoritativeReplacement
    }

    let id: UInt64
    let stateVersion: UInt64
    let diskObservationVersion: UInt64
    let local: [Snippet]
    let ancestorData: Data?
    let expectedDigest: String?
    let libraryURL: URL
    let stateURL: URL
    let lockURL: URL
    let temporaryDirectory: URL
    let lockTimeout: TimeInterval
    let disposition: Disposition
}

nonisolated struct SnippetPersistenceSuccess: Sendable {
    let snippets: [Snippet]
    let data: Data
    let digest: String
    let foldedInForeignWrite: Bool
    let wroteWithoutLock: Bool
    let attempts: Int
    let merge: SyncMerge.Outcome?
    let recreatedMissingFile: Bool
}

nonisolated enum SnippetPersistenceFailure: Sendable {
    case busy
    case other(DiagnosticFailure)
}

nonisolated enum SnippetPersistenceResult: Sendable {
    case success(SnippetPersistenceSuccess)
    case failure(SnippetPersistenceFailure)
}

/// A one-shot, thread-safe result inbox.
///
/// An asynchronous completion normally applies this on MainActor. An immediate write
/// or lifecycle flush can instead wait for the same inbox and apply it synchronously;
/// the already-enqueued callback then observes that the store no longer owns this
/// operation and becomes a no-op. The worker never waits for MainActor.
nonisolated final class SnippetPersistenceOperation: @unchecked Sendable {
    let request: SnippetPersistenceRequest

    private let condition = NSCondition()
    private var storedResult: SnippetPersistenceResult?

    init(request: SnippetPersistenceRequest) {
        self.request = request
    }

    func finish(with result: SnippetPersistenceResult) {
        condition.lock()
        precondition(storedResult == nil, "A persistence operation may finish only once")
        storedResult = result
        condition.broadcast()
        condition.unlock()
    }

    func wait() -> SnippetPersistenceResult {
        condition.lock()
        while storedResult == nil {
            condition.wait()
        }
        let result = storedResult!
        condition.unlock()
        return result
    }

    func resultIfReady() -> SnippetPersistenceResult? {
        condition.lock()
        let result = storedResult
        condition.unlock()
        return result
    }
}

/// Serial executor for the heavyweight portion of library persistence.
///
/// Hooks are dependency-injection seams for deterministic concurrency tests. Shipping
/// callers use the empty defaults; no environment variable or global mutable test mode
/// can accidentally affect a real library.
nonisolated final class SnippetPersistenceWorker: @unchecked Sendable {
    struct Hooks: Sendable {
        var willPerform: (@Sendable (SnippetPersistenceRequest) -> Void)?
        var didPerform: (@Sendable (SnippetPersistenceRequest, SnippetPersistenceResult) -> Void)?
        var overrideResult: (@Sendable (SnippetPersistenceRequest) -> SnippetPersistenceResult?)?
        var willWaitForResult: (@Sendable () -> Void)?

        init(
            willPerform: (@Sendable (SnippetPersistenceRequest) -> Void)? = nil,
            didPerform: (@Sendable (SnippetPersistenceRequest, SnippetPersistenceResult) -> Void)? = nil,
            overrideResult: (@Sendable (SnippetPersistenceRequest) -> SnippetPersistenceResult?)? = nil,
            willWaitForResult: (@Sendable () -> Void)? = nil
        ) {
            self.willPerform = willPerform
            self.didPerform = didPerform
            self.overrideResult = overrideResult
            self.willWaitForResult = willWaitForResult
        }
    }

    private let queue: DispatchQueue
    private let hooks: Hooks

    init(
        label: String = "com.khm.snippets.persistence",
        hooks: Hooks = Hooks()
    ) {
        queue = DispatchQueue(label: label, qos: .utility)
        self.hooks = hooks
    }

    func submit(
        _ request: SnippetPersistenceRequest,
        completion: (@Sendable (SnippetPersistenceOperation) -> Void)? = nil
    ) -> SnippetPersistenceOperation {
        let operation = SnippetPersistenceOperation(request: request)
        queue.async { [hooks] in
            hooks.willPerform?(request)
            let result = hooks.overrideResult?(request) ?? Self.perform(request)
            hooks.didPerform?(request, result)
            operation.finish(with: result)
            guard let completion else { return }
            DispatchQueue.main.async {
                completion(operation)
            }
        }
        return operation
    }

    /// Waits behind the submitted operation on its own serial queue. `sync` donates
    /// the caller's QoS while a lifecycle/immediate path is blocked, avoiding a
    /// user-interactive MainActor waiting on an unboosted utility worker. The result
    /// itself was published before the queue block can finish, so no MainActor callback
    /// participates in this handoff.
    func wait(for operation: SnippetPersistenceOperation) -> SnippetPersistenceResult {
        hooks.willWaitForResult?()
        queue.sync {}
        return operation.wait()
    }

    private static func perform(_ request: SnippetPersistenceRequest) -> SnippetPersistenceResult {
        let ancestor = request.ancestorData.flatMap {
            try? SnippetLibraryCodec.decode($0)
        } ?? []
        var pendingMerge: SyncMerge.Outcome?
        var recreatedMissingFile = false

        do {
            let outcome: LibraryWriter.Outcome
            if request.disposition == .authoritativeReplacement {
                pendingMerge = nil
                recreatedMissingFile = false
                outcome = try LibraryWriter.replaceQuarantinedPrimary(
                    with: request.local,
                    libraryURL: request.libraryURL,
                    stateURL: request.stateURL,
                    lockURL: request.lockURL,
                    temporaryDirectory: request.temporaryDirectory,
                    lockTimeout: request.lockTimeout,
                    expectedDigest: request.expectedDigest)
            } else {
                outcome = try LibraryWriter.update(
                    libraryURL: request.libraryURL,
                    stateURL: request.stateURL,
                    lockURL: request.lockURL,
                    temporaryDirectory: request.temporaryDirectory,
                    lockTimeout: request.lockTimeout,
                    expectedDigest: request.expectedDigest
                ) { onDisk in
                    guard onDisk.digest != request.expectedDigest else {
                        pendingMerge = nil
                        recreatedMissingFile = false
                        return request.local
                    }

                    guard onDisk.fileExisted else {
                        pendingMerge = nil
                        recreatedMissingFile = request.expectedDigest != nil
                        return request.local
                    }

                    let merged = SyncMerge.mergeLocal(
                        base: ancestor,
                        local: request.local,
                        remote: onDisk.snippets
                    )
                    pendingMerge = merged
                    recreatedMissingFile = false
                    return merged.snippets
                }
            }

            return .success(SnippetPersistenceSuccess(
                snippets: outcome.snippets,
                data: outcome.data,
                digest: outcome.digest,
                foldedInForeignWrite: outcome.foldedInForeignWrite,
                wroteWithoutLock: outcome.wroteWithoutLock,
                attempts: outcome.attempts,
                merge: pendingMerge,
                recreatedMissingFile: recreatedMissingFile
            ))
        } catch {
            if let failure = error as? LibraryWriter.Failure,
               case .busy = failure {
                return .failure(.busy)
            }
            return .failure(.other(DiagnosticFailure(error)))
        }
    }
}

/// The second observer of library changes, alongside `SnippetStore.onChange`.
///
/// Two named channels rather than an observer registry: `onChange` is a
/// single-assignment slot owned by `ViewController`, and there will only ever be one
/// other listener — the sync engine. A dictionary of observers would be more general
/// and strictly harder to reason about at the exact moment reasoning matters, which
/// is when a remote change lands mid-edit.
@MainActor
protocol SnippetStoreSyncDelegate: AnyObject {
    func libraryDidChange(_ source: SnippetStore.ChangeSource)
}

@MainActor
final class SnippetStore {
    enum DurableSnapshotFailure: Error {
        case primaryLibraryWriteFailed
    }

    /// An opaque, process-local handle for restoring one specific deletion.
    ///
    /// Unlike the store's global undo stack, this token never represents a whole
    /// library snapshot. It is intended for transient UI affordances such as an
    /// "Undo delete" toast, where unrelated edits may happen before the user taps
    /// Undo and must remain intact.
    struct DeletionUndoToken: Hashable {
        fileprivate let operationID: UUID
    }

    struct Configuration {
        var seedsStarterSnippet: Bool
        var observesExternalChanges: Bool

        nonisolated static let macOSDefault = Configuration(
            seedsStarterSnippet: true,
            observesExternalChanges: true
        )
        /// Native iOS clients start empty and never watch a desktop filesystem.
        nonisolated static let iOS = Configuration(
            seedsStarterSnippet: false,
            observesExternalChanges: false
        )
    }

    nonisolated struct ImportOptions: Sendable {
        var preserveExclamationPrefix = false
    }

    enum ChangeSource {
        /// A mutation made through this in-process store.
        case local
        /// A mutation adopted from another local process or a filesystem writer.
        case external
        /// A mutation written by the active CloudKit round itself.
        case remoteSync
    }

    /// A process-local description of a published library mutation. `nil` means the
    /// publisher cannot identify the affected records and consumers must refresh
    /// conservatively; an empty set means the mutation is known not to affect any
    /// snippet currently represented by the store.
    struct Change {
        let source: ChangeSource
        let changedIDs: Set<UUID>?

        init(source: ChangeSource, changedIDs: Set<UUID>? = nil) {
            self.source = source
            self.changedIDs = changedIDs
        }

        func affects(_ id: UUID) -> Bool {
            changedIDs?.contains(id) ?? true
        }
    }

    private(set) var snippets: [Snippet] = []
    /// An unreadable primary library was preserved out of the data path. While true,
    /// ordinary persistence and sync must not turn its apparent absence into a new
    /// empty library. A full file import or a valid restored primary clears this
    /// process-local flag; the durable sync halt still requires Check Again.
    private(set) var isLibraryQuarantined = false

    var onChange: ((Change) -> Void)?
    weak var syncDelegate: SnippetStoreSyncDelegate?

    /// Vends content-free shells for the secure snippets held in `Vault/vault.json`.
    ///
    /// The two stores stay separate on disk and in memory; only the *display* and
    /// *uniqueness* views below merge them. `snippets` itself remains plaintext-only,
    /// which is what keeps export, the undo stack, and plaintext persistence structurally
    /// incapable of touching a secret.
    weak var secureProvider: SecureSnippetProviding?

    private let saveURL: URL
    private let saveFolderURL: URL
    private let encoder = JSONEncoder()
    private let persistenceWorker: SnippetPersistenceWorker
    private var persistWorkItem: DispatchWorkItem?
    private let persistDelay: TimeInterval
    private let persistenceRetryBaseDelay: TimeInterval
    private var inFlightWrite: SnippetPersistenceOperation?
    private var persistenceStateVersion: UInt64 = 0
    private var nextPersistenceRequestID: UInt64 = 0
    private var diskObservationVersion: UInt64 = 0
    private var needsPersistence = false
    private let externalReloadDelay: TimeInterval = 0.05
    private var externalReloadWorkItem: DispatchWorkItem?
    private var saveDirectoryMonitor: DispatchSourceFileSystemObject?
    #if os(macOS)
    private var distributedChangeObserver: NSObjectProtocol?
    #endif
    private var lastKnownDiskData: Data?

    /// SHA-256 of `lastKnownDiskData`. Kept alongside the bytes so the hot path can
    /// answer "did the file change under me?" without rehashing the whole library.
    private var lastKnownDigest: String?

    /// This install's eight-hex identity, from `Sync/state.json`.
    ///
    /// Not used by the merge — that tiebreak is symmetric and takes no identity. This
    /// is for sync bookkeeping (which device authored a change) and diagnostics.
    /// Regenerated if the state file is lost, which costs nothing.
    private(set) var deviceID: String = HLC.foreignDevice

    /// How long the writer has been unable to take the cross-process lock. Drives an
    /// escalating retry rather than a dropped write.
    private var lockFailureCount = 0

    /// How long to wait for the library lock on the ordinary debounced write path.
    ///
    /// Deliberately small even though polling now happens on the serial worker. The
    /// app holds the same cross-process lock as a CLI that gives up after five seconds;
    /// an ordinary edit should back off behind a stuck peer instead of occupying that
    /// worker indefinitely and delaying a lifecycle flush queued behind it.
    private let lockTimeout: TimeInterval = 0.25
    /// The terminate path has nothing left to reschedule onto, so it waits longer.
    private let terminateLockTimeout: TimeInterval = 5.0

    /// Bumped on every accepted mutation, local or remote. Lets an observer notice it
    /// is looking at stale state without diffing the whole array.
    private(set) var librarySeq: UInt64 = 0

    /// How well the last write went, beyond "it landed".
    ///
    /// Exists because both degraded modes were previously invisible: they were
    /// `NSLog`ged and nothing read them, so a user whose filesystem cannot lock would
    /// sit in a permanently lossy configuration with no signal at all. `.unlocked` in
    /// particular is not transient — it is every write, forever, for that user.
    ///
    /// The settings pane is not built yet, so nothing renders this today; the CLI
    /// warns on stderr in the meantime. Keeping the state here rather than only in the
    /// log is what makes surfacing it a UI change rather than an archaeology exercise.
    enum WriteHealth: Equatable {
        case healthy
        /// A peer wrote inside our critical section — the lock is not holding.
        case contended(attempts: Int)
        /// Neither `flock` nor the `link(2)` sentinel was available.
        case unlocked

        var isDegraded: Bool { self != .healthy }
    }

    private(set) var writeHealth: WriteHealth = .healthy

    private var undoStack: [[Snippet]] = []
    private var redoStack: [[Snippet]] = []
    private var editTransactionSnapshot: [Snippet]?
    private var editTransactionNeedsRestart = false
    private let maxUndoLevels = 50

    private struct PendingDeletionUndo {
        let snippet: Snippet
        let originalIndex: Int
    }
    private var pendingDeletionUndos: [UUID: PendingDeletionUndo] = [:]
    private var pendingDeletionUndoOrder: [UUID] = []
    private let maxPendingDeletionUndos = 50

    /// A snippet `addSnippet` created with nothing in it, remembered so a second
    /// ⌘N can reuse it and so leaving it can take it back out. Creation writes to
    /// disk before the first keystroke — that is what makes the editor bind to a
    /// real record at all — so removing it afterwards is the only way an
    /// abandoned one stays out of snippets.json.
    ///
    /// The undo entry the creation pushed is recorded with it. Popping that
    /// entry blind is not safe: `reloadFromDiskIfNeeded` clears the whole stack,
    /// and anything the user did since pushed on top of it, so the discard pops
    /// only while that exact entry is provably still the one on top.
    private struct BlankDraft {
        let id: UUID
        let undoDepth: Int
        let undoSnapshot: [Snippet]?
    }
    private var blankDraft: BlankDraft?
    private let configuration: Configuration

    enum ImportExportError: LocalizedError {
        case emptyImport
        case invalidFormat
        case cannotAccessFile
        case libraryRecoveryRequired
        case libraryRecoveryNoLongerRequired
        case importConflicts([String])

        var errorDescription: String? {
            switch self {
            case .emptyImport:
                return "The selected file does not contain any snippets."
            case .invalidFormat:
                return "Unsupported file format. Expected JSON exported from this app."
            case .cannotAccessFile:
                return "Could not read or write the selected file."
            case .libraryRecoveryRequired:
                return "Restore or import a valid snippet library, then confirm recovery in Sync settings before making changes."
            case .libraryRecoveryNoLongerRequired:
                return "The library no longer needs recovery. Import the file again to merge it normally."
            case .importConflicts(let conflicts):
                if conflicts.count == 1, let conflict = conflicts.first {
                    return "Import conflict: \(conflict)"
                }

                return "Import conflicts:\n" + conflicts.map { "- \($0)" }.joined(separator: "\n")
            }
        }
    }

    private struct SnippetCollection: Codable {
        let snippets: [Snippet]
    }

    init(
        configuration: Configuration = .macOSDefault,
        persistenceWorker: SnippetPersistenceWorker = SnippetPersistenceWorker(),
        persistDelay: TimeInterval = 0.3,
        persistenceRetryBaseDelay: TimeInterval = 0.25
    ) {
        self.configuration = configuration
        self.persistenceWorker = persistenceWorker
        self.persistDelay = persistDelay
        self.persistenceRetryBaseDelay = persistenceRetryBaseDelay
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let folder = SnippetStorageLocations.supportFolderURL
        // Every directory is created here, before the monitor goes up a few lines
        // below. Creating any of them later would mutate the watched folder's vnode
        // at an arbitrary moment and fire `scheduleExternalReload` for no reason —
        // the same trap the `Usage/` subdirectory comment describes.
        SnippetStorageLocations.createAllDirectories()
        saveFolderURL = folder
        saveURL = SnippetStorageLocations.snippetsFileURL

        adoptDeviceIdentity()
        seedFirstRunBackupIfNeeded()
        load()
        if configuration.observesExternalChanges {
            startObservingExternalChanges()
        }
    }

    /// Reads (or mints) this install's device id.
    ///
    /// Deliberately tolerant: if `state.json` is missing, unreadable, or from a newer
    /// build, we fall back to a fresh random id. The id only breaks exact merge ties,
    /// so a wrong one costs nothing, and refusing to launch over it would be absurd.
    private func adoptDeviceIdentity() {
        switch SyncStateFile.load() {
        case .loaded(let state):
            deviceID = state.deviceID
        case .fresh(let state):
            deviceID = state.deviceID
            try? SyncStateFile.write(state)
        case .tooNew(let version):
            // A newer build owns this directory. Do not write anything here; a random
            // id for this session is harmless.
            Diagnostics.record(.storageState(
                area: .syncState,
                state: .versionTooNew,
                value: version))
            deviceID = HLC.makeDeviceID()
        }
    }

    /// One byte-copy of the library, taken the first time a sync-capable build ever
    /// runs, before that build has written anything.
    ///
    /// The merge below is careful, but "careful" is not "proven on your machine with
    /// your data". This is the copy the user can be pointed at if anything about the
    /// new write path goes wrong, and it costs one file copy, once, ever.
    private func seedFirstRunBackupIfNeeded() {
        let fileManager = FileManager.default
        let backups = SnippetStorageLocations.backupsFolderURL
        let existing = (try? fileManager.contentsOfDirectory(atPath: backups.path)) ?? []
        guard !existing.contains(where: { $0.hasPrefix("pre-sync-") }) else { return }
        guard fileManager.fileExists(atPath: SnippetStorageLocations.snippetsFileURL.path) else { return }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let destination = backups.appendingPathComponent(
            "pre-sync-\(formatter.string(from: Date())).json", isDirectory: false)
        try? fileManager.copyItem(at: SnippetStorageLocations.snippetsFileURL, to: destination)
    }

    deinit {
        persistWorkItem?.cancel()
        externalReloadWorkItem?.cancel()
        saveDirectoryMonitor?.cancel()
        #if os(macOS)
        if let distributedChangeObserver {
            DistributedNotificationCenter.default().removeObserver(distributedChangeObserver)
        }
        #endif
    }

    /// `name` is set here rather than by a follow-up `update`: creation pushes
    /// one undo entry, and a second call to name the new snippet would push
    /// another, so one ⌘Z would clear the name and only a second would undo the
    /// creation the user actually asked to take back.
    func addSnippet(
        name: String = "",
        content: String = "",
        tags: [String] = []
    ) throws -> Snippet {
        guard !isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryRequired
        }
        pushUndo()
        let snippet = Snippet(name: name, keyword: "", content: content, tags: SnippetTagging.normalizedTags(tags))
        snippets.insert(snippet, at: 0)
        // Only a snippet created with nothing in it is a draft. One seeded from
        // the clipboard, a Service, a drop, a search query or a tag filter is
        // already carrying what the user asked to save, and is never taken back.
        blankDraft = snippet.isBlankDraft
            ? BlankDraft(id: snippet.id, undoDepth: undoStack.count, undoSnapshot: undoStack.last)
            : nil
        persist(immediately: true)
        return snippet
    }

    /// The open blank draft, for as long as it is still blank in every field the
    /// user can type into.
    ///
    /// Recomputed on every read rather than invalidated on edit: "blank" is a
    /// fact about the snippet, not a mode. A draft typed into and cleared again
    /// is blank once more, and — the part that matters — nothing holding text
    /// can ever be handed out here for discarding.
    var blankDraftSnippet: Snippet? {
        guard let blankDraft,
              let snippet = snippet(id: blankDraft.id),
              snippet.isBlankDraft else { return nil }
        return snippet
    }

    /// Removes the blank draft and the traces that would let it come back: the
    /// undo entry its creation pushed, every other entry still holding it, and an
    /// open edit transaction whose baseline still contains it —
    /// `commitEditTransaction` would push that baseline and one ⌘Z would
    /// resurrect the ghost.
    ///
    /// It pushes no undo entry of its own. A row the user never typed into is
    /// not a change worth being able to take back, and an entry for it would
    /// restore exactly what this removes.
    @discardableResult
    func discardBlankDraft(id: UUID) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let draft = blankDraft, draft.id == id else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == id }),
              snippets[index].isBlankDraft else {
            blankDraft = nil
            return false
        }

        blankDraft = nil
        snippets.remove(at: index)

        if undoStack.count == draft.undoDepth, undoStack.last == draft.undoSnapshot {
            undoStack.removeLast()
        }
        // Declining that pop is not the end of it. The creation's entry is
        // rarely the only one holding the draft by the time it is abandoned:
        // typing into it and clearing it again closes an edit transaction whose
        // baseline is a library that still contains it, and so does a single
        // click on Enabled. A row nobody typed into must not be restorable at
        // any depth, so it comes out of every level rather than only that one.
        eraseFromHistory(id: id)
        if editTransactionSnapshot?.contains(where: { $0.id == id }) == true {
            editTransactionSnapshot = nil
        }

        persist(immediately: true)
        return true
    }

    private func eraseFromHistory(id: UUID) {
        for index in undoStack.indices {
            undoStack[index].removeAll { $0.id == id }
        }
        for index in redoStack.indices {
            redoStack[index].removeAll { $0.id == id }
        }
        undoStack = withoutDeadLevels(undoStack)
        redoStack = withoutDeadLevels(redoStack)
    }

    /// `stack` with every level that erasing the draft turned into a copy of the
    /// state it would be reached from removed. Restoring a state identical to
    /// the current one moves nothing on screen while still announcing "Undid
    /// last change.", so leaving those in place would make the user press ⌘Z
    /// past one dead level per snapshot the draft appeared in before reaching
    /// the change they meant to take back.
    private func withoutDeadLevels(_ stack: [[Snippet]]) -> [[Snippet]] {
        var kept: [[Snippet]] = []
        var successor = snippets
        for level in stack.reversed() where level != successor {
            kept.append(level)
            successor = level
        }
        return kept.reversed()
    }

    @discardableResult
    func update(_ snippet: Snippet) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else {
            return false
        }
        let existing = snippets[index]

        var updated = snippet
        updated.keyword = updated.normalizedKeyword
        updated.tags = SnippetTagging.normalizedTags(updated.tags)

        let didChange =
            existing.name != updated.name ||
            existing.keyword != updated.keyword ||
            existing.content != updated.content ||
            existing.tags != updated.tags ||
            existing.isEnabled != updated.isEnabled ||
            existing.isPinned != updated.isPinned

        guard didChange else { return false }

        if editTransactionSnapshot == nil {
            pushUndo()
        } else {
            redoStack.removeAll()
        }

        updated.updatedAt = Date()
        snippets[index] = updated
        persist()
        return true
    }

    @discardableResult
    func delete(snippetID: UUID) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard snippets.contains(where: { $0.id == snippetID }) else { return false }
        pushUndo()
        snippets.removeAll { $0.id == snippetID }
        persist(immediately: true)
        return true
    }

    /// Deletes one snippet and returns a one-use handle that can restore only that
    /// record. This is deliberately separate from `undo()`: restoring the token
    /// after another snippet was edited, pinned, imported, or deleted preserves all
    /// of those intervening changes.
    ///
    /// The normal global undo entry is still recorded, so keyboard-oriented clients
    /// retain their existing undo/redo behaviour.
    @discardableResult
    func deleteForUndo(snippetID: UUID) -> DeletionUndoToken? {
        guard !isLibraryQuarantined else { return nil }
        guard let originalIndex = snippets.firstIndex(where: { $0.id == snippetID }) else {
            return nil
        }

        // At most one live scoped deletion can refer to a record. A stale toast from
        // an earlier delete/restore/delete sequence must not resurrect an older copy.
        invalidatePendingDeletionUndos(for: snippetID)

        pushUndo()
        let deleted = snippets.remove(at: originalIndex)
        let token = DeletionUndoToken(operationID: UUID())
        pendingDeletionUndos[token.operationID] = PendingDeletionUndo(
            snippet: deleted,
            originalIndex: originalIndex
        )
        pendingDeletionUndoOrder.append(token.operationID)
        trimPendingDeletionUndosIfNeeded()
        persist(immediately: true)
        return token
    }

    /// Restores the record represented by `token` into the current library without
    /// rolling back any intervening mutations. The token is consumed before any
    /// validation or mutation, so every call after the first is a no-op.
    @discardableResult
    func restoreDeletedSnippet(using token: DeletionUndoToken) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let pending = consumePendingDeletionUndo(token.operationID) else {
            return false
        }

        // A global undo, import, or remote merge may already have restored this ID.
        // Consuming the token and leaving that current record untouched is safer than
        // replacing newer data with the transient deletion snapshot.
        guard !snippets.contains(where: { $0.id == pending.snippet.id }) else {
            return false
        }

        pushUndo()
        snippets.insert(pending.snippet, at: min(pending.originalIndex, snippets.count))
        persist(immediately: true)
        return true
    }

    private func consumePendingDeletionUndo(_ operationID: UUID) -> PendingDeletionUndo? {
        pendingDeletionUndoOrder.removeAll { $0 == operationID }
        return pendingDeletionUndos.removeValue(forKey: operationID)
    }

    private func invalidatePendingDeletionUndos(for snippetID: UUID) {
        let operationIDs = pendingDeletionUndos.compactMap { operationID, pending in
            pending.snippet.id == snippetID ? operationID : nil
        }
        guard !operationIDs.isEmpty else { return }

        let invalidated = Set(operationIDs)
        pendingDeletionUndoOrder.removeAll { invalidated.contains($0) }
        for operationID in operationIDs {
            pendingDeletionUndos.removeValue(forKey: operationID)
        }
    }

    private func trimPendingDeletionUndosIfNeeded() {
        while pendingDeletionUndoOrder.count > maxPendingDeletionUndos {
            let operationID = pendingDeletionUndoOrder.removeFirst()
            pendingDeletionUndos.removeValue(forKey: operationID)
        }
    }

    @discardableResult
    func duplicate(snippetID: UUID) -> Snippet? {
        guard !isLibraryQuarantined else { return nil }
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return nil }
        pushUndo()

        let source = snippets[index]
        let shouldDisableDuplicate = source.isEnabled && !source.normalizedKeyword.isEmpty
        // Derived from `name`, never from `displayName`: an unnamed snippet shows
        // its first line of content, and freezing that into the stored name would
        // stop the copy tracking its own content forever. An empty name stays
        // empty for the same reason — " Copy" on its own is not a name.
        let sourceName = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let duplicate = Snippet(
            name: sourceName.isEmpty ? "" : sourceName + " Copy",
            keyword: source.normalizedKeyword,
            content: source.content,
            tags: source.tags,
            isEnabled: shouldDisableDuplicate ? false : source.isEnabled,
            isPinned: source.isPinned
        )
        snippets.insert(duplicate, at: index + 1)
        persist(immediately: true)
        return duplicate
    }

    @discardableResult
    func togglePinned(snippetID: UUID) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return false }
        pushUndo()
        snippets[index].isPinned.toggle()
        snippets[index].updatedAt = Date()
        persist(immediately: true)
        return true
    }

    @discardableResult
    func toggleEnabled(snippetID: UUID) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return false }
        pushUndo()
        snippets[index].isEnabled.toggle()
        snippets[index].updatedAt = Date()
        persist(immediately: true)
        return true
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    /// Resolves a row in the merged UI without weakening `snippet(id:)`'s plaintext-only
    /// contract. Secure records are represented by content-free shells, so callers that
    /// only need selection and metadata can address them while export, expansion, undo,
    /// and other plaintext paths continue to see only `snippets`.
    func snippetForDisplay(id: UUID) -> Snippet? {
        snippet(id: id)
            ?? secureProvider?.secureShellsForDisplay().first { $0.id == id }
    }

    /// All distinct tags across snippets, deduped case-insensitively and
    /// sorted alphabetically for stable filter/completion UI.
    func allTags() -> [String] {
        tagUsage().map(\.tag)
    }

    /// Distinct tags with the number of snippets using each, sorted alphabetically.
    func tagUsage() -> [(tag: String, count: Int)] {
        var canonicalTags: [String: String] = [:]
        var counts: [String: Int] = [:]

        // Both stores: a tag used only by secure snippets must still appear in the
        // filter bar, or filtering by it would show an empty list.
        for snippet in snippets + (secureProvider?.secureShellsForDisplay() ?? []) {
            for tag in snippet.tags {
                let key = SnippetTagging.filterKey(for: tag)
                if canonicalTags[key] == nil {
                    canonicalTags[key] = tag
                }
                counts[key, default: 0] += 1
            }
        }

        return canonicalTags
            .sorted { $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending }
            .map { (tag: $0.value, count: counts[$0.key] ?? 0) }
    }

    @discardableResult
    func toggleTag(_ tag: String, snippetID: UUID) -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return false }
        pushUndo()

        let key = SnippetTagging.filterKey(for: tag)
        var tags = snippets[index].tags
        if let existing = tags.firstIndex(where: { SnippetTagging.filterKey(for: $0) == key }) {
            tags.remove(at: existing)
        } else {
            tags.append(tag)
        }

        snippets[index].tags = SnippetTagging.normalizedTags(tags)
        snippets[index].updatedAt = Date()
        persist(immediately: true)
        return true
    }

    /// Everything the user should see in the list, plaintext and secure together.
    ///
    /// File-array order is intentionally local and can differ after a CloudKit fetch.
    /// Sort only this presentation projection so storage, undo, and merge semantics do
    /// not churn while every platform still renders the same canonical order.
    func snippetsSortedForDisplay() -> [Snippet] {
        let combined = snippets + (secureProvider?.secureShellsForDisplay() ?? [])
        return SnippetDisplayOrder.sorted(combined)
    }

    /// Whether this id belongs to a secure record rather than to `snippets`.
    func isSecure(_ id: UUID) -> Bool {
        secureProvider?.isSecure(id) ?? false
    }

    /// The auto-expansion candidates — deliberately **plaintext only**.
    ///
    /// Do not merge secure shells in here. This is the list the keystroke buffer is
    /// matched against, and its not containing secure records is what makes "a secret
    /// is never typed by an unauthenticated trigger" a structural property rather than
    /// a policy some later refactor forgets. A secure snippet is reachable only through
    /// the picker, which can require an unlock.
    func enabledSnippetsSorted() -> [Snippet] {
        snippets
            .filter { $0.isEnabled && !$0.normalizedKeyword.isEmpty }
            .sorted { lhs, rhs in
                if lhs.normalizedKeyword.count == rhs.normalizedKeyword.count {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.normalizedKeyword.count > rhs.normalizedKeyword.count
            }
    }

    /// Peeks at a file to check if it contains Raycast snippets with `!`-prefixed keywords.
    func detectsRaycastExclamationKeywords(in url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let prepared = try? SnippetImportParser.parse(data) else { return false }
        return prepared.hasRaycastExclamationKeywords
    }

    @discardableResult
    func importSnippets(from url: URL) throws -> Int {
        try importSnippets(from: url, options: ImportOptions())
    }

    @discardableResult
    func importSnippets(from url: URL, options: ImportOptions) throws -> Int {
        guard !isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryRequired
        }
        return try importSnippets(prepareImport(from: url), options: options)
    }

    func prepareImport(from url: URL) throws -> PreparedSnippetImport {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportExportError.cannotAccessFile
        }

        let prepared: PreparedSnippetImport
        do {
            prepared = try SnippetImportParser.parse(data)
        } catch {
            throw ImportExportError.invalidFormat
        }
        return prepared
    }

    /// Applies JSON that was already decoded off the main actor by the iOS document
    /// loader. Preflight and mutation remain actor-isolated and atomic.
    @discardableResult
    func importSnippets(
        _ prepared: PreparedSnippetImport,
        options: ImportOptions = ImportOptions()
    ) throws -> Int {
        guard !isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryRequired
        }
        return importSnippets(try preparedImport(
            prepared,
            options: options,
            authoritativeRecovery: false))
    }

    /// Validates the exact ordinary-library candidate before UI asks the user to make
    /// it authoritative. This is intentionally separate from ordinary import: merely
    /// choosing a partial JSON or Raycast export must never replace quarantined data.
    func quarantinedLibraryRecoveryCandidateCount(
        _ prepared: PreparedSnippetImport,
        options: ImportOptions = ImportOptions()
    ) throws -> Int {
        guard isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryNoLongerRequired
        }
        return try preparedImport(
            prepared,
            options: options,
            authoritativeRecovery: true).count
    }

    @discardableResult
    func replaceQuarantinedLibrary(
        with prepared: PreparedSnippetImport,
        options: ImportOptions = ImportOptions()
    ) throws -> Int {
        guard isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryNoLongerRequired
        }
        let imported = try preparedImport(
            prepared,
            options: options,
            authoritativeRecovery: true)
        undoStack.removeAll()
        redoStack.removeAll()
        try installAuthoritativeRecoveryCandidate(imported)
        return imported.count
    }

    @discardableResult
    func importSharedSnippet(_ snippet: Snippet) throws -> Snippet {
        guard !isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryRequired
        }
        try preflightImportedSnippets([snippet])

        let imported = normalizeImportedSnippets([snippet])
        try preflightImportMerge(imported)

        guard let normalizedSnippet = imported.first else {
            throw ImportExportError.emptyImport
        }

        pushUndo()
        var merged = snippets
        let finalSnippet = upsertImportedSnippet(normalizedSnippet, into: &merged)
        snippets = merged
        persist(immediately: true)
        return finalSnippet
    }

    @discardableResult
    private func importSnippets(_ imported: [Snippet]) -> Int {
        pushUndo()
        var merged = snippets
        var importedCount = 0

        for incoming in imported {
            _ = upsertImportedSnippet(incoming, into: &merged)
            importedCount += 1
        }

        snippets = merged
        persist(immediately: true)
        return importedCount
    }

    private func upsertImportedSnippet(_ incoming: Snippet, into merged: inout [Snippet]) -> Snippet {
        if let idIndex = merged.firstIndex(where: { $0.id == incoming.id }) {
            merged[idIndex] = incoming
            return incoming
        }

        let incomingKey = SnippetTagging.filterKey(for: incoming.normalizedKeyword)
        if !incoming.normalizedKeyword.isEmpty,
           let keywordIndex = merged.firstIndex(where: {
               SnippetTagging.filterKey(for: $0.normalizedKeyword) == incomingKey
           }) {
            var replacement = incoming
            replacement.id = merged[keywordIndex].id
            replacement.createdAt = merged[keywordIndex].createdAt
            merged[keywordIndex] = replacement
            return replacement
        }

        merged.insert(incoming, at: 0)
        return incoming
    }

    @discardableResult
    func exportSnippets(to url: URL) throws -> Int {
        guard !isLibraryQuarantined else {
            throw ImportExportError.libraryRecoveryRequired
        }
        do {
            let payload = SnippetCollection(snippets: snippets)
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
            return snippets.count
        } catch {
            throw ImportExportError.cannotAccessFile
        }
    }

    private func load() {
        let hasIndependentQuarantine = LibraryQuarantineMarker.exists()
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            if hasIndependentQuarantine || hasDurableLibraryQuarantineMarker() {
                snippets = []
                isLibraryQuarantined = true
                return
            }
            // Seeding here is why the list's empty state carries no explanation
            // of how expansion works: a genuinely new user always has this
            // snippet, so that screen only ever appears to someone who deleted
            // everything. Remove the seed and the teaching sentence has to come
            // back with it.
            snippets = configuration.seedsStarterSnippet ? [Snippet.starterSnippet] : []
            if !snippets.isEmpty { persist() }
            return
        }

        do {
            let data = try Data(contentsOf: saveURL)
            snippets = try decodeImportData(data)
            rememberDiskBytes(data)
            // A restored file is only a recovery candidate. Keep all mutation and
            // ordinary sync paths closed until Check Again validates it and Core first
            // persists the non-destructive merge fence in base.json.
            isLibraryQuarantined = hasIndependentQuarantine
        } catch {
            Diagnostics.record(.storageFailure(
                area: .library,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            quarantineUnreadableLibrary()
        }
    }

    /// Re-reads a user-restored primary while the in-memory store is quarantined. This is
    /// called by the sync recovery check so the user does not have to wait for a filesystem
    /// observer debounce or relaunch before a valid replacement can be verified. It does
    /// not release mutation access: Core must first durably publish the merge fence and
    /// retire the independent quarantine marker.
    @discardableResult
    func adoptRecoveredLibraryIfPresent() -> Bool {
        guard isLibraryQuarantined else { return true }
        guard let data = try? Data(contentsOf: saveURL),
              let recovered = try? decodeImportData(data) else { return false }
        let changed = snippets != recovered
        snippets = recovered
        rememberDiskBytes(data)
        undoStack.removeAll()
        redoStack.removeAll()
        if changed { notifyChanged(.external) }
        return true
    }

    /// Completes an already validated recovery after Core commits its crash fence.
    /// Refuse an out-of-order call while the filesystem marker still exists.
    func finalizeRecoveredLibraryReview() -> Bool {
        guard !LibraryQuarantineMarker.exists() else { return false }
        isLibraryQuarantined = false
        return true
    }

    /// Persists the stop before moving unreadable user data out of the primary path.
    /// If the marker cannot be written atomically under the shared lock, the original
    /// file stays in place and the in-memory quarantine still blocks this process.
    private func quarantineUnreadableLibrary() {
        snippets = []
        isLibraryQuarantined = true

        let held: FileGuard.Held
        do {
            held = try FileGuard.acquire(
                at: SnippetStorageLocations.libraryLockFileURL,
                timeout: lockTimeout)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncState,
                operation: .lock,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return
        }
        defer { held.release() }
        guard !held.isUnlocked else {
            Diagnostics.record(.storageState(
                area: .syncState,
                state: .degraded,
                value: nil))
            return
        }

        // A cooperating writer may have repaired the file while this process waited
        // for the lock. Adopt those valid bytes instead of quarantining stale evidence.
        if let currentData = try? Data(contentsOf: saveURL),
           let repaired = try? decodeImportData(currentData) {
            snippets = repaired
            rememberDiskBytes(currentData)
            isLibraryQuarantined = LibraryQuarantineMarker.exists()
            return
        }

        do {
            try LibraryQuarantineMarker.write()
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncState,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return
        }

        var state: SyncState
        switch SyncStateFile.load(
            makeFresh: { SyncState.fresh(deviceID: deviceID, now: Date()) }
        ) {
        case .loaded(let loaded), .fresh(let loaded):
            state = loaded
        case .tooNew(let version):
            Diagnostics.record(.storageState(
                area: .syncState,
                state: .versionTooNew,
                value: version))
            return
        }
        state.halt = SyncState.Halt(
            reason: .localLibraryQuarantined,
            detail: "the primary snippet library could not be read and was preserved; "
                + "sync stopped before treating its records as deleted",
            at: Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970)),
            recoveryContext: .localLibraryQuarantine)
        do {
            try SyncStateFile.write(state)
        } catch {
            Diagnostics.record(.storageFailure(
                area: .syncState,
                operation: .write,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return
        }

        guard FileManager.default.fileExists(atPath: saveURL.path) else { return }
        let backupURL = saveFolderURL.appendingPathComponent(
            "snippets.json.corrupt-\(Self.backupTimestamp())", isDirectory: false)
        do {
            try FileManager.default.moveItem(at: saveURL, to: backupURL)
            Diagnostics.record(.storageState(
                area: .library,
                state: .recovered,
                value: nil))
        } catch {
            // The durable stop is already in place. Retaining the unreadable primary is
            // conservative and gives a later launch another chance to preserve it.
            Diagnostics.record(.storageFailure(
                area: .library,
                operation: .recover,
                failure: DiagnosticFailure(error),
                attempt: nil))
        }
    }

    private func hasDurableLibraryQuarantineMarker() -> Bool {
        switch SyncStateFile.load() {
        case .loaded(let state):
            return state.halt?.recoveryContext == .localLibraryQuarantine
        case .tooNew:
            // A future state file may contain a safety marker this build cannot decode.
            // With no primary library, seeding would be an irreversible downgrade write.
            return true
        case .fresh:
            return false
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    private func decodeImportData(_ data: Data) throws -> [Snippet] {
        try decodeImportData(data, options: ImportOptions())
    }

    private func decodeImportData(_ data: Data, options: ImportOptions) throws -> [Snippet] {
        do {
            return try SnippetImportParser.parse(data).snippets(
                preservingExclamationPrefix: options.preserveExclamationPrefix
            )
        } catch {
            throw ImportExportError.invalidFormat
        }
    }

    private func preflightImportedSnippets(_ imported: [Snippet]) throws {
        var conflicts: [String] = []
        var seenIDs = Set<UUID>()
        var seenKeywords: [String: Snippet] = [:]

        for snippet in imported {
            if !seenIDs.insert(snippet.id).inserted {
                conflicts.append("The import contains duplicate snippet ID \(snippet.id.uuidString).")
            }

            // Match the expansion engine, which folds case AND diacritics.
            let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
            guard !keyword.isEmpty else { continue }

            if let existing = seenKeywords[keyword] {
                conflicts.append("The import contains duplicate keyword \\\(snippet.normalizedKeyword) in \(existing.displayName) and \(snippet.displayName).")
            } else {
                seenKeywords[keyword] = snippet
            }
        }

        try throwImportConflictsIfNeeded(conflicts)
    }

    private func preparedImport(
        _ prepared: PreparedSnippetImport,
        options: ImportOptions,
        authoritativeRecovery: Bool
    ) throws -> [Snippet] {
        let decoded = prepared.snippets(
            preservingExclamationPrefix: options.preserveExclamationPrefix)
        try preflightImportedSnippets(decoded)
        let imported = normalizeImportedSnippets(decoded)
        try preflightImportMerge(
            imported,
            includeExistingOrdinarySnippets: !authoritativeRecovery)
        guard authoritativeRecovery || !imported.isEmpty else {
            throw ImportExportError.emptyImport
        }
        return imported
    }

    private func preflightImportMerge(
        _ imported: [Snippet],
        includeExistingOrdinarySnippets: Bool = true
    ) throws {
        var conflicts: [String] = []

        // Both stores. An import that reuses a secure record's id would replace its
        // plaintext twin here while the encrypted original stayed in the vault, and one
        // that reuses a secure keyword would leave two live rows on the same trigger —
        // in both cases with nothing said to the user, because this only ever looked at
        // `snippets`.
        let secureShells = secureProvider?.secureShellsForDisplay() ?? []
        let existing = (includeExistingOrdinarySnippets ? snippets : []) + secureShells

        for incoming in imported {
            if secureShells.contains(where: { $0.id == incoming.id }) {
                conflicts.append(
                    "Imported \(incoming.displayName) has the same ID as a secure snippet. "
                    + "Importing it would create a plaintext copy of something you chose to encrypt.")
                continue
            }

            let keyword = incoming.normalizedKeyword
            guard !keyword.isEmpty else { continue }
            let keywordKey = SnippetTagging.filterKey(for: keyword)

            if let secureMatch = secureShells.first(where: {
                SnippetTagging.filterKey(for: $0.normalizedKeyword) == keywordKey
            }) {
                conflicts.append(
                    "Imported \(incoming.displayName) uses keyword \\\(keyword), which belongs to the "
                    + "secure snippet \(secureMatch.displayName).")
                continue
            }

            guard let idMatch = existing.first(where: { $0.id == incoming.id }) else { continue }
            if let keywordMatch = existing.first(where: {
                $0.id != incoming.id &&
                SnippetTagging.filterKey(for: $0.normalizedKeyword) == keywordKey
            }) {
                conflicts.append("Imported \(incoming.displayName) matches existing ID \(idMatch.displayName), but keyword \\\(keyword) belongs to \(keywordMatch.displayName).")
            }
        }

        try throwImportConflictsIfNeeded(conflicts)
    }

    private func throwImportConflictsIfNeeded(_ conflicts: [String]) throws {
        guard !conflicts.isEmpty else { return }
        throw ImportExportError.importConflicts(Array(conflicts.prefix(8)))
    }

    private func normalizeImportedSnippets(_ imported: [Snippet]) -> [Snippet] {
        var normalized: [Snippet] = []
        var seenIDs = Set<UUID>()

        for item in imported {
            var snippet = item
            snippet.keyword = snippet.normalizedKeyword
            snippet.tags = SnippetTagging.normalizedTags(snippet.tags)

            if seenIDs.contains(snippet.id) {
                snippet.id = UUID()
            }
            seenIDs.insert(snippet.id)

            if snippet.updatedAt < snippet.createdAt {
                snippet.updatedAt = snippet.createdAt
            }

            normalized.append(snippet)
        }

        return normalized
    }

    private func persist(immediately: Bool = false, notifyChange: Bool = true) {
        // Never create a replacement primary from the empty quarantine projection.
        // Full-file recovery uses its own explicit authoritative writer below.
        guard !isLibraryQuarantined else { return }
        restartEditTransactionIfNeeded()
        persistenceStateVersion &+= 1
        needsPersistence = true
        persistWorkItem?.cancel()
        persistWorkItem = nil
        // Publish only after the dirty bit and its write/retry ownership are established.
        // A synchronous observer is allowed to request Sync Now; it must never see new
        // in-memory bytes while `flushPendingWritesForSync()` still believes there is
        // nothing to make durable.
        defer { if notifyChange { notifyChanged(.local) } }

        if immediately {
            // A prior debounced write may still be running. Its result must be folded
            // into current memory before this action snapshots, otherwise two worker
            // operations are serialized on disk but applied to the store out of order.
            _ = drainInFlightWrite(scheduleRetryOnFailure: false)
            persistWorkItem?.cancel()
            persistWorkItem = nil
            guard needsPersistence else { return }
            if !performWriteSynchronously(lockTimeout: lockTimeout) {
                schedulePersistRetry()
            }
            return
        }

        schedulePersistence(after: persistDelay)
    }

    private func schedulePersistence(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistWorkItem = nil
                self.startAsynchronousWriteIfNeeded()
            }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Starts the heavyweight write without doing JSON, digest, lock, or filesystem
    /// work in the debounce callback. Only one operation is owned at a time. If the
    /// trailing debounce expires behind an existing operation, that operation's
    /// completion observes `needsPersistence` and starts the newer snapshot next.
    private func startAsynchronousWriteIfNeeded() {
        guard needsPersistence, inFlightWrite == nil else { return }
        let request = makePersistenceRequest(lockTimeout: lockTimeout)
        let operation = persistenceWorker.submit(request) { [weak self] operation in
            MainActor.assumeIsolated {
                self?.finishAsynchronousWrite(operation)
            }
        }
        inFlightWrite = operation
    }

    private func finishAsynchronousWrite(_ operation: SnippetPersistenceOperation) {
        // A synchronous immediate/flush drain may already have consumed this inbox.
        // Its callback was enqueued before MainActor became available again, so identity
        // is the exactly-once guard rather than another mutable completion flag.
        guard inFlightWrite === operation,
              let result = operation.resultIfReady() else { return }
        inFlightWrite = nil

        if applyPersistenceResult(result, for: operation.request) {
            if needsPersistence, persistWorkItem == nil {
                startAsynchronousWriteIfNeeded()
            }
        } else {
            schedulePersistRetry()
        }
    }

    @discardableResult
    private func drainInFlightWrite(scheduleRetryOnFailure: Bool) -> Bool? {
        guard let operation = inFlightWrite else { return nil }
        let result = persistenceWorker.wait(for: operation)
        guard inFlightWrite === operation else { return nil }
        inFlightWrite = nil
        let succeeded = applyPersistenceResult(result, for: operation.request)
        if !succeeded, scheduleRetryOnFailure {
            schedulePersistRetry()
        }
        return succeeded
    }

    @discardableResult
    private func performWriteSynchronously(lockTimeout: TimeInterval) -> Bool {
        let request = makePersistenceRequest(lockTimeout: lockTimeout)
        let operation = persistenceWorker.submit(request)
        let result = persistenceWorker.wait(for: operation)
        return applyPersistenceResult(result, for: request)
    }

    private func makePersistenceRequest(
        lockTimeout: TimeInterval,
        disposition: SnippetPersistenceRequest.Disposition = .merge
    ) -> SnippetPersistenceRequest {
        nextPersistenceRequestID &+= 1
        return SnippetPersistenceRequest(
            id: nextPersistenceRequestID,
            stateVersion: persistenceStateVersion,
            diskObservationVersion: diskObservationVersion,
            local: snippets,
            ancestorData: lastKnownDiskData,
            expectedDigest: lastKnownDigest,
            libraryURL: saveURL,
            stateURL: SnippetStorageLocations.syncStateFileURL,
            lockURL: SnippetStorageLocations.libraryLockFileURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL,
            lockTimeout: lockTimeout,
            disposition: disposition
        )
    }

    /// Installs one complete recovery file without interpreting the quarantined primary
    /// as a concurrent peer. The independent quarantine marker remains in force until
    /// SyncEngine commits its non-destructive merge fence and explicitly unlocks edits.
    private func installAuthoritativeRecoveryCandidate(_ replacement: [Snippet]) throws {
        persistWorkItem?.cancel()
        persistWorkItem = nil
        _ = drainInFlightWrite(scheduleRetryOnFailure: false)

        let previous = snippets
        persistenceStateVersion &+= 1
        snippets = replacement
        needsPersistence = true
        let request = makePersistenceRequest(
            lockTimeout: lockTimeout,
            disposition: .authoritativeReplacement)
        let operation = persistenceWorker.submit(request)
        let result = persistenceWorker.wait(for: operation)

        guard applyPersistenceResult(result, for: request) else {
            snippets = previous
            needsPersistence = false
            throw ImportExportError.cannotAccessFile
        }
        notifyChanged(.local)
    }

    /// Applies one worker result, in submission order, on MainActor.
    ///
    /// The request snapshot is the merge base for a completion that arrives after a
    /// newer edit. Treating the worker's actual written result as the remote side folds
    /// in foreign edits/deletes without reverting the newer in-memory fields. The
    /// resulting newer state remains dirty and is submitted by the trailing debounce.
    ///
    /// `diskObservationVersion` prevents an older callback from replacing a cache that
    /// an external reload observed while the worker ran. In the ordinary case the
    /// returned bytes become byte-exact authority without rehashing them on MainActor.
    private func applyPersistenceResult(
        _ result: SnippetPersistenceResult,
        for request: SnippetPersistenceRequest
    ) -> Bool {
        switch result {
        case .success(let outcome):
            lockFailureCount = 0
            let diskWasObservedWhileWriting =
                diskObservationVersion != request.diskObservationVersion
            let preCompletionLocal = snippets

            if preCompletionLocal == request.local, let merge = outcome.merge {
                adoptMergedLibrary(merge, preMergeLocal: preCompletionLocal)
            } else if preCompletionLocal != outcome.snippets {
                let reconciled = SyncMerge.mergeLocal(
                    base: request.local,
                    local: preCompletionLocal,
                    remote: outcome.snippets
                )
                if reconciled.snippets != preCompletionLocal {
                    adoptMergedLibrary(reconciled, preMergeLocal: preCompletionLocal)
                }
            }

            if !diskWasObservedWhileWriting {
                rememberDiskBytes(outcome.data, digest: outcome.digest)
            }

            let completionChangedMemory = snippets != preCompletionLocal

            // Settle ownership before publishing callbacks. `onChange` and the sync
            // delegate are deliberately synchronous and may re-enter the store with a
            // newer edit. Finalizing this request after such a callback could clear the
            // dirty bit that the callback just set. Once published, only the re-entrant
            // mutation is allowed to change this decision.
            if persistenceStateVersion == request.stateVersion,
               !diskWasObservedWhileWriting,
               snippets == outcome.snippets {
                needsPersistence = false
            } else {
                needsPersistence = true
            }

            let reloadChangedMemory: Bool
            if diskWasObservedWhileWriting {
                // Re-read against the newer cache observation rather than letting this
                // completion claim byte authority. If the observed bytes are still the
                // latest, the comparison is a cheap no-op; if another writer moved them,
                // the normal external merge path folds that state in.
                reloadChangedMemory = reloadFromDiskIfNeeded()
            } else {
                reloadChangedMemory = false
            }

            if outcome.recreatedMissingFile {
                Diagnostics.record(.storageState(
                    area: .library,
                    state: .recreated,
                    value: nil))
            }

            let health: WriteHealth =
                outcome.wroteWithoutLock ? .unlocked
                : outcome.attempts > 1 ? .contended(attempts: outcome.attempts)
                : .healthy
            if health != writeHealth {
                writeHealth = health
                if health.isDegraded {
                    let attempts: Int?
                    if case .contended(let value) = health { attempts = value } else { attempts = nil }
                    Diagnostics.record(.storageState(
                        area: .library,
                        state: .degraded,
                        value: attempts))
                }
                syncDelegate?.libraryDidChange(.local)
            }

            if outcome.foldedInForeignWrite,
               (!diskWasObservedWhileWriting
                || (completionChangedMemory && !reloadChangedMemory)) {
                notifyChanged(.external)
            }
            return true

        case .failure(let failure):
            lockFailureCount += 1
            needsPersistence = true
            if case .other(let diagnosticFailure) = failure {
                Diagnostics.record(.storageFailure(
                    area: .library,
                    operation: .write,
                    failure: diagnosticFailure,
                    attempt: lockFailureCount))
            }
            return false
        }
    }

    /// Backs off linearly, capped, and keeps trying. The alternative — giving up —
    /// silently discards whatever the user just typed.
    private func schedulePersistRetry() {
        persistWorkItem?.cancel()
        let delay = min(persistenceRetryBaseDelay * Double(lockFailureCount), 2.0)
        schedulePersistence(after: delay)

        // Two failures in a row is no longer a hiccup; let the UI say so.
        if lockFailureCount >= 2 { syncDelegate?.libraryDidChange(.local) }
    }

    /// Re-reads after something else wrote the library through a route that bypasses
    /// this store's own write path, such as `SnippetLibraryBridge` or an iOS secure
    /// transition applying a `LibraryTransaction`.
    ///
    /// Distinct from the folder monitor, which is debounced and may not have fired yet:
    /// the caller knows for a fact the bytes changed, so waiting for a notification
    /// would leave the UI showing state that is already gone. A coordinated caller may
    /// suppress this store's notification while it reloads another projection, then
    /// publish one combined change after both caches agree.
    @discardableResult
    func reloadAfterExternalWrite(notifyChange: Bool = true) -> Bool {
        reloadFromDiskIfNeeded(notifyChange: notifyChange)
    }

    /// Publishes one change after a coordinator has reloaded multiple on-disk
    /// projections with their individual callbacks suppressed. The sync bridge uses
    /// this after applying a CloudKit batch so UI observers refresh once while the sync
    /// delegate can identify and ignore its own write.
    func coordinatedReloadDidFinish(
        _ source: ChangeSource,
        changedIDs: Set<UUID>? = nil
    ) {
        notifyChanged(source, changedIDs: changedIDs)
    }

    private func rememberDiskBytes(_ data: Data, digest: String? = nil) {
        lastKnownDiskData = data
        lastKnownDigest = digest ?? SnippetLibraryCodec.digest(of: data)
        diskObservationVersion &+= 1
    }

    private func notifyChanged(_ source: ChangeSource, changedIDs: Set<UUID>? = nil) {
        librarySeq &+= 1
        onChange?(Change(source: source, changedIDs: changedIDs))
        syncDelegate?.libraryDidChange(source)
    }

    /// Flushes a pending write, synchronously, with nowhere to defer to.
    ///
    /// This runs from `applicationWillTerminate`, which returns and then the process
    /// dies — so the run loop never spins again and `schedulePersistRetry`'s
    /// `asyncAfter` would simply never fire. Retrying has to happen inline, and if it
    /// still cannot land, the edit has to go *somewhere* rather than evaporate.
    func flushPendingWrites() {
        guard persistWorkItem != nil || inFlightWrite != nil || needsPersistence else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil

        // Waiting is safe: the worker publishes into a thread-safe inbox before it
        // enqueues MainActor completion. Applying here consumes that inbox, and the
        // callback becomes an identity-guarded no-op when the run loop resumes.
        _ = drainInFlightWrite(scheduleRetryOnFailure: false)
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard needsPersistence else { return }

        for attempt in 0..<3 {
            if performWriteSynchronously(lockTimeout: terminateLockTimeout),
               !needsPersistence {
                return
            }
            if attempt < 2 { Thread.sleep(forTimeInterval: 0.1) }
        }

        // Three locked attempts failed and the process is about to exit. Overwriting
        // the library unlocked would risk clobbering whatever peer is holding the
        // lock, so the edit goes to a recovery file instead: nothing is lost, nothing
        // is corrupted, and the next launch can offer it back.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let rescue = SnippetStorageLocations.backupsFolderURL.appendingPathComponent(
            "unsaved-\(formatter.string(from: Date())).json", isDirectory: false)
        let pending = snippets
        if let data = try? SnippetLibraryCodec.encode(pending) {
            do {
                try AtomicFileWriter.write(data, to: rescue)
                Diagnostics.record(.storageState(
                    area: .library,
                    state: .recovered,
                    value: pending.count))
            } catch {
                Diagnostics.record(.storageFailure(
                    area: .library,
                    operation: .recover,
                    failure: DiagnosticFailure(error),
                    attempt: 3))
            }
        }
    }

    /// Makes the exact in-memory ordinary library durable before sync may describe it
    /// as desired or offered state.
    ///
    /// This is intentionally stricter than the lifecycle `flushPendingWrites()` above.
    /// A termination rescue file preserves text for a human, but it is not the primary
    /// library a restarted sync engine projects. Treating that backup as success would
    /// let the server accept edit B while `snippets.json` still contains A; after a crash
    /// A could then be mistaken for a newer edit and overwrite B. This method therefore
    /// returns only after the current snapshot is in the primary file, or throws before
    /// the journal/network boundary.
    func flushPendingWritesForSync() throws {
        guard persistWorkItem != nil || inFlightWrite != nil || needsPersistence else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil

        // Fold any older worker result into memory first. It may have merged a concurrent
        // CLI write, in which case the resulting current snapshot is what must be flushed.
        _ = drainInFlightWrite(scheduleRetryOnFailure: false)
        persistWorkItem?.cancel()
        persistWorkItem = nil
        guard needsPersistence else { return }

        // A short bounded retry absorbs ordinary lock handoff without turning outbound
        // sync into an unbounded MainActor stall. Failure keeps the store dirty and its
        // normal retry scheduled, but sync itself must stop before journaling these bytes.
        for _ in 0..<3 {
            if performWriteSynchronously(lockTimeout: lockTimeout), !needsPersistence {
                return
            }
        }

        schedulePersistRetry()
        throw DurableSnapshotFailure.primaryLibraryWriteFailed
    }

    // MARK: - Undo / Redo

    func beginEditTransaction() {
        guard !isLibraryQuarantined else { return }
        guard editTransactionSnapshot == nil else { return }
        editTransactionSnapshot = snippets
    }

    func commitEditTransaction() {
        guard !isLibraryQuarantined else {
            editTransactionSnapshot = nil
            return
        }
        guard let snapshot = editTransactionSnapshot else { return }
        editTransactionSnapshot = nil

        guard snapshot != snippets else { return }
        pushUndo(snapshot)
    }

    private func pushUndo() {
        // A discrete action (pin/delete/import/…) is interrupting an open edit
        // transaction. Keep the undo stack chronological: push the
        // transaction's baseline first (undoes the in-transaction edits), then
        // the pre-action state, and restart the transaction from the
        // post-action state (rebased by the action's follow-up persist call).
        if let transactionSnapshot = editTransactionSnapshot {
            editTransactionSnapshot = nil
            editTransactionNeedsRestart = true
            if transactionSnapshot != snippets {
                appendUndoSnapshot(transactionSnapshot)
            }
        }
        pushUndo(snippets)
    }

    private func pushUndo(_ snapshot: [Snippet]) {
        appendUndoSnapshot(snapshot)
        redoStack.removeAll()
    }

    private func appendUndoSnapshot(_ snapshot: [Snippet]) {
        undoStack.append(snapshot)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
    }

    /// Completes the transaction restart requested by `pushUndo()`. Runs from
    /// `persist`, which every interrupting action calls right after mutating
    /// `snippets`, so the reopened transaction is baselined on the
    /// post-action state.
    private func restartEditTransactionIfNeeded() {
        guard editTransactionNeedsRestart else { return }
        editTransactionNeedsRestart = false
        editTransactionSnapshot = snippets
    }

    func undo() -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let snapshot = undoStack.popLast() else { return false }
        redoStack.append(snippets)
        snippets = snapshot
        persist(immediately: true)
        return true
    }

    func redo() -> Bool {
        guard !isLibraryQuarantined else { return false }
        guard let snapshot = redoStack.popLast() else { return false }
        undoStack.append(snippets)
        snippets = snapshot
        persist(immediately: true)
        return true
    }

    private func startObservingExternalChanges() {
        #if os(macOS)
        distributedChangeObserver = DistributedNotificationCenter.default().addObserver(
            forName: SnippetStorageSync.distributedChangeNotification,
            object: saveURL.path,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.scheduleExternalReload(immediately: true)
        }

        let descriptor = open(saveFolderURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let monitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        monitor.setEventHandler { [weak self] in
            guard let self else { return }
            self.scheduleExternalReload(immediately: false)
        }
        monitor.setCancelHandler {
            close(descriptor)
        }
        saveDirectoryMonitor = monitor
        monitor.resume()
        #endif
    }

    private func scheduleExternalReload(immediately: Bool) {
        externalReloadWorkItem?.cancel()

        guard !immediately else {
            externalReloadWorkItem = nil
            reloadFromDiskIfNeeded()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.externalReloadWorkItem = nil
                self?.reloadFromDiskIfNeeded()
            }
        }
        externalReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + externalReloadDelay, execute: workItem)
    }

    /// Folds an external change into our state.
    ///
    /// The behaviour this replaces was: *if a local write is pending, flush it over
    /// the external change.* That policy destroys any CLI write that lands within
    /// `persistDelay` of a keystroke — silently, while the CLI reports success. It was
    /// a reasonable call when merging was out of scope; now that there is a merge,
    /// there is no reason to choose a side at all.
    ///
    /// A pending write is now no longer special. Both sides are merged against the
    /// last bytes we saw, and whatever comes out is persisted on the normal path.
    @discardableResult
    private func reloadFromDiskIfNeeded(notifyChange: Bool = true) -> Bool {
        guard let data = try? Data(contentsOf: saveURL) else { return false }
        guard data != lastKnownDiskData else { return false }

        let reloaded: [Snippet]
        do {
            reloaded = try decodeImportData(data)
        } catch {
            // Unreadable bytes must never be adopted, and must never be written back
            // over. Keep serving what we have; `load()` owns the quarantine path.
            Diagnostics.record(.storageFailure(
                area: .library,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            return false
        }

        if isLibraryQuarantined {
            snippets = reloaded
            rememberDiskBytes(data)
            undoStack.removeAll()
            redoStack.removeAll()
            if notifyChange { notifyChanged(.external) }
            return true
        }

        let ancestor = lastKnownDiskData.flatMap { try? SnippetLibraryCodec.decode($0) } ?? []
        rememberDiskBytes(data)

        let preMergeLocal = snippets
        let merged = SyncMerge.mergeLocal(
            base: ancestor, local: snippets, remote: reloaded)

        guard merged.snippets != preMergeLocal else { return false }
        adoptMergedLibrary(merged, preMergeLocal: preMergeLocal)
        if notifyChange { notifyChanged(.external) }

        // If the merge produced something neither side had on disk — a conflict copy,
        // a disabled duplicate keyword, or simply our own unflushed edits surviving —
        // that result has to be written back or it exists only in this process.
        if merged.snippets != reloaded {
            persist(notifyChange: notifyChange)
        }
        return true
    }

    /// Installs a merge result and keeps undo coherent with it.
    private func adoptMergedLibrary(_ merged: SyncMerge.Outcome, preMergeLocal: [Snippet]) {
        snippets = merged.snippets
        rebaseUndoHistory(preMergeLocal: preMergeLocal, merged: merged.snippets)

        if !merged.conflictCopies.isEmpty || !merged.disabledByKeywordCollision.isEmpty {
            Diagnostics.record(.libraryMerge(
                conflictCopies: merged.conflictCopies.count,
                keywordCollisions: merged.disabledByKeywordCollision.count))
        }
    }

    /// Rebases the undo/redo stacks onto merged state instead of discarding them.
    ///
    /// Each undo entry is "the library as it was before my edit", stated relative to
    /// `preMergeLocal`. Left untouched, pressing ⌘Z after a merge would persist an
    /// array that predates every record the other side just added — i.e. undo would
    /// delete someone else's snippets. Replaying the remote delta onto each entry
    /// keeps undo meaning "undo *my* edit" and nothing more.
    ///
    /// The size guard exists because this is O(entries × records) on the main thread.
    /// Above the threshold it degrades to the previous behaviour, which is safe: a
    /// cleared stack loses undo history, never data.
    private func rebaseUndoHistory(preMergeLocal: [Snippet], merged: [Snippet]) {
        let work = (undoStack.count + redoStack.count) * max(merged.count, 1)
        guard work <= 20_000 else {
            // Above the budget this runs long enough on the main thread to be felt,
            // and the main thread also hosts the keyDown event tap. Clearing the
            // stacks loses undo history; it never loses data.
            undoStack.removeAll()
            redoStack.removeAll()
            editTransactionSnapshot = editTransactionSnapshot.map { _ in merged }
            return
        }

        func rebase(_ snapshot: [Snippet]) -> [Snippet] {
            SyncMerge.rebaseSnapshot(snapshot, from: preMergeLocal, onto: merged)
        }
        undoStack = undoStack.map(rebase)
        redoStack = redoStack.map(rebase)
        editTransactionSnapshot = editTransactionSnapshot.map(rebase)
    }
}

private extension Snippet {
    /// Empty in all four fields the user types into. `isEnabled` and `isPinned`
    /// are not consulted: neither is something anyone typed, and a new snippet
    /// arrives enabled without being asked.
    ///
    /// Deliberately literal — a single stray space makes this false. Being wrong
    /// here costs a blank row nobody clears up; being wrong the other way costs
    /// something somebody wrote.
    var isBlankDraft: Bool {
        name.isEmpty && normalizedKeyword.isEmpty && content.isEmpty && tags.isEmpty
    }
}
