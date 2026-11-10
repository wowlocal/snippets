import Foundation

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// Complete snapshots of a few recent commits, kept so a fetch can diff two trees
/// locally and tell the server which objects it already has.
///
/// The cache is an optimization, never a source of truth. Objects are content
/// addressed and re-hashed on every read, so a corrupt or truncated file is simply a
/// miss; a missing cache degrades to a full snapshot fetch, which the engine already
/// treats as a snapshot rather than a delta. Nothing here is a credential or a cursor.
///
/// Each file is `"<type> <size>\0<content>"`, the exact bytes git hashes. Contents
/// are record ciphertext and tree listings that the host also holds.
nonisolated final class GitObjectCache: @unchecked Sendable {
    static let schemaVersion = 1
    static let maximumRetainedCommits = 4

    struct Retained: Codable, Equatable, Sendable {
        var commit: String
        var tree: String
    }

    private struct State: Codable, Equatable {
        var schemaVersion: Int
        var scope: String
        var retained: [Retained]
        /// The snapshots the next fetch may diff against: the head the last fetch
        /// returned and the base it diffed from. Submit commits never evict them.
        var pinned: [Retained]
    }

    private let directory: URL
    private let objectsDirectory: URL
    private let stateURL: URL
    private let scope: String
    private let fileManager = FileManager.default
    private var state: State

    /// `scope` names the repository and branch. A cache written for any other scope,
    /// or by an unknown schema, is discarded rather than interpreted.
    init(directory: URL, scope: String) {
        self.directory = directory
        objectsDirectory = directory.appending(path: "objects", directoryHint: .isDirectory)
        stateURL = directory.appending(path: "state.json")
        self.scope = scope
        state = State(schemaVersion: Self.schemaVersion, scope: scope, retained: [], pinned: [])
        if let data = try? Data(contentsOf: stateURL),
           let decoded = try? JSONDecoder().decode(State.self, from: data),
           decoded.schemaVersion == Self.schemaVersion, decoded.scope == scope {
            state = decoded
        } else {
            try? removeAll()
        }
        try? createDirectories(directory)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var url = directory
        try? url.setResourceValues(excluded)
    }

    // MARK: Objects

    func object(_ id: GitObjectID) -> GitObject? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let nul = data.firstIndex(of: 0) else { return nil }
        let header = String(decoding: data[data.startIndex..<nul], as: UTF8.self)
        let parts = header.split(separator: " ")
        guard parts.count == 2, let type = GitObjectType(name: parts[0]),
              let size = Int(parts[1]), size == data.count - (nul - data.startIndex) - 1 else {
            return nil
        }
        let object = GitObject(type: type, content: Data(data[(nul + 1)...]))
        guard object.id == id else {
            try? fileManager.removeItem(at: url(for: id))
            return nil
        }
        return object
    }

    func contains(_ id: GitObjectID) -> Bool {
        fileManager.fileExists(atPath: url(for: id).path)
    }

    /// Writes `object` unless a valid copy is already present. `object(_:)` deletes a
    /// corrupt copy, so a refetched object always replaces a damaged one.
    func store(_ object: GitObject, as id: GitObjectID) throws {
        let target = url(for: id)
        if fileManager.fileExists(atPath: target.path), self.object(id) != nil { return }
        try createDirectories(target.deletingLastPathComponent())
        var data = GitObjectType.header(type: object.type, size: object.content.count)
        data.append(object.content)
        try data.write(to: target, options: [.atomic])
    }

    // MARK: Retained snapshots

    var retained: [Retained] { state.retained }

    /// Every commit whose complete snapshot is held, most recently used first.
    var snapshotCommits: [GitObjectID] {
        var seen = Set<String>()
        return (state.retained + state.pinned)
            .filter { seen.insert($0.commit).inserted }
            .compactMap { GitObjectID(hex: $0.commit) }
    }

    func retainedTree(for commit: GitObjectID) -> GitObjectID? {
        (state.retained + state.pinned)
            .first { $0.commit == commit.hex }
            .flatMap { GitObjectID(hex: $0.tree) }
    }

    /// Keeps these snapshots until the next pin replaces them. Each must already be
    /// stored, which every installed snapshot is.
    func pin(_ snapshots: [(commit: GitObjectID, tree: GitObjectID)]) throws {
        var seen = Set<String>()
        let entries = snapshots.map { Retained(commit: $0.commit.hex, tree: $0.tree.hex) }
            .filter { seen.insert($0.commit).inserted }
        guard state.pinned != entries else { return }
        var next = state
        next.pinned = entries
        try persist(next)
        prune()
    }

    /// Marks `commit` most recently used. The caller has already stored every object
    /// reachable from `tree`. Older snapshots beyond the limit are released and their
    /// unshared objects removed.
    func retain(commit: GitObjectID, tree: GitObjectID) throws {
        var retained = state.retained.filter { $0.commit != commit.hex }
        retained.insert(Retained(commit: commit.hex, tree: tree.hex), at: 0)
        let evicted = retained.count > Self.maximumRetainedCommits
        retained = Array(retained.prefix(Self.maximumRetainedCommits))
        var next = state
        next.retained = retained
        try persist(next)
        if evicted { prune() }
    }

    func release(commit: GitObjectID) throws {
        var next = state
        next.retained = state.retained.filter { $0.commit != commit.hex }
        next.pinned.removeAll { $0.commit == commit.hex }
        guard next != state else { return }
        try persist(next)
        prune()
    }

    /// Empties the cache but keeps its directory, and with it the directory's
    /// exclusion from backups.
    func removeAll() throws {
        for url in [objectsDirectory, stateURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        state = State(schemaVersion: Self.schemaVersion, scope: scope, retained: [], pinned: [])
    }

    /// Deletes every stored object not reachable from a retained snapshot. A snapshot
    /// whose own tree turns out to be incomplete is released as well, so `retained`
    /// always means "complete".
    func prune() {
        var keep = Set<GitObjectID>()
        func isComplete(_ entry: Retained) -> Bool {
            guard let commit = GitObjectID(hex: entry.commit),
                  let tree = GitObjectID(hex: entry.tree),
                  contains(commit),
                  let reachable = reachableObjects(fromTree: tree) else { return false }
            keep.insert(commit)
            keep.formUnion(reachable)
            return true
        }
        var next = state
        next.retained = state.retained.filter(isComplete)
        next.pinned = state.pinned.filter(isComplete)
        if next != state { try? persist(next) }
        guard let fanouts = try? fileManager.contentsOfDirectory(
            at: objectsDirectory, includingPropertiesForKeys: nil) else { return }
        for fanout in fanouts {
            guard let files = try? fileManager.contentsOfDirectory(
                at: fanout, includingPropertiesForKeys: nil) else { continue }
            for file in files {
                let hex = fanout.lastPathComponent + file.lastPathComponent
                if let id = GitObjectID(hex: hex), keep.contains(id) { continue }
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Every tree and blob reachable from `tree`, or nil if any is missing.
    func reachableObjects(fromTree tree: GitObjectID) -> Set<GitObjectID>? {
        var seen = Set<GitObjectID>()
        var stack = [tree]
        while let next = stack.popLast() {
            guard seen.insert(next).inserted else { continue }
            guard let object = object(next) else { return nil }
            guard object.type == .tree else { continue }
            guard let entries = try? GitTree.parse(object.content) else { return nil }
            for entry in entries where entry.isTree || entry.isRegularFile {
                if entry.isTree {
                    stack.append(entry.id)
                } else if seen.insert(entry.id).inserted, !contains(entry.id) {
                    return nil
                }
            }
        }
        return seen
    }

    // MARK: Files

    private func url(for id: GitObjectID) -> URL {
        let hex = id.hex
        return objectsDirectory
            .appending(path: String(hex.prefix(2)), directoryHint: .isDirectory)
            .appending(path: String(hex.dropFirst(2)))
    }

    private func persist(_ newState: State) throws {
        try createDirectories(directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(newState).write(to: stateURL, options: [.atomic])
        state = newState
    }

    private func createDirectories(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
    }
}
