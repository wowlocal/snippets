import Foundation

// App target only (macOS and iOS). Settings on both platforms drive this one flow.

/// Connects this device to a Snippets library in a git repository.
///
/// The flow never guesses on the user's behalf:
///
/// 1. `inspect` reports whether the branch is empty, a Snippets library, or someone
///    else's files. Nothing is written.
/// 2. An empty branch becomes a library only through `createLibrary`, after the user
///    confirmed it. That mints a fresh library key, writes its recovery envelope in the
///    same commit, and returns the recovery code exactly once.
/// 3. An existing library is joined with a key this device already holds (an earlier
///    connection, or iCloud Keychain), or with that library's recovery code.
///
/// Only after the library and its key are both in place are the coordinates and token
/// saved. Selecting Git as the provider is a separate, explicit Switch and Sync.
@MainActor
final class GitSyncSetup {
    struct Form: Equatable {
        /// An HTTPS address, or an SSH one (`git@host:owner/repo.git`, `ssh://…`).
        var repositoryURL: String
        var branch: String
        /// HTTPS only.
        var username: String
        /// HTTPS only. Empty means "keep the saved token", allowed only for the saved
        /// repository.
        var token: String

        init(repositoryURL: String, branch: String = "main", username: String = "", token: String = "") {
            self.repositoryURL = repositoryURL
            self.branch = branch
            self.username = username
            self.token = token
        }

        /// True when the address is an SSH one, so the user name and token do not apply.
        var usesSSH: Bool { GitSyncSetup.looksLikeSSH(repositoryURL) }
    }

    // MARK: - Guidance shared by every Settings UI

    /// Shown above the fields before anything is connected.
    nonisolated static let beforeYouStart =
        "Create a new private repository without a README, then paste its address."

    /// The branch offered when the one entered already holds someone else's files.
    nonisolated static let suggestedBranch = "snippets"

    enum Host: Equatable {
        case github, gitlab, other
    }

    /// The well-known host an address (HTTPS or SSH, possibly still being typed) names.
    nonisolated static func host(of text: String) -> Host {
        let host = hostName(of: text)
        if host == "github.com" || host.hasSuffix(".github.com") { return .github }
        if host == "gitlab.com" { return .gitlab }
        return .other
    }

    nonisolated private static func hostName(of text: String) -> String {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme = rest.range(of: "://") { rest = String(rest[scheme.upperBound...]) }
        if let at = rest.firstIndex(of: "@"), !rest[..<at].contains("/") { rest = String(rest[rest.index(after: at)...]) }
        return String(rest.prefix { $0 != "/" && $0 != ":" })
    }

    /// `owner/repo` for a GitHub or GitLab address, used to link to its settings pages.
    nonisolated private static func repositoryPath(of text: String) -> String? {
        guard let location = try? GitRepositoryLocation.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        let path: String
        switch location {
        case .https(let url): path = url.path
        case .ssh(let ssh): path = ssh.path
        }
        var trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        guard !trimmed.isEmpty, trimmed.split(separator: "/").count >= 2,
              trimmed.allSatisfy({ $0.isLetter || $0.isNumber || "-_./".contains($0) }) else { return nil }
        return trimmed
    }

    /// What kind of access token to create, for the host the address names.
    nonisolated static func tokenHelp(for text: String) -> (text: String, link: URL?) {
        switch host(of: text) {
        case .github:
            ("Create a fine-grained token: Repository access “Only select repositories” → this repository; "
                + "Permissions “Contents: Read and write”. When it expires, Snippets asks for a new one.",
             URL(string: "https://github.com/settings/personal-access-tokens/new"))
        case .gitlab:
            ("Create a project access token with the read_repository and write_repository scopes "
                + "(Developer role, or Maintainer if the branch is protected).",
             repositoryPath(of: text).flatMap { URL(string: "https://gitlab.com/\($0)/-/settings/access_tokens") })
        case .other:
            ("Create a token that can read and write this repository. On Gitea and Forgejo, give it "
                + "write:repository and use your account name as the user name.", nil)
        }
    }

    /// Where to add a deploy key, for GitHub and GitLab addresses.
    nonisolated static func deployKeyLink(for text: String) -> URL? {
        guard let path = repositoryPath(of: text) else { return nil }
        return switch host(of: text) {
        case .github: URL(string: "https://github.com/\(path)/settings/keys/new")
        case .gitlab: URL(string: "https://gitlab.com/\(path)/-/settings/repository#js-deploy-keys-settings")
        case .other: nil
        }
    }

    /// The user name sent with a token when the field is left empty. GitHub and GitLab
    /// accept any name with a token; other hosts need the account name.
    nonisolated static func defaultUsername(for text: String) -> String? {
        switch host(of: text) {
        case .github: "x-access-token"
        case .gitlab: "oauth2"
        case .other: nil
        }
    }

    /// Recognizes SSH addresses while they are still being typed, so a form can hide
    /// the token fields before the address is complete.
    nonisolated static func looksLikeSSH(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("ssh://") || trimmed.hasPrefix("git+ssh://") { return true }
        if trimmed.contains("://") { return false }
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed.hasPrefix("git@") }
        // `https:` while the rest of the scheme is still being typed is not scp syntax.
        let before = trimmed[..<colon]
        if before == "http" || before == "https" { return false }
        return !before.contains("/")
    }

    enum Inspection: Equatable {
        case empty
        /// `mode` matters for consent: joining a plain-text library makes this device's
        /// ordinary snippets readable in the repository.
        case library(datasetID: UUID, keyAvailable: Bool, recoveryAvailable: Bool, mode: GitLibraryMode = .encrypted)
        case foreign
    }

    enum Outcome: Equatable {
        /// A new library. Show this code once; it is not stored anywhere.
        case created(recoveryCode: String)
        case connected
    }

    /// The SSH endpoint a failure is about, for messages and the Terminal check.
    nonisolated struct SSHHost: Equatable, Sendable {
        let user: String?
        let host: String
        let port: Int?

        init(user: String?, host: String, port: Int?) {
            self.user = user
            self.host = host
            self.port = port
        }

        init(_ location: GitSSHLocation) {
            self.init(user: location.user, host: location.host, port: location.port)
        }

        static let unknown = SSHHost(user: nil, host: "the host", port: nil)

        /// `host`, or `[host]:port` as known_hosts writes a non-standard port.
        var label: String {
            guard let port, port != 22 else { return host }
            return "[\(host)]:\(port)"
        }

        /// `ssh -T [-p port] [user@]host`: what checks (and on first use records) the
        /// host key in Terminal.
        var testCommand: String {
            let portPart = port.flatMap { $0 == 22 ? nil : "-p \($0) " } ?? ""
            return "ssh -T \(portPart)\(user.map { "\($0)@" } ?? "")\(host)"
        }
    }

    enum Failure: Error, Equatable, LocalizedError {
        case invalidURL
        /// This build has no way to reach SSH remotes.
        case sshUnavailable
        /// The host's key is not trusted yet (iOS: confirm its fingerprint; macOS: add
        /// it to known_hosts).
        case sshHostKeyUnknown(host: SSHHost)
        /// The host presented a different key than the trusted one.
        case sshHostKeyChanged(host: SSHHost)
        /// The host accepted no key, or the key cannot write to the repository.
        case sshPermissionDenied(host: SSHHost)
        /// The SSH server offers no algorithm this client supports (iOS: for example
        /// only RSA host keys).
        case sshIncompatible(host: SSHHost)
        /// The SSH login works but runs no git for this account.
        case sshNoGit(host: SSHHost)
        case invalidBranch
        case invalidUsername
        case missingToken
        case foreignBranch
        /// Refused for a plain-text library: the repository can be read anonymously.
        case publicRepository
        /// A plain-text library needs the user to confirm the repository is private.
        case visibilityUnknown
        case notALibrary
        /// Another device created a library on this branch first.
        case libraryExists(datasetID: UUID)
        /// The repository no longer holds the library the user chose.
        case libraryChanged
        case recoveryCodeRequired
        case invalidRecoveryCode
        case incorrectRecoveryCode
        case recoveryUnavailable
        case keyUnavailable
        case notConfigured
        case authentication
        case repositoryNotFound
        case unsupportedServer
        case unreachable
        case rateLimited
        case pushRejected
        case refused
        /// The library exists and this device holds its key, but saving the connection
        /// failed. The code must still be shown: nothing else ever will.
        case createdButNotSaved(recoveryCode: String)
        /// The creating push may or may not have landed and the repository could not be
        /// checked. The key is kept; the code opens the library if it exists.
        case creationUncertain(recoveryCode: String)
        case pushTooLarge
        /// Git is syncing another repository or library; changing it in place would
        /// merge two libraries without the Switch and Sync review.
        case otherLibraryActive(String)
        case busy
        case switchInProgress
        case saveFailed
        case removeWhileActive

        /// The SSH host's key needs the user's confirmation (iOS) or known_hosts (macOS).
        var isUntrustedSSHHostKey: Bool {
            switch self {
            case .sshHostKeyUnknown, .sshHostKeyChanged: true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                "Enter the repository’s address, for example https://github.com/you/snippets-library or git@github.com:you/snippets-library.git."
            case .sshUnavailable:
                GitSyncSetup.sshUnavailableMessage
            case .sshIncompatible(let host):
                GitSyncSetup.sshIncompatibleMessage(host)
            case .sshNoGit(let host):
                "\(host.label) accepted the SSH login but doesn’t run git for it. Check the address, or use the repository’s https:// address."
            case .sshHostKeyUnknown(let host):
                GitSyncSetup.sshHostKeyUnknownMessage(host)
            case .sshHostKeyChanged(let host):
                GitSyncSetup.sshHostKeyChangedMessage(host)
            case .sshPermissionDenied(let host):
                GitSyncSetup.sshPermissionDeniedMessage(host)
            case .invalidBranch:
                "Enter a valid branch name, such as main."
            case .invalidUsername:
                "Enter your account name on this Git host as the user name."
            case .missingToken:
                "Enter an access token with read and write access to the repository’s contents."
            case .foreignBranch:
                "This branch already has files, such as a README. Snippets can use its own branch in this repository instead."
            case .publicRepository:
                "This repository is public. Anyone on the internet could read plain-text snippets. Make it private, or create an encrypted library."
            case .visibilityUnknown:
                GitSyncSetup.visibilityUnknownMessage
            case .notALibrary:
                "This branch does not hold a Snippets library."
            case .libraryExists:
                "Another device created a Snippets library in this repository a moment ago. Connect to it instead."
            case .libraryChanged:
                "The repository changed while connecting. Check it again."
            case .recoveryCodeRequired:
                "Enter this library’s recovery code. It was shown when the library was created."
            case .invalidRecoveryCode:
                "That is not a valid recovery code. Check it for typos."
            case .incorrectRecoveryCode:
                "That recovery code does not open this library."
            case .recoveryUnavailable:
                "This library has no recovery code. Connect from a device that already has its key."
            case .keyUnavailable:
                "This device does not have the library’s key."
            case .notConfigured:
                "No Git repository is connected on this device."
            case .authentication:
                "The Git host didn’t accept the access token. It may have expired, or it can’t write to this repository. Enter a new token."
            case .repositoryNotFound:
                "Repository not found. Check the address, and that the token or SSH key can see this private repository."
            case .unsupportedServer:
                "This address isn’t a git repository Snippets can use. Check that you copied the clone address."
            case .unreachable:
                "Couldn’t reach the Git host. Check the address and your connection, then try again."
            case .rateLimited:
                "The Git host is limiting requests. Try again shortly."
            case .pushRejected:
                "The Git host refused the change. Check that the branch is not protected and that the token or SSH key can write to it."
            case .refused:
                "The Git host refused the request."
            case .createdButNotSaved:
                "The library was created, but this device could not save the connection. Keep the recovery code, then \(GitSyncSetup.press) Connect again."
            case .creationUncertain:
                "Snippets couldn’t confirm whether the library was created. Keep the recovery code: if the library exists, it opens it. Then \(GitSyncSetup.press) Connect again."
            case .pushTooLarge:
                "The Git host refused the upload as too large. If a proxy sits in front of it, raise its request size limit (for example nginx client_max_body_size)."
            case .otherLibraryActive(let location):
                "Git is syncing with \(location). To use a different repository or library, switch sync to iCloud first, then connect it here."
            case .busy:
                "Sync is busy with another account change. Try again in a moment."
            case .switchInProgress:
                "A switch to or from Git has not finished yet. Use Sync Now until it completes, then change the repository."
            case .saveFailed:
                "This device could not save the repository settings. Try again."
            case .removeWhileActive:
                "Git is in use. Switch sync to another provider before removing the repository."
            }
        }
    }

    #if os(macOS)
    nonisolated private static let press = "click"
    #else
    nonisolated private static let press = "tap"
    #endif

    #if os(macOS)
    nonisolated private static let sshUnavailableMessage =
        "This Mac’s ssh (/usr/bin/ssh) couldn’t be started. Use the repository’s https:// address."
    nonisolated private static func sshHostKeyUnknownMessage(_ host: SSHHost) -> String {
        "\(host.label) isn’t in your SSH known_hosts yet. In Terminal, run \(host.testCommand) once, check the fingerprint against the one the host publishes, then try again."
    }
    nonisolated private static func sshHostKeyChangedMessage(_ host: SSHHost) -> String {
        "The SSH host key for \(host.label) has changed, so ssh refuses to connect. Check the host’s published fingerprint before you update known_hosts."
    }
    nonisolated private static func sshPermissionDeniedMessage(_ host: SSHHost) -> String {
        "\(host.label) didn’t accept an SSH key from your ssh-agent, or the key can’t write to this repository. Check that \(host.testCommand) works in Terminal and that the key has write access."
    }
    nonisolated private static func sshIncompatibleMessage(_ host: SSHHost) -> String {
        "This Mac’s ssh and \(host.label) have no key exchange, cipher or host key type in common. Use the repository’s https:// address."
    }
    #else
    nonisolated private static let sshUnavailableMessage =
        "SSH isn’t available in this version of Snippets. Use the repository’s https:// address."
    nonisolated private static func sshHostKeyUnknownMessage(_ host: SSHHost) -> String {
        "This device hasn’t connected to \(host.label) before. Confirm its host key fingerprint to continue."
    }
    nonisolated private static func sshHostKeyChangedMessage(_ host: SSHHost) -> String {
        "The SSH host key for \(host.label) is different from the one this device trusted. This can mean the host changed its key, or that someone is intercepting the connection."
    }
    nonisolated private static func sshPermissionDeniedMessage(_ host: SSHHost) -> String {
        "\(host.label) didn’t accept this device’s SSH key, or the key can’t write to this repository. Add the key shown below to the repository with write access, or to your account."
    }
    nonisolated private static func sshIncompatibleMessage(_ host: SSHHost) -> String {
        "\(host.label) offers SSH settings this device can’t use, for example only RSA host keys. Use the repository’s https:// address instead."
    }
    #endif

    private let selection: SyncBackendSelectionStore
    private let keys: GitSyncKeyStore
    private weak var coordinator: SyncCoordinator?
    private let scratchDirectory: URL
    private var session: URLSession?
    /// The SSH host of the step in progress, for failure messages.
    private var activeSSHHost: SSHHost?

    init(selection: SyncBackendSelectionStore, coordinator: SyncCoordinator?) {
        self.selection = selection
        keys = selection.gitKeys
        self.coordinator = coordinator
        scratchDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SnippetsGitSetup-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        // A screen that disappeared mid-flow still must not leave cached repository
        // objects or an open session behind.
        try? FileManager.default.removeItem(at: scratchDirectory)
        session?.finishTasksAndInvalidate()
    }

    /// Removes the setup-only snapshot cache. Safe to call more than once.
    func finish() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        session?.finishTasksAndInvalidate()
        session = nil
    }

    /// One session for every setup step, closed by `finish()`.
    private func setupSession() -> URLSession {
        if let session { return session }
        let created = selection.makeGitSession() ?? GitSyncTransport.makeSession()
        session = created
        return created
    }

    /// The saved repository as a form, with the token left for the Keychain.
    var savedForm: Form? {
        selection.gitCoordinates.map {
            Form(repositoryURL: $0.repository.spec, branch: $0.branch,
                 username: $0.username, token: "")
        }
    }

    // MARK: - Steps

    func inspect(_ form: Form) async throws -> Inspection {
        let (remote, _) = try validated(form)
        let transport = setupTransport(remote)
        let state = try await mapped { try await transport.inspectRepository() }
        switch state {
        case .empty:
            return .empty
        case .foreign:
            return .foreign
        case .library(let datasetID, let mode):
            let keyAvailable = keys.hasMaterial(for: .init(remote: remote, datasetID: datasetID))
            let recoveryAvailable = keyAvailable
                ? true
                : (try await mapped { try await transport.readFile(GitSyncRecovery.path) }) != nil
            return .library(
                datasetID: datasetID, keyAvailable: keyAvailable, recoveryAvailable: recoveryAvailable, mode: mode)
        }
    }

    /// Creates a library in `mode`: encrypted (every record ciphertext), or plain text
    /// (ordinary snippets as readable Markdown, secure snippets still encrypted).
    /// `confirmedPrivate` is the user's word that a plain-text library's repository is
    /// private when Snippets could not check it (`visibilityUnknown`).
    func createLibrary(
        _ form: Form, mode: GitLibraryMode = .encrypted, confirmedPrivate: Bool = false
    ) async throws -> Outcome {
        let (remote, token) = try validated(form)
        if mode == .plainText {
            switch await visibility(of: remote.location) {
            case .isPublic: throw Failure.publicRepository
            case .unknown where !confirmedPrivate: throw Failure.visibilityUnknown
            default: break
            }
        }
        // `inspect` found this branch empty, so if it is the active branch its library
        // is gone and a new one there is the recovery. Any other branch needs a switch.
        try requireReconnectable(remote: remote)
        let datasetID = UUID()
        let material = GitSyncKeyStore.mintMaterial()
        let kit = GitSyncRecovery.Kit(datasetID: datasetID)
        let envelope = try GitSyncRecovery.seal(material: material, kit: kit)
        let scope = GitSyncKeyStore.Scope(remote: remote, datasetID: datasetID)
        // The key exists before the library does: a crash after the push leaves a
        // library this device can still open (and a recovery code it can replace).
        do { try keys.install(material, for: scope) } catch { throw Failure.keyUnavailable }
        let created: UUID
        do {
            created = try await mapped {
                try await setupTransport(remote).initializeRepository(
                    datasetID: datasetID, files: [GitSyncRecovery.path: envelope], mode: mode)
            }
        } catch {
            // A lost response can hide a push that landed. Forget the key only once the
            // repository proves this library does not exist; otherwise keep it (an
            // orphaned key is harmless, a library without its key is not).
            switch try? await setupTransport(remote).inspectRepository() {
            case .library(let existing, _) where existing == datasetID:
                created = datasetID
            case .some:
                try? keys.forget(scope)
                throw error
            case nil:
                // Neither outcome is known. Keep the key and hand out the code, which
                // opens the library if it was created.
                throw Failure.creationUncertain(recoveryCode: kit.code)
            }
        }
        guard created == datasetID else {
            try? keys.forget(scope)
            throw Failure.libraryExists(datasetID: created)
        }
        do {
            try await save(remote: remote, token: token, datasetID: datasetID, mode: mode)
        } catch {
            throw Failure.createdButNotSaved(recoveryCode: kit.code)
        }
        return .created(recoveryCode: kit.code)
    }

    /// Joins the library `datasetID` that `inspect` reported. `recoveryCode` is needed
    /// only when this device does not hold the key yet.
    /// `mode` is the storage mode the user saw and agreed to in `inspect`; a repository
    /// that now says otherwise has changed underneath the decision.
    func connect(
        _ form: Form, datasetID: UUID, recoveryCode: String? = nil, mode agreedMode: GitLibraryMode = .encrypted
    ) async throws -> Outcome {
        let (remote, token) = try validated(form)
        let scope = GitSyncKeyStore.Scope(remote: remote, datasetID: datasetID)
        let transport = setupTransport(remote)
        guard case .library(let current, let mode) = try await mapped({ try await transport.inspectRepository() }),
              current == datasetID, mode == agreedMode else { throw Failure.libraryChanged }
        try requireReconnectable(remote: remote)
        try await mapped { try await transport.verifyWriteAccess() }
        if !keys.hasMaterial(for: scope) {
            guard let recoveryCode, !recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw Failure.recoveryCodeRequired }
            let kit: GitSyncRecovery.Kit
            do { kit = try GitSyncRecovery.Kit(code: recoveryCode, datasetID: datasetID) }
            catch { throw Failure.invalidRecoveryCode }
            guard let envelope = try await mapped({ try await transport.readFile(GitSyncRecovery.path) })
            else { throw Failure.recoveryUnavailable }
            let material: Data
            do {
                material = try GitSyncRecovery.open(envelope, kit: kit)
            } catch GitSyncRecovery.Failure.incorrectCode {
                throw Failure.incorrectRecoveryCode
            } catch {
                throw Failure.recoveryUnavailable
            }
            do { try keys.install(material, for: scope) } catch { throw Failure.keyUnavailable }
        }
        try await save(remote: remote, token: token, datasetID: datasetID, mode: mode)
        return .connected
    }

    /// Seals the current library key under a new code and replaces the repository's
    /// envelope. Earlier envelopes remain in git history, so this replaces a lost code;
    /// it cannot revoke a leaked one.
    func replaceRecoveryCode() async throws -> String {
        guard let coordinates = selection.gitCoordinates else { throw Failure.notConfigured }
        if case .ssh(let ssh) = coordinates.repository { activeSSHHost = SSHHost(ssh) } else { activeSSHHost = nil }
        let token = coordinates.usesSSH ? nil : try? selection.storedGitToken()
        guard coordinates.usesSSH || token != nil else { throw Failure.notConfigured }
        let remote: GitRemote
        do { remote = try selection.gitRemote(for: coordinates, token: token) }
        catch { throw Failure.notConfigured }
        guard let material = try? keys.material(for: coordinates.keyScope) else {
            throw Failure.keyUnavailable
        }
        let kit = GitSyncRecovery.Kit(datasetID: coordinates.datasetID)
        let envelope = try GitSyncRecovery.seal(material: material, kit: kit)
        let transport = GitSyncTransport(
            configuration: .init(
                remote: remote, cacheDirectory: scratchCache(),
                expectedDatasetID: coordinates.datasetID, sshConnector: selection.gitSSH?.connector),
            session: setupSession())
        do {
            try await mapped {
                try await transport.writeFiles(
                    [GitSyncRecovery.path: envelope], message: "Replace recovery envelope")
            }
        } catch {
            // A lost response can hide a write that landed, after which only the new
            // code opens the stored envelope. Show it whenever that is the case.
            if let current = try? await transport.readFile(GitSyncRecovery.path),
               (try? GitSyncRecovery.open(current, kit: kit)) != nil {
                return kit.code
            }
            throw error
        }
        return kit.code
    }

    /// Forgets the repository on this device. The library key stays in the Keychain so
    /// reconnecting later needs no recovery code.
    func disconnect() throws {
        do {
            try selection.removeGitConfiguration()
        } catch SyncBackendSelectionStore.Failure.gitConfigurationInUse {
            throw selection.provider == .git ? Failure.removeWhileActive : Failure.switchInProgress
        } catch {
            throw Failure.saveFailed
        }
    }

    // MARK: - Helpers

    /// While Git is the active provider only its own repository and branch may be
    /// reconnected: a new token, a recovered key, or the library that replaced the old
    /// one there (a branch holds exactly one library). Any other destination needs
    /// Switch and Sync's review.
    private func requireReconnectable(remote: GitRemote) throws {
        guard selection.provider == .git, let active = selection.gitCoordinates else { return }
        guard Self.sameEndpoint(active.repository, remote.location), active.branch == remote.branch else {
            throw Failure.otherLibraryActive(active.displayLocation)
        }
    }

    /// One repository reached two ways. The shared identity (host and path) lets a
    /// device move between HTTPS and SSH; between two SSH addresses the account and
    /// port must also match, because on a self-hosted server they select a different
    /// home directory or daemon. Between two HTTPS addresses the port must match.
    nonisolated static func sameEndpoint(_ a: GitRepositoryLocation, _ b: GitRepositoryLocation) -> Bool {
        guard a.canonicalIdentity == b.canonicalIdentity else { return false }
        switch (a, b) {
        case (.ssh(let x), .ssh(let y)):
            return (x.user ?? "") == (y.user ?? "") && (x.port ?? 22) == (y.port ?? 22)
        case (.https(let x), .https(let y)):
            return (x.port ?? 443) == (y.port ?? 443)
        default:
            return true
        }
    }

    /// Whether joining `datasetID` in `mode` at `form`'s repository and branch needs the
    /// plain-text warning: always for a plain-text library, unless this device already
    /// agreed to exactly that library, mode, repository and branch (a mirror of the same
    /// library elsewhere, say a public one, is asked about again).
    func needsPlainTextConsent(datasetID: UUID, mode: GitLibraryMode, form: Form) -> Bool {
        guard mode == .plainText else { return false }
        guard let saved = selection.gitCoordinates, saved.datasetID == datasetID, saved.mode == .plainText,
              let location = try? GitRepositoryLocation.parse(
                  form.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines),
                  allowsInsecureLoopback: selection.gitAllowsInsecureLoopback),
              Self.sameEndpoint(saved.repository, location),
              saved.branch == form.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return true }
        return false
    }

    nonisolated static let visibilityUnknownTitle = "Couldn’t Check the Repository"
    nonisolated static let visibilityUnknownMessage =
        "Snippets couldn’t check whether this repository is private. Create a plain-text library only if it "
        + "is private: anyone who can read the repository can read your ordinary snippets."

    /// True when `datasetID` at the active repository is not the library this device was
    /// syncing, so Settings must confirm the replacement before merging into it.
    func replacesActiveLibrary(_ form: Form, datasetID: UUID?) -> Bool {
        guard selection.provider == .git, let active = selection.gitCoordinates,
              let (remote, _) = try? validated(form),
              Self.sameEndpoint(active.repository, remote.location),
              active.branch == remote.branch else { return false }
        return active.datasetID != datasetID
    }

    private func save(remote: GitRemote, token: String?, datasetID: UUID, mode: GitLibraryMode) async throws {
        try requireReconnectable(remote: remote)
        let coordinates = SyncBackendSelectionStore.GitCoordinates(
            repository: remote.location, branch: remote.branch, username: remote.username,
            datasetID: datasetID, mode: mode)
        // Rewriting the active provider's settings must not race its transport.
        do {
            if selection.provider == .git, let coordinator {
                try await coordinator.withQuiescedCloudTransport { [selection] in
                    try selection.configureGit(coordinates, token: token)
                }
            } else {
                try selection.configureGit(coordinates, token: token)
            }
        } catch let failure as Failure {
            throw failure
        } catch SyncBackendSelectionStore.Failure.gitConfigurationInUse {
            throw Failure.switchInProgress
        } catch is SyncBackendSelectionStore.Failure {
            throw Failure.saveFailed
        } catch {
            throw Failure.busy
        }
    }

    private func validated(_ form: Form) throws -> (GitRemote, String?) {
        let text = form.repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let location = try? GitRepositoryLocation.parse(
            text, allowsInsecureLoopback: selection.gitAllowsInsecureLoopback) else {
            throw Failure.invalidURL
        }
        let branch = form.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard GitRemote.isValidBranch(branch) else { throw Failure.invalidBranch }
        let url: URL
        switch location {
        case .ssh(let ssh):
            guard selection.gitSSH != nil else { throw Failure.sshUnavailable }
            activeSSHHost = SSHHost(ssh)
            do { return (try GitRemote(ssh: ssh, branch: branch), nil) }
            catch { throw Failure.invalidURL }
        case .https(let normalized):
            activeSSHHost = nil
            url = normalized
        }
        var username = form.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if username.isEmpty, let fallback = Self.defaultUsername(for: text) { username = fallback }
        guard GitRemote.isValidUsername(username) else { throw Failure.invalidUsername }
        var token = form.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if token.isEmpty,
           let saved = selection.gitCoordinates,
           saved.repository == location,
           saved.branch == branch, saved.username == username,
           let stored = try? selection.storedGitToken() {
            token = stored
        }
        guard GitRemote.isValidToken(token) else { throw Failure.missingToken }
        do {
            let remote = try GitRemote(
                url: url, branch: branch, username: username, password: token,
                allowsInsecureLoopback: selection.gitAllowsInsecureLoopback)
            return (remote, token)
        } catch {
            throw Failure.invalidURL
        }
    }

    // MARK: - SSH host keys (iOS)

    /// The host key the last failed connection to `form`'s host presented, when this
    /// device keeps its own host-key trust.
    func presentedHostKey(_ form: Form) -> GitSSHPresentedHostKey? {
        guard let device = selection.gitSSH?.device, let location = sshLocation(form) else { return nil }
        return device.hostKeys.presentedKey(for: location)
    }

    /// Trusts exactly the key with `fingerprint` that `form`'s host presented.
    @discardableResult
    func trustPresentedHostKey(_ form: Form, fingerprint: String) -> Bool {
        guard let device = selection.gitSSH?.device, let location = sshLocation(form) else { return false }
        return device.hostKeys.trustPresentedKey(for: location, fingerprint: fingerprint)
    }

    /// This device's SSH public key, for platforms that keep their own (iOS).
    func devicePublicKey() throws -> String? {
        guard let device = selection.gitSSH?.device else { return nil }
        do { return try device.publicKey() }
        catch { throw Failure.keyUnavailable }
    }

    /// The SSH endpoint `form` names, for labels such as the trust prompt.
    func sshHost(_ form: Form) -> SSHHost? { sshLocation(form).map(SSHHost.init) }

    private func sshLocation(_ form: Form) -> GitSSHLocation? {
        guard case .ssh(let location) = try? GitRepositoryLocation.parse(form.repositoryURL) else { return nil }
        return location
    }

    enum RepositoryVisibility: Equatable { case isPublic, isPrivate, unknown }

    /// Whether anyone can clone the repository without signing in, asked anonymously
    /// (no credentials, cookies or cache; redirects only within the same origin). An
    /// SSH address is checked only at the well-known hosts whose HTTPS address it maps
    /// to; an alias or self-hosted SSH host is `unknown`, never guessed.
    func repositoryVisibility(_ form: Form) async throws -> RepositoryVisibility {
        let (remote, _) = try validated(form)
        return await visibility(of: remote.location)
    }

    private func visibility(of location: GitRepositoryLocation) async -> RepositoryVisibility {
        guard let probe = Self.visibilityProbe(for: location) else { return .unknown }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        // Test seam: the injected git session's protocol handlers, never its credentials.
        if let classes = selection.gitSessionConfiguration?.protocolClasses { configuration.protocolClasses = classes }
        let session = URLSession(
            configuration: configuration, delegate: SameOriginRedirects(origin: probe), delegateQueue: nil)
        return await Self.visibility(probe: probe, session: session)
    }

    /// The anonymous `info/refs` address that tells whether `location` is public.
    nonisolated static func visibilityProbe(for location: GitRepositoryLocation) -> URL? {
        let base: URL?
        switch location {
        case .https(let url):
            base = url
        case .ssh(let ssh):
            guard let host = publicForgeHost(ssh) else { return nil }
            base = URL(string: "https://\(host)/\(ssh.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")
        }
        guard let base, var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        guard let clean = components.url,
              var query = URLComponents(url: clean.appending(path: "info/refs"), resolvingAgainstBaseURL: false)
        else { return nil }
        query.queryItems = [URLQueryItem(name: "service", value: "git-upload-pack")]
        return query.url
    }

    nonisolated private static func visibility(probe: URL, session: URLSession) async -> RepositoryVisibility {
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: probe)
        request.setValue(GitSmartHTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return .unknown }
        switch http.statusCode {
        case 200 where http.mimeType == "application/x-git-upload-pack-advertisement": return .isPublic
        case 401, 403, 404: return .isPrivate
        default: return .unknown
        }
    }

    /// The HTTPS host of a well-known forge an SSH address points at, if it does.
    nonisolated static func publicForgeHost(_ ssh: GitSSHLocation) -> String? {
        switch (ssh.host.lowercased(), ssh.port ?? 22) {
        case ("github.com", 22), ("ssh.github.com", 22), ("ssh.github.com", 443): "github.com"
        case ("gitlab.com", 22), ("altssh.gitlab.com", 443): "gitlab.com"
        case ("codeberg.org", 22): "codeberg.org"
        case ("bitbucket.org", 22): "bitbucket.org"
        default: nil
        }
    }

    private func setupTransport(_ remote: GitRemote) -> GitSyncTransport {
        GitSyncTransport(
            configuration: .init(
                remote: remote, cacheDirectory: scratchCache(), sshConnector: selection.gitSSH?.connector),
            session: setupSession())
    }

    private func scratchCache() -> URL {
        try? FileManager.default.createDirectory(
            at: scratchDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return scratchDirectory
    }

    private func mapped<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as Failure {
            throw failure
        } catch let failure as SyncTransportFailure {
            throw Self.failure(for: failure, host: activeSSHHost ?? .unknown)
        }
    }

    static func failure(for failure: SyncTransportFailure, host: SSHHost = .unknown) -> Failure {
        switch failure {
        case .rejected(.authenticationRequired(let detail)):
            switch detail {
            case "git_repository_not_found": .repositoryNotFound
            case "git_ssh_host_key_unknown": .sshHostKeyUnknown(host: host)
            case "git_ssh_host_key_changed": .sshHostKeyChanged(host: host)
            case "git_ssh_permission_denied": .sshPermissionDenied(host: host)
            default: .authentication
            }
        case .rejected(.rateLimited):
            .rateLimited
        case .rejected(.permanent(let detail)):
            switch detail {
            case "git_branch_not_snippets_library": .foreignBranch
            case "git_repository_not_initialized": .notALibrary
            case "git_push_rejected": .pushRejected
            case "git_push_too_large": .pushTooLarge
            case "git_library_replaced", "git_library_mode_changed": .libraryChanged
            case "git_unsupported_ssh_unavailable", "git_unsupported_ssh": .sshUnavailable
            case "git_unsupported_ssh_algorithms", "git_unsupported_ssh_handshake": .sshIncompatible(host: host)
            case "git_unsupported_ssh_no_git": .sshNoGit(host: host)
            case "git_unsupported_ssh_exec": .sshNoGit(host: host)
            case let code where code.hasPrefix("git_unsupported_"): .unsupportedServer
            default: .refused
            }
        case .unreachable:
            .unreachable
        case .remoteDataReset:
            .libraryChanged
        case .rejected(.conflict), .pushUnsupported, .accountChanged, .checkpointUnreadable:
            .refused
        }
    }
}

/// Follows a redirect only within the probed origin (scheme, host and port).
nonisolated private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let origin: URL
    init(origin: URL) { self.origin = origin }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let target = request.url, target.scheme == origin.scheme,
              target.host?.lowercased() == origin.host?.lowercased(), target.port == origin.port,
              target.user == nil, target.password == nil else { return completionHandler(nil) }
        completionHandler(request)
    }
}
