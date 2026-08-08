import Foundation

// MARK: - Storage

private let saveURL: URL = SnippetStorageLocations.snippetsFileURL

/// How long to wait for the cross-process library lock before giving up.
///
/// Generous, because the CLI is usually scripted: a caller would far rather wait a
/// moment than handle a spurious failure. The app's own writes are debounced at
/// 0.3 s, so any realistic contention clears well inside this.
private let cliLockTimeout: TimeInterval = 5.0

/// Loads the snippet library for a read-only command.
///
/// A missing file means an empty library; an existing file that cannot be decoded
/// aborts the command so a later save can never wipe the user's data.
private func loadSnippets() -> [Snippet] {
    do {
        return try LibraryWriter.read(from: saveURL).snippets
    } catch {
        // Report what actually went wrong. Telling someone to "move it aside" when the
        // file is merely unreadable — a permissions problem, an unmounted volume, a
        // half-finished restore — is advice that destroys a perfectly good library.
        fail("\(error)")
    }
}

/// Runs a mutation under the cross-process library lock.
///
/// This is the whole reason the CLI links the Core files. Previously every mutating
/// command did an unlocked read-modify-write of the entire file: decode, edit, rename
/// a complete replacement into place. Two writers doing that concurrently lose
/// roughly two thirds of their writes, and the CLI printed a success receipt either
/// way. The lock removes the interleaving; re-reading inside it removes the
/// stale-snapshot window that locking alone leaves open.
///
/// `mutate` therefore receives what is genuinely on disk *at this instant*, not
/// whatever a `loadSnippets()` call read a few milliseconds earlier.
private func withLockedLibrary(_ mutate: ([Snippet]) -> [Snippet]) -> [Snippet] {
    // Directories may not exist yet if the CLI runs before the app has ever started.
    SnippetStorageLocations.createAllDirectories()

    do {
        let outcome = try LibraryWriter.update(
            libraryURL: saveURL,
            lockTimeout: cliLockTimeout,
            expectedDigest: nil
        ) { onDisk in mutate(onDisk.snippets) }

        // Surface a degraded write. Silence here is how a user on a network-mounted
        // home stayed in permanent no-lock mode without ever being told: `attempts > 1`
        // means a peer got inside our critical section, and `wroteWithoutLock` means
        // neither `flock` nor the sentinel was available. stderr, not stdout, so
        // scripts parsing the JSON receipt are unaffected.
        if outcome.wroteWithoutLock {
            fputs("warning: wrote without a lock — this filesystem supports neither flock nor link-based locking; concurrent writes may be lost\n", stderr)
        } else if outcome.attempts > 1 {
            fputs("warning: needed \(outcome.attempts) attempts; another process is writing the library concurrently\n", stderr)
        }

        DistributedNotificationCenter.default().postNotificationName(
            SnippetStorageSync.distributedChangeNotification,
            object: saveURL.path,
            userInfo: nil,
            deliverImmediately: true
        )
        return outcome.snippets
    } catch LibraryWriter.Failure.busy {
        fail("another process is writing the snippet library; try again")
    } catch {
        fail("failed to save: \(error)")
    }
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
    // Shells included: a secure snippet the CLI cannot see is a secure snippet whose
    // keyword someone will accidentally reuse. Their `content` is empty, never
    // ciphertext — printing ciphertext would invite someone to try to crack it.
    var snippets = loadSnippets() + secureShells()
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

/// Secure snippets, as content-free shells, read straight from the vault file.
///
/// The CLI reads metadata directly rather than asking the app, because metadata is
/// plaintext in `vault.json` and the app may not be running. It can never read content
/// this way: that is ciphertext, and the key is only ever in the app's memory.
private func secureShells() -> [Snippet] {
    switch VaultFile.loadMetadata() {
    case .loaded(let metadata): return metadata.shells
    case .missing, .tooNew, .unreadable, .corrupt: return []
    }
}

/// Asks the running app to reveal a secure snippet.
///
/// The CLI cannot decrypt. This sends a request over the local socket and the app
/// prompts a human, naming this process. That is the whole design: a script can *ask*,
/// and a person answers.
private func cmdReveal(keyword: String) {
    let url = SnippetsIPC.socketURL()
    let descriptor: Int32
    do {
        descriptor = try UnixSocket.connect(to: url)
    } catch {
        fail("Snippets is not running, so there is nothing to approve the request. Open Snippets and try again.",
             code: SnippetsIPC.ExitCode.appNotRunning.rawValue)
    }
    defer { close(descriptor) }

    let invocation = CommandLine.arguments.joined(separator: " ")
    do {
        try UnixSocket.send(
            SnippetsIPC.Request(command: SnippetsIPC.Command.reveal, keyword: keyword, invocation: invocation),
            on: descriptor)
        let response = try UnixSocket.receive(SnippetsIPC.Response.self, on: descriptor)

        switch response.status {
        case .ok:
            // Bare content on stdout, nothing else, so `$(snippets-cli reveal x)` is
            // usable. Every other channel goes to stderr.
            if let content = response.content { print(content) }
        case .denied:
            fail("the request was not approved", code: SnippetsIPC.ExitCode.denied.rawValue)
        case .locked:
            fail(response.message ?? "the vault could not be unlocked",
                 code: SnippetsIPC.ExitCode.locked.rawValue)
        case .notFound:
            fail(response.message ?? "no such secure snippet",
                 code: SnippetsIPC.ExitCode.notFound.rawValue)
        case .unsupported:
            fail(response.message ?? "unsupported request",
                 code: SnippetsIPC.ExitCode.protocolMismatch.rawValue)
        case .refused, .error:
            fail(response.message ?? "the request was refused")
        }
    } catch {
        fail("\(error)")
    }
}

private func cmdSecureStatus() {
    struct Status: Encodable {
        let appRunning: Bool
        let secureCount: Int
        let unlocked: Bool?
        let socket: String
    }

    let url = SnippetsIPC.socketURL()
    guard let descriptor = try? UnixSocket.connect(to: url) else {
        // Still useful with the app closed: the metadata is on disk.
        printJSON(Status(appRunning: false, secureCount: secureShells().count,
                         unlocked: nil, socket: url.path))
        return
    }
    defer { close(descriptor) }

    guard (try? UnixSocket.send(SnippetsIPC.Request(command: SnippetsIPC.Command.status), on: descriptor)) != nil,
          let response = try? UnixSocket.receive(SnippetsIPC.Response.self, on: descriptor) else {
        printJSON(Status(appRunning: false, secureCount: secureShells().count,
                         unlocked: nil, socket: url.path))
        return
    }
    printJSON(Status(
        appRunning: true,
        secureCount: response.secureCount ?? secureShells().count,
        unlocked: response.unlocked,
        socket: url.path))
}

private func cmdGet(keyword: String) {
    let lookupKeyword = Snippet.sanitizedKeyword(keyword)
    if let snippet = loadSnippets().first(where: {
        $0.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
    }) {
        printJSON(snippet)
        return
    }

    // A secure snippet must not look like a missing one — "no snippet found" would send
    // someone off to recreate a secret they already have. Say it exists, say it is
    // secure, and point at the command that can actually produce it.
    if secureShells().contains(where: {
        $0.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
    }) {
        fail("'\(keyword)' is a secure snippet; its text is not readable from the command line. "
             + "Use: snippets-cli reveal \(keyword)")
    }

    fail("no snippet found with keyword '\(keyword)'")
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
    var created: Snippet?
    _ = withLockedLibrary { current in
        // Validated against what is on disk right now, inside the lock. Checking a
        // copy read earlier would let two concurrent `add`s both pass the collision
        // check and both land.
        requireNoKeywordCollision(sanitizedKeyword, in: current)
        let snippet = Snippet(
            name: name,
            keyword: sanitizedKeyword,
            content: content,
            tags: tags,
            isEnabled: enabled,
            isPinned: pinned
        )
        created = snippet
        return [snippet] + current
    }

    guard let created else { fail("failed to add the snippet") }
    printJSON(created)
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

    let lookupKeyword = Snippet.sanitizedKeyword(keywordOrID)
    var result: Snippet?

    _ = withLockedLibrary { current in
        var snippets = current
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
        result = updated
        return snippets
    }

    guard let result else { fail("failed to update the snippet") }
    printJSON(result)
}

private func cmdDelete(keywordOrID: String) {
    let lookupKeyword = Snippet.sanitizedKeyword(keywordOrID)

    // `sanitizedKeyword` strips leading backslashes and collapses whitespace, so
    // arguments like "", " ", or "\" all reduce to the empty string. Matching that
    // against `normalizedKeyword` would equal EVERY snippet that has no keyword and
    // delete all of them at once. Refuse instead: there is no legitimate way to
    // address a snippet by an empty keyword.
    if UUID(uuidString: keywordOrID) == nil && lookupKeyword.isEmpty {
        fail("delete requires a non-empty keyword or a UUID")
    }

    var deleted = 0
    _ = withLockedLibrary { current in
        var snippets = current
        // Remove exactly one snippet. The previous `removeAll` deleted every record
        // sharing the keyword, which turns a duplicate-keyword situation — the very
        // thing the app warns about and the merge can now create — into silent bulk
        // data loss from a command the user believed was singular.
        let index: Int? = {
            if let id = UUID(uuidString: keywordOrID) {
                return snippets.firstIndex { $0.id == id }
            }
            return snippets.firstIndex {
                $0.normalizedKeyword.caseInsensitiveCompare(lookupKeyword) == .orderedSame
            }
        }()

        guard let index else { fail("no snippet found matching '\(keywordOrID)'") }
        snippets.remove(at: index)
        deleted = 1
        return snippets
    }

    struct Result: Encodable { let deleted: Int }
    printJSON(Result(deleted: deleted))
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
                                     Secure snippets are reported, not printed.

      reveal <keyword>               Ask the running Snippets app to reveal a secure
                                     snippet. A person must approve it in the app; the
                                     CLI cannot decrypt anything itself.
                                     Exit codes: 3 app not running, 4 denied,
                                     5 locked, 6 not found.

      secure-status                  Report how many secure snippets exist and whether
                                     the vault is currently unlocked.

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

case "reveal":
    guard args.count >= 2 else { fail("reveal requires a keyword argument") }
    cmdReveal(keyword: args[1])

case "secure-status":
    cmdSecureStatus()

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
