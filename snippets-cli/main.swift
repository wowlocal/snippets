import Foundation

// MARK: - Storage

private let saveURL: URL = {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    return appSupport.appendingPathComponent("SnippetsClone/snippets.json")
}()

private func loadSnippets() -> [Snippet] {
    guard let data = try? Data(contentsOf: saveURL) else { return [] }
    let decoder = JSONDecoder()
    if let array = try? decoder.decode([Snippet].self, from: data) { return array }
    struct Wrapper: Decodable { let snippets: [Snippet] }
    if let wrapper = try? decoder.decode(Wrapper.self, from: data) { return wrapper.snippets }
    return []
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

// MARK: - Commands

private func cmdList(enabledOnly: Bool, pinnedOnly: Bool) {
    var snippets = loadSnippets()
    if enabledOnly { snippets = snippets.filter(\.isEnabled) }
    if pinnedOnly  { snippets = snippets.filter(\.isPinned) }
    printJSON(snippets)
}

private func cmdSearch(query: String, enabledOnly: Bool) {
    struct SearchResult: Encodable {
        let score: Int
        let snippet: Snippet
    }

    func searchScore(for snippet: Snippet, query: String) -> Int? {
        let nameScore = FuzzyMatch.score(query: query, target: snippet.displayName)
        let keywordScore = FuzzyMatch.score(query: query, target: snippet.normalizedKeyword)
        let contentMatches = snippet.content.localizedCaseInsensitiveContains(query)

        let fuzzyScore = max(
            nameScore.matched ? nameScore.score + 10 : 0,
            keywordScore.matched ? keywordScore.score + 20 : 0
        )

        if fuzzyScore > 0 {
            return contentMatches ? fuzzyScore + 1 : fuzzyScore
        }

        guard contentMatches else { return nil }
        return max(1, query.count)
    }

    var snippets = loadSnippets()
    if enabledOnly { snippets = snippets.filter(\.isEnabled) }

    let results = snippets
        .compactMap { snippet -> SearchResult? in
            guard let score = searchScore(for: snippet, query: query) else { return nil }
            return SearchResult(score: score, snippet: snippet)
        }
        .sorted { $0.score > $1.score }

    printJSON(results)
}

private func cmdGet(keyword: String) {
    let snippets = loadSnippets()
    guard let snippet = snippets.first(where: {
        $0.normalizedKeyword.caseInsensitiveCompare(keyword) == .orderedSame
    }) else {
        fail("no snippet found with keyword '\(keyword)'")
    }
    printJSON(snippet)
}

private func cmdAdd(name: String, keyword: String, content: String, enabled: Bool, pinned: Bool) {
    guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        fail("--keyword must not be empty")
    }
    var snippets = loadSnippets()
    let snippet = Snippet(
        name: name,
        keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines),
        content: content,
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
    enabled: Bool?,
    pinned: Bool?
) {
    var snippets = loadSnippets()

    guard let index = snippets.firstIndex(where: { s in
        if let id = UUID(uuidString: keywordOrID) { return s.id == id }
        return s.normalizedKeyword.caseInsensitiveCompare(keywordOrID) == .orderedSame
    }) else {
        fail("no snippet found matching '\(keywordOrID)'")
    }

    var updated = snippets[index]
    if let name    = name    { updated.name    = name }
    if let keyword = keyword { updated.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines) }
    if let content = content { updated.content = content }
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

    if let id = UUID(uuidString: keywordOrID) {
        snippets.removeAll { $0.id == id }
    } else {
        snippets.removeAll {
            $0.normalizedKeyword.caseInsensitiveCompare(keywordOrID) == .orderedSame
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

      search <query>                 Search snippets by name, keyword, and content
        --enabled                    Search only enabled snippets

      get <keyword>                  Get a snippet by exact keyword match

      add --keyword <kw>             Add a new snippet
          --name <name>
          --content <text>|-         (use - to read content from stdin)
          --disabled
          --pinned

      update <keyword-or-id>         Update an existing snippet
             [--name <name>]
             [--keyword <kw>]
             [--content <text>|-]
             [--enabled|--disabled]
             [--pinned|--unpinned]

      delete <keyword-or-id>         Delete a snippet by keyword or UUID

    All output is JSON. Errors are written to stderr with a non-zero exit code.
    """)
    exit(0)
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else { usage() }

switch args[0] {

case "list":
    cmdList(
        enabledOnly: args.contains("--enabled"),
        pinnedOnly:  args.contains("--pinned")
    )

case "search":
    var query = ""
    var enabledOnly = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--enabled": enabledOnly = true
        default: query = args[i]
        }
        i += 1
    }
    guard !query.isEmpty else { fail("search requires a query argument") }
    cmdSearch(query: query, enabledOnly: enabledOnly)

case "get":
    guard args.count >= 2 else { fail("get requires a keyword argument") }
    cmdGet(keyword: args[1])

case "add":
    var name    = ""
    var keyword = ""
    var content = ""
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
        case "--disabled": enabled = false
        case "--pinned":   pinned  = true
        default: break
        }
        i += 1
    }
    cmdAdd(name: name, keyword: keyword, content: content, enabled: enabled, pinned: pinned)

case "update":
    guard args.count >= 2 else { fail("update requires a keyword or UUID argument") }
    let target = args[1]
    var name:    String? = nil
    var keyword: String? = nil
    var content: String? = nil
    var enabled: Bool?   = nil
    var pinned:  Bool?   = nil
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--name":
            name = nextArg(args, after: i, flag: "--name"); i += 1
        case "--keyword":
            keyword = nextArg(args, after: i, flag: "--keyword"); i += 1
        case "--content":
            content = readContent(from: nextArg(args, after: i, flag: "--content")); i += 1
        case "--enabled":  enabled = true
        case "--disabled": enabled = false
        case "--pinned":   pinned  = true
        case "--unpinned": pinned  = false
        default: break
        }
        i += 1
    }
    cmdUpdate(keywordOrID: target, name: name, keyword: keyword, content: content, enabled: enabled, pinned: pinned)

case "delete":
    guard args.count >= 2 else { fail("delete requires a keyword or UUID argument") }
    cmdDelete(keywordOrID: args[1])

case "help", "--help", "-h":
    usage()

default:
    fail("unknown command '\(args[0])'. Run 'snippets-cli help' for usage.")
}
