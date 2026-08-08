import Foundation

// This file is compiled into THREE targets with different default isolation:
//   - the Snippets app target (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor)
//   - the snippets-cli target (no default isolation)
//   - the SnippetsCore test package (no default isolation)
// Every top-level declaration below is therefore explicitly `nonisolated`. Without
// it the same source compiles with two different semantics in two targets, and the
// mismatch only ever shows up as a confusing diagnostic in the target you were not
// looking at.

nonisolated struct Snippet: Identifiable, Codable, Equatable {
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

nonisolated enum SnippetStorageSync {
    static let distributedChangeNotification = Notification.Name("com.khm.snippets.storageDidChange")
}

nonisolated enum SnippetStorageLocations {

    /// Redirects every path below to a different root.
    ///
    /// This exists because there is no other honest way to test the cross-process
    /// concurrency behaviour. Proving that two processes do not lose each other's
    /// writes means actually running two processes, and those processes resolve their
    /// own paths — so the test has to be able to point them somewhere safe. Overriding
    /// `HOME` does not work: `FileManager.urls(for:.applicationSupportDirectory)`
    /// resolves the real home regardless, which is how a concurrency test once wrote
    /// sixty rows into a live library.
    ///
    /// Unset in every shipping configuration; the app and the CLI both simply ignore it.
    static let rootOverrideEnvironmentKey = "SNIPPETS_SUPPORT_DIR"

    static var supportFolderURL: URL {
        if let override = ProcessInfo.processInfo.environment[rootOverrideEnvironmentKey],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default
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

    // MARK: - Sync, vault, and backup locations
    //
    // Every one of these is a SUBDIRECTORY, for exactly the reason spelled out
    // above `usageFolderURL`. `SnippetStore` watches `supportFolderURL` with a
    // `DispatchSource`, and `rename(2)` — which is what an atomic write ends in —
    // mutates the *destination* directory's vnode. A sidecar file living next to
    // `snippets.json` would fire that monitor on every sync tick, every lock
    // acquisition, and every backup, collapsing the editor's write debounce each
    // time. Nothing outside this type may ever put a file directly in
    // `supportFolderURL`.

    /// Sync bookkeeping: device identity, the merge ancestor, tombstones, and the
    /// lock file. None of it is user data; all of it is derived or regenerable.
    static var syncFolderURL: URL {
        supportFolderURL.appendingPathComponent("Sync", isDirectory: true)
    }

    static var syncStateFileURL: URL {
        syncFolderURL.appendingPathComponent("state.json", isDirectory: false)
    }

    /// The last-synced snapshot of the library — the common ancestor every
    /// three-way merge is resolved against.
    static var syncBaseFileURL: URL {
        syncFolderURL.appendingPathComponent("base.json", isDirectory: false)
    }

    /// The last envelope projected into the frozen local library files.
    ///
    /// Unlike `base.json`, this is the local side of the merge. It retains clocks,
    /// origins and extension data that neither `snippets.json` nor `vault.json` can
    /// represent, and is entirely derived/recoverable.
    static var syncLibraryMetadataFileURL: URL {
        syncFolderURL.appendingPathComponent("library-metadata.json", isDirectory: false)
    }

    static var tombstonesFileURL: URL {
        syncFolderURL.appendingPathComponent("tombstones.json", isDirectory: false)
    }

    /// A zero-byte `flock(2)` target, created once and **never unlinked or
    /// replaced**. Locking `snippets.json` itself does not work: an atomic write
    /// renames a fresh inode over the path, so the next writer flocks a different
    /// file than the one already held and both proceed. Measured: locking the data
    /// file loses as many writes as no lock at all.
    static var libraryLockFileURL: URL {
        syncFolderURL.appendingPathComponent("library.lock", isDirectory: false)
    }

    /// Remote records that could not be decrypted. Kept for diagnosis, never applied.
    static var syncQuarantineFolderURL: URL {
        syncFolderURL.appendingPathComponent("Quarantine", isDirectory: true)
    }

    /// Secure snippets. Metadata is plaintext here; `content` never is.
    static var vaultFolderURL: URL {
        supportFolderURL.appendingPathComponent("Vault", isDirectory: true)
    }

    static var vaultFileURL: URL {
        vaultFolderURL.appendingPathComponent("vault.json", isDirectory: false)
    }

    /// Reveal-audit log. Deliberately *not* in `Usage/`, which carries a published
    /// promise never to leave the Mac and a very different retention policy.
    static var vaultAuditFileURL: URL {
        vaultFolderURL.appendingPathComponent("audit.json", isDirectory: false)
    }

    /// Rolling snapshots taken before anything destructive.
    static var backupsFolderURL: URL {
        supportFolderURL.appendingPathComponent("Backups", isDirectory: true)
    }

    /// Scratch for `mkstemp`. Creating the temp file in the *same* directory as the
    /// final path would make every atomic write two monitor events (create, then
    /// rename) instead of one.
    static var tmpFolderURL: URL {
        supportFolderURL.appendingPathComponent("Tmp", isDirectory: true)
    }

    /// Creates every directory the app needs.
    ///
    /// Must be called from `SnippetStore.init` *before* `startObservingExternalChanges()`,
    /// so these `mkdir`s happen while no monitor exists to observe them. Creating
    /// them lazily on first use would fire the folder monitor at an arbitrary later
    /// moment — the exact bug the `Usage/` comment above was written to prevent.
    static func createAllDirectories(fileManager: FileManager = .default) {
        for folder in [
            supportFolderURL, usageFolderURL, syncFolderURL,
            syncQuarantineFolderURL, vaultFolderURL, backupsFolderURL, tmpFolderURL,
        ] {
            try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }
}

nonisolated enum SnippetTagging {
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
    ///
    /// Folded against a FIXED locale, never `.current`. This key decides tag identity
    /// and keyword collisions, and the merge is specified as a pure function of its
    /// inputs — reading `Locale.current` would make it a function of ambient process
    /// state as well, so two machines with different system languages could compute
    /// different results from byte-identical files and never converge. Turkish is the
    /// live case: with a Turkish locale `I` folds to `ı`, not `i`, so a tag written on
    /// one Mac stops matching itself on another.
    ///
    /// `en_US_POSIX` is the usual choice for a locale that is guaranteed not to drift.
    static func filterKey(for tag: String) -> String {
        tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
    }

    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
}

nonisolated extension Snippet {
    func hasTag(withKey key: String) -> Bool {
        tags.contains { SnippetTagging.filterKey(for: $0) == key }
    }
}

nonisolated extension Snippet {
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
