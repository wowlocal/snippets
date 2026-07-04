import Foundation

// MARK: - Storage

private let saveURL: URL = {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return appSupport.appendingPathComponent("SnippetsClone/snippets.json")
}()

/// Loads the snippet library. A missing file means an empty library; an
/// existing file that cannot be read or decoded aborts the command (for every
/// command, read or write) so a later save can never wipe the user's data.
private func loadSnippets() -> [Snippet] {
    guard FileManager.default.fileExists(atPath: saveURL.path) else { return [] }

    let data: Data
    do {
        data = try Data(contentsOf: saveURL)
    } catch {
        fail("cannot read snippets file at '\(saveURL.path)': \(error.localizedDescription)")
    }

    let decoder = JSONDecoder()
    if let array = try? decoder.decode([Snippet].self, from: data) { return array }
    struct Wrapper: Decodable { let snippets: [Snippet] }
    if let wrapper = try? decoder.decode(Wrapper.self, from: data) { return wrapper.snippets }
    fail("snippets file at '\(saveURL.path)' exists but could not be decoded; fix or move it aside and retry")
}

private func saveSnippets(_ snippets: [Snippet]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(snippets)
    try data.write(to: saveURL, options: .atomic)
    DistributedNotificationCenter.default().postNotificationName(
        SnippetStorageSync.distributedChangeNotification,
        object: saveURL.path,
        userInfo: nil,
        deliverImmediately: true
    )
}

// MARK: - Output

private let outputEncoder: JSONEncoder = {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    return enc
}()

private func printJSON(_ value: some Encodable) {
    guard let data = try? outputEncoder.encode(value),
          let str = String(data: data, encoding: .utf8) else { return }
    print(str)
}

private func fail(_ message: String, code: Int32 = 1) -> Never {
    fputs("error: \(message)\n", stderr)
    exit(code)
}

// MARK: - Tags

private func parseTags(_ value: String) -> [String] {
    SnippetTagging.normalizedTags(value.components(separatedBy: ","))
}

/// AND semantics across filters, matching the app's tag filter bar.
private func filterByTags(_ snippets: [Snippet], tagFilters: [String]) -> [Snippet] {
    guard !tagFilters.isEmpty else { return snippets }
    let keys = tagFilters.map { SnippetTagging.filterKey(for: $0) }
    return snippets.filter { snippet in keys.allSatisfy { snippet.hasTag(withKey: $0) } }
}

// MARK: - Commands

private func cmdList(enabledOnly: Bool, pinnedOnly: Bool, tagFilters: [String]) {
    var snippets = loadSnippets()
    if enabledOnly { snippets = snippets.filter(\.isEnabled) }
    if pinnedOnly  { snippets = snippets.filter(\.isPinned) }
    snippets = filterByTags(snippets, tagFilters: tagFilters)
    printJSON(snippets)
}

private func cmdTags() {
    struct TagUsage: Encodable {
        let tag: String
        let count: Int
    }

    // Mirror the app's tag list: dedupe by folded key, keep first-seen casing.
    var canonicalTags: [String: String] = [:]
    var counts: [String: Int] = [:]
    for snippet in loadSnippets() {
        for tag in snippet.tags {
            let key = SnippetTagging.filterKey(for: tag)
            if canonicalTags[key] == nil { canonicalTags[key] = tag }
            counts[key, default: 0] += 1
        }
    }

    let usage = canonicalTags
        .map { TagUsage(tag: $0.value, count: counts[$0.key] ?? 0) }
        .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    printJSON(usage)
}

private func cmdSearch(query: String, enabledOnly: Bool, tagFilters: [String]) {
    struct SearchResult: Encodable {
        let score: Int
        let snippet: Snippet
    }

    func searchScore(for snippet: Snippet, query: String) -> Int? {
        let nameScore = FuzzyMatch.score(query: query, target: snippet.displayName)
        let keywordScore = FuzzyMatch.score(query: query, target: snippet.normalizedKeyword)
        let contentMatches = snippet.content.localizedCaseInsensitiveContains(query)
        let tagMatches = snippet.tags.contains { $0.localizedCaseInsensitiveContains(query) }

        let fuzzyScore = max(
            nameScore.matched ? nameScore.score + 10 : 0,
            keywordScore.matched ? keywordScore.score + 20 : 0
        )

        if fuzzyScore > 0 {
            return (contentMatches || tagMatches) ? fuzzyScore + 1 : fuzzyScore
        }

        guard contentMatches || tagMatches else { return nil }
        return max(1, query.count)
    }

    var snippets = loadSnippets()
    if enabledOnly { snippets = snippets.filter(\.isEnabled) }
    snippets = filterByTags(snippets, tagFilters: tagFilters)

    let results = snippets
        .compactMap { snippet -> SearchResult? in
            guard let score = searchScore(for: snippet, query: query) else { return nil }
            return SearchResult(score: score, snippet: snippet)
        }
        .sorted { $0.score > $1.score }

    printJSON(results)
}

private func cmdGet(keyword: String) {
    let lookupKeyword = Snippet.sanitizedKeyword(keyword)
    let snippets = loadSnippets()
    guard let snippet = snippets.first(where: {
        $0.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
    }) else {
        fail("no snippet found with keyword '\(keyword)'")
    }
    printJSON(snippet)
}

/// The expansion engine matches keywords ignoring case AND diacritics, so two
/// keywords with the same folded key (e.g. `cafe` and `café`) would silently
/// stop expanding. Reject such collisions up front.
private func requireNoKeywordCollision(
    _ keyword: String, in snippets: [Snippet], excludingID: UUID? = nil
) {
    let key = SnippetTagging.filterKey(for: keyword)
    guard !key.isEmpty else { return }

    if let existing = snippets.first(where: {
        $0.id != excludingID && SnippetTagging.filterKey(for: $0.normalizedKeyword) == key
    }) {
        fail("keyword '\(keyword)' conflicts with existing snippet '\(existing.displayName)' (keyword '\(existing.normalizedKeyword)'); keywords are compared ignoring case and diacritics")
    }
}

private func cmdAdd(name: String, keyword: String, content: String, tags: [String], enabled: Bool, pinned: Bool) {
    let sanitizedKeyword = Snippet.sanitizedKeyword(keyword)
    guard !sanitizedKeyword.isEmpty else {
        fail("--keyword must not be empty")
    }
    var snippets = loadSnippets()
    requireNoKeywordCollision(sanitizedKeyword, in: snippets)
    let snippet = Snippet(
        name: name,
        keyword: sanitizedKeyword,
        content: content,
        tags: tags,
        isEnabled: enabled,
        isPinned: pinned
    )
    snippets.insert(snippet, at: 0)
    do { try saveSnippets(snippets) } catch { fail("failed to save: \(error.localizedDescription)") }
    printJSON(snippet)
}

private func cmdUpdate(
    keywordOrID: String,
    name: String?,
    keyword: String?,
    content: String?,
    tags: [String]?,
    addTags: [String]?,
    removeTags: [String]?,
    enabled: Bool?,
    pinned: Bool?
) {
    if tags != nil && (addTags != nil || removeTags != nil) {
        fail("--tags replaces all tags and cannot be combined with --add-tags/--remove-tags")
    }

    var snippets = loadSnippets()
    let lookupKeyword = Snippet.sanitizedKeyword(keywordOrID)

    guard let index = snippets.firstIndex(where: { s in
        if let id = UUID(uuidString: keywordOrID) { return s.id == id }
        return s.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
    }) else {
        fail("no snippet found matching '\(keywordOrID)'")
    }

    var updated = snippets[index]
    if let name    = name    { updated.name    = name }
    if let keyword = keyword {
        let sanitized = Snippet.sanitizedKeyword(keyword)
        requireNoKeywordCollision(sanitized, in: snippets, excludingID: updated.id)
        updated.keyword = sanitized
    }
    if let content = content { updated.content = content }
    if let tags = tags { updated.tags = tags }
    if let addTags = addTags {
        updated.tags = SnippetTagging.normalizedTags(updated.tags + addTags)
    }
    if let removeTags = removeTags {
        let removeKeys = Set(removeTags.map { SnippetTagging.filterKey(for: $0) })
        updated.tags.removeAll { removeKeys.contains(SnippetTagging.filterKey(for: $0)) }
    }
    if let enabled = enabled { updated.isEnabled = enabled }
    if let pinned  = pinned  { updated.isPinned  = pinned  }
    updated.updatedAt = Date()

    snippets[index] = updated
    do { try saveSnippets(snippets) } catch { fail("failed to save: \(error.localizedDescription)") }
    printJSON(updated)
}

private func cmdDelete(keywordOrID: String) {
    var snippets = loadSnippets()
    let before = snippets.count
    let lookupKeyword = Snippet.sanitizedKeyword(keywordOrID)

    if let id = UUID(uuidString: keywordOrID) {
        snippets.removeAll { $0.id == id }
    } else {
        snippets.removeAll {
            $0.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
        }
    }

    guard snippets.count < before else {
        fail("no snippet found matching '\(keywordOrID)'")
    }

    do { try saveSnippets(snippets) } catch { fail("failed to save: \(error.localizedDescription)") }

    struct Result: Encodable { let deleted: Int }
    printJSON(Result(deleted: before - snippets.count))
}

// MARK: - Argument parsing helpers

private func nextArg(_ args: [String], after i: Int, flag: String) -> String {
    guard i + 1 < args.count else { fail("\(flag) requires a value") }
    return args[i + 1]
}

private func readContent(from arg: String) -> String {
    if arg == "-" {
        return String(bytes: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
    return arg
}

// MARK: - Usage

private func usage() -> Never {
    print("""
    Usage: snippets-cli <command> [options]

    Commands:
      list                           List all snippets
        --enabled                    Show only enabled snippets
        --pinned                     Show only pinned snippets
        --tag <tag>                  Show only snippets with this tag (repeatable; AND)

      search <query>                 Search snippets by name, keyword, content, and tags
        --enabled                    Search only enabled snippets
        --tag <tag>                  Search only snippets with this tag (repeatable; AND)

      get <keyword>                  Get a snippet by exact keyword match

      tags                           List all tags with usage counts

      add --keyword <kw>             Add a new snippet
          --name <name>
          --content <text>|-         (use - to read content from stdin)
          --tags <a,b,c>             Comma-separated tags
          --disabled
          --pinned

      update <keyword-or-id>         Update an existing snippet
             [--name <name>]
             [--keyword <kw>]
             [--content <text>|-]
             [--tags <a,b,c>]        Replace all tags (empty string clears them)
             [--add-tags <a,b>]      Add tags, keeping existing ones
             [--remove-tags <a,b>]   Remove tags, keeping the rest
             [--enabled|--disabled]
             [--pinned|--unpinned]

      delete <keyword-or-id>         Delete a snippet by keyword or UUID

    Tags are matched ignoring case and diacritics, like the app.
    All output is JSON. Errors are written to stderr with a non-zero exit code.
    """)
    exit(0)
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }

switch args[0] {

case "list":
    var tagFilters: [String] = []
    var i = 1
    while i < args.count {
        if args[i] == "--tag" {
            tagFilters.append(nextArg(args, after: i, flag: "--tag")); i += 1
        }
        i += 1
    }
    cmdList(
        enabledOnly: args.contains("--enabled"),
        pinnedOnly:  args.contains("--pinned"),
        tagFilters:  tagFilters
    )

case "search":
    var query = ""
    var enabledOnly = false
    var tagFilters: [String] = []
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--enabled": enabledOnly = true
        case "--tag":
            tagFilters.append(nextArg(args, after: i, flag: "--tag")); i += 1
        default: query = args[i]
        }
        i += 1
    }
    guard !query.isEmpty else { fail("search requires a query argument") }
    cmdSearch(query: query, enabledOnly: enabledOnly, tagFilters: tagFilters)

case "get":
    guard args.count >= 2 else { fail("get requires a keyword argument") }
    cmdGet(keyword: args[1])

case "tags":
    cmdTags()

case "add":
    var name    = ""
    var keyword = ""
    var content = ""
    var tags: [String] = []
    var enabled = true
    var pinned  = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--name":
            name = nextArg(args, after: i, flag: "--name"); i += 1
        case "--keyword":
            keyword = nextArg(args, after: i, flag: "--keyword"); i += 1
        case "--content":
            content = readContent(from: nextArg(args, after: i, flag: "--content")); i += 1
        case "--tags":
            tags = parseTags(nextArg(args, after: i, flag: "--tags")); i += 1
        case "--disabled": enabled = false
        case "--pinned":   pinned  = true
        default: break
        }
        i += 1
    }
    cmdAdd(name: name, keyword: keyword, content: content, tags: tags, enabled: enabled, pinned: pinned)

case "update":
    guard args.count >= 2 else { fail("update requires a keyword or UUID argument") }
    let target = args[1]
    var name:       String?   = nil
    var keyword:    String?   = nil
    var content:    String?   = nil
    var tags:       [String]? = nil
    var addTags:    [String]? = nil
    var removeTags: [String]? = nil
    var enabled:    Bool?     = nil
    var pinned:     Bool?     = nil
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--name":
            name = nextArg(args, after: i, flag: "--name"); i += 1
        case "--keyword":
            keyword = nextArg(args, after: i, flag: "--keyword"); i += 1
        case "--content":
            content = readContent(from: nextArg(args, after: i, flag: "--content")); i += 1
        case "--tags":
            tags = parseTags(nextArg(args, after: i, flag: "--tags")); i += 1
        case "--add-tags":
            addTags = parseTags(nextArg(args, after: i, flag: "--add-tags")); i += 1
        case "--remove-tags":
            removeTags = parseTags(nextArg(args, after: i, flag: "--remove-tags")); i += 1
        case "--enabled":  enabled = true
        case "--disabled": enabled = false
        case "--pinned":   pinned  = true
        case "--unpinned": pinned  = false
        default: break
        }
        i += 1
    }
    cmdUpdate(
        keywordOrID: target,
        name: name,
        keyword: keyword,
        content: content,
        tags: tags,
        addTags: addTags,
        removeTags: removeTags,
        enabled: enabled,
        pinned: pinned
    )

case "delete":
    guard args.count >= 2 else { fail("delete requires a keyword or UUID argument") }
    cmdDelete(keywordOrID: args[1])

case "help", "--help", "-h":
    usage()

default:
    fail("unknown command '\(args[0])'. Run 'snippets-cli help' for usage.")
}
