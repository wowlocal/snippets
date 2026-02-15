import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var keyword: String
    var content: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        keyword: String,
        content: String,
        isEnabled: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.content = content
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static var starterSnippet: Snippet {
        Snippet(
            name: "Temporary Password",
            keyword: "\\tp",
            content: "TP-{date:yyyyMMdd}-{clipboard}"
        )
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Snippet" : trimmed
    }

    var normalizedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
