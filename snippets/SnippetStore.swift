import Darwin
import Foundation

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
    struct ImportOptions {
        var preserveExclamationPrefix = false
    }

    enum ChangeSource {
        case local
        case external
    }

    private(set) var snippets: [Snippet] = []

    var onChange: ((ChangeSource) -> Void)?
    weak var syncDelegate: SnippetStoreSyncDelegate?

    /// Vends content-free shells for the secure snippets held in `Vault/vault.json`.
    ///
    /// The two stores stay separate on disk and in memory; only the *display* and
    /// *uniqueness* views below merge them. `snippets` itself remains plaintext-only,
    /// which is what keeps export, the undo stack, and `writeToDisk` structurally
    /// incapable of touching a secret.
    weak var secureProvider: SecureSnippetProviding?

    private let saveURL: URL
    private let saveFolderURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistWorkItem: DispatchWorkItem?
    private let persistDelay: TimeInterval = 0.3
    private let externalReloadDelay: TimeInterval = 0.05
    private var externalReloadWorkItem: DispatchWorkItem?
    private var saveDirectoryMonitor: DispatchSourceFileSystemObject?
    private var distributedChangeObserver: NSObjectProtocol?
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

    /// Set by `writeToDisk` when a write genuinely lands. Only `flushPendingWrites`
    /// reads it, because on the terminate path "did it work?" cannot be answered by
    /// scheduling anything.
    private var didWriteDuringTerminate = false

    /// How long to wait for the library lock on the ordinary debounced write path.
    ///
    /// Deliberately small. This runs on the main thread, which also hosts a
    /// head-inserted `CGEventTap` for `keyDown` — every millisecond spent polling here
    /// is a millisecond of the user's typing held up system-wide. It also holds a
    /// cross-process lock for its whole duration, against a CLI that gives up after
    /// five seconds. An uncontended acquire is immediate and a CLI write holds the
    /// lock for single-digit milliseconds, so 250 ms is many times the realistic
    /// worst case; anything beyond that is a stuck peer, and the right answer then is
    /// to back off and retry rather than to wait.
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

    enum ImportExportError: LocalizedError {
        case emptyImport
        case invalidFormat
        case cannotAccessFile
        case importConflicts([String])

        var errorDescription: String? {
            switch self {
            case .emptyImport:
                return "The selected file does not contain any snippets."
            case .invalidFormat:
                return "Unsupported file format. Expected JSON exported from this app."
            case .cannotAccessFile:
                return "Could not read or write the selected file."
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

    private struct RaycastSnippet: Decodable {
        let name: String
        let text: String
        let keyword: String?
    }

    init() {
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
        startObservingExternalChanges()
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
            NSLog("Snippets: Sync/state.json is version \(version); running without sync bookkeeping.")
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
        if let distributedChangeObserver {
            DistributedNotificationCenter.default().removeObserver(distributedChangeObserver)
        }
    }

    func addSnippet(tags: [String] = []) -> Snippet {
        pushUndo()
        let snippet = Snippet(name: "", keyword: "", content: "", tags: SnippetTagging.normalizedTags(tags))
        snippets.insert(snippet, at: 0)
        persist(immediately: true)
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
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

        guard didChange else { return }

        if editTransactionSnapshot == nil {
            pushUndo()
        } else {
            redoStack.removeAll()
        }

        updated.updatedAt = Date()
        snippets[index] = updated
        persist()
    }

    func delete(snippetID: UUID) {
        pushUndo()
        snippets.removeAll { $0.id == snippetID }
        persist(immediately: true)
    }

    @discardableResult
    func duplicate(snippetID: UUID) -> Snippet? {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return nil }
        pushUndo()

        let source = snippets[index]
        let shouldDisableDuplicate = source.isEnabled && !source.normalizedKeyword.isEmpty
        let duplicate = Snippet(
            name: source.displayName + " Copy",
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

    func togglePinned(snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }
        pushUndo()
        snippets[index].isPinned.toggle()
        snippets[index].updatedAt = Date()
        persist(immediately: true)
    }

    func toggleEnabled(snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }
        pushUndo()
        snippets[index].isEnabled.toggle()
        snippets[index].updatedAt = Date()
        persist(immediately: true)
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
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

    func toggleTag(_ tag: String, snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }
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
    }

    /// Everything the user should see in the list, plaintext and secure together.
    func snippetsSortedForDisplay() -> [Snippet] {
        let combined = snippets + (secureProvider?.secureShellsForDisplay() ?? [])
        let pinned = combined.filter(\.isPinned)
        let unpinned = combined.filter { !$0.isPinned }
        return pinned + unpinned
    }

    /// Whether this id belongs to a secure record rather than to `snippets`.
    func isSecure(_ id: UUID) -> Bool {
        secureProvider?.isSecure(id) ?? false
    }

    /// Every keyword in use across BOTH stores, folded.
    ///
    /// Uniqueness has to span the two files or the expander becomes ambiguous: a
    /// plaintext snippet and a secure one sharing `awsroot` would both match, and the
    /// user would have no way to see why. The editor's existing conflict warning reads
    /// this rather than `snippets` alone.
    func keywordKeysInUse(excluding id: UUID? = nil) -> Set<String> {
        var keys = Set<String>()
        for snippet in snippets + (secureProvider?.secureShellsForDisplay() ?? []) where snippet.id != id {
            let key = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
            if !key.isEmpty { keys.insert(key) }
        }
        return keys
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
              let raycastArray = decodeRaycastSnippets(from: data),
              !raycastArray.isEmpty else { return false }
        return raycastArray.contains {
            Self.normalizedRaycastKeyword(
                from: $0.keyword,
                preserveExclamationPrefix: true
            ).hasPrefix("!")
        }
    }

    @discardableResult
    func importSnippets(from url: URL) throws -> Int {
        try importSnippets(from: url, options: ImportOptions())
    }

    @discardableResult
    func importSnippets(from url: URL, options: ImportOptions) throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportExportError.cannotAccessFile
        }

        let decoded = try decodeImportData(data, options: options)
        try preflightImportedSnippets(decoded)

        let imported = normalizeImportedSnippets(decoded)
        try preflightImportMerge(imported)

        guard !imported.isEmpty else {
            throw ImportExportError.emptyImport
        }

        return importSnippets(imported)
    }

    @discardableResult
    func importSharedSnippet(_ snippet: Snippet) throws -> Snippet {
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
            upsertImportedSnippet(incoming, into: &merged)
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
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            snippets = [Snippet.starterSnippet]
            persist()
            return
        }

        do {
            let data = try Data(contentsOf: saveURL)
            snippets = try decodeImportData(data)
            rememberDiskBytes(data)
        } catch {
            NSLog("Failed to load snippets: \(error.localizedDescription)")
            snippets = [Snippet.starterSnippet]

            // Preserve the user's data: move the unreadable file aside before
            // anything is written back to snippets.json. If the move fails,
            // skip persisting so the original bytes are never overwritten.
            let backupURL = saveFolderURL.appendingPathComponent(
                "snippets.json.corrupt-\(Self.backupTimestamp())", isDirectory: false
            )
            do {
                try FileManager.default.moveItem(at: saveURL, to: backupURL)
                NSLog("Moved unreadable snippets file to \(backupURL.path)")
            } catch {
                NSLog("Could not move unreadable snippets file aside: \(error.localizedDescription); leaving it untouched")
                return
            }
            persist()
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
        if let directArray = try? decoder.decode([Snippet].self, from: data) {
            return directArray
        }

        if let collection = try? decoder.decode(SnippetCollection.self, from: data) {
            return collection.snippets
        }

        if let raycastArray = decodeRaycastSnippets(from: data) {
            return raycastArray.map { rc in
                return Snippet(
                    name: rc.name,
                    keyword: Self.normalizedRaycastKeyword(
                        from: rc.keyword,
                        preserveExclamationPrefix: options.preserveExclamationPrefix
                    ),
                    content: Self.convertRaycastPlaceholders(rc.text)
                )
            }
        }

        throw ImportExportError.invalidFormat
    }

    private func decodeRaycastSnippets(from data: Data) -> [RaycastSnippet]? {
        let isNative = (try? decoder.decode([Snippet].self, from: data)) != nil
            || (try? decoder.decode(SnippetCollection.self, from: data)) != nil
        guard !isNative,
              let raycastArray = try? decoder.decode([RaycastSnippet].self, from: data),
              !raycastArray.isEmpty else {
            return nil
        }

        return raycastArray
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

    private func preflightImportMerge(_ imported: [Snippet]) throws {
        var conflicts: [String] = []

        for incoming in imported {
            guard let idMatch = snippets.first(where: { $0.id == incoming.id }) else { continue }

            let keyword = incoming.normalizedKeyword
            guard !keyword.isEmpty else { continue }

            let keywordKey = SnippetTagging.filterKey(for: keyword)
            if let keywordMatch = snippets.first(where: {
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

    private static func normalizedRaycastKeyword(
        from rawKeyword: String?,
        preserveExclamationPrefix: Bool
    ) -> String {
        var keyword = Snippet.sanitizedKeyword(rawKeyword ?? "")

        if !preserveExclamationPrefix, keyword.hasPrefix("!") {
            keyword.removeFirst()
            keyword = Snippet.sanitizedKeyword(keyword)
        }

        return keyword
    }

    private static let raycastDateRegex = try? NSRegularExpression(
        pattern: #"\{date "([^"]+)"\}"#
    )

    private static func convertRaycastPlaceholders(_ text: String) -> String {
        guard let regex = raycastDateRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "{date:$1}"
        )
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

    private func persist(immediately: Bool = false) {
        restartEditTransactionIfNeeded()
        notifyChanged(.local)
        persistWorkItem?.cancel()
        persistWorkItem = nil

        if immediately {
            writeToDisk()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Clear the reference before writing: a non-nil persistWorkItem
                // must always mean a write is still pending.
                self.persistWorkItem = nil
                self.writeToDisk()
            }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDelay, execute: workItem)
    }

    /// The single write funnel, and the place the library's oldest data-loss bug is fixed.
    ///
    /// Two processes used to read-modify-write the whole file with no coordination,
    /// which loses roughly two thirds of concurrent writes outright. Serializing them
    /// is necessary but not sufficient, because of a race that survives correct
    /// locking entirely:
    ///
    /// 1. `t=0.00` the user types; a debounced write is scheduled for `t=0.30`.
    /// 2. `t=0.28` the CLI writes, correctly, under the lock.
    /// 3. `t=0.30` this method writes, correctly, under the lock — from an in-memory
    ///    array that never saw step 2 — and records its own bytes as "what is on disk".
    /// 4. `t=0.33` the folder monitor fires, sees bytes matching what we last wrote,
    ///    and short-circuits. The CLI's edit is gone, silently.
    ///
    /// Everyone behaved correctly and an edit still vanished. So the writer re-reads
    /// *inside* the lock and merges when the bytes moved, instead of trusting its own
    /// snapshot to still be current.
    private func writeToDisk(lockTimeout timeout: TimeInterval? = nil, isTerminating: Bool = false) {
        let previousDigest = lastKnownDigest
        let ancestor = lastKnownDiskData.flatMap { try? SnippetLibraryCodec.decode($0) } ?? []

        // The transform below may run more than once: `LibraryWriter` retries it when a
        // peer writes inside the critical section. It must therefore be free of side
        // effects — the merge result is stashed here and applied only once, after the
        // write is confirmed. Mutating `snippets` or the undo stacks from inside would
        // apply them once per attempt.
        var pendingMerge: (outcome: SyncMerge.Outcome, preMergeLocal: [Snippet])?

        do {
            let outcome = try LibraryWriter.update(
                libraryURL: saveURL,
                lockTimeout: timeout ?? lockTimeout,
                expectedDigest: previousDigest
            ) { onDisk in
                // Fast path: nobody moved the file, so there is nothing to reconcile.
                guard onDisk.digest != previousDigest else {
                    pendingMerge = nil
                    return self.snippets
                }

                // The file is GONE, not empty. Nobody deleted these records — there is
                // simply no remote side to merge against, so merging would read every
                // untouched record as "the peer deleted this" and write one snippet
                // over the whole library, durably, with the undo stacks rebased onto
                // the wreckage. Recreate the file from what we have, which is exactly
                // what the plain atomic write this replaced always did.
                guard onDisk.fileExisted else {
                    NSLog("Snippets: snippets.json disappeared; recreating it from memory rather than merging.")
                    pendingMerge = nil
                    return self.snippets
                }

                let merged = SyncMerge.mergeLocal(
                    base: ancestor, local: self.snippets, remote: onDisk.snippets)
                pendingMerge = (merged, self.snippets)
                return merged.snippets
            }

            lockFailureCount = 0
            didWriteDuringTerminate = true
            if let pendingMerge {
                adoptMergedLibrary(pendingMerge.outcome, preMergeLocal: pendingMerge.preMergeLocal)
            }
            rememberDiskBytes(outcome.data)

            let health: WriteHealth =
                outcome.wroteWithoutLock ? .unlocked
                : outcome.attempts > 1 ? .contended(attempts: outcome.attempts)
                : .healthy
            if health != writeHealth {
                writeHealth = health
                if health.isDegraded {
                    NSLog("Snippets: degraded library write — \(health).")
                }
                syncDelegate?.libraryDidChange(.local)
            }

            if outcome.foldedInForeignWrite {
                // Someone else's edit just became part of our state. The UI has to be
                // told, or it keeps rendering a library that no longer exists.
                notifyChanged(.external)
            }

        } catch {
            // NEVER return silently here, for ANY error. `persist()` has already
            // cleared `persistWorkItem`, so nothing else would reschedule this write —
            // and by this point the transform may already have mutated `snippets` and
            // the undo stacks. A disk-full or permissions failure would leave the
            // user's edit existing only in RAM, with no indication anything was wrong,
            // until the process exits.
            //
            // `.busy` is the ordinary case and retries quickly. Everything else is
            // probably persistent, so it backs off further but still keeps trying:
            // disks get emptied and permissions get repaired, and the alternative is
            // discarding work the user can see on screen.
            lockFailureCount += 1
            if case LibraryWriter.Failure.busy = error {} else {
                NSLog("Snippets: could not save the library (attempt \(lockFailureCount)): \(error)")
            }
            // On the terminate path the run loop will never spin again, so an
            // asyncAfter retry would silently never run. `flushPendingWrites` retries
            // inline instead and falls back to a recovery file.
            guard !isTerminating else { return }
            schedulePersistRetry()
        }
    }

    /// Backs off linearly, capped, and keeps trying. The alternative — giving up —
    /// silently discards whatever the user just typed.
    private func schedulePersistRetry() {
        persistWorkItem?.cancel()
        let delay = min(0.25 * Double(lockFailureCount), 2.0)
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.persistWorkItem = nil
                self.writeToDisk()
            }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)

        // Two failures in a row is no longer a hiccup; let the UI say so.
        if lockFailureCount >= 2 { syncDelegate?.libraryDidChange(.local) }
    }

    private func rememberDiskBytes(_ data: Data) {
        lastKnownDiskData = data
        lastKnownDigest = SnippetLibraryCodec.digest(of: data)
    }

    private func notifyChanged(_ source: ChangeSource) {
        librarySeq &+= 1
        onChange?(source)
        syncDelegate?.libraryDidChange(source)
    }

    /// Flushes a pending write, synchronously, with nowhere to defer to.
    ///
    /// This runs from `applicationWillTerminate`, which returns and then the process
    /// dies — so the run loop never spins again and `schedulePersistRetry`'s
    /// `asyncAfter` would simply never fire. Retrying has to happen inline, and if it
    /// still cannot land, the edit has to go *somewhere* rather than evaporate.
    func flushPendingWrites() {
        guard persistWorkItem != nil else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil

        let pending = snippets
        for attempt in 0..<3 {
            didWriteDuringTerminate = false
            writeToDisk(lockTimeout: terminateLockTimeout, isTerminating: true)
            if didWriteDuringTerminate { return }
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
        if let data = try? SnippetLibraryCodec.encode(pending) {
            try? AtomicFileWriter.write(data, to: rescue)
            NSLog("Snippets: could not save on quit; the pending library was written to \(rescue.path)")
        }
    }

    // MARK: - Undo / Redo

    func beginEditTransaction() {
        guard editTransactionSnapshot == nil else { return }
        editTransactionSnapshot = snippets
    }

    func commitEditTransaction() {
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
        guard let snapshot = undoStack.popLast() else { return false }
        redoStack.append(snippets)
        snippets = snapshot
        persist(immediately: true)
        return true
    }

    func redo() -> Bool {
        guard let snapshot = redoStack.popLast() else { return false }
        undoStack.append(snippets)
        snippets = snapshot
        persist(immediately: true)
        return true
    }

    private func startObservingExternalChanges() {
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
    private func reloadFromDiskIfNeeded() {
        guard let data = try? Data(contentsOf: saveURL) else { return }
        guard data != lastKnownDiskData else { return }

        let reloaded: [Snippet]
        do {
            reloaded = try decodeImportData(data)
        } catch {
            // Unreadable bytes must never be adopted, and must never be written back
            // over. Keep serving what we have; `load()` owns the quarantine path.
            NSLog("Failed to reload snippets: \(error.localizedDescription)")
            return
        }

        let ancestor = lastKnownDiskData.flatMap { try? SnippetLibraryCodec.decode($0) } ?? []
        rememberDiskBytes(data)

        let preMergeLocal = snippets
        let merged = SyncMerge.mergeLocal(
            base: ancestor, local: snippets, remote: reloaded)

        guard merged.snippets != preMergeLocal else { return }
        adoptMergedLibrary(merged, preMergeLocal: preMergeLocal)
        notifyChanged(.external)

        // If the merge produced something neither side had on disk — a conflict copy,
        // a disabled duplicate keyword, or simply our own unflushed edits surviving —
        // that result has to be written back or it exists only in this process.
        if merged.snippets != reloaded {
            persist()
        }
    }

    /// Installs a merge result and keeps undo coherent with it.
    private func adoptMergedLibrary(_ merged: SyncMerge.Outcome, preMergeLocal: [Snippet]) {
        snippets = merged.snippets
        rebaseUndoHistory(preMergeLocal: preMergeLocal, merged: merged.snippets)

        if !merged.conflictCopies.isEmpty {
            NSLog("Snippets: kept \(merged.conflictCopies.count) conflicting edit(s) as separate disabled snippets.")
        }
        if !merged.disabledByKeywordCollision.isEmpty {
            NSLog("Snippets: disabled \(merged.disabledByKeywordCollision.count) snippet(s) whose keyword collided after merging.")
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
