import Foundation
import Combine

@MainActor
final class SnippetStore: ObservableObject {
    @Published private(set) var snippets: [Snippet] = []

    private let saveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

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

    private func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            snippets = [Snippet.starterSnippet]
            persist()
            return
        }

        do {
            let data = try Data(contentsOf: saveURL)
            snippets = try decoder.decode([Snippet].self, from: data)
        } catch {
            snippets = [Snippet.starterSnippet]
            persist()
        }
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
