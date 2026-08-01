import Foundation

struct Snippet: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var keyword: String
    var content: String
    var tags: [String]
    var isEnabled: Bool
    var isPinned: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        keyword: String,
        content: String,
        tags: [String] = [],
        isEnabled: Bool = true,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.content = content
        self.tags = tags
        self.isEnabled = isEnabled
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    static var starterSnippet: Snippet {
        Snippet(
            name: "Temporary Password",
            keyword: "tp",
            content: "TP-{date:yyyyMMdd}-{clipboard}"
        )
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled Snippet" : trimmed
    }

    var normalizedKeyword: String {
        Self.sanitizedKeyword(keyword)
    }

    static func sanitizedKeyword(_ rawKeyword: String) -> String {
        var keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)

        while keyword.hasPrefix("\\") {
            keyword.removeFirst()
            keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return keyword
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

enum SnippetStorageSync {
    static let distributedChangeNotification = Notification.Name("com.khm.snippets.storageDidChange")
}

enum SnippetStorageLocations {
    static var supportFolderURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnippetsClone", isDirectory: true)
    }

    static var snippetsFileURL: URL {
        supportFolderURL.appendingPathComponent("snippets.json", isDirectory: false)
    }

    /// Deliberately a subdirectory: `SnippetStore` watches the parent folder
    /// with a `DispatchSource`, and an atomic write renames an inode into the
    /// destination directory. Writing usage data next to `snippets.json` would
    /// fire that monitor on every expansion and collapse the editor's write
    /// debounce.
    static var usageFolderURL: URL {
        supportFolderURL.appendingPathComponent("Usage", isDirectory: true)
    }

    static var usageFileURL: URL {
        usageFolderURL.appendingPathComponent("usage.json", isDirectory: false)
    }
}

enum SnippetTagging {
    /// Trims whitespace, drops empties, and dedupes case-insensitively while
    /// preserving the first-seen casing and input order.
    static func normalizedTags(_ rawTags: [String]) -> [String] {
        var seenKeys = Set<String>()
        var normalized: [String] = []

        for rawTag in rawTags {
            let tag = rawTag
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !tag.isEmpty else { continue }

            if seenKeys.insert(filterKey(for: tag)).inserted {
                normalized.append(tag)
            }
        }

        return normalized
    }

    /// Canonical key used for tag comparison, filtering, and color hashing.
    static func filterKey(for tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

extension Snippet {
    func hasTag(withKey key: String) -> Bool {
        tags.contains { SnippetTagging.filterKey(for: $0) == key }
    }
}

extension Snippet {
    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case keyword
        case content
        case tags
        case isEnabled
        case isPinned
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        keyword = try container.decode(String.self, forKey: .keyword)
        content = try container.decode(String.self, forKey: .content)
        tags = SnippetTagging.normalizedTags(try container.decodeIfPresent([String].self, forKey: .tags) ?? [])
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(keyword, forKey: .keyword)
        try container.encode(content, forKey: .content)
        try container.encode(tags, forKey: .tags)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }
}
