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
        if !trimmed.isEmpty { return trimmed }

        let firstLine = contentFirstLine
        return firstLine.isEmpty ? "Untitled Snippet" : firstLine
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

    /// The one line that stands in for an unnamed snippet, whole. Which line it
    /// is gets decided here and nowhere else, so `displayName` and the row's
    /// content preview can never disagree about it.
    ///
    /// Lines that hold only whitespace are skipped rather than returned: a name
    /// made of blanks paints an empty row, which reads as a broken app rather
    /// than as a snippet nobody named.
    var contentFirstLineUntruncated: String {
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { return line }
        }

        return ""
    }

    /// The same line cut to a name's length, with the "…" baked in because these
    /// consumers are plain text — `displayName`, status strings, alerts, the CLI
    /// — where a silent cut would pass a truncated line off as the whole name.
    ///
    /// A label that truncates for itself wants `contentFirstLineUntruncated`: a
    /// count decided here lands the ellipsis wherever 50 characters happen to
    /// end, which in a resizable row is mid-width with empty space after it.
    var contentFirstLine: String {
        let maxCharacters = 50

        let line = contentFirstLineUntruncated
        guard line.count > maxCharacters else { return line }

        let endIndex = line.index(line.startIndex, offsetBy: maxCharacters)
        return String(line[..<endIndex]) + "…"
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
