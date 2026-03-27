import Foundation

@MainActor
final class SnippetStore {
    struct ImportResult {
        let insertedCount: Int
        let updatedCount: Int
        let duplicateNames: [String]

        var importedCount: Int {
            insertedCount + updatedCount
        }
    }

    struct GroupCreationResult {
        let group: SnippetGroup
        let created: Bool
    }

    enum GroupMutationError: LocalizedError {
        case emptyName
        case duplicateName
        case missingGroup

        var errorDescription: String? {
            switch self {
            case .emptyName:
                return "Group names cannot be empty."
            case .duplicateName:
                return "A group with that name already exists."
            case .missingGroup:
                return "The selected group no longer exists."
            }
        }
    }

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
        let groups: [SnippetGroup]
        let snippets: [Snippet]
    }

    private struct LegacySnippetCollection: Codable {
        let snippets: [Snippet]
    }

    private struct DecodedImportPayload {
        let groups: [SnippetGroup]
        let snippets: [Snippet]
    }

    private struct NormalizedGroupPayload {
        let groups: [SnippetGroup]
        let sourceToCanonicalID: [UUID: UUID]
    }

    private struct GroupMergeResult {
        let groups: [SnippetGroup]
        let sourceToResolvedID: [UUID: UUID]
        let didChange: Bool
    }

    private(set) var snippets: [Snippet] = []
    private(set) var groups: [SnippetGroup] = []

    var onChange: (() -> Void)?

    private let saveURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var persistWorkItem: DispatchWorkItem?
    private let persistDelay: TimeInterval = 0.3

    init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = appSupport.appendingPathComponent("SnippetsClone", isDirectory: true)
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        saveURL = folder.appendingPathComponent("snippets.json", isDirectory: false)

        load()
    }

    func addSnippet(defaultGroupID: UUID? = nil) -> Snippet {
        let snippet = Snippet(name: "", keyword: "", content: "", groupID: resolvedGroupID(defaultGroupID))
        snippets.insert(snippet, at: 0)
        persist(immediately: true)
        return snippet
    }

    func update(_ snippet: Snippet) {
        guard let index = snippets.firstIndex(where: { $0.id == snippet.id }) else { return }
        let existing = snippets[index]

        var updated = snippet
        updated.keyword = updated.normalizedKeyword
        updated.groupID = resolvedGroupID(updated.groupID)

        let didChange =
            existing.name != updated.name ||
            existing.keyword != updated.keyword ||
            existing.content != updated.content ||
            existing.groupID != updated.groupID ||
            existing.isEnabled != updated.isEnabled ||
            existing.isPinned != updated.isPinned

        guard didChange else { return }

        updated.updatedAt = Date()
        snippets[index] = updated
        persist()
    }

    func delete(snippetID: UUID) {
        snippets.removeAll { $0.id == snippetID }
        persist(immediately: true)
    }

    @discardableResult
    func duplicate(snippetID: UUID) -> Snippet? {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return nil }

        let source = snippets[index]
        let duplicate = Snippet(
            name: source.displayName + " Copy",
            keyword: source.keyword,
            content: source.content,
            groupID: source.groupID,
            isEnabled: source.isEnabled,
            isPinned: source.isPinned
        )
        snippets.insert(duplicate, at: index + 1)
        persist(immediately: true)
        return duplicate
    }

    func togglePinned(snippetID: UUID) {
        guard let index = snippets.firstIndex(where: { $0.id == snippetID }) else { return }
        snippets[index].isPinned.toggle()
        snippets[index].updatedAt = Date()
        persist(immediately: true)
    }

    func assignGroup(snippetID: UUID, groupID: UUID?) {
        guard let snippetIndex = snippets.firstIndex(where: { $0.id == snippetID }) else { return }

        let resolvedGroupID = resolvedGroupID(groupID)
        let now = Date()

        if snippets[snippetIndex].groupID == resolvedGroupID {
            if let resolvedGroupID, let groupIndex = groups.firstIndex(where: { $0.id == resolvedGroupID }) {
                groups[groupIndex].lastUsedAt = now
                groups[groupIndex].updatedAt = now
                persist()
            }
            return
        }

        snippets[snippetIndex].groupID = resolvedGroupID
        snippets[snippetIndex].updatedAt = now

        if let resolvedGroupID, let groupIndex = groups.firstIndex(where: { $0.id == resolvedGroupID }) {
            groups[groupIndex].lastUsedAt = now
            groups[groupIndex].updatedAt = now
        }

        persist(immediately: true)
    }

    func snippet(id: UUID) -> Snippet? {
        snippets.first { $0.id == id }
    }

    func group(id: UUID) -> SnippetGroup? {
        groups.first { $0.id == id }
    }

    func groupName(for groupID: UUID?) -> String? {
        guard let groupID, let group = group(id: groupID) else { return nil }
        return group.displayName
    }

    func groupsSortedForDisplay() -> [SnippetGroup] {
        groups.sorted { lhs, rhs in
            if lhs.lastUsedAt != rhs.lastUsedAt {
                return lhs.lastUsedAt > rhs.lastUsedAt
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    func snippetsSortedForDisplay() -> [Snippet] {
        sortSnippetsForDisplay(snippets)
    }

    func sortSnippetsForDisplay(_ snippets: [Snippet]) -> [Snippet] {
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

    @discardableResult
    func createOrFindGroup(named name: String) throws -> GroupCreationResult {
        let trimmedName = trimmedGroupName(name)
        guard !trimmedName.isEmpty else {
            throw GroupMutationError.emptyName
        }

        let comparisonKey = normalizedGroupNameKey(trimmedName)
        let now = Date()

        if let index = groups.firstIndex(where: { $0.comparisonKey == comparisonKey }) {
            groups[index].lastUsedAt = now
            groups[index].updatedAt = now
            persist(immediately: true)
            return GroupCreationResult(group: groups[index], created: false)
        }

        let group = SnippetGroup(name: trimmedName, createdAt: now, updatedAt: now, lastUsedAt: now)
        groups.append(group)
        persist(immediately: true)
        return GroupCreationResult(group: group, created: true)
    }

    @discardableResult
    func renameGroup(groupID: UUID, to name: String) throws -> SnippetGroup {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            throw GroupMutationError.missingGroup
        }

        let trimmedName = trimmedGroupName(name)
        guard !trimmedName.isEmpty else {
            throw GroupMutationError.emptyName
        }

        let comparisonKey = normalizedGroupNameKey(trimmedName)
        if groups.contains(where: { $0.id != groupID && $0.comparisonKey == comparisonKey }) {
            throw GroupMutationError.duplicateName
        }

        groups[index].name = trimmedName
        groups[index].updatedAt = Date()
        persist(immediately: true)
        return groups[index]
    }

    func deleteGroup(groupID: UUID) {
        guard groups.contains(where: { $0.id == groupID }) else { return }
        groups.removeAll { $0.id == groupID }
        for index in snippets.indices where snippets[index].groupID == groupID {
            snippets[index].groupID = nil
            snippets[index].updatedAt = Date()
        }
        persist(immediately: true)
    }

    func touchGroup(groupID: UUID?) {
        guard let groupID, let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let now = Date()
        groups[index].lastUsedAt = now
        groups[index].updatedAt = now
        persist()
    }

    @discardableResult
    func importSnippets(from url: URL) throws -> ImportResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ImportExportError.cannotAccessFile
        }

        let decoded = try decodeImportData(data)
        let normalizedPayload = normalizeImportedPayload(decoded)

        guard !normalizedPayload.snippets.isEmpty else {
            throw ImportExportError.emptyImport
        }

        let groupMerge = mergeImportedGroups(normalizedPayload.groups)
        let validGroupIDs = Set(groupMerge.groups.map(\.id))

        var mergedSnippets = snippets
        var insertedCount = 0
        var updatedCount = 0
        var duplicateNames: [String] = []

        for incoming in normalizedPayload.snippets {
            var resolvedSnippet = incoming
            if let groupID = resolvedSnippet.groupID {
                resolvedSnippet.groupID = groupMerge.sourceToResolvedID[groupID]
            }
            if let groupID = resolvedSnippet.groupID, !validGroupIDs.contains(groupID) {
                resolvedSnippet.groupID = nil
            }

            if let duplicate = mergedSnippets.first(where: { $0.content == resolvedSnippet.content }) {
                recordDuplicate(named: duplicate.displayName, in: &duplicateNames)
                continue
            }

            if let idIndex = mergedSnippets.firstIndex(where: { $0.id == resolvedSnippet.id }) {
                mergedSnippets[idIndex] = resolvedSnippet
                updatedCount += 1
                continue
            }

            if !resolvedSnippet.normalizedKeyword.isEmpty,
               let keywordIndex = mergedSnippets.firstIndex(where: {
                   $0.normalizedKeyword.caseInsensitiveCompare(resolvedSnippet.normalizedKeyword) == .orderedSame
               }) {
                var replacement = resolvedSnippet
                replacement.id = mergedSnippets[keywordIndex].id
                replacement.createdAt = mergedSnippets[keywordIndex].createdAt
                mergedSnippets[keywordIndex] = replacement
                updatedCount += 1
                continue
            }

            mergedSnippets.insert(resolvedSnippet, at: 0)
            insertedCount += 1
        }

        if groupMerge.didChange || insertedCount > 0 || updatedCount > 0 {
            groups = groupMerge.groups
            snippets = mergedSnippets
            persist(immediately: true)
        }

        return ImportResult(
            insertedCount: insertedCount,
            updatedCount: updatedCount,
            duplicateNames: duplicateNames
        )
    }

    @discardableResult
    func exportSnippets(to url: URL) throws -> Int {
        do {
            let payload = SnippetCollection(groups: groups, snippets: snippets)
            let data = try encoder.encode(payload)
            try data.write(to: url, options: .atomic)
            return snippets.count
        } catch {
            throw ImportExportError.cannotAccessFile
        }
    }

    func flushPendingWrites() {
        guard persistWorkItem != nil else { return }
        persistWorkItem?.cancel()
        persistWorkItem = nil
        writeToDisk()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: saveURL.path) else {
            groups = []
            snippets = [Snippet.starterSnippet]
            persist()
            return
        }

        do {
            let data = try Data(contentsOf: saveURL)
            let decoded = try decodeImportData(data)
            let normalized = normalizeImportedPayload(decoded)
            groups = normalized.groups
            snippets = normalized.snippets
        } catch {
            groups = []
            snippets = [Snippet.starterSnippet]
            persist()
        }
    }

    private func decodeImportData(_ data: Data) throws -> DecodedImportPayload {
        if let directArray = try? decoder.decode([Snippet].self, from: data) {
            return DecodedImportPayload(groups: [], snippets: directArray)
        }

        if let collection = try? decoder.decode(SnippetCollection.self, from: data) {
            return DecodedImportPayload(groups: collection.groups, snippets: collection.snippets)
        }

        if let legacyCollection = try? decoder.decode(LegacySnippetCollection.self, from: data) {
            return DecodedImportPayload(groups: [], snippets: legacyCollection.snippets)
        }

        throw ImportExportError.invalidFormat
    }

    private func normalizeImportedPayload(_ payload: DecodedImportPayload) -> DecodedImportPayload {
        let normalizedGroups = normalizeImportedGroups(payload.groups)
        let validGroupIDs = Set(normalizedGroups.groups.map(\.id))
        let normalizedSnippets = normalizeImportedSnippets(
            payload.snippets,
            sourceToCanonicalGroupID: normalizedGroups.sourceToCanonicalID,
            validGroupIDs: validGroupIDs
        )

        return DecodedImportPayload(groups: normalizedGroups.groups, snippets: normalizedSnippets)
    }

    private func normalizeImportedGroups(_ imported: [SnippetGroup]) -> NormalizedGroupPayload {
        var normalized: [SnippetGroup] = []
        var sourceToCanonicalID: [UUID: UUID] = [:]
        var seenIDs = Set<UUID>()
        var groupIndexByName: [String: Int] = [:]

        for item in imported {
            let sourceID = item.id

            var group = item
            group.name = trimmedGroupName(group.name)
            guard !group.name.isEmpty else { continue }

            if group.updatedAt < group.createdAt {
                group.updatedAt = group.createdAt
            }
            if group.lastUsedAt < group.createdAt {
                group.lastUsedAt = group.createdAt
            }

            let comparisonKey = group.comparisonKey
            if let existingIndex = groupIndexByName[comparisonKey] {
                let canonicalID = normalized[existingIndex].id
                if sourceToCanonicalID[sourceID] == nil {
                    sourceToCanonicalID[sourceID] = canonicalID
                }
                normalized[existingIndex].createdAt = min(normalized[existingIndex].createdAt, group.createdAt)
                normalized[existingIndex].updatedAt = max(normalized[existingIndex].updatedAt, group.updatedAt)
                normalized[existingIndex].lastUsedAt = max(normalized[existingIndex].lastUsedAt, group.lastUsedAt)
                continue
            }

            if seenIDs.contains(group.id) {
                group.id = UUID()
            }
            seenIDs.insert(group.id)

            if sourceToCanonicalID[sourceID] == nil {
                sourceToCanonicalID[sourceID] = group.id
            }
            groupIndexByName[comparisonKey] = normalized.count
            normalized.append(group)
        }

        return NormalizedGroupPayload(groups: normalized, sourceToCanonicalID: sourceToCanonicalID)
    }

    private func normalizeImportedSnippets(
        _ imported: [Snippet],
        sourceToCanonicalGroupID: [UUID: UUID],
        validGroupIDs: Set<UUID>
    ) -> [Snippet] {
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

            if let groupID = snippet.groupID {
                snippet.groupID = sourceToCanonicalGroupID[groupID]
                if let resolvedGroupID = snippet.groupID, !validGroupIDs.contains(resolvedGroupID) {
                    snippet.groupID = nil
                }
            }

            normalized.append(snippet)
        }

        return normalized
    }

    private func mergeImportedGroups(_ importedGroups: [SnippetGroup]) -> GroupMergeResult {
        var mergedGroups = groups
        var sourceToResolvedID: [UUID: UUID] = [:]
        var didChange = false

        for incoming in importedGroups {
            if let existingIndex = mergedGroups.firstIndex(where: { $0.comparisonKey == incoming.comparisonKey }) {
                sourceToResolvedID[incoming.id] = mergedGroups[existingIndex].id

                let updatedCreatedAt = min(mergedGroups[existingIndex].createdAt, incoming.createdAt)
                let updatedTimestamp = max(mergedGroups[existingIndex].updatedAt, incoming.updatedAt)
                let updatedLastUsedAt = max(mergedGroups[existingIndex].lastUsedAt, incoming.lastUsedAt)

                if updatedCreatedAt != mergedGroups[existingIndex].createdAt ||
                    updatedTimestamp != mergedGroups[existingIndex].updatedAt ||
                    updatedLastUsedAt != mergedGroups[existingIndex].lastUsedAt {
                    mergedGroups[existingIndex].createdAt = updatedCreatedAt
                    mergedGroups[existingIndex].updatedAt = updatedTimestamp
                    mergedGroups[existingIndex].lastUsedAt = updatedLastUsedAt
                    didChange = true
                }
                continue
            }

            var resolved = incoming
            if mergedGroups.contains(where: { $0.id == resolved.id }) {
                resolved.id = UUID()
            }

            mergedGroups.append(resolved)
            sourceToResolvedID[incoming.id] = resolved.id
            didChange = true
        }

        return GroupMergeResult(
            groups: mergedGroups,
            sourceToResolvedID: sourceToResolvedID,
            didChange: didChange
        )
    }

    private func trimmedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedGroupNameKey(_ name: String) -> String {
        trimmedGroupName(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func resolvedGroupID(_ groupID: UUID?) -> UUID? {
        guard let groupID, groups.contains(where: { $0.id == groupID }) else { return nil }
        return groupID
    }

    private func recordDuplicate(named name: String, in duplicates: inout [String]) {
        guard !duplicates.contains(name) else { return }
        duplicates.append(name)
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
            let data = try encoder.encode(SnippetCollection(groups: groups, snippets: snippets))
            try data.write(to: saveURL, options: .atomic)
        } catch {
            NSLog("Failed to save snippets: \(error.localizedDescription)")
        }
    }
}
