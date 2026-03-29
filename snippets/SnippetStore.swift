import Foundation

@MainActor
final class SnippetStore {
    struct ImportOptions {
        var preserveExclamationPrefix = false
    }

    private(set) var snippets: [Snippet] = []

    var onChange: (() -> Void)?

    private let saveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistWorkItem: DispatchWorkItem?
    private let persistDelay: TimeInterval = 0.3

    private var undoStack: [[Snippet]] = []
    private var redoStack: [[Snippet]] = []
    private let maxUndoLevels = 50

    enum ImportExportError: LocalizedError {
        case emptyImport
        case invalidFormat
        case cannotAccessFile

        var errorDescription: String? {
            switch self {
            case .emptyImport:
                return "The selected file does not contain any snippets."
            case .invalidFormat:
                return "Unsupported file format. Expected JSON exported from this app."
            case .cannotAccessFile:
                return "Could not read or write the selected file."
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

        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SnippetsClone", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        saveURL = folder.appendingPathComponent("snippets.json", isDirectory: false)

        load()
    }

    func addSnippet() -> Snippet {
        pushUndo()
        let snippet = Snippet(name: "", keyword: "", content: "")
        snippets.insert(snippet, at: 0)
        persist(immediately: true)
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let existing = snippets[index]

        var updated = snippet
        updated.keyword = updated.normalizedKeyword

        let didChange =
            existing.name != updated.name ||
            existing.keyword != updated.keyword ||
            existing.content != updated.content ||
            existing.isEnabled != updated.isEnabled ||
            existing.isPinned != updated.isPinned

        guard didChange else { return }

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
        let duplicate = Snippet(
            name: source.displayName + " Copy",
            keyword: source.keyword,
            content: source.content,
            isEnabled: source.isEnabled,
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

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
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

        var imported = try decodeImportData(data, options: options)
        imported = normalizeImportedSnippets(imported)

        guard !imported.isEmpty else {
            throw ImportExportError.emptyImport
        }

        pushUndo()

        var merged = snippets
        var importedCount = 0

        for incoming in imported {
            if let idIndex = merged.firstIndex(where: { $0.id == incoming.id }) {
                merged[idIndex] = incoming
                importedCount += 1
                continue
            }

            if !incoming.normalizedKeyword.isEmpty,
               let keywordIndex = merged.firstIndex(where: {
                   $0.normalizedKeyword.caseInsensitiveCompare(incoming.normalizedKeyword) == .orderedSame
               }) {
                var replacement = incoming
                replacement.id = merged[keywordIndex].id
                replacement.createdAt = merged[keywordIndex].createdAt
                merged[keywordIndex] = replacement
                importedCount += 1
                continue
            }

            merged.insert(incoming, at: 0)
            importedCount += 1
        }

        snippets = merged
        persist(immediately: true)
        return importedCount
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
        } catch {
            snippets = [Snippet.starterSnippet]
            persist()
        }
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

    private static func normalizedRaycastKeyword(
        from rawKeyword: String?,
        preserveExclamationPrefix: Bool
    ) -> String {
        var keyword = (rawKeyword ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if keyword.hasPrefix("\\") {
            keyword.removeFirst()
        }

        if !preserveExclamationPrefix, keyword.hasPrefix("!") {
            keyword.removeFirst()
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
        onChange?()
        persistWorkItem?.cancel()

        if immediately {
            writeToDisk()
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.writeToDisk()
            }
        }
        persistWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + persistDelay, execute: workItem)
    }

    private func writeToDisk() {
        do {
            let data = try encoder.encode(snippets)
            try data.write(to: saveURL, options: .atomic)
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

    private func pushUndo() {
        undoStack.append(snippets)
        if undoStack.count > maxUndoLevels {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
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
}
