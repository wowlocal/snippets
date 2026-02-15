import Foundation
import Combine

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let saveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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
        let snippet = Snippet(name: "", keyword: "\\", content: "")
        snippets.insert(snippet, at: 0)
        persist()
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        var updated = snippet
        updated.keyword = updated.normalizedKeyword
        updated.updatedAt = Date()
        snippets[index] = updated
        persist()
    }

    func delete(snippetID: UUID) {
        snippets.removeAll { $0.id == snippetID }
        persist()
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
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

    @discardableResult
    func importSnippets(from url: URL) throws -> Int {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportExportError.cannotAccessFile
        }

        var imported = try decodeImportData(data)
        imported = normalizeImportedSnippets(imported)

        guard !imported.isEmpty else {
            throw ImportExportError.emptyImport
        }

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
        persist()
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
        if let directArray = try? decoder.decode([Snippet].self, from: data) {
            return directArray
        }

        if let collection = try? decoder.decode(SnippetCollection.self, from: data) {
            return collection.snippets
        }

        throw ImportExportError.invalidFormat
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

    private func persist() {
        do {
            let data = try encoder.encode(snippets)
            try data.write(to: saveURL, options: .atomic)
        } catch {
            NSLog("Failed to save snippets: \(error.localizedDescription)")
        }
    }
}
