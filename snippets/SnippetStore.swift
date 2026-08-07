import Darwin
import Foundation

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

    private var undoStack: [[Snippet]] = []
    private var redoStack: [[Snippet]] = []
    private var editTransactionSnapshot: [Snippet]?
    private var editTransactionNeedsRestart = false
    private let maxUndoLevels = 50

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
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveFolderURL = folder
        saveURL = SnippetStorageLocations.snippetsFileURL

        load()
        startObservingExternalChanges()
    }

    deinit {
        persistWorkItem?.cancel()
        externalReloadWorkItem?.cancel()
        saveDirectoryMonitor?.cancel()
        if let distributedChangeObserver {
            DistributedNotificationCenter.default().removeObserver(distributedChangeObserver)
        }
    }

    /// `name` is set here rather than by a follow-up `update`: creation pushes
    /// one undo entry, and a second call to name the new snippet would push
    /// another, so one ⌘Z would clear the name and only a second would undo the
    /// creation the user actually asked to take back.
    func addSnippet(name: String = "", content: String = "", tags: [String] = []) -> Snippet {
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

        for snippet in snippets {
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

    func snippetsSortedForDisplay() -> [Snippet] {
        let pinned = snippets.filter(\.isPinned)
        let unpinned = snippets.filter { !$0.isPinned }
        return pinned + unpinned
    }

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
            lastKnownDiskData = data
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
        onChange?(.local)
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

    private func writeToDisk() {
        do {
            let data = try encoder.encode(snippets)
            try data.write(to: saveURL, options: .atomic)
            lastKnownDiskData = data
        } catch {
            NSLog("Failed to save snippets: \(error.localizedDescription)")
        }
    }

    func flushPendingWrites() {
        guard persistWorkItem != nil else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil
        writeToDisk()
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

    private func reloadFromDiskIfNeeded() {
        // True conflict: a local debounced write is still pending AND the file
        // changed underneath us. Policy: the in-app edit wins — the user made
        // it within the last `persistDelay` seconds, so flush it over the
        // external change rather than dropping their keystrokes. (Merging the
        // two is out of scope.) A non-nil persistWorkItem is guaranteed to
        // mean a genuinely pending write; completed or superseded work items
        // clear the reference.
        guard persistWorkItem == nil else {
            flushPendingWrites()
            return
        }

        guard let data = try? Data(contentsOf: saveURL) else { return }
        guard data != lastKnownDiskData else { return }

        do {
            let reloadedSnippets = try decodeImportData(data)
            lastKnownDiskData = data

            guard reloadedSnippets != snippets else { return }

            undoStack.removeAll()
            redoStack.removeAll()
            // If a UI edit transaction is open, rebase it onto the reloaded
            // state; committing the pre-reload snapshot would let undo
            // resurrect (and persist) data that no longer exists on disk.
            if editTransactionSnapshot != nil {
                editTransactionSnapshot = reloadedSnippets
            }
            snippets = reloadedSnippets
            onChange?(.external)
        } catch {
            NSLog("Failed to reload snippets: \(error.localizedDescription)")
        }
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
