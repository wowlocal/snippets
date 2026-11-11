import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// Serverless sync through an ordinary hosted git repository.
///
/// GitHub, GitLab, Gitea/Forgejo, GitVerse, or any other smart-HTTP git host acts as
/// the sync service. The transport speaks the git wire protocol directly; there is no
/// Snippets server and no host-specific REST API. Like every transport it only ever
/// handles opaque `WireRecord`s, so the host stores ciphertext it cannot read.
///
/// ## Repository layout (one branch)
///
/// ```text
/// snippets-sync.json            manifest: format, schema, random dataset id
/// README.md                     explains the repository to a human browsing it
/// records/<2 hex>/<uuid>.json   {"blob","deleted","id","rev"}: one WireRecord
/// ```
///
/// Anything else in the tree is preserved byte-for-byte on every commit.
///
/// ## How the sync contract maps onto git
///
/// - **Record version** (per-record CAS token): the git blob id of the record file.
///   It changes whenever the stored bytes change and survives rebasing onto another
///   device's commit.
/// - **Cursor**: the dataset id plus the commit the engine last fetched. A fetch diffs
///   that commit's tree against the current head locally, so it returns exactly the
///   changed records however many commits lie between them.
/// - **Batch atomicity**: one commit per submission. The push names the head it was
///   built on, and the server moves the ref only if it still points there. That is
///   the compare-and-swap for the whole library; a lost race re-reads the new head
///   and re-evaluates every record's CAS against it.
/// - **Dataset identity**: the manifest's random dataset id. A branch recreated with a
///   new manifest is a remote reset, never silently merged.
/// - **Tombstones** are record saves with `deleted: true`. A record file that vanishes
///   from the tree is treated as remote data loss and requires review.
/// - **Push notifications**: none; the transport polls `info/refs`, which costs one
///   small GET when nothing changed.
actor GitSyncTransport: SyncTransport {
    nonisolated struct Configuration: Sendable, Equatable {
        let remote: GitRemote
        /// Transport-private snapshot cache. Safe to delete at any time.
        let cacheDirectory: URL
        /// The library this device was connected to and holds the key for. A branch
        /// whose manifest names any other dataset was replaced underneath this device;
        /// the data plane stops (`git_library_replaced`) instead of encrypting the local
        /// library under a key the new library's other devices do not have. Setup-only
        /// transports leave it nil.
        let expectedDatasetID: UUID?
        /// Carries SSH remotes. Nil uses the platform default: the system `ssh` on
        /// macOS, none elsewhere. Ignored for HTTPS.
        let sshConnector: (any GitSSHConnector)?
        /// The library sealer, needed to read and write a plain-text library's Markdown
        /// files. Setup-only transports leave it nil; a data-plane transport without it
        /// refuses a plain-text library (`git_key_required`).
        let plainText: GitPlainCodec?
        /// The storage mode this device agreed to. A manifest that names another mode
        /// (someone with push access turning an encrypted library into plain text) stops
        /// sync (`git_library_mode_changed`) until the user reconnects and consents.
        /// Setup-only transports leave it nil.
        let expectedMode: GitLibraryMode?

        init(
            remote: GitRemote, cacheDirectory: URL, expectedDatasetID: UUID? = nil,
            sshConnector: (any GitSSHConnector)? = nil, plainText: GitPlainCodec? = nil,
            expectedMode: GitLibraryMode? = nil
        ) {
            self.remote = remote
            self.cacheDirectory = cacheDirectory
            self.expectedDatasetID = expectedDatasetID
            self.sshConnector = sshConnector
            self.plainText = plainText
            self.expectedMode = expectedMode
        }

        static func == (lhs: Configuration, rhs: Configuration) -> Bool {
            lhs.remote == rhs.remote && lhs.cacheDirectory == rhs.cacheDirectory
                && lhs.expectedDatasetID == rhs.expectedDatasetID
        }

        nonisolated static var defaultSSHConnector: any GitSSHConnector {
            #if os(macOS)
            GitSystemSSHConnector()
            #else
            GitUnavailableSSHConnector()
            #endif
        }
    }

    /// What a repository/branch currently holds, for the setup flow.
    nonisolated enum RepositoryState: Sendable, Equatable {
        /// The branch does not exist yet; `initializeRepository()` may create it.
        case empty
        /// The branch holds a Snippets library.
        case library(datasetID: UUID, mode: GitLibraryMode = .encrypted)
        /// The branch exists but is not a Snippets library. It is never overwritten.
        case foreign
    }

    nonisolated static let maximumBatchRecords = 50
    nonisolated static let maximumBlobBytes = 900_000
    nonisolated static let maximumRevisionBytes = 256
    nonisolated static let maximumPushAttempts = 5
    nonisolated static let maximumCommitBlobBytes = 24 * 1024 * 1024

    nonisolated let identifier = "git"
    nonisolated let supportsPush = true
    nonisolated let pollInterval: TimeInterval = 60
    nonisolated let events: AsyncStream<SyncTransportEvent>

    private let configuration: Configuration
    private let client: any GitWireClient
    /// Set when this transport created its session and must close it on shutdown.
    private let ownedSession: URLSession?
    private let cache: GitObjectCache
    private let accountIdentity: SyncAccountIdentity
    private let now: @Sendable () -> Date

    /// The dataset Core admitted for data-plane use. Only an explicit review moves it.
    private var pinnedDatasetID: UUID?
    private var uploadPackAdvertisement: GitRefAdvertisement?
    /// Counts operations, so a fetch can tell it immediately follows a preflight.
    private var operationSequence = 0
    /// A sync round opens with a preflight and its fetch; a fetch that is the very next
    /// operation, within a few seconds, reuses the preflight's view of the branch instead
    /// of asking again. That halves the cost of every idle poll. Anything in between (a
    /// push, another preflight) or a later fetch asks the host afresh.
    private var preflightDiscovery: (advertisement: GitRefAdvertisement, sequence: Int, at: ContinuousClock.Instant)?
    nonisolated static let preflightReuseWindow: Duration = .seconds(3)
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isShutDown = false

    init(
        configuration: Configuration,
        session: URLSession? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        switch configuration.remote.location {
        case .https:
            let resolved = session ?? Self.makeSession()
            ownedSession = session == nil ? resolved : nil
            client = GitSmartHTTPClient(remote: configuration.remote, session: resolved)
        case .ssh(let location):
            ownedSession = nil
            client = GitSSHClient(
                remote: configuration.remote, location: location,
                connector: configuration.sshConnector ?? Configuration.defaultSSHConnector)
        }
        let digest = Self.accountDigest(configuration.remote)
        accountIdentity = SyncAccountIdentity(digest)
        cache = GitObjectCache(
            directory: configuration.cacheDirectory,
            scope: digest.map { String(format: "%02x", $0) }.joined())
        self.now = now
        events = AsyncStream { $0.finish() }
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: configuration)
    }

    // MARK: - Setup

    func inspectRepository() async throws -> RepositoryState {
        try await serialized {
            let advertisement = try await mapped { try await client.discover(.uploadPack) }
            uploadPackAdvertisement = advertisement
            guard let head = advertisement.refs[configuration.remote.refName] else { return .empty }
            do {
                let manifest = try await snapshot(at: head).manifest
                return .library(datasetID: manifest.datasetID, mode: manifest.mode)
            } catch GitSyncLayoutError.notALibrary {
                return .foreign
            }
        }
    }

    /// Creates the library branch if it does not exist and returns its dataset id. An
    /// existing library is adopted, never replaced; a foreign branch is refused, so the
    /// returned id differs from `datasetID` exactly when another device created the
    /// library first. `files` are extra paths under `keys/` written in the same commit.
    func initializeRepository(
        datasetID: UUID = UUID(), files: [String: Data] = [:], mode: GitLibraryMode = .encrypted
    ) async throws -> UUID {
        let paths = try Self.auxiliaryPaths(files)
        return try await serialized {
            for _ in 0..<Self.maximumPushAttempts {
                let advertisement = try await mapped { try await client.discover(.receivePack) }
                if let head = advertisement.refs[configuration.remote.refName] {
                    do {
                        return try await snapshot(at: head).manifest.datasetID
                    } catch GitSyncLayoutError.notALibrary {
                        throw SyncTransportFailure.rejected(.permanent(detail: "git_branch_not_snippets_library"))
                    }
                }
                var blobs: [[String]: GitObject] = [
                    [GitSyncLayout.manifestName]: GitObject(
                        type: .blob, content: try GitSyncManifest(datasetID: datasetID, mode: mode).encoded()),
                    [GitSyncLayout.readmeName]: GitObject(
                        type: .blob, content: Data(GitSyncLayout.readme(for: mode).utf8)),
                ]
                for (components, data) in paths { blobs[components] = GitObject(type: .blob, content: data) }
                var objects = Array(blobs.values)
                let root = try rewriteTree(nil, setting: blobs.mapValues(\.id), into: &objects)
                let commit = GitObject(type: .commit, content: GitCommit.serialize(
                    tree: root, parents: [], date: now(), message: "Create Snippets library"))
                objects.append(commit)
                let result = try await mapped {
                    try await client.push(
                        old: .zero, new: commit.id, pack: try GitPack.build(objects),
                        advertisement: advertisement)
                }
                if result == .updated {
                    _ = try? install(head: commit.id, objects: Self.index(objects))
                    return datasetID
                }
                // Another device created the branch first; adopt it on the next pass. If
                // the branch still does not exist, the host refused the creation itself.
                let after = try await mapped { try await client.discover(.receivePack) }
                if after.refs[configuration.remote.refName] == nil {
                    throw SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))
                }
            }
            throw SyncTransportFailure.rejected(.rateLimited(retryAfter: 5))
        }
    }

    /// Fails unless the credential may push. Hosts authorize the receive-pack
    /// advertisement only for writers, so joining a library with a read-only token is
    /// refused at setup instead of at the first sync.
    func verifyWriteAccess() async throws {
        try await serialized {
            _ = try await mapped { try await client.discover(.receivePack) }
        }
    }

    /// The bytes at `path` in the current library head, or nil if absent. Only paths
    /// under `keys/` are readable this way.
    func readFile(_ path: String) async throws -> Data? {
        let components = try Self.auxiliaryPath(path)
        return try await serialized { try await healingCache {
            let head = try await currentSnapshot()
            var entries = head.rootEntries
            for (index, component) in components.enumerated() {
                guard let entry = entries.first(where: { $0.name == Array(component.utf8) }) else {
                    return nil
                }
                if index == components.count - 1 {
                    guard entry.isRegularFile, let blob = cache.object(entry.id), blob.type == .blob else {
                        return nil
                    }
                    return blob.content
                }
                guard entry.isTree else { return nil }
                entries = try treeEntries(entry.id)
            }
            return nil
        } }
    }

    /// Replaces files under `keys/` in one compare-and-swap commit on top of the current
    /// head, retrying a lost race. Records and the manifest are never touched.
    func writeFiles(_ files: [String: Data], message: String) async throws {
        let paths = try Self.auxiliaryPaths(files)
        guard !paths.isEmpty else { return }
        try await serialized { try await healingCache {
            var rejectedHead: GitObjectID?
            for _ in 0..<Self.maximumPushAttempts {
                let advertisement = try await mapped { try await client.discover(.receivePack) }
                guard let headID = advertisement.refs[configuration.remote.refName] else {
                    throw SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))
                }
                if rejectedHead == headID {
                    throw SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))
                }
                let head = try await snapshot(at: headID)
                try validateDataset(head.manifest)
                var objects = paths.map { GitObject(type: .blob, content: $0.value) }
                let blobs = Dictionary(uniqueKeysWithValues: paths.map {
                    ($0.key, GitObjectID.hash(type: .blob, content: $0.value))
                })
                let root = try rewriteTree(head.tree, setting: blobs, into: &objects)
                guard root != head.tree else { return }
                let commit = GitObject(type: .commit, content: GitCommit.serialize(
                    tree: root, parents: [head.commit], date: now(), message: message))
                objects.append(commit)
                let outcome = try await mapped {
                    try await client.push(
                        old: headID, new: commit.id, pack: try GitPack.build(objects),
                        advertisement: advertisement)
                }
                if outcome == .updated {
                    _ = try? install(head: commit.id, objects: Self.index(objects))
                    return
                }
                rejectedHead = headID
            }
            throw SyncTransportFailure.rejected(.rateLimited(retryAfter: 5))
        } }
    }

    /// Replaces the library `current` on the branch with a new, empty one named
    /// `datasetID`, in one compare-and-swap commit on top of the current head: a new
    /// manifest (same storage mode, `rotatedSchemaVersion`), `files` as the whole of
    /// `keys/`, and no records. Files this client does not own are kept byte-for-byte.
    /// This is how a library's keys are rotated: nothing sealed under the old library
    /// key stays in the tree, and the creating device uploads its library again under
    /// the new one.
    ///
    /// Every other device stops with `git_library_replaced` until it is reconnected.
    /// The commit is an ordinary fast-forward, so earlier commits (and the old
    /// ciphertext) remain in history.
    ///
    /// `expectedHead` is the commit the caller has fully synced. A head that moved
    /// since holds changes the caller has not merged; the call fails with the
    /// retryable `git_ref_moved` and writes nothing. A branch that already holds
    /// `datasetID` is success, so a lost response can be retried.
    func replaceLibrary(
        _ current: UUID, with datasetID: UUID, files: [String: Data], mode: GitLibraryMode,
        expectedHead: GitObjectID? = nil
    ) async throws {
        let paths = try Self.auxiliaryPaths(files)
        try await serialized { try await healingCache {
            let advertisement = try await mapped { try await client.discover(.receivePack) }
            guard let headID = advertisement.refs[configuration.remote.refName] else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))
            }
            let head: GitSnapshot
            do {
                head = try await snapshot(at: headID)
            } catch GitSyncLayoutError.notALibrary {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_branch_not_snippets_library"))
            }
            if head.manifest.datasetID == datasetID { return }
            guard head.manifest.datasetID == current else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))
            }
            guard head.manifest.mode == mode else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_library_mode_changed"))
            }
            if let expectedHead, expectedHead != headID {
                throw SyncTransportFailure.unreachable(detail: "git_ref_moved")
            }
            var blobs: [[String]: GitObject] = [
                [GitSyncLayout.manifestName]: GitObject(type: .blob, content: try GitSyncManifest(
                    datasetID: datasetID, mode: mode,
                    schemaVersion: GitSyncManifest.rotatedSchemaVersion).encoded()),
                [GitSyncLayout.readmeName]: GitObject(
                    type: .blob, content: Data(GitSyncLayout.readme(for: mode).utf8)),
            ]
            for (components, data) in paths { blobs[components] = GitObject(type: .blob, content: data) }
            var objects = Array(blobs.values)
            // Everything the old library owned goes: its records, its key files and, in a
            // plain-text library, its Markdown files (the new library writes them again).
            var edits: [[String]: GitObjectID?] = [
                [GitSyncLayout.recordsName]: nil,
                [GitSyncLayout.keysName]: nil,
            ]
            if mode == .plainText { edits[[GitPlainSnippetFile.directoryName]] = .some(nil) }
            for (components, blob) in blobs { edits[components] = .some(blob.id) }
            guard let root = try editTree(head.tree, edits: edits, into: &objects) else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))
            }
            let commit = GitObject(type: .commit, content: GitCommit.serialize(
                tree: root, parents: [head.commit], date: now(), message: "Replace library keys"))
            objects.append(commit)
            let outcome = try await mapped {
                try await client.push(
                    old: headID, new: commit.id, pack: try GitPack.build(objects),
                    advertisement: advertisement)
            }
            if outcome == .updated {
                _ = try? install(head: commit.id, objects: Self.index(objects))
                return
            }
            // A head that did not move was refused by the host; one that moved has
            // changes the caller must sync before trying again.
            let after = try await mapped { try await client.discover(.receivePack) }
            if after.refs[configuration.remote.refName] == headID {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))
            }
            throw SyncTransportFailure.unreachable(detail: "git_ref_moved")
        } }
    }

    /// The commit a cursor of `datasetID` names: what the engine last fetched.
    nonisolated static func commit(of cursor: SyncCursor, datasetID: UUID) -> GitObjectID? {
        guard let position = GitSyncCursor(cursor), position.datasetID == datasetID else { return nil }
        return position.commit
    }

    /// Validates auxiliary file paths: `keys/` plus plain, non-hidden components.
    private nonisolated static func auxiliaryPaths(_ files: [String: Data]) throws -> [[String]: Data] {
        var result: [[String]: Data] = [:]
        for (path, data) in files { result[try auxiliaryPath(path)] = data }
        return result
    }

    private nonisolated static func auxiliaryPath(_ path: String) throws -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.count >= 2, components.count <= 4,
              components[0] == GitSyncLayout.keysName,
              components.allSatisfy({ component in
                  !component.isEmpty && !component.hasPrefix(".") && component.utf8.count <= 128
                      && component.utf8.allSatisfy { byte in
                          (0x30...0x39).contains(byte) || (0x41...0x5a).contains(byte)
                              || (0x61...0x7a).contains(byte) || byte == UInt8(ascii: "-")
                              || byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".")
                      }
              }) else {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_invalid_path"))
        }
        return components
    }

    /// Returns the id of `tree` (nil: empty) with each path set to its blob, appending
    /// every new tree object to `objects`. Unrelated entries are kept byte-for-byte.
    /// Like `rewriteTree`, but a nil value removes that path, and a directory left empty
    /// disappears with it.
    private func editTree(
        _ tree: GitObjectID?, edits: [[String]: GitObjectID?], into objects: inout [GitObject]
    ) throws -> GitObjectID? {
        var entries = try tree.map { try treeEntries($0) } ?? []
        var children: [String: [[String]: GitObjectID?]] = [:]
        for (components, blob) in edits {
            guard let first = components.first else { continue }
            if components.count == 1 {
                entries.removeAll { $0.name == Array(first.utf8) }
                if let blob { entries.append(.blob(first, blob)) }
            } else {
                children[first, default: [:]][Array(components.dropFirst())] = .some(blob)
            }
        }
        for (name, nested) in children {
            let existing = entries.first { $0.name == Array(name.utf8) && $0.isTree }?.id
            let subtree = try editTree(existing, edits: nested, into: &objects)
            entries.removeAll { $0.name == Array(name.utf8) }
            if let subtree { entries.append(.tree(name, subtree)) }
        }
        guard !entries.isEmpty else { return nil }
        let object = GitObject(type: .tree, content: GitTree.serialize(entries))
        objects.append(object)
        return object.id
    }

    private func rewriteTree(
        _ tree: GitObjectID?, setting files: [[String]: GitObjectID], into objects: inout [GitObject]
    ) throws -> GitObjectID {
        var entries = try tree.map { try treeEntries($0) } ?? []
        var children: [String: [[String]: GitObjectID]] = [:]
        for (components, blob) in files {
            if components.count == 1 {
                entries.removeAll { $0.name == Array(components[0].utf8) }
                entries.append(.blob(components[0], blob))
            } else {
                children[components[0], default: [:]][Array(components.dropFirst())] = blob
            }
        }
        for (name, nested) in children {
            let existing = entries.first { $0.name == Array(name.utf8) && $0.isTree }?.id
            let subtree = try rewriteTree(existing, setting: nested, into: &objects)
            entries.removeAll { $0.name == Array(name.utf8) }
            entries.append(.tree(name, subtree))
        }
        let object = GitObject(type: .tree, content: GitTree.serialize(entries))
        objects.append(object)
        return object.id
    }

    /// Deletes the library branch if it still points at a library. Nothing in the
    /// apps calls this; it exists so live-host tests can clean up their scratch branch.
    func deleteRepositoryBranchForTesting() async throws {
        try await serialized {
            let advertisement = try await mapped { try await client.discover(.receivePack) }
            guard let head = advertisement.refs[configuration.remote.refName] else { return }
            _ = try await snapshot(at: head)
            let result = try await mapped {
                try await client.push(old: head, new: .zero, pack: Data(), advertisement: advertisement)
            }
            guard result == .updated else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))
            }
            try? cache.removeAll()
        }
    }

    // MARK: - SyncTransport: scope

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        try await preflightScope().identity
    }

    func preflightScope() async throws -> SyncScopePreflight {
        try await serialized { try await healingCache {
            let datasetID = try await currentSnapshot().manifest.datasetID
            if let advertisement = uploadPackAdvertisement {
                preflightDiscovery = (advertisement, operationSequence, .now)
            }
            if pinnedDatasetID == nil { pinnedDatasetID = datasetID }
            return SyncScopePreflight(
                identity: accountIdentity,
                datasetIdentity: datasetIdentity(datasetID))
        } }
    }

    func resetAfterAccountReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        try await adoptReviewedScope(
            expectedIdentity: expectedIdentity,
            expectedDatasetIdentity: expectedDatasetIdentity,
            discardingCache: true)
    }

    func resetAfterCheckpointReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        try await adoptReviewedScope(
            expectedIdentity: expectedIdentity,
            expectedDatasetIdentity: expectedDatasetIdentity,
            discardingCache: true)
    }

    func resetAfterRemoteDataResetReview(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        try await adoptReviewedScope(
            expectedIdentity: expectedIdentity,
            expectedDatasetIdentity: expectedDatasetIdentity,
            discardingCache: true)
    }

    func resetForLocalFullResync(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?
    ) async throws {
        // The cursor lives in Core's base and the cache is content-addressed, so there
        // is no scheduler progress to discard; pin the reviewed scope for the full fetch.
        try await adoptReviewedScope(
            expectedIdentity: expectedIdentity,
            expectedDatasetIdentity: expectedDatasetIdentity,
            discardingCache: false)
    }

    func shutdown() async {
        isShutDown = true
        // Wait for an in-flight operation. Every later waiter fails fast and hands the
        // gate on, so nothing can touch the cache or the network after this returns.
        while busy { await withCheckedContinuation { waiters.append($0) } }
        resumeNextWaiter()
        ownedSession?.finishTasksAndInvalidate()
    }

    private func resumeNextWaiter() {
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    private func adoptReviewedScope(
        expectedIdentity: SyncAccountIdentity?,
        expectedDatasetIdentity: SyncDatasetIdentity?,
        discardingCache: Bool
    ) async throws {
        try await serialized {
            guard expectedIdentity == accountIdentity else { throw SyncTransportFailure.accountChanged }
            if discardingCache { try? cache.removeAll() }
            let datasetID = try await currentSnapshot().manifest.datasetID
            guard datasetIdentity(datasetID) == expectedDatasetIdentity else {
                throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
            }
            pinnedDatasetID = datasetID
        }
    }

    // MARK: - SyncTransport: data plane

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        try await serialized { try await healingCache {
            let datasetID = try await establishedDatasetID()
            let head = try await currentSnapshot(reusingPreflight: true)
            try validateDataset(head.manifest)
            let identity = datasetIdentity(datasetID)
            if head.manifest.mode == .plainText {
                return try await plainFetch(
                    head: head, since: cursor, datasetID: datasetID, identity: identity)
            }
            let nextCursor = GitSyncCursor(datasetID: datasetID, commit: head.commit).cursor

            if let cursor, let position = GitSyncCursor(cursor), position.datasetID == datasetID {
                if position.commit == head.commit {
                    try cache.pin([(head.commit, head.tree)])
                    return SyncFetch(
                        records: [], cursor: cursor, cursorKind: .legacy,
                        accountIdentity: accountIdentity, datasetIdentity: identity)
                }
                if let base = try? cachedSnapshot(commit: position.commit),
                   base.manifest.datasetID == datasetID {
                    let records = try changedRecords(from: base, to: head)
                    // The engine may not adopt the new cursor (for example while a record
                    // is quarantined); keep the base it diffed from as well.
                    try cache.pin([(head.commit, head.tree), (base.commit, base.tree)])
                    return SyncFetch(
                        records: records, cursor: nextCursor, cursorKind: .legacy,
                        accountIdentity: accountIdentity, datasetIdentity: identity)
                }
            }
            // No usable base: a first fetch, a cursor from another dataset, or a base
            // snapshot this device no longer holds. A full snapshot is always safe.
            let records = try allRecords(in: head)
            try cache.pin([(head.commit, head.tree)])
            return SyncFetch(
                records: records, cursor: nextCursor, cursorKind: .legacy,
                hasMore: false, isFullResync: true, replacesPriorPages: cursor != nil,
                accountIdentity: accountIdentity, datasetIdentity: identity)
        } }
    }

    func submit(_ records: [WireRecord], at cursor: SyncCursor?) async throws -> SyncSubmission {
        guard !records.isEmpty else {
            throw SyncTransportFailure.rejected(.permanent(detail: "invalid_batch_size"))
        }
        return try await serialized {
            let datasetID = try await establishedDatasetID()
            let identity = datasetIdentity(datasetID)
            // The engine offers everything pending at once. Each bounded chunk is its own
            // CAS-checked commit; a failure after earlier chunks landed returns their
            // acceptances and a retryable rejection for the rest, never a whole-call throw.
            var results: [SyncSubmitResult] = []
            var nextCursor: SyncCursor?
            var queue = Self.chunks(records)
            while !queue.isEmpty {
                let chunk = queue.removeFirst()
                do {
                    guard !isShutDown else {
                        throw SyncTransportFailure.unreachable(detail: "git_transport_shut_down")
                    }
                    let (chunkResults, chunkCursor) = try await healingCache {
                        try await submitChunk(chunk, datasetID: datasetID)
                    }
                    results += chunkResults
                    nextCursor = chunkCursor
                } catch SyncTransportFailure.rejected(.permanent(detail: "git_push_too_large")) {
                    // The host (or a proxy in front of it) refused the request body.
                    // Halve the commit; a single record that still does not fit is
                    // refused on its own.
                    if chunk.count > 1 {
                        let middle = chunk.startIndex + chunk.count / 2
                        queue.insert(contentsOf: [chunk[..<middle], chunk[middle...]], at: 0)
                    } else {
                        results += chunk.map {
                            SyncSubmitResult(id: $0.id, outcome: .rejected(.permanent(detail: "git_push_too_large")))
                        }
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Once anything landed, report it: the rest gets a rejection the
                    // engine retries (or reviews) instead of a whole-call throw that would
                    // discard acknowledgements for pushed commits.
                    let failure = Self.transportFailure(for: error)
                    guard !results.isEmpty else { throw failure }
                    let rejection = Self.rejectionForUnsubmitted(after: failure)
                    results += records[results.count...].map {
                        SyncSubmitResult(id: $0.id, outcome: .rejected(rejection))
                    }
                    break
                }
            }
            return SyncSubmission(
                results: results, cursor: nextCursor,
                accountIdentity: accountIdentity, datasetIdentity: identity)
        }
    }

    /// At most `maximumBatchRecords` records and about 24 MiB of ciphertext per commit.
    private nonisolated static func chunks(_ records: [WireRecord]) -> [ArraySlice<WireRecord>] {
        var chunks: [ArraySlice<WireRecord>] = []
        var start = records.startIndex
        var bytes = 0
        for index in records.indices {
            let size = records[index].blob.count
            if index > start, index - start >= maximumBatchRecords || bytes + size > maximumCommitBlobBytes {
                chunks.append(records[start..<index])
                start = index
                bytes = 0
            }
            bytes += size
        }
        chunks.append(records[start...])
        return chunks
    }

    private nonisolated static func rejectionForUnsubmitted(after failure: SyncTransportFailure) -> SyncRejection {
        switch failure {
        case .rejected(let rejection): rejection
        // A reset or account change is rediscovered on the next round, which then halts
        // for review before anything else is sent.
        case .unreachable, .pushUnsupported, .accountChanged, .checkpointUnreadable, .remoteDataReset:
            .rateLimited(retryAfter: 5)
        }
    }

    /// The same closed mapping `serialized` applies at the boundary.
    private nonisolated static func transportFailure(for error: any Error) -> SyncTransportFailure {
        switch error {
        case let failure as SyncTransportFailure: failure
        case let failure as GitSyncLayoutError: failure.transportFailure
        case let failure as GitRemoteFailure: failure.transportFailure
        case let failure as GitFormatError: .unreachable(detail: "git_format_\(failure.code)")
        default: .unreachable(detail: "git_local_storage")
        }
    }

    private func submitChunk(
        _ records: ArraySlice<WireRecord>, datasetID: UUID
    ) async throws -> ([SyncSubmitResult], SyncCursor) {
        var rejectedHead: GitObjectID?
        for _ in 0..<Self.maximumPushAttempts {
            guard !isShutDown else { throw SyncTransportFailure.unreachable(detail: "git_transport_shut_down") }
            let advertisement = try await mapped { try await client.discover(.receivePack) }
            guard let headID = advertisement.refs[configuration.remote.refName] else {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))
            }
            // A rejection that did not move the branch is not a race: a protected
            // branch, a hook, or missing permission. Retrying cannot help.
            if rejectedHead == headID {
                throw SyncTransportFailure.rejected(.permanent(detail: "git_push_rejected"))
            }
            let head = try await snapshot(at: headID)
            try validateDataset(head.manifest)
            let plan = try plan(Array(records), on: head)
            guard let commit = plan.commit else {
                return (plan.results, GitSyncCursor(datasetID: datasetID, commit: headID).cursor)
            }
            let pack = try GitPack.build(plan.objects)
            let outcome = try await mapped {
                try await client.push(old: headID, new: commit, pack: pack, advertisement: advertisement)
            }
            switch outcome {
            case .updated:
                // The push landed; a local cache problem must not turn it into a failure.
                _ = try? install(head: commit, objects: Self.index(plan.objects))
                return (plan.results, GitSyncCursor(datasetID: datasetID, commit: commit).cursor)
            case .rejected:
                rejectedHead = headID
            }
        }
        throw SyncTransportFailure.rejected(.rateLimited(retryAfter: 5))
    }

    // MARK: - Planning a commit

    private struct Plan {
        var results: [SyncSubmitResult]
        var objects: [GitObject]
        var commit: GitObjectID?
    }

    /// Applies records in order, each CAS-checked against the head plus the records
    /// already accepted earlier in this batch, exactly like a sequential backend.
    private func plan(_ records: [WireRecord], on head: GitSnapshot) throws -> Plan {
        if head.manifest.mode == .plainText { return try planPlain(records, on: head) }
        var results: [SyncSubmitResult] = []
        var newBlobs: [GitObjectID: GitObject] = [:]
        var fanouts: [String: [GitTreeEntry]] = [:]

        func entries(for prefix: String) throws -> [GitTreeEntry] {
            if let existing = fanouts[prefix] { return existing }
            let loaded = try head.fanout[prefix].map { try treeEntries($0) } ?? []
            fanouts[prefix] = loaded
            return loaded
        }

        for record in records {
            guard record.blob.count <= Self.maximumBlobBytes,
                  (1...Self.maximumRevisionBytes).contains(record.rev.utf8.count) else {
                // Refused on its own; the rest of the batch still syncs.
                results.append(SyncSubmitResult(
                    id: record.id, outcome: .rejected(.permanent(detail: "record_too_large"))))
                continue
            }
            let path = GitSyncLayout.recordPath(record.id)
            let current = try entries(for: path.prefix).first { $0.name == Array(path.name.utf8) }?.id
            if let current {
                guard record.recordVersion == Self.recordVersion(current) else {
                    let remote = try newBlobs[current].map {
                        try GitRecordFile.decode($0.content, id: record.id, version: Self.recordVersion(current))
                    } ?? readRecord(record.id, blob: current)
                    results.append(SyncSubmitResult(id: record.id, outcome: .rejected(.conflict(remote: remote))))
                    continue
                }
            } else if record.recordVersion != nil {
                // Tombstones are saves, so a generation with no file was removed by hand.
                // That is remote data loss and goes to review, not an endless conflict.
                throw SyncTransportFailure.remoteDataReset(detail: "git_record_removed")
            }
            let blob = GitObject(type: .blob, content: try GitRecordFile.encode(record))
            let blobID = blob.id
            newBlobs[blobID] = blob
            var updated = try entries(for: path.prefix).filter { $0.name != Array(path.name.utf8) }
            updated.append(.blob(path.name, blobID))
            fanouts[path.prefix] = updated
            results.append(SyncSubmitResult(
                id: record.id,
                outcome: .accepted(rev: record.rev, recordVersion: Self.recordVersion(blobID))))
        }

        guard !newBlobs.isEmpty else { return Plan(results: results, objects: [], commit: nil) }

        var objects = Array(newBlobs.values)
        var recordsEntries = try head.recordsTree.map { try treeEntries($0) } ?? []
        for (prefix, entries) in fanouts {
            let tree = GitObject(type: .tree, content: GitTree.serialize(entries))
            objects.append(tree)
            recordsEntries.removeAll { $0.name == Array(prefix.utf8) }
            recordsEntries.append(.tree(prefix, tree.id))
        }
        let recordsTree = GitObject(type: .tree, content: GitTree.serialize(recordsEntries))
        var rootEntries = head.rootEntries.filter { $0.name != Array(GitSyncLayout.recordsName.utf8) }
        rootEntries.append(.tree(GitSyncLayout.recordsName, recordsTree.id))
        let root = GitObject(type: .tree, content: GitTree.serialize(rootEntries))
        guard root.id != head.tree else {
            // Every accepted record already held identical bytes.
            return Plan(results: results, objects: [], commit: nil)
        }
        objects.append(recordsTree)
        objects.append(root)
        let accepted = results.filter { if case .accepted = $0.outcome { true } else { false } }.count
        let commit = GitObject(type: .commit, content: GitCommit.serialize(
            tree: root.id, parents: [head.commit], date: now(),
            message: accepted == 1 ? "Sync 1 record" : "Sync \(accepted) records"))
        objects.append(commit)
        return Plan(results: results, objects: objects, commit: commit.id)
    }

    // MARK: - Snapshots

    private func establishedDatasetID() async throws -> UUID {
        if let pinnedDatasetID { return pinnedDatasetID }
        let datasetID = try await currentSnapshot().manifest.datasetID
        pinnedDatasetID = datasetID
        return datasetID
    }

    private func currentSnapshot(reusingPreflight: Bool = false) async throws -> GitSnapshot {
        let advertisement: GitRefAdvertisement
        if reusingPreflight, let discovery = preflightDiscovery,
           discovery.sequence == operationSequence - 1,
           ContinuousClock.now - discovery.at < Self.preflightReuseWindow {
            advertisement = discovery.advertisement
        } else {
            advertisement = try await mapped { try await client.discover(.uploadPack) }
            uploadPackAdvertisement = advertisement
        }
        preflightDiscovery = nil
        guard let head = advertisement.refs[configuration.remote.refName] else {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_repository_not_initialized"))
        }
        let snapshot: GitSnapshot
        do {
            snapshot = try await self.snapshot(at: head)
        } catch GitSyncLayoutError.notALibrary {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_branch_not_snippets_library"))
        }
        if let expected = configuration.expectedDatasetID, snapshot.manifest.datasetID != expected {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))
        }
        if let mode = configuration.expectedMode, snapshot.manifest.mode != mode {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_library_mode_changed"))
        }
        return snapshot
    }

    /// The data-plane dataset check. A library other than the connected one stops
    /// sync for reconnection; a change of the pinned dataset is a reviewed reset.
    private func validateDataset(_ manifest: GitSyncManifest) throws {
        if let expected = configuration.expectedDatasetID, manifest.datasetID != expected {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_library_replaced"))
        }
        if let mode = configuration.expectedMode, manifest.mode != mode {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_library_mode_changed"))
        }
        if let pinnedDatasetID, manifest.datasetID != pinnedDatasetID {
            throw SyncTransportFailure.remoteDataReset(detail: "dataset_reset")
        }
    }

    /// A complete local snapshot of `commit`, downloading only what the cache lacks.
    private func snapshot(at commit: GitObjectID) async throws -> GitSnapshot {
        if let cached = try? cachedSnapshot(commit: commit) { return cached }
        let advertisement: GitRefAdvertisement
        if let uploadPackAdvertisement {
            advertisement = uploadPackAdvertisement
        } else {
            advertisement = try await mapped { try await client.discover(.uploadPack) }
            uploadPackAdvertisement = advertisement
        }
        let haves = cache.snapshotCommits
        for attempt in 0..<2 {
            let pack: Data
            do {
                pack = try await mapped {
                    try await client.fetchPack(
                        want: commit, haves: attempt == 0 ? haves : [], advertisement: advertisement)
                }
            } catch SyncTransportFailure.rejected(.permanent(detail: "git_response_too_large"))
                where attempt == 0 && !haves.isEmpty {
                // Catching up through a long history can exceed the limit; the tip alone
                // (`deepen 1`) may not.
                continue
            }
            let objects: [GitObjectID: GitObject]
            do {
                objects = try GitPack.parse(pack, externalBase: { [cache] in cache.object($0) })
            } catch {
                throw SyncTransportFailure.unreachable(detail: "git_pack_invalid")
            }
            if try install(head: commit, objects: objects) {
                return try cachedSnapshot(commit: commit)
            }
            // The server assumed history this device does not keep; ask for everything.
            guard attempt == 0, !haves.isEmpty else { break }
        }
        throw SyncTransportFailure.unreachable(detail: "git_snapshot_incomplete")
    }

    /// Stores every object reachable from `head` and retains it. Returns false, storing
    /// nothing, if any reachable object is in neither `objects` nor the cache.
    @discardableResult
    private func install(head: GitObjectID, objects: [GitObjectID: GitObject]) throws -> Bool {
        // Only objects that arrived in `objects` need writing; anything found in the
        // cache was just read back and re-hashed by `cache.object`.
        var toStore: [(GitObjectID, GitObject)] = []
        func lookup(_ id: GitObjectID) -> GitObject? {
            if let object = objects[id] {
                toStore.append((id, object))
                return object
            }
            return cache.object(id)
        }
        guard let commitObject = lookup(head), commitObject.type == .commit,
              let commit = try? GitCommit.parse(commitObject.content) else { return false }
        var seenTrees = Set<GitObjectID>()
        var stack = [commit.tree]
        while let treeID = stack.popLast() {
            guard seenTrees.insert(treeID).inserted else { continue }
            guard let tree = lookup(treeID), tree.type == .tree,
                  let entries = try? GitTree.parse(tree.content) else { return false }
            for entry in entries {
                if entry.isTree {
                    stack.append(entry.id)
                } else if entry.isRegularFile {
                    if let blob = objects[entry.id] {
                        guard blob.type == .blob else { return false }
                        toStore.append((entry.id, blob))
                    } else if !cache.contains(entry.id) {
                        return false
                    }
                }
            }
        }
        // Children before parents, so a crash can leave orphans but never a tree whose
        // children are missing.
        for (id, object) in toStore.reversed() { try cache.store(object, as: id) }
        try cache.retain(commit: head, tree: commit.tree)
        return true
    }

    private func cachedSnapshot(commit: GitObjectID) throws -> GitSnapshot {
        guard let tree = cache.retainedTree(for: commit) else { throw GitSyncLayoutError.missingObject }
        let rootEntries = try treeEntries(tree)
        guard let manifestEntry = rootEntries.first(where: {
            $0.name == Array(GitSyncLayout.manifestName.utf8) && $0.isRegularFile
        }) else { throw GitSyncLayoutError.notALibrary }
        guard let manifestBlob = cache.object(manifestEntry.id), manifestBlob.type == .blob else {
            throw GitSyncLayoutError.missingObject
        }
        let manifest = try GitSyncManifest.decode(manifestBlob.content)
        let recordsTree = rootEntries.first {
            $0.name == Array(GitSyncLayout.recordsName.utf8) && $0.isTree
        }?.id
        let snippetsTree = rootEntries.first {
            $0.name == Array(GitPlainSnippetFile.directoryName.utf8) && $0.isTree
        }?.id
        var fanout: [String: GitObjectID] = [:]
        if let recordsTree {
            for entry in try treeEntries(recordsTree) where entry.isTree {
                if let name = entry.nameString, GitSyncLayout.isFanoutName(name) { fanout[name] = entry.id }
            }
        }
        return GitSnapshot(
            commit: commit, tree: tree, rootEntries: rootEntries, manifest: manifest,
            recordsTree: recordsTree, fanout: fanout, snippetsTree: snippetsTree)
    }

    private func treeEntries(_ id: GitObjectID) throws -> [GitTreeEntry] {
        guard let object = cache.object(id), object.type == .tree else { throw GitSyncLayoutError.missingObject }
        return try GitTree.parse(object.content)
    }

    /// The record files in one fanout directory, keyed by id. Other names are ignored.
    private func recordEntries(_ tree: GitObjectID, prefix: String) throws -> [UUID: GitObjectID] {
        var result: [UUID: GitObjectID] = [:]
        for entry in try treeEntries(tree) where entry.isRegularFile {
            guard let name = entry.nameString, let id = GitSyncLayout.recordID(fileName: name, prefix: prefix)
            else { continue }
            result[id] = entry.id
        }
        return result
    }

    private func changedRecords(from base: GitSnapshot, to head: GitSnapshot) throws -> [WireRecord] {
        guard base.recordsTree != head.recordsTree else { return [] }
        var changed: [WireRecord] = []
        for prefix in Set(base.fanout.keys).union(head.fanout.keys).sorted() {
            let before = base.fanout[prefix]
            let after = head.fanout[prefix]
            guard before != after else { continue }
            let old = try before.map { try recordEntries($0, prefix: prefix) } ?? [:]
            let new = try after.map { try recordEntries($0, prefix: prefix) } ?? [:]
            guard old.keys.allSatisfy({ new[$0] != nil }) else {
                // The engine never deletes physically; tombstones are saves.
                throw SyncTransportFailure.remoteDataReset(detail: "git_record_removed")
            }
            for (id, blob) in new.sorted(by: { $0.key.uuidString < $1.key.uuidString }) where old[id] != blob {
                changed.append(try readRecord(id, blob: blob))
            }
        }
        return changed
    }

    private func allRecords(in snapshot: GitSnapshot) throws -> [WireRecord] {
        var records: [WireRecord] = []
        for (prefix, tree) in snapshot.fanout.sorted(by: { $0.key < $1.key }) {
            for (id, blob) in try recordEntries(tree, prefix: prefix)
                .sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                records.append(try readRecord(id, blob: blob))
            }
        }
        return records
    }

    private func readRecord(_ id: UUID, blob: GitObjectID) throws -> WireRecord {
        guard let object = cache.object(blob), object.type == .blob else {
            throw GitSyncLayoutError.missingObject
        }
        do {
            return try GitRecordFile.decode(object.content, id: id, version: Self.recordVersion(blob))
        } catch {
            // A damaged or future-format file is delivered as an unopenable record, so
            // the engine quarantines this one snippet instead of every device stopping.
            return WireRecord(
                id: id, rev: "git-unreadable-\(blob.hex)", deleted: false, blob: Data(),
                recordVersion: Self.recordVersion(blob))
        }
    }

    // MARK: - Plain-text libraries

    /// Where one record lives in a plain-text library.
    private enum RecordLocation: Equatable {
        case record(prefix: String, name: String, blob: GitObjectID)
        case plain(name: String, blob: GitObjectID)

        var blob: GitObjectID {
            switch self {
            case .record(_, _, let blob), .plain(_, let blob): blob
            }
        }

        var path: [String] {
            switch self {
            case .record(let prefix, let name, _): [GitSyncLayout.recordsName, prefix, name]
            case .plain(let name, _): [GitPlainSnippetFile.directoryName, name]
            }
        }
    }

    private struct ReadOutcome {
        var record: WireRecord
        /// The file rewritten with fresh `sync` metadata, for a file edited by hand.
        var normalized: (name: String, data: Data)?
    }

    private var plainIndexMemo: (tree: GitObjectID, index: [UUID: (name: String, blob: GitObjectID)])?
    /// A device that could not push (read-only access, say) pauses rewriting edited files.
    private var normalizationPausedUntil: ContinuousClock.Instant?
    /// Hand deletions not yet recorded as tombstones under `records/`. Retried on later
    /// fetches until one is (by this device or another), so a lost race or a failed push
    /// does not leave the deletion known only to devices that happened to see it.
    private var pendingDeletions: [UUID: WireRecord] = [:]

    private func plainCodec() throws -> GitPlainCodec {
        guard let codec = configuration.plainText else {
            throw SyncTransportFailure.rejected(.permanent(detail: "git_key_required"))
        }
        return codec
    }

    /// Every Markdown file under `snippets/`, by the id it declares (or is derived from
    /// its path). Two files claiming one id: the first by name wins, deterministically.
    private func plainIndex(_ snapshot: GitSnapshot) throws -> [UUID: (name: String, blob: GitObjectID)] {
        guard let tree = snapshot.snippetsTree else { return [:] }
        if let memo = plainIndexMemo, memo.tree == tree { return memo.index }
        var claims: [UUID: [(name: String, blob: GitObjectID)]] = [:]
        for entry in try treeEntries(tree) where entry.isRegularFile {
            guard let name = entry.nameString,
                  name.lowercased().hasSuffix(GitPlainSnippetFile.fileExtension) else { continue }
            guard let object = cache.object(entry.id), object.type == .blob else {
                throw GitSyncLayoutError.missingObject
            }
            let id = GitPlainSnippetFile.declaredID(
                object.content, path: "\(GitPlainSnippetFile.directoryName)/\(name)")
            claims[id, default: []].append((name, entry.id))
        }
        // Several files claiming one id are copies. The one named for the id (`…-<id8>.md`)
        // keeps it, else the first by name; every other copy becomes its own snippet with
        // an id derived from its path, rather than taking the original over.
        var index: [UUID: (name: String, blob: GitObjectID)] = [:]
        for (id, files) in claims {
            let sorted = files.sorted { $0.name < $1.name }
            let suffix = "-\(id.uuidString.lowercased().prefix(8))\(GitPlainSnippetFile.fileExtension)"
            let owner = sorted.first { $0.name.hasSuffix(suffix) } ?? sorted[0]
            index[id] = owner
            for copy in sorted where copy.name != owner.name {
                let derived = GitPlainSnippetFile.derivedID(path: "\(GitPlainSnippetFile.directoryName)/\(copy.name)")
                if claims[derived] == nil, index[derived] == nil { index[derived] = copy }
            }
        }
        plainIndexMemo = (tree, index)
        return index
    }

    /// Every record's file, by id. A ciphertext record wins over a Markdown file with the
    /// same id, so a readable file can never shadow a secure snippet or a deletion.
    private func locations(_ snapshot: GitSnapshot) throws -> [UUID: RecordLocation] {
        var result: [UUID: RecordLocation] = [:]
        for (prefix, tree) in snapshot.fanout {
            for (id, blob) in try recordEntries(tree, prefix: prefix) {
                result[id] = .record(prefix: prefix, name: GitSyncLayout.recordPath(id).name, blob: blob)
            }
        }
        for (id, entry) in try plainIndex(snapshot) where result[id] == nil {
            result[id] = .plain(name: entry.name, blob: entry.blob)
        }
        return result
    }

    private func read(
        _ id: UUID, at location: RecordLocation, extra: [GitObjectID: GitObject] = [:]
    ) throws -> ReadOutcome {
        switch location {
        case .record(_, _, let blob):
            if let object = extra[blob] {
                return ReadOutcome(record: try GitRecordFile.decode(
                    object.content, id: id, version: Self.recordVersion(blob)))
            }
            return ReadOutcome(record: try readRecord(id, blob: blob))
        case .plain(let name, let blob):
            guard let object = extra[blob] ?? cache.object(blob), object.type == .blob else {
                throw GitSyncLayoutError.missingObject
            }
            let codec = try plainCodec()
            do {
                let (envelope, edited) = try GitPlainSnippetFile.read(
                    object.content, path: "\(GitPlainSnippetFile.directoryName)/\(name)", assigning: id)
                var record = try WireCodec.seal(envelope, using: codec.sealer)
                record.recordVersion = Self.markdownVersion(blob)
                let normalized = edited ? (try? GitPlainSnippetFile.render(envelope)).map { (name, $0) } : nil
                return ReadOutcome(record: record, normalized: normalized)
            } catch {
                // Unreadable by hand: quarantine this one snippet, as for a damaged record.
                return ReadOutcome(record: WireRecord(
                    id: id, rev: "git-unreadable-\(blob.hex)", deleted: false, blob: Data(),
                    recordVersion: Self.markdownVersion(blob)))
            }
        }
    }

    /// The tombstone every device derives for a Markdown file deleted by hand: one tick
    /// after the deleted file's clock, on the foreign device, without the in-app marker.
    ///
    /// Without the deleted file (a cache this device lost), the deletion carries the
    /// lowest clock, so an edit made since outranks it rather than halting sync.
    private func handDeletion(_ id: UUID, of blob: GitObjectID, requireFile: Bool = true) throws -> WireRecord? {
        let previous: SyncEnvelope?
        if let object = cache.object(blob), object.type == .blob {
            previous = try? GitPlainSnippetFile.read(
                object.content, path: "\(GitPlainSnippetFile.directoryName)/deleted.md", assigning: id).envelope
        } else if requireFile {
            throw GitSyncLayoutError.missingObject
        } else {
            previous = nil
        }
        let tombstone: SyncEnvelope
        if let previous {
            tombstone = previous.tombstoned(hlc: GitPlainSnippetFile.bumped(previous.hlc), origin: HLC.foreignDevice)
        } else if requireFile {
            return nil
        } else {
            tombstone = .tombstone(
                id: id, secure: false, hlc: HLC(wallMs: 0, counter: 0, device: HLC.foreignDevice),
                origin: HLC.foreignDevice)
        }
        return try WireCodec.seal(tombstone, using: try plainCodec().sealer)
    }

    /// The Markdown blob a record version names, if it names one.
    private nonisolated static func markdownBlob(_ version: SyncRecordVersion) -> GitObjectID? {
        let text = String(decoding: version.data, as: UTF8.self)
        guard text.hasPrefix("git-md-blob-sha1:") else { return nil }
        return GitObjectID(hex: text.dropFirst("git-md-blob-sha1:".count))
    }

    private func plainFetch(
        head: GitSnapshot, since cursor: SyncCursor?, datasetID: UUID, identity: SyncDatasetIdentity
    ) async throws -> SyncFetch {
        _ = try plainCodec()
        var base: GitSnapshot?
        if let cursor, let position = GitSyncCursor(cursor), position.datasetID == datasetID {
            if position.commit == head.commit, pendingDeletions.isEmpty {
                try cache.pin([(head.commit, head.tree)])
                return SyncFetch(
                    records: [], cursor: cursor, cursorKind: .legacy,
                    accountIdentity: accountIdentity, datasetIdentity: identity)
            }
            if let cached = try? cachedSnapshot(commit: position.commit), cached.manifest.datasetID == datasetID {
                base = cached
            }
        }
        let headLocations = try locations(head)
        var outcomes: [UUID: ReadOutcome] = [:]
        var deletions: [UUID: WireRecord] = [:]
        if let base {
            let baseLocations = try locations(base)
            for (id, location) in headLocations where baseLocations[id]?.blob != location.blob {
                outcomes[id] = try read(id, at: location)
            }
            for (id, location) in baseLocations where headLocations[id] == nil {
                guard case .plain = location else {
                    // Ciphertext is never removed by the apps: remote data loss.
                    throw SyncTransportFailure.remoteDataReset(detail: "git_record_removed")
                }
                // A Markdown file deleted by hand deletes the snippet, through the same
                // unexplained-deletion safety as any deletion without the in-app marker.
                if let tombstone = try handDeletion(id, of: location.blob) { deletions[id] = tombstone }
            }
        } else {
            for (id, location) in headLocations { outcomes[id] = try read(id, at: location) }
        }

        // Rewrite hand-edited files with fresh `sync` metadata (and record hand deletions
        // as tombstones), so the next edit of the same file orders after this one. Every
        // device derives the same bytes, so racing devices converge; one that cannot push
        // still syncs the edits and leaves the rewrite to another.
        var cursorCommit = head.commit
        let rewrites = outcomes.compactMapValues(\.normalized)
        // Earlier deletions still unrecorded: drop the ones resolved since (a tombstone
        // landed, or the id is back), retry the rest.
        pendingDeletions = pendingDeletions.filter { headLocations[$0.key] == nil }
        pendingDeletions.merge(deletions) { _, new in new }
        let recording = pendingDeletions
        if let normalized = await normalize(head: head, rewrites: rewrites, deletions: recording) {
            for id in recording.keys { pendingDeletions[id] = nil }
            cursorCommit = normalized.commit
            for (id, version) in normalized.versions {
                if outcomes[id] != nil { outcomes[id]?.record.recordVersion = version }
                // Earlier deletions recorded now are delivered again with their version,
                // so the engine's next edit of that id is not one conflict round behind.
                if var deletion = recording[id] {
                    deletion.recordVersion = version
                    deletions[id] = deletion
                }
            }
        }

        var records = outcomes.values.map(\.record) + deletions.values
        records.sort { $0.id.uuidString < $1.id.uuidString }
        var pinned = [(head.commit, head.tree)]
        if cursorCommit != head.commit, let tree = cache.retainedTree(for: cursorCommit) {
            pinned.insert((cursorCommit, tree), at: 0)
        }
        if let base { pinned.append((base.commit, base.tree)) }
        try cache.pin(pinned)
        let nextCursor = GitSyncCursor(datasetID: datasetID, commit: cursorCommit).cursor
        return SyncFetch(
            records: records, cursor: nextCursor, cursorKind: .legacy,
            hasMore: false, isFullResync: base == nil, replacesPriorPages: base == nil && cursor != nil,
            accountIdentity: accountIdentity, datasetIdentity: identity)
    }

    /// One best-effort commit replacing edited files with their normalized form and
    /// adding tombstones for files deleted by hand. Nil when there is nothing to do, the
    /// branch moved, or this device cannot push.
    private func normalize(
        head: GitSnapshot, rewrites: [UUID: (name: String, data: Data)], deletions: [UUID: WireRecord]
    ) async -> (commit: GitObjectID, versions: [UUID: SyncRecordVersion])? {
        if let paused = normalizationPausedUntil, ContinuousClock.now < paused { return nil }
        guard !rewrites.isEmpty || !deletions.isEmpty, !isShutDown else { return nil }
        do {
            var objects: [GitObject] = []
            var edits: [[String]: GitObjectID?] = [:]
            var versions: [UUID: SyncRecordVersion] = [:]
            for (id, rewrite) in rewrites {
                let blob = GitObject(type: .blob, content: rewrite.data)
                objects.append(blob)
                edits[[GitPlainSnippetFile.directoryName, rewrite.name]] = .some(blob.id)
                versions[id] = Self.markdownVersion(blob.id)
            }
            for (id, tombstone) in deletions {
                let blob = GitObject(type: .blob, content: try GitRecordFile.encode(tombstone))
                objects.append(blob)
                let path = GitSyncLayout.recordPath(id)
                edits[[GitSyncLayout.recordsName, path.prefix, path.name]] = .some(blob.id)
                versions[id] = Self.recordVersion(blob.id)
            }
            guard let root = try editTree(head.tree, edits: edits, into: &objects), root != head.tree else {
                return nil
            }
            let commit = GitObject(type: .commit, content: GitCommit.serialize(
                tree: root, parents: [head.commit], date: now(),
                message: "Normalize \(versions.count) file(s) edited outside Snippets"))
            objects.append(commit)
            let advertisement = try await mapped { try await client.discover(.receivePack) }
            guard advertisement.refs[configuration.remote.refName] == head.commit else { return nil }
            let outcome = try await mapped {
                try await client.push(
                    old: head.commit, new: commit.id, pack: try GitPack.build(objects), advertisement: advertisement)
            }
            guard outcome == .updated else { return nil }
            _ = try? install(head: commit.id, objects: Self.index(objects))
            return (commit.id, versions)
        } catch SyncTransportFailure.rejected(.authenticationRequired) {
            // Probably read-only access: try again in an hour, not on every poll.
            normalizationPausedUntil = .now + .seconds(3_600)
            return nil
        } catch {
            return nil
        }
    }

    /// `plan` for a plain-text library: ordinary snippets become Markdown under
    /// `snippets/`, everything else ciphertext under `records/`, and a record that moves
    /// between the two (made secure, deleted, recreated) leaves its old file behind in
    /// history only. Same CAS rule: a record's version is its current file's blob id.
    private func planPlain(_ records: [WireRecord], on head: GitSnapshot) throws -> Plan {
        let codec = try plainCodec()
        var current = try locations(head)
        var usedNames = Set(try head.snippetsTree.map { try treeEntries($0) }?.compactMap(\.nameString) ?? [])
        var results: [SyncSubmitResult] = []
        var newBlobs: [GitObjectID: GitObject] = [:]
        var edits: [[String]: GitObjectID?] = [:]

        for record in records {
            guard record.blob.count <= Self.maximumBlobBytes,
                  (1...Self.maximumRevisionBytes).contains(record.rev.utf8.count) else {
                results.append(SyncSubmitResult(
                    id: record.id, outcome: .rejected(.permanent(detail: "record_too_large"))))
                continue
            }
            let location = current[record.id]
            if let location {
                guard record.recordVersion == Self.version(of: location) else {
                    let remote = try read(record.id, at: location, extra: newBlobs).record
                    results.append(SyncSubmitResult(id: record.id, outcome: .rejected(.conflict(remote: remote))))
                    continue
                }
            } else if let version = record.recordVersion {
                // The edit names a Markdown file that was deleted by hand: answer with the
                // deletion every device derives, and let the engine merge the two.
                if let blob = Self.markdownBlob(version),
                   let tombstone = try handDeletion(record.id, of: blob, requireFile: false) {
                    pendingDeletions[record.id] = tombstone
                    results.append(SyncSubmitResult(id: record.id, outcome: .rejected(.conflict(remote: tombstone))))
                    continue
                }
                throw SyncTransportFailure.remoteDataReset(detail: "git_record_removed")
            }

            let target: RecordLocation
            let blob: GitObject
            if let envelope = try? WireCodec.open(record, using: codec.sealer),
               let rendered = try? GitPlainSnippetFile.render(envelope),
               let fields = envelope.fields {
                blob = GitObject(type: .blob, content: rendered)
                var name: String
                if case .plain(let existing, let existingBlob) = location,
                   !Self.renamed(existingBlob, to: fields.name, extra: newBlobs, cache: cache) {
                    name = existing
                } else if case .record = location, let shadowed = try plainIndex(head)[record.id],
                          !current.values.contains(where: { $0.path == [GitPlainSnippetFile.directoryName, shadowed.name] }) {
                    // A Markdown file restored by hand while a tombstone shadowed it still
                    // claims this id. Overwrite it, or it would keep the id and this
                    // snippet's file would become a copy.
                    name = shadowed.name
                } else {
                    if case .plain(let existing, _) = location { usedNames.remove(existing) }
                    name = GitPlainSnippetFile.fileName(name: fields.name, id: record.id)
                    var suffix = 2
                    while usedNames.contains(name) {
                        let stem = name.dropLast(GitPlainSnippetFile.fileExtension.count)
                        name = "\(stem)-\(suffix)\(GitPlainSnippetFile.fileExtension)"
                        suffix += 1
                    }
                }
                usedNames.insert(name)
                target = .plain(name: name, blob: blob.id)
            } else {
                blob = GitObject(type: .blob, content: try GitRecordFile.encode(record))
                let path = GitSyncLayout.recordPath(record.id)
                target = .record(prefix: path.prefix, name: path.name, blob: blob.id)
            }
            newBlobs[blob.id] = blob
            if let location, location.path != target.path {
                edits[location.path] = .some(nil)
                if case .plain(let old, _) = location { usedNames.remove(old) }
            }
            edits[target.path] = .some(blob.id)
            current[record.id] = target
            results.append(SyncSubmitResult(
                id: record.id, outcome: .accepted(rev: record.rev, recordVersion: Self.version(of: target))))
        }

        guard !edits.isEmpty else { return Plan(results: results, objects: [], commit: nil) }
        var objects = Array(newBlobs.values)
        guard let root = try editTree(head.tree, edits: edits, into: &objects), root != head.tree else {
            return Plan(results: results, objects: [], commit: nil)
        }
        let accepted = results.filter { if case .accepted = $0.outcome { true } else { false } }.count
        let commit = GitObject(type: .commit, content: GitCommit.serialize(
            tree: root, parents: [head.commit], date: now(),
            message: accepted == 1 ? "Sync 1 record" : "Sync \(accepted) records"))
        objects.append(commit)
        return Plan(results: results, objects: objects, commit: commit.id)
    }

    /// Whether the snippet in `blob` had another name: then its file is renamed.
    private nonisolated static func renamed(
        _ blob: GitObjectID, to name: String, extra: [GitObjectID: GitObject], cache: GitObjectCache
    ) -> Bool {
        guard let object = extra[blob] ?? cache.object(blob),
              let parsed = try? GitPlainSnippetFile.parse(object.content),
              let previous = parsed.name else { return false }
        return previous != name
    }

    // MARK: - Identities

    nonisolated static func recordVersion(_ blob: GitObjectID) -> SyncRecordVersion {
        SyncRecordVersion(Data("git-blob-sha1:\(blob.hex)".utf8))
    }

    /// A Markdown file's version says so, so a version whose file is gone can be told
    /// apart from a removed ciphertext record without the (disposable) cache.
    nonisolated static func markdownVersion(_ blob: GitObjectID) -> SyncRecordVersion {
        SyncRecordVersion(Data("git-md-blob-sha1:\(blob.hex)".utf8))
    }

    private nonisolated static func version(of location: RecordLocation) -> SyncRecordVersion {
        switch location {
        case .record(_, _, let blob): recordVersion(blob)
        case .plain(_, let blob): markdownVersion(blob)
        }
    }

    private func datasetIdentity(_ datasetID: UUID) -> SyncDatasetIdentity {
        let remote = configuration.remote
        let text = "snippets-git-dataset-v1\n\(remote.canonicalLocation)\n\(remote.refName)\n"
            + datasetID.uuidString.lowercased()
        return SyncDatasetIdentity(Data(SHA256.hash(data: Data(text.utf8))))
    }

    private nonisolated static func accountDigest(_ remote: GitRemote) -> Data {
        let text = "snippets-git-account-v1\n\(remote.canonicalLocation)\n\(remote.refName)"
        return Data(SHA256.hash(data: Data(text.utf8)))
    }

    private nonisolated static func index(_ objects: [GitObject]) -> [GitObjectID: GitObject] {
        Dictionary(objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Serialization and error mapping

    /// Runs data-plane and setup work one operation at a time, so two calls can never
    /// interleave cache writes across a network suspension.
    private func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        operationSequence += 1
        defer {
            busy = false
            resumeNextWaiter()
        }
        guard !isShutDown else { throw SyncTransportFailure.unreachable(detail: "git_transport_shut_down") }
        do {
            return try await operation()
        } catch let failure as SyncTransportFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as GitSyncLayoutError {
            throw failure.transportFailure
        } catch let failure as GitFormatError {
            throw SyncTransportFailure.unreachable(detail: "git_format_\(failure.code)")
        } catch {
            throw SyncTransportFailure.unreachable(detail: "git_local_storage")
        }
    }

    /// The cache is only an optimization. If an object a retained snapshot needs has
    /// gone missing or failed its hash check, forget every snapshot and run the
    /// operation once more against a fresh download.
    private func healingCache<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch GitSyncLayoutError.missingObject {
            try? cache.removeAll()
            return try await operation()
        }
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as GitRemoteFailure {
            throw failure.transportFailure
        }
    }
}

// MARK: - Layout

nonisolated struct GitSnapshot: Sendable {
    let commit: GitObjectID
    let tree: GitObjectID
    let rootEntries: [GitTreeEntry]
    let manifest: GitSyncManifest
    let recordsTree: GitObjectID?
    /// Two-hex-digit directory name under `records/` → its tree.
    let fanout: [String: GitObjectID]
    /// `snippets/` in a plain-text library.
    let snippetsTree: GitObjectID?
}

nonisolated enum GitSyncLayoutError: Error, Equatable {
    case notALibrary
    case incompatibleSchema
    case malformedRecord
    case missingObject

    var transportFailure: SyncTransportFailure {
        switch self {
        case .notALibrary: .rejected(.permanent(detail: "git_branch_not_snippets_library"))
        case .incompatibleSchema: .rejected(.permanent(detail: "git_sync_schema_unsupported"))
        case .malformedRecord: .rejected(.permanent(detail: "git_record_malformed"))
        case .missingObject: .unreachable(detail: "git_snapshot_incomplete")
        }
    }
}

nonisolated enum GitSyncLayout {
    static let manifestName = "snippets-sync.json"
    static let readmeName = "README.md"
    static let recordsName = "records"
    /// Recovery envelopes and other key-distribution files. Never record data.
    static let keysName = "keys"

    static func readme(for mode: GitLibraryMode) -> String {
        mode == .encrypted ? readme : plainReadme
    }

    static let plainReadme = """
        # Snippets library (plain text)

        This repository holds a Snippets library. The Snippets apps read and write it \
        directly over git; there is no Snippets server.

        Ordinary snippets are readable Markdown files directly in `snippets/`: a few lines \
        of front matter (name, keyword, tags, enabled, pinned), then the snippet text. Edit \
        them in any editor or on the web and the apps pick the change up on their next \
        sync. Leave the `id` and `sync` lines alone. A copied file becomes a new snippet, a \
        new Markdown file becomes a new snippet, and deleting a file deletes the snippet on \
        every device. Files in subfolders are ignored, and restoring a deleted snippet's \
        file from history does not bring it back; recreate it in the app.

        Everything stays in git history. A snippet that was ordinary once remains readable \
        in old commits even after it is made secure or deleted.

        Secure snippets, deletions and snippets carrying sync bookkeeping (such as conflict \
        copies) are encrypted under `records/`; only your own devices can open them. \
        `keys/recovery.json` holds the library key sealed under your offline recovery code.

        Do not rebase or force-push this branch. Snippets treats a removed encrypted record \
        or a replaced `snippets-sync.json` as a reset of the remote library and stops \
        syncing until you review it on one of your devices.

        """

    static let readme = """
        # Snippets library

        This repository holds an end-to-end encrypted Snippets library. The Snippets apps \
        read and write it directly over git; there is no Snippets server.

        Every file under `records/` is ciphertext. Names, keywords, tags and bodies can be \
        decrypted only on your own devices. `keys/recovery.json` holds the library key \
        sealed under your offline recovery code; without that code it is useless.

        Do not edit, rebase, or force-push this branch by hand. Snippets treats a removed \
        record or a replaced `snippets-sync.json` as a reset of the remote library and stops \
        syncing until you review it on one of your devices.

        """

    static func recordPath(_ id: UUID) -> (prefix: String, name: String) {
        let text = id.uuidString.lowercased()
        return (String(text.prefix(2)), "\(text).json")
    }

    static func isFanoutName(_ name: String) -> Bool {
        name.utf8.count == 2 && name.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    static func recordID(fileName: String, prefix: String) -> UUID? {
        guard fileName.hasSuffix(".json") else { return nil }
        let text = String(fileName.dropLast(5))
        guard let id = UUID(uuidString: text), id.uuidString.lowercased() == text,
              text.hasPrefix(prefix) else { return nil }
        return id
    }
}

nonisolated struct GitSyncManifest: Equatable, Sendable {
    static let format = "snippets-git-sync"
    /// What `initializeRepository` writes. Every build that knows Git sync reads it.
    static let currentSchemaVersion = 1
    /// A library whose keys were replaced (`replaceLibrary`). The layout is the same as
    /// schema 1. The number exists to keep out builds from before `keys/vault.json`:
    /// they would join with their old vault and upload secure snippets under the
    /// retired vault key, which every other device refuses.
    static let rotatedSchemaVersion = 2
    static let supportedSchemaVersions = currentSchemaVersion...rotatedSchemaVersion

    let datasetID: UUID
    /// Named by `recordProfile`; an unknown profile is a newer format.
    let mode: GitLibraryMode
    let schemaVersion: Int

    init(
        datasetID: UUID, mode: GitLibraryMode = .encrypted,
        schemaVersion: Int = GitSyncManifest.currentSchemaVersion
    ) {
        self.datasetID = datasetID
        self.mode = mode
        self.schemaVersion = schemaVersion
    }

    private struct File: Codable {
        let datasetID: String
        let format: String
        let recordProfile: String
        let schemaVersion: Int
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(File(
            datasetID: datasetID.uuidString.lowercased(), format: Self.format,
            recordProfile: mode.rawValue, schemaVersion: schemaVersion))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// A branch without our `format` marker is someone else's data. One with the
    /// marker but an unknown schema was written by a newer build and must not be
    /// rewritten by this one.
    static func decode(_ data: Data) throws -> GitSyncManifest {
        guard data.count <= 16_384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["format"] as? String == format else {
            throw GitSyncLayoutError.notALibrary
        }
        guard Set(object.keys) == ["datasetID", "format", "recordProfile", "schemaVersion"],
              let file = try? JSONDecoder().decode(File.self, from: data),
              supportedSchemaVersions.contains(file.schemaVersion),
              let mode = GitLibraryMode(rawValue: file.recordProfile),
              let id = UUID(uuidString: file.datasetID),
              id.uuidString.lowercased() == file.datasetID else {
            throw GitSyncLayoutError.incompatibleSchema
        }
        return GitSyncManifest(datasetID: id, mode: mode, schemaVersion: file.schemaVersion)
    }
}

/// One record file. Canonical JSON with sorted keys, so identical records hash to the
/// same blob and an unchanged re-upload is a no-op.
nonisolated enum GitRecordFile {
    private struct File: Codable {
        let blob: String
        let deleted: Bool
        let id: String
        let rev: String
    }

    static func encode(_ record: WireRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(File(
            blob: record.blob.base64EncodedString(), deleted: record.deleted,
            id: record.id.uuidString.lowercased(), rev: record.rev))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    static func decode(_ data: Data, id: UUID, version: SyncRecordVersion) throws -> WireRecord {
        guard data.count <= GitSyncTransport.maximumBlobBytes * 2,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["blob", "deleted", "id", "rev"],
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.id == id.uuidString.lowercased(),
              (1...GitSyncTransport.maximumRevisionBytes).contains(file.rev.utf8.count),
              let blob = Data(base64Encoded: file.blob),
              blob.base64EncodedString() == file.blob,
              blob.count <= GitSyncTransport.maximumBlobBytes else {
            throw GitSyncLayoutError.malformedRecord
        }
        return WireRecord(id: id, rev: file.rev, deleted: file.deleted, blob: blob, recordVersion: version)
    }
}

/// `git1.<dataset>.<commit>`. Opaque to Core.
nonisolated struct GitSyncCursor: Equatable {
    let datasetID: UUID
    let commit: GitObjectID

    init(datasetID: UUID, commit: GitObjectID) {
        self.datasetID = datasetID
        self.commit = commit
    }

    init?(_ cursor: SyncCursor) {
        let parts = cursor.rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "git1",
              let datasetID = UUID(uuidString: String(parts[1])),
              datasetID.uuidString.lowercased() == parts[1],
              let commit = GitObjectID(hex: parts[2]) else { return nil }
        self.datasetID = datasetID
        self.commit = commit
    }

    var cursor: SyncCursor {
        SyncCursor("git1.\(datasetID.uuidString.lowercased()).\(commit.hex)")
    }
}

extension GitRemoteFailure {
    nonisolated var transportFailure: SyncTransportFailure {
        switch self {
        case .authenticationRequired(let status):
            .rejected(.authenticationRequired(detail: "git_http_\(status)"))
        case .repositoryNotFound:
            // A typo and a token that cannot see a private repository look identical.
            .rejected(.authenticationRequired(detail: "git_repository_not_found"))
        case .rateLimited(let retryAfter):
            .rejected(.rateLimited(retryAfter: retryAfter))
        case .unreachable(let detail):
            .unreachable(detail: "git_\(detail)")
        case .serverError(let status):
            .unreachable(detail: "git_http_\(status)")
        case .unsupportedServer(let detail):
            .rejected(.permanent(detail: "git_unsupported_\(detail)"))
        case .protocolViolation(let detail):
            .unreachable(detail: "git_protocol_\(detail)")
        case .responseTooLarge:
            .rejected(.permanent(detail: "git_response_too_large"))
        case .requestTooLarge:
            .rejected(.permanent(detail: "git_push_too_large"))
        case .sshHostKeyUnknown:
            .rejected(.authenticationRequired(detail: "git_ssh_host_key_unknown"))
        case .sshHostKeyChanged:
            .rejected(.authenticationRequired(detail: "git_ssh_host_key_changed"))
        case .sshPermissionDenied:
            .rejected(.authenticationRequired(detail: "git_ssh_permission_denied"))
        }
    }
}

extension GitFormatError {
    nonisolated var code: String {
        switch self {
        case .invalidObject: "object"
        case .invalidPack: "pack"
        case .invalidPktLine: "pkt_line"
        case .invalidDelta: "delta"
        case .limitExceeded: "limit"
        case .compression: "zlib"
        }
    }
}
