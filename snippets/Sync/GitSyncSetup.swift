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
/// A library also owns its secure-snippet vault. Creating one publishes the vault's
/// identity and its key under the same recovery code (`GitSyncVault`); joining adopts
/// that vault instead of ever minting another, so one code opens the whole library.
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

    /// What kind of access token to create, for the host the address names. Nothing
    /// until an address is typed: advice for hosts the user did not name is noise.
    nonisolated static func tokenHelp(for text: String) -> (text: String, link: URL?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return ("", nil) }
        return switch host(of: text) {
        case .github:
            ("Use a fine-grained token limited to this repository, with Contents: Read and write.",
             URL(string: "https://github.com/settings/personal-access-tokens/new"))
        case .gitlab:
            ("Use a project access token with read_repository and write_repository (Developer role; "
                + "Maintainer for a protected branch).",
             repositoryPath(of: text).flatMap { URL(string: "https://gitlab.com/\($0)/-/settings/access_tokens") })
        case .other:
            ("Use a token that can read and write this repository. On Gitea and Forgejo: write:repository.", nil)
        }
    }

    /// GitHub or GitLab when the address names one, for link titles.
    nonisolated static func hostDisplayName(of text: String) -> String? {
        switch host(of: text) {
        case .github: "GitHub"
        case .gitlab: "GitLab"
        case .other: nil
        }
    }

    // MARK: - Texts both Settings screens show

    /// A library is created encrypted unless the user asks for plain text, which is a
    /// second, separate question: its warning is shown only to someone choosing it.
    nonisolated static let createLibraryTitle = "Create a Snippets Library Here?"
    nonisolated static func createLibraryMessage(_ place: String = "This branch") -> String {
        "\(place) is empty. Snippets will create an encrypted library here and show you a recovery code to save."
    }
    nonisolated static let createLibraryAction = "Create Library"
    nonisolated static let plainTextInsteadAction = "Plain Text Instead…"
    nonisolated static let plainTextLibraryTitle = "Create a Plain-Text Library?"
    nonisolated static let plainTextLibraryMessage =
        "Ordinary snippets become Markdown files that the host and anyone with access to the repository "
        + "can read. They stay in its history even after you delete them, and you can’t change this "
        + "later. Secure snippets stay encrypted."
    nonisolated static let plainTextLibraryAction = "Create Plain-Text Library"

    nonisolated static let foreignBranchTitle = "This Branch Has Other Files"
    nonisolated static let recoveryCodePrompt = "Enter this library’s newest recovery code."
    nonisolated static func recoveryCodeExplanation(keychainSyncs: Bool) -> String {
        "This code opens your library on a new device, secure snippets included. Snippets can’t show it "
            + "again. Store it in your password manager."
            + (keychainSyncs ? " Your other Apple devices with iCloud Keychain connect without it." : "")
    }
    nonisolated static let recoveryCodeCopied = "Copied. It clears from the clipboard in 2 minutes."

    nonisolated static func plainTextJoinMessage(deviceName: String) -> String {
        "This \(deviceName)’s ordinary snippets will be readable by anyone with access to the repository, "
            + "and stay in its history. Secure snippets stay encrypted."
    }
    nonisolated static let replacementTitle = "Reconnect to This Repository?"
    nonisolated static func replacementMessage(deviceName: String) -> String {
        "This library’s keys were replaced on another device, or a new library was created in this "
            + "repository. Reconnecting merges this \(deviceName)’s snippets into it. Nothing on this "
            + "\(deviceName) is deleted."
    }
    nonisolated static let replacementAction = "Reconnect and Merge"
    nonisolated static let removeMessage =
        "Nothing in the repository is deleted. You can reconnect later without the recovery code."
    /// What each key action is for, in a few words.
    nonisolated static let newCodeHint = "For a lost code."
    nonisolated static let replaceKeysHint = "For a leaked code or a lost device."
    nonisolated static let fallbackMessage = "Something went wrong. Try again."

    /// The confirmation before a new recovery code. Replace Keys is offered only while
    /// Git is syncing the library.
    var newCodeExplanation: String {
        "The old code stops working in Snippets. If it may have leaked, "
            + (selection.provider == .git
                ? "use Replace Keys instead."
                : "switch sync to this library and use Replace Keys instead.")
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
        /// This device's secure snippets are sealed under another vault's key.
        case differentVault(secureCount: Int)
        /// This device cannot open the vault, so it cannot wrap its key under a code.
        case vaultKeyUnavailable
        /// Device-owner authentication for the vault did not complete.
        case vaultAuthentication
        /// `keys/vault.json` cannot be read: damaged, or written by a newer build.
        case vaultUnavailable
        /// This device's own `vault.json` cannot be read.
        case localVaultUnreadable
        /// The code is well formed but does not open the library's vault key.
        case incorrectVaultRecoveryCode
        /// Secure snippets in the library are sealed under a vault another device holds.
        case vaultHeldElsewhere
        /// A vault may be created for an older library only after a completed sync.
        case syncBeforeSecureSetup
        /// Keys are replaced only for the library Git is syncing, right after a round
        /// that left nothing pending.
        case syncBeforeRotation
        /// A secure sync conflict is still held as ciphertext under the current key.
        case pendingSecureConflicts
        /// The repository holds the new keys, but this device did not finish switching
        /// to them. The code must still be shown: nothing else ever will.
        case rotatedButNotSaved(recoveryCode: String)
        /// The replacing push may or may not have landed and the repository could not be
        /// checked. The new keys are kept; the code opens the library if it was replaced.
        case rotationUncertain(recoveryCode: String)

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
            case .differentVault(let count):
                GitSyncSetup.differentVaultMessage(count)
            case .vaultKeyUnavailable:
                "This device can’t open its secure snippets yet, so a code made here wouldn’t open them either. Use Set Up Secure Snippets first, or do this on a device that can open them."
            case .vaultAuthentication:
                "Snippets couldn’t confirm it’s you, so your secure snippets were left as they are. Nothing was changed."
            case .vaultUnavailable:
                "This library’s secure-snippet key file can’t be read. Update Snippets on this device, or create a new recovery code on a device that can open the secure snippets."
            case .localVaultUnreadable:
                "Secure snippets on this device can’t be read, so nothing was changed. Check Secure Snippets in Settings."
            case .incorrectVaultRecoveryCode:
                "That recovery code does not open this library’s secure snippets. If the code was replaced, enter the newest one."
            case .vaultHeldElsewhere:
                "Another device holds the key to this library’s secure snippets. Update Snippets on that device, create a new recovery code there, then enter that code here."
            case .syncBeforeSecureSetup:
                "Switch sync to this Git library and let it finish syncing, then set up secure snippets."
            case .syncBeforeRotation:
                "Keys can be replaced only while Git sync is on and up to date. Use Sync Now, fix anything it reports, then try again."
            case .pendingSecureConflicts:
                "A secure snippet on this device still has an unresolved sync conflict, so its key can’t be replaced yet. Unlock your secure snippets and use Sync Now, then try again. If sync can’t run, \(GitSyncSetup.forgetVaultAction), then connect again."
            case .rotatedButNotSaved:
                "The repository now uses the new keys, but this device could not finish switching to them. Keep the new recovery code, then \(GitSyncSetup.press) \(GitSyncSetup.reconnect)."
            case .rotationUncertain:
                "Snippets couldn’t confirm whether the keys were replaced. Keep the new recovery code: if the library asks for one, this is it. Use Sync Now; if it asks you to reconnect, \(GitSyncSetup.press) \(GitSyncSetup.reconnect)."
            }
        }
    }

    #if os(macOS)
    nonisolated private static let forgetVaultAction = "choose Forget Secure Snippets in Settings"
    #else
    nonisolated private static let forgetVaultAction = "choose Remove Secure Snippets from This Device in Settings"
    #endif

    nonisolated private static func differentVaultMessage(_ count: Int) -> String {
        guard count > 0 else {
            return "This device has synced secure snippets under a different key than this library’s. To use the library’s, \(forgetVaultAction), then connect again."
        }
        let them = count == 1 ? "it" : "them"
        return "This device has \(count) secure snippet\(count == 1 ? "" : "s") protected by a different key than this library’s. Turn \(them) into ordinary snippets or delete \(them), \(forgetVaultAction), then connect again."
    }

    nonisolated static let newCodeReason = "Create a new recovery code for your Git library"
    nonisolated static let rotateReason = "Replace the keys of your Git library"

    /// What replacing the keys does, for the confirmation on both platforms.
    nonisolated static let keyRotationExplanation =
        "Your other devices stop syncing until you reconnect each one with the new recovery code. Sync "
        + "them first if you can.\n\n"
        + "The old code still opens earlier versions in the repository’s history. If it may have leaked, "
        + "also change the passwords you keep in secure snippets."
    nonisolated private static let resealReason = "Move your secure snippets to the library’s new key"
    nonisolated private static let createLibraryReason = "Include your secure snippets in the new library’s recovery code"

    #if os(macOS)
    nonisolated private static let press = "click"
    #else
    nonisolated private static let press = "tap"
    #endif
    /// The action that reconnects a library sync stopped on, on both platforms.
    nonisolated private static let reconnect = "Reconnect"

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
    /// The device's secure-snippet store. Nil only where there is none to publish.
    private let vault: SecureSnippetStore?
    private let scratchDirectory: URL
    private var session: URLSession?
    /// The SSH host of the step in progress, for failure messages.
    private var activeSSHHost: SSHHost?
    /// Where the outcome of replacing the keys is recorded. Tests read it here.
    var recordDiagnostic: (DiagnosticEvent) -> Void = { Diagnostics.record($0) }

    init(
        selection: SyncBackendSelectionStore, coordinator: SyncCoordinator?, vault: SecureSnippetStore? = nil
    ) {
        self.selection = selection
        keys = selection.gitKeys
        self.coordinator = coordinator
        self.vault = vault ?? coordinator?.libraryVault
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
        var files = [GitSyncRecovery.path: try GitSyncRecovery.seal(material: material, kit: kit)]
        // The library's vault, its key under the same code. Prepared before any key is
        // stored or anything is pushed: it may ask for the owner, and a refusal must
        // leave nothing behind.
        let prepared = try await prepareVault(under: kit, reason: Self.createLibraryReason)
        if let prepared {
            files[GitSyncVault.path] = try GitSyncVault.seal(
                prepared.identity, material: material, datasetID: datasetID)
        }
        let scope = GitSyncKeyStore.Scope(remote: remote, datasetID: datasetID)
        // The key exists before the library does: a crash after the push leaves a
        // library this device can still open (and a recovery code it can replace).
        do {
            try keys.install(material, for: scope)
        } catch {
            discard(prepared)
            throw Failure.keyUnavailable
        }
        let created: UUID
        do {
            created = try await mapped {
                try await setupTransport(remote).initializeRepository(
                    datasetID: datasetID, files: files, mode: mode)
            }
        } catch {
            // A lost response can hide a push that landed. Forget the keys only once the
            // repository proves this library does not exist; otherwise keep them (an
            // orphaned key is harmless, a library without its key is not).
            switch try? await setupTransport(remote).inspectRepository() {
            case .library(let existing, _) where existing == datasetID:
                created = datasetID
            case .some:
                try? keys.forget(scope)
                discard(prepared)
                throw error
            case nil:
                // Neither outcome is known. Keep the keys and hand out the code, which
                // opens the library if it was created.
                throw Failure.creationUncertain(recoveryCode: kit.code)
            }
        }
        guard created == datasetID else {
            try? keys.forget(scope)
            discard(prepared)
            throw Failure.libraryExists(datasetID: created)
        }
        do {
            try adopt(prepared)
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
        // The code's secret opens the vault key too, so it is read whenever one was
        // entered, even by a device that already holds the library key.
        var kit: GitSyncRecovery.Kit?
        if let recoveryCode, !recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do { kit = try GitSyncRecovery.Kit(code: recoveryCode, datasetID: datasetID) }
            catch { throw Failure.invalidRecoveryCode }
        }
        // Set only when the library key comes from the recovery code in this call.
        var recovered: Data?
        if !keys.hasMaterial(for: scope) {
            guard let kit else { throw Failure.recoveryCodeRequired }
            guard let envelope = try await mapped({ try await transport.readFile(GitSyncRecovery.path) })
            else { throw Failure.recoveryUnavailable }
            do {
                recovered = try GitSyncRecovery.open(envelope, kit: kit)
            } catch GitSyncRecovery.Failure.incorrectCode {
                throw Failure.incorrectRecoveryCode
            } catch {
                throw Failure.recoveryUnavailable
            }
        }
        // The library that replaced the one Git was syncing on this branch: its keys
        // were rotated, or it was created anew.
        let replaced = replacedLibrary(by: remote, datasetID: datasetID)
        // The library's vault, checked before anything is saved: a device whose secure
        // snippets belong to another vault is told now, not by a halted sync later. A
        // file this build cannot read does not block ordinary snippets; secure ones
        // then wait for `setUpSecureSnippets`.
        var identity: GitSyncVault.Identity?
        var reseals = false
        if let vault {
            let material: Data
            if let recovered {
                material = recovered
            } else if let stored = try? keys.material(for: scope) {
                material = stored
            } else {
                throw Failure.keyUnavailable
            }
            if case .identity(let published) = try await publishedVault(
                transport, material: material, datasetID: datasetID) {
                // Only a device following its library to that library's replacement
                // moves its secure snippets under the new vault key. Anywhere else a
                // vault in use may be shared with another provider's devices, and is
                // never re-pointed.
                if replaced != nil, vault.libraryVaultNeedsReseal(published) {
                    try await vaultStep { try vault.checkCanResealIntoLibraryVault(published) }
                    reseals = true
                } else {
                    try await vaultStep { try vault.checkCanJoinLibraryVault(published) }
                }
                identity = published
            }
        }
        if let recovered {
            do { try keys.install(recovered, for: scope) } catch { throw Failure.keyUnavailable }
        }
        if let identity, let vault {
            try await vaultStep {
                if reseals {
                    try await vault.resealIntoLibraryVault(
                        identity, recoveryKey: kit?.secret, reason: Self.resealReason)
                    return
                }
                do {
                    try vault.joinLibraryVault(identity, recoveryKey: kit?.secret)
                } catch SecureSnippetStore.LibraryVaultFailure.incorrectRecoveryCode {
                    // A code issued by a build that predates `keys/vault.json` opens the
                    // library but not its vault. Join anyway; secure snippets wait for a
                    // code that does.
                    try vault.joinLibraryVault(identity)
                }
            }
        }
        try await save(remote: remote, token: token, datasetID: datasetID, mode: mode)
        // The replaced library is gone from the branch; its key opens only history.
        if let replaced { forgetRetiredKey(replaced) }
        return .connected
    }

    /// Forgets the key of a library the branch no longer holds. A key that iCloud
    /// Keychain shares stays: deleting it here deletes it on the user's other devices,
    /// which would then ask for a recovery code instead of saying that the keys were
    /// replaced, and could not re-seal what they hold.
    private func forgetRetiredKey(_ scope: GitSyncKeyStore.Scope) {
        guard !keys.syncsBetweenDevices else { return }
        try? keys.forget(scope)
    }

    /// Seals the current library key under a new code and replaces the repository's
    /// envelope. When this device holds the library's vault, its key is wrapped under
    /// the same code in the same commit, so one code keeps opening everything. Earlier
    /// envelopes remain in git history, so this replaces a lost code; it cannot revoke
    /// a leaked one.
    ///
    /// The device owner is asked once: by unlocking the vault when its key is wrapped
    /// under the new code, otherwise through `authenticateOwner`.
    func replaceRecoveryCode(authenticateOwner: (String) async throws -> Void) async throws -> String {
        try await issueRecoveryCode(mintingVault: false, askingOwnerWith: authenticateOwner)
    }

    /// Replaces every key of the connected library and returns its new recovery code.
    ///
    /// A new library takes the old one's place on the branch in one commit: a new
    /// dataset id, a new library key, a new vault key (this device's secure snippets
    /// are re-sealed under it) and a new recovery code. This device then uploads its
    /// library again under the new keys. Every other device stops with
    /// `git_library_replaced` and reconnects with the new code, which re-seals its own
    /// secure snippets (`connect`).
    ///
    /// The old code, library key and vault key open nothing written from now on. They
    /// still open the commits before this one: history is not rewritten.
    ///
    /// The library must be the one Git is syncing, and exactly as this device last
    /// synced it: the replacing commit is refused if the branch moved since, and the
    /// round is repeated. The new keys are stored before the push, so a crash after it
    /// leaves a library this device can still open by reconnecting.
    ///
    /// The device owner is asked once: by unlocking the vault when there are secure
    /// snippets to re-seal, otherwise through `authenticateOwner`.
    func rotateKeys(authenticateOwner: (String) async throws -> Void) async throws -> String {
        let started = ProcessInfo.processInfo.systemUptime
        var progress = RotationProgress()
        func record(_ outcome: DiagnosticGitKeyRotationOutcome, _ reason: DiagnosticGitKeyRotationReason?) {
            recordDiagnostic(.gitKeyRotation(
                outcome: outcome, reason: reason, attempts: progress.attempts,
                durationMilliseconds: Int64(max(0, ProcessInfo.processInfo.systemUptime - started) * 1_000)))
        }
        do {
            let code = try await replaceKeys(&progress, authenticateOwner: authenticateOwner)
            record(.replaced, nil)
            return code
        } catch {
            switch error as? Failure {
            case .rotatedButNotSaved: record(.replacedNotSaved, nil)
            case .rotationUncertain: record(.uncertain, nil)
            case let failure:
                let reason: DiagnosticGitKeyRotationReason =
                    progress.ownerDeclined ? .authentication
                    : progress.branchKeptMoving ? .branchMoved : Self.rotationReason(failure)
                record(.notReplaced, reason)
            }
            throw error
        }
    }

    /// What `rotateKeys` reports about its rounds; never part of an error.
    private struct RotationProgress {
        /// Replacing pushes tried.
        var attempts = 0
        /// Every try found the branch ahead of the round before it.
        var branchKeptMoving = false
        /// The device owner did not confirm.
        var ownerDeclined = false
    }

    /// The closed reason diagnostics keep for a rotation that replaced nothing.
    nonisolated private static func rotationReason(_ failure: Failure?) -> DiagnosticGitKeyRotationReason {
        switch failure {
        case .syncBeforeRotation, .switchInProgress, .notConfigured, .removeWhileActive:
            .notSyncing
        case .pendingSecureConflicts:
            .pendingSecureConflicts
        case .vaultAuthentication:
            .authentication
        case .differentVault, .vaultKeyUnavailable, .vaultUnavailable, .localVaultUnreadable, .vaultHeldElsewhere:
            .vault
        case .keyUnavailable:
            .keyStorage
        case .libraryChanged, .notALibrary, .foreignBranch:
            .libraryChanged
        case .authentication, .refused, .pushRejected, .pushTooLarge, .repositoryNotFound,
             .sshPermissionDenied, .sshHostKeyUnknown, .sshHostKeyChanged:
            .rejected
        case .unreachable, .rateLimited, .unsupportedServer, .sshIncompatible, .sshNoGit, .sshUnavailable:
            .unreachable
        case .busy:
            .busy
        default:
            .other
        }
    }

    private func replaceKeys(
        _ progress: inout RotationProgress, authenticateOwner: (String) async throws -> Void
    ) async throws -> String {
        guard selection.provider == .git, let coordinator else { throw Failure.syncBeforeRotation }
        // An unfinished provider switch pins the library's location; moving it now
        // would leave the repository on new keys this device could not save.
        guard selection.interruptedProviderSwitch == nil else { throw Failure.switchInProgress }
        let old = try activeLibrary()
        let coordinates = old.coordinates
        if let waiting = waitingFailure(coordinator) { throw waiting }
        if let vault {
            switch try await publishedVault(old.transport, material: old.material, datasetID: coordinates.datasetID) {
            case .tooNew:
                throw Failure.vaultUnavailable
            case .identity(let identity):
                try await vaultStep { try vault.checkCanJoinLibraryVault(identity) }
            case .absent, .unreadable:
                break
            }
        }

        let datasetID = UUID()
        let material = GitSyncKeyStore.mintMaterial()
        let kit = GitSyncRecovery.Kit(datasetID: datasetID)
        var next = coordinates
        next.datasetID = datasetID
        var files = [GitSyncRecovery.path: try GitSyncRecovery.seal(material: material, kit: kit)]
        // Asks for the owner and opens every secure snippet once, before any key is
        // stored or anything is pushed: a refusal must leave nothing behind.
        let rotation = try await vaultStep {
            try await vault?.prepareVaultRotation(wrappingUnder: kit.secret, reason: Self.rotateReason)
        }
        func forgetNewKeys() {
            try? keys.forget(next.keyScope)
            if let rotation { vault?.discardVaultRotation(rotation) }
        }
        // Unlocking the vault to re-seal it asked the owner. With nothing to re-seal
        // nobody was asked yet, whatever the screen believed about the vault.
        if rotation?.authenticatedOwner != true {
            do {
                try await authenticateOwner(Self.rotateReason)
            } catch {
                progress.ownerDeclined = true
                forgetNewKeys()
                throw error
            }
        }
        do {
            if let rotation {
                files[GitSyncVault.path] = try GitSyncVault.seal(
                    rotation.identity, material: material, datasetID: datasetID)
            }
            try keys.install(material, for: next.keyScope)
        } catch {
            forgetNewKeys()
            throw Failure.keyUnavailable
        }

        for attempt in 1...3 {
            // Everything this device has must be in the repository, and everything in
            // the repository on this device, before the old library is dropped.
            guard case .completed(.idle) = await coordinator.requestSync(trigger: .manual) else {
                forgetNewKeys()
                throw waitingFailure(coordinator) ?? Failure.syncBeforeRotation
            }
            progress.attempts = attempt
            do {
                return try await coordinator.withQuiescedCloudTransport { [self] in
                    try await replaceLibrary(
                        old, with: next, files: files, rotation: rotation, code: kit.code)
                }
            } catch RotationStep.branchMoved where attempt < 3 {
                continue
            } catch RotationStep.branchMoved {
                progress.branchKeptMoving = true
                forgetNewKeys()
                throw Failure.unreachable
            } catch RotationStep.notReplaced(let failure) {
                forgetNewKeys()
                throw failure
            } catch let failure as Failure {
                throw failure
            } catch {
                // Sync was busy with another account change; nothing was pushed.
                forgetNewKeys()
                throw Failure.busy
            }
        }
        forgetNewKeys()
        throw Failure.unreachable
    }

    /// Why the keys cannot be replaced while sync holds secure snippets back. Whatever
    /// waits is not in this device's library, so it would not be uploaded again.
    private func waitingFailure(_ coordinator: SyncCoordinator) -> Failure? {
        guard coordinator.isWaitingForVault else { return nil }
        switch vault?.libraryVaultAvailability {
        case .ready:
            // With the key here, what waits is a secure conflict that needs the vault open.
            return .pendingSecureConflicts
        case .keyMissing:
            // The vault is on this device without its key: the recovery code restores it.
            return .vaultKeyUnavailable
        case .some(.none), nil:
            return .vaultHeldElsewhere
        }
    }

    private enum RotationStep: Error {
        /// The branch changed after the last round; sync again and retry.
        case branchMoved
        /// The repository provably still holds the old library.
        case notReplaced(Failure)
    }

    /// The replacing push and, once the repository holds the new library, this
    /// device's move to it. Runs with sync stopped.
    private func replaceLibrary(
        _ old: ActiveLibrary, with next: SyncBackendSelectionStore.GitCoordinates,
        files: [String: Data], rotation: SecureSnippetStore.PendingVaultRotation?, code: String
    ) async throws -> String {
        let current = old.coordinates
        // The commit the engine last fetched is the library this device has merged.
        guard let locations = try? selection.protocolLocations(),
              case .loaded(let base) = SyncBaseFile.load(from: locations.baseURL),
              let cursor = base.cursor,
              let head = GitSyncTransport.commit(of: cursor, datasetID: current.datasetID) else {
            throw RotationStep.notReplaced(.syncBeforeRotation)
        }
        // Rounds ran since the vault was checked. With sync stopped, make sure what it
        // holds now can still be re-sealed before the old library is dropped.
        if let rotation, let vault {
            do {
                try await vaultStep { try vault.checkVaultRotation(rotation) }
            } catch let failure as Failure {
                throw RotationStep.notReplaced(failure)
            }
        }
        do {
            try await old.transport.replaceLibrary(
                current.datasetID, with: next.datasetID, files: files, mode: current.mode,
                expectedHead: head)
        } catch {
            // A lost response can hide a push that landed. Give up the new keys only
            // once the repository proves it still holds the old library.
            switch try? await setupTransport(old.remote).inspectRepository() {
            case .library(let existing, _) where existing == next.datasetID:
                break
            case .library(let existing, _) where existing == current.datasetID:
                if case SyncTransportFailure.unreachable(detail: "git_ref_moved") = error {
                    throw RotationStep.branchMoved
                }
                let failure = (error as? Failure)
                    ?? (error as? SyncTransportFailure).map { Self.failure(for: $0, host: activeSSHHost ?? .unknown) }
                    ?? .unreachable
                throw RotationStep.notReplaced(failure)
            case .some:
                throw RotationStep.notReplaced(.libraryChanged)
            case nil:
                throw Failure.rotationUncertain(recoveryCode: code)
            }
        }
        // The repository holds the new library and only `code` opens its envelopes.
        // Whatever fails from here, the code is handed out; reconnecting finishes the
        // move with the keys already in the Keychain.
        do {
            if let rotation, let vault { try vault.commitVaultRotation(rotation) }
            try selection.configureGit(next, token: old.token)
        } catch {
            throw Failure.rotatedButNotSaved(recoveryCode: code)
        }
        forgetRetiredKey(current.keyScope)
        return code
    }

    /// Where secure snippets stand on this device for the connected library.
    enum SecureSnippetsStatus: Equatable {
        /// Nothing is connected, or this build has no vault to offer.
        case unavailable
        case ready
        /// No vault on this device yet.
        case needsSetup
        /// The library's vault is here; its key is not.
        case needsRecoveryCode
    }

    var secureSnippetsStatus: SecureSnippetsStatus {
        guard let vault, selection.gitCoordinates != nil, selection.gitIsReady else { return .unavailable }
        switch vault.libraryVaultDisplayAvailability {
        case .ready: return .ready
        case .none: return .needsSetup
        case .keyMissing: return .needsRecoveryCode
        }
    }

    /// True when sync stopped on something only reconnecting fixes: this device has no
    /// key for the library, or the branch no longer holds the library it was syncing.
    var needsReconnect: Bool {
        guard let coordinates = selection.gitCoordinates else { return false }
        if !keys.hasMaterial(for: coordinates.keyScope) { return true }
        guard selection.provider == .git, case .needsAttention(let detail)? = coordinator?.state else {
            return false
        }
        return ["git_library_replaced", "git_repository_not_initialized", "git_library_mode_changed",
                "git_key_required"].contains(detail)
    }

    /// The lines under the connected library's name: what it is, anything that needs
    /// the user, and how sync stands. Facts that are simply true are left out.
    func connectedSummary(deviceName: String) -> [String] {
        guard let coordinates = selection.gitCoordinates else { return [] }
        var lines = [
            "\(coordinates.mode == .plainText ? "Plain text" : "Encrypted") · \(coordinates.usesSSH ? "SSH" : "HTTPS")",
        ]
        let press = Self.press.prefix(1).uppercased() + Self.press.dropFirst()
        if !keys.hasMaterial(for: coordinates.keyScope) {
            lines.append("This \(deviceName) can’t open the library. \(press) Reconnect and enter the recovery code.")
        } else if !coordinates.usesSSH, !selection.hasGitCredential {
            lines.append("Access token missing. Enter it below and \(Self.press) Update.")
        }
        switch secureSnippetsStatus {
        case .needsSetup:
            lines.append("Secure snippets: not set up on this \(deviceName).")
        case .needsRecoveryCode:
            lines.append("Secure snippets: locked. This \(deviceName) needs the recovery code.")
        case .ready, .unavailable:
            break
        }
        lines.append(selection.provider == .git
            ? (coordinator?.statusDescription ?? "")
            : "Not syncing with it yet: \(Self.press) Switch and Sync.")
        return lines.filter { !$0.isEmpty }
    }

    /// False while a token is saved for the host the address names: advice on creating
    /// one is for someone who has yet to.
    func showsTokenHelp(for address: String) -> Bool {
        guard selection.hasStoredGitToken, let saved = selection.gitCoordinates else { return true }
        return Self.hostName(of: address) != Self.hostName(of: saved.repository.spec)
    }

    /// True when the connected screen must show the address and token form without
    /// being asked: the token it holds is what is missing.
    var connectionFormIsRequired: Bool {
        guard let coordinates = selection.gitCoordinates else { return true }
        return !coordinates.usesSSH && !selection.hasGitCredential
    }

    /// Makes secure snippets work on this device for the connected library.
    ///
    /// The library's vault is adopted, with its key taken from the Keychain or from
    /// `recoveryCode`; `recoveryCodeRequired` asks for the code. A library created
    /// before `keys/vault.json` has no vault yet: it gets one, together with a new
    /// recovery code that opens both (`.created`), after `authenticateOwner`.
    func setUpSecureSnippets(
        recoveryCode: String? = nil, authenticateOwner: (String) async throws -> Void
    ) async throws -> Outcome {
        guard let vault else { throw Failure.notConfigured }
        let library = try activeLibrary()
        let datasetID = library.coordinates.datasetID
        switch try await publishedVault(library.transport, material: library.material, datasetID: datasetID) {
        case .tooNew, .unreadable:
            throw Failure.vaultUnavailable
        case .identity(let identity):
            var secret: Data?
            if let recoveryCode, !recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                do { secret = try GitSyncRecovery.Kit(code: recoveryCode, datasetID: datasetID).secret }
                catch { throw Failure.invalidRecoveryCode }
            }
            let availability = try await vaultStep { try vault.joinLibraryVault(identity, recoveryKey: secret) }
            guard availability == .ready else { throw Failure.recoveryCodeRequired }
            return .connected
        case .absent:
            switch vault.libraryVaultAvailability {
            case .keyMissing:
                throw Failure.vaultKeyUnavailable
            case .ready:
                // Publishing an existing vault authenticates by unlocking it.
                break
            case .none:
                // A vault minted here must be the library's only one. Secure snippets
                // another device already uploaded are sealed under that device's vault,
                // and only a round that finishes now shows there are none: an idle
                // state from earlier says nothing about what was uploaded since.
                guard selection.provider == .git, let coordinator else {
                    throw Failure.syncBeforeSecureSetup
                }
                let round = await coordinator.requestSync(trigger: .manual)
                if coordinator.isWaitingForVault { throw Failure.vaultHeldElsewhere }
                guard case .completed(.idle(let lastSync)) = round, lastSync != nil else {
                    throw Failure.syncBeforeSecureSetup
                }
                try await authenticateOwner(Self.newCodeReason)
                return .created(recoveryCode: try await issueRecoveryCode(
                    mintingVault: true, ownerAsked: true, askingOwnerWith: authenticateOwner))
            }
            return .created(recoveryCode: try await issueRecoveryCode(
                mintingVault: true, askingOwnerWith: authenticateOwner))
        }
    }

    private struct ActiveLibrary {
        let coordinates: SyncBackendSelectionStore.GitCoordinates
        let remote: GitRemote
        let token: String?
        let material: Data
        let transport: GitSyncTransport
    }

    /// The saved library with its key and a transport pinned to its dataset.
    private func activeLibrary() throws -> ActiveLibrary {
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
        let transport = GitSyncTransport(
            configuration: .init(
                remote: remote, cacheDirectory: scratchCache(),
                expectedDatasetID: coordinates.datasetID, sshConnector: selection.gitSSH?.connector),
            session: setupSession())
        return ActiveLibrary(
            coordinates: coordinates, remote: remote, token: token, material: material, transport: transport)
    }

    /// `authenticateOwner` is asked when wrapping the vault key did not unlock the
    /// vault (there was none to wrap, or it was minted here), unless the caller says
    /// it has asked already.
    private func issueRecoveryCode(
        mintingVault: Bool, ownerAsked: Bool = false,
        askingOwnerWith authenticateOwner: (String) async throws -> Void
    ) async throws -> String {
        let library = try activeLibrary()
        let datasetID = library.coordinates.datasetID
        let kit = GitSyncRecovery.Kit(datasetID: datasetID)
        var files = [GitSyncRecovery.path: try GitSyncRecovery.seal(material: library.material, kit: kit)]
        let prepared = try await vaultForNewCode(kit, library: library, minting: mintingVault)
        if prepared?.minted != false, !ownerAsked {
            do {
                try await authenticateOwner(Self.newCodeReason)
            } catch {
                discard(prepared)
                throw error
            }
        }
        if let prepared {
            files[GitSyncVault.path] = try GitSyncVault.seal(
                prepared.identity, material: library.material, datasetID: datasetID)
        }
        do {
            try await mapped {
                try await library.transport.writeFiles(files, message: "Replace recovery envelope")
            }
        } catch {
            // A lost response can hide a write that landed, after which only the new
            // code opens the stored envelopes. Show it whenever that is the case.
            let current = try? await library.transport.readFile(GitSyncRecovery.path)
            if let current, (try? GitSyncRecovery.open(current, kit: kit)) != nil {
                try? adopt(prepared)
                return kit.code
            }
            // Forget a minted vault key only when the repository proves the write did
            // not land. If it cannot be read, the key may be the library's only copy.
            if current != nil { discard(prepared) }
            throw error
        }
        // Both envelopes are in the repository and only this code opens them. A local
        // write that fails now must not swallow it; `setUpSecureSnippets` repeats it.
        try? adopt(prepared)
        return kit.code
    }

    /// The vault to publish with a new recovery code, or nil to leave `keys/vault.json`
    /// alone. A published vault must be rewrapped, or the new code would open the
    /// library without its secure snippets; only a device holding its key can do that.
    private func vaultForNewCode(
        _ kit: GitSyncRecovery.Kit, library: ActiveLibrary, minting: Bool
    ) async throws -> SecureSnippetStore.PreparedLibraryVault? {
        guard let vault else { return nil }
        let published = try await publishedVault(
            library.transport, material: library.material, datasetID: library.coordinates.datasetID)
        switch published {
        case .tooNew:
            throw Failure.vaultUnavailable
        case .identity(let identity):
            // Only the library's own vault is rewrapped. A device still holding an
            // unused vault of its own takes the library's here, as connecting would
            // have: publishing its own would give the library a second vault.
            let joined = try await vaultStep { try vault.joinLibraryVault(identity) }
            guard joined == .ready else { throw Failure.vaultKeyUnavailable }
        case .absent, .unreadable:
            switch vault.libraryVaultAvailability {
            case .ready:
                break
            case .keyMissing:
                if minting { throw Failure.vaultKeyUnavailable }
                return nil
            case .none:
                guard minting else { return nil }
            }
        }
        return try await prepareVault(under: kit, reason: Self.newCodeReason)
    }

    // MARK: - The library's vault

    private enum PublishedVault {
        case absent
        case identity(GitSyncVault.Identity)
        /// Damaged, or sealed under another key. Safe to replace.
        case unreadable
        /// Written by a newer build. Never replaced from this one.
        case tooNew
    }

    private func publishedVault(
        _ transport: GitSyncTransport, material: Data, datasetID: UUID
    ) async throws -> PublishedVault {
        guard let file = try await mapped({ try await transport.readFile(GitSyncVault.path) }) else {
            return .absent
        }
        do {
            return .identity(try GitSyncVault.open(file, material: material, datasetID: datasetID))
        } catch GitSyncVault.Failure.unsupportedVersion {
            return .tooNew
        } catch {
            return .unreadable
        }
    }

    private func prepareVault(
        under kit: GitSyncRecovery.Kit, reason: String
    ) async throws -> SecureSnippetStore.PreparedLibraryVault? {
        guard let vault else { return nil }
        return try await vaultStep { try await vault.prepareLibraryVault(wrappingUnder: kit.secret, reason: reason) }
    }

    /// Writes the published vault's document on this device (a no-op for a vault that
    /// was already here).
    private func adopt(_ prepared: SecureSnippetStore.PreparedLibraryVault?) throws {
        guard let prepared, let vault else { return }
        try vault.joinLibraryVault(prepared.identity)
    }

    private func discard(_ prepared: SecureSnippetStore.PreparedLibraryVault?) {
        guard let prepared else { return }
        vault?.discardMintedLibraryVault(prepared)
    }

    private func vaultStep<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as SecureSnippetStore.LibraryVaultFailure {
            switch failure {
            case .differentVault(let count): throw Failure.differentVault(secureCount: count)
            case .keyUnavailable: throw Failure.vaultKeyUnavailable
            case .authentication: throw Failure.vaultAuthentication
            case .incorrectRecoveryCode: throw Failure.incorrectVaultRecoveryCode
            case .unreadable: throw Failure.localVaultUnreadable
            case .recoveryCodeRequired: throw Failure.recoveryCodeRequired
            case .pendingConflicts: throw Failure.pendingSecureConflicts
            }
        }
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

    /// The key scope of the library Git was syncing when `datasetID` has taken its
    /// place on the same branch; nil when nothing active is being replaced.
    private func replacedLibrary(by remote: GitRemote, datasetID: UUID) -> GitSyncKeyStore.Scope? {
        guard selection.provider == .git, let active = selection.gitCoordinates,
              Self.sameEndpoint(active.repository, remote.location),
              active.branch == remote.branch, active.datasetID != datasetID else { return nil }
        return active.keyScope
    }

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
