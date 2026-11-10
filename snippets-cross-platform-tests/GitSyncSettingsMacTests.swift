#if os(macOS)
import Foundation
import XCTest
@testable import Snippets_Debug

/// Drives the real Settings → Git sheet end to end on macOS. Every HTTP request is
/// answered by `git http-backend` on a temporary bare repository through
/// `GitBackendURLProtocol`, so the test needs no server or network. Modal alerts are
/// answered through the sheet's injection points.
@MainActor
final class GitSyncSettingsMacTests: XCTestCase {
    private var root: URL!
    private var bare: URL!
    private var host: String!
    private var previousSupportDirectory: String?
    private var previousRuntimeEnabledOverride: Bool?
    private var defaultsNames: [String] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "GitSyncSettingsMac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bare = root.appendingPathComponent("repos/library.git", isDirectory: true)
        try git(["init", "--quiet", "--bare", "--initial-branch=main", bare.path])
        host = "git-\(UUID().uuidString.lowercased()).localhost"
        GitBackendURLProtocol.register(host: host, projectRoot: root.appendingPathComponent("repos"), token: Self.token)
        previousSupportDirectory = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        previousRuntimeEnabledOverride = SyncCoordinator.runtimeEnabledOverride
        SyncCoordinator.runtimeEnabledOverride = true
    }

    override func tearDown() async throws {
        GitBackendURLProtocol.unregister(host: host)
        SyncCoordinator.runtimeEnabledOverride = previousRuntimeEnabledOverride
        if let previousSupportDirectory {
            setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousSupportDirectory, 1)
        } else {
            unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        }
        for name in defaultsNames { UserDefaults.standard.removePersistentDomain(forName: name) }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Tests

    func testCreateSwitchThenJoinFromASecondMacWithTheRecoveryCode() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let sheet: MacGitSyncViewController = first.sheet
        var created: String?
        var switchRequests = 0
        first.onSwitchRequest = { switchRequests += 1 }
        sheet.confirmCreation = { repository in
            XCTAssertTrue(repository.contains("library.git"))
            return .encrypted
        }
        sheet.presentRecoveryCode = { code, _ in created = code }
        sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(sheet, token: Self.token)

        await sheet.connect()
        let code = try XCTUnwrap(created)
        XCTAssertEqual(sheet.statusText, "Connected.")
        XCTAssertEqual(switchRequests, 1)
        XCTAssertTrue(first.selection.gitIsReady)
        XCTAssertEqual(first.selection.provider, .iCloud, "connecting alone never switches providers")
        XCTAssertEqual(sheet.tokenField.stringValue, "", "the token is not kept in the form")

        let switched = await first.coordinator.switchProvider(to: .git)
        guard case .completed(.idle(let lastSync)) = switched, lastSync != nil else {
            return XCTFail("switch did not sync: \(switched) · \(first.coordinator.statusDescription)")
        }
        XCTAssertEqual(try recordFiles().count, 1)
        first.coordinator.stop()

        // A second Mac: fresh installation, same repository, no key yet.
        let second = try makeDevice("second", seed: [])
        var prompts: [String?] = []
        second.sheet.promptForRecoveryCode = { problem in
            prompts.append(problem)
            return prompts.count == 1 ? GitSyncRecovery.Kit(datasetID: UUID()).code : code.lowercased()
        }
        second.sheet.confirmCreation = { _ in XCTFail("an existing library must not be recreated"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(second.sheet, token: Self.token)

        await second.sheet.connect()
        XCTAssertEqual(prompts.count, 2)
        XCTAssertNil(prompts[0])
        XCTAssertEqual(prompts[1], GitSyncSetup.Failure.incorrectRecoveryCode.localizedDescription)
        XCTAssertTrue(second.selection.gitIsReady)
        let joined = await second.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = joined else {
            return XCTFail("second Mac did not sync: \(joined) · \(second.coordinator.statusDescription)")
        }
        XCTAssertEqual(second.store.snippets.map(\.content), [Self.snippet.content])
        XCTAssertEqual(second.selection.provider, .git)

        // While Git is active the sheet reports it and offers Sync Now, not removal.
        second.sheet.reloadState()
        second.coordinator.stop()
    }

    /// An SSH address needs no token: the system ssh and the user's agent authenticate.
    /// A device connected over SSH and one connected over HTTPS share one library.
    func testSSHAddressConnectsWithoutATokenAndSyncsWithAnHTTPSDevice() async throws {
        let ssh = try fakeSSH()
        let first = try makeDevice("ssh", seed: [Self.snippet], ssh: ssh)
        var created: String?
        first.sheet.confirmCreation = { _ in .encrypted }
        first.sheet.presentRecoveryCode = { code, _ in created = code }
        var errors: [String] = []
        first.sheet.presentError = { _, message in errors.append(message) }
        first.sheet.urlField.stringValue = "git@fixture.invalid:library.git"
        first.sheet.updateAccessMethod()
        XCTAssertFalse(first.sheet.showsTokenFields)
        XCTAssertTrue(first.sheet.hintText.contains("ssh -T git@fixture.invalid"),
                      "the hint names the real command for the typed host")

        // The host refuses the agent's keys: explained with the host, nothing saved.
        try Data("255\ngit@fixture.invalid: Permission denied (publickey).\n".utf8)
            .write(to: root.appendingPathComponent("ssh-fail"))
        await first.sheet.connect()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.sshPermissionDenied(
            host: .init(user: "git", host: "fixture.invalid", port: nil)).localizedDescription])
        XCTAssertTrue(errors[0].contains("ssh -T git@fixture.invalid"))
        XCTAssertNil(first.selection.gitCoordinates)
        try FileManager.default.removeItem(at: root.appendingPathComponent("ssh-fail"))

        await first.sheet.connect()
        XCTAssertEqual(errors.count, 1)
        _ = try XCTUnwrap(created)
        let coordinates = try XCTUnwrap(first.selection.gitCoordinates)
        XCTAssertTrue(coordinates.usesSSH)
        XCTAssertEqual(coordinates.displayLocation, "git@fixture.invalid:library.git")
        XCTAssertNil(try first.selection.storedGitToken())
        XCTAssertTrue(first.selection.gitIsReady)
        let switched = await first.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = switched else {
            return XCTFail("ssh device did not sync: \(switched) · \(first.coordinator.statusDescription)")
        }
        XCTAssertEqual(try recordFiles().count, 1)
        let invocations = try String(contentsOf: root.appendingPathComponent("ssh.log"), encoding: .utf8)
        XCTAssertTrue(invocations.contains("BatchMode=yes"))
        XCTAssertTrue(invocations.contains("git-receive-pack 'library.git'"))
        first.coordinator.stop()

        // The same repository over HTTPS, joined with the recovery code.
        let second = try makeDevice("https", seed: [])
        second.sheet.promptForRecoveryCode = { _ in created }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(second.sheet, token: Self.token)
        XCTAssertTrue(second.sheet.showsTokenFields)
        await second.sheet.connect()
        let joined = await second.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = joined else {
            return XCTFail("https device did not sync: \(joined) · \(second.coordinator.statusDescription)")
        }
        XCTAssertEqual(second.store.snippets.map(\.content), [Self.snippet.content])
        second.coordinator.stop()
    }

    /// One repository moved between HTTPS and SSH keeps its library key (one identity),
    /// and an SSH connection leaves no access token behind.
    func testMovingARepositoryBetweenHTTPSAndSSHKeepsItsKeyAndDropsTheToken() async throws {
        let ssh = try fakeSSH()
        let device = try makeDevice("move", seed: [Self.snippet], ssh: ssh)
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { _, _ in }
        device.sheet.promptForRecoveryCode = { _ in XCTFail("the key must already be here"); return nil }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        XCTAssertTrue(device.credentials.hasItem(account: SyncBackendSelectionStore.gitTokenAccount))
        let https = try XCTUnwrap(device.selection.gitCoordinates)
        XCTAssertFalse(https.usesSSH)

        // The same host and path over SSH: the library and its key are found as-is.
        device.sheet.urlField.stringValue = "git@\(host!):library.git"
        device.sheet.updateAccessMethod()
        await device.sheet.connect()
        let moved = try XCTUnwrap(device.selection.gitCoordinates)
        XCTAssertTrue(moved.usesSSH)
        XCTAssertEqual(moved.datasetID, https.datasetID)
        XCTAssertEqual(moved.keyScope, https.keyScope)
        XCTAssertFalse(device.credentials.hasItem(account: SyncBackendSelectionStore.gitTokenAccount),
                       "an SSH connection keeps no access token")
        XCTAssertFalse(device.selection.hasStoredGitToken)
        XCTAssertTrue(device.selection.gitIsReady)

        // Back to HTTPS needs the token again: the old one is gone, not silently reused.
        var failures: [String] = []
        device.sheet.presentError = { _, message in failures.append(message) }
        fill(device.sheet, token: "")
        await device.sheet.connect()
        XCTAssertEqual(failures, [GitSyncSetup.Failure.missingToken.localizedDescription])
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(device.selection.gitCoordinates?.usesSSH, false)
        XCTAssertEqual(device.selection.gitCoordinates?.datasetID, https.datasetID)
    }

    /// Plain text is chosen at creation: ordinary snippets become readable Markdown in
    /// the repository, the sheet says so, and a second Mac joins as usual.
    func testCreatingAPlainTextLibraryWritesReadableSnippets() async throws {
        let first = try makeDevice("plain", seed: [Self.snippet])
        var code: String?
        first.sheet.confirmCreation = { _ in .plainText }
        first.sheet.presentRecoveryCode = { created, _ in code = created }
        first.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(first.sheet, token: Self.token)
        await first.sheet.connect()
        XCTAssertEqual(first.selection.gitCoordinates?.mode, .plainText)
        let switched = await first.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = switched else {
            return XCTFail("\(switched) · \(first.coordinator.statusDescription)")
        }
        let files = try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"]).split(separator: "\n")
        let markdown = try XCTUnwrap(files.first { $0.hasPrefix("snippets/") && $0.hasSuffix(".md") })
        XCTAssertEqual(markdown, "snippets/settings-git-617a0002.md")
        XCTAssertTrue(try git(["--git-dir", bare.path, "show", "main:\(markdown)"]).contains(Self.snippet.content))
        XCTAssertFalse(files.contains { $0.hasPrefix("records/") })
        first.sheet.reloadState()
        XCTAssertTrue(first.sheet.connectedText.contains("Plain text"))
        first.coordinator.stop()

        let second = try makeDevice("plain-2", seed: [])
        var consentAsked = 0
        second.sheet.confirmPlainTextJoin = { consentAsked += 1; return consentAsked > 1 }
        second.sheet.promptForRecoveryCode = { _ in code }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertNil(second.selection.gitCoordinates, "declining the plain-text warning connects nothing")
        await second.sheet.connect()
        XCTAssertEqual(consentAsked, 2)
        XCTAssertEqual(second.selection.gitCoordinates?.mode, .plainText)
        let joined = await second.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = joined else {
            return XCTFail("\(joined) · \(second.coordinator.statusDescription)")
        }
        XCTAssertEqual(second.store.snippets.map(\.content), [Self.snippet.content])
        second.coordinator.stop()
    }

    /// The guidance follows the host typed: which token to create, where to add a
    /// deploy key, and whether the user name may be left empty.
    func testGuidanceFollowsTheAddress() throws {
        let device = try makeDevice("guidance", seed: [])
        let sheet: MacGitSyncViewController = try XCTUnwrap(device.sheet)
        sheet.urlField.stringValue = "https://github.com/you/snippets-library"
        sheet.updateAccessMethod()
        XCTAssertTrue(sheet.hintText.contains("fine-grained token"))
        XCTAssertEqual(sheet.guidanceLink?.host, "github.com")
        XCTAssertEqual(sheet.usernameField.placeholderString, "Optional for GitHub and GitLab")

        sheet.urlField.stringValue = "git@github.com:you/snippets-library.git"
        sheet.updateAccessMethod()
        XCTAssertEqual(sheet.guidanceLink?.absoluteString, "https://github.com/you/snippets-library/settings/keys/new")

        sheet.urlField.stringValue = "https://gitea.example.com/you/snippets-library"
        sheet.updateAccessMethod()
        XCTAssertNil(sheet.guidanceLink)
        XCTAssertTrue(sheet.hintText.contains("write:repository"))
        XCTAssertEqual(sheet.usernameField.placeholderString, "Your account name on the host")
    }

    func testWrongTokenAndForeignBranchAreExplainedAndSaveNothing() async throws {
        let device = try makeDevice("errors", seed: [])
        var errors: [String] = []
        var offers: [String] = []
        device.sheet.presentError = { _, message in errors.append(message) }
        device.sheet.offerSuggestedBranch = { message in offers.append(message); return false }
        device.sheet.confirmCreation = { _ in XCTFail("nothing should be created"); return nil }

        fill(device.sheet, token: "not-the-token")
        await device.sheet.connect()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.authentication.localizedDescription])

        let work = root.appendingPathComponent("foreign", isDirectory: true)
        try git(["init", "--quiet", "--initial-branch=main", work.path])
        try Data("code\n".utf8).write(to: work.appendingPathComponent("main.c"))
        try git(["-C", work.path, "add", "-A"])
        try git(["-C", work.path, "commit", "--quiet", "-m", "code"])
        try git(["-C", work.path, "push", "--quiet", bare.path, "HEAD:refs/heads/main"])
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        XCTAssertEqual(offers, [GitSyncSetup.Failure.foreignBranch.localizedDescription])
        XCTAssertEqual(errors.count, 1, "declining the offer is not an error")
        XCTAssertEqual(device.sheet.statusText, "Not connected.")

        XCTAssertNil(device.selection.gitCoordinates)
        XCTAssertFalse(device.selection.hasGitCredential)
        XCTAssertEqual(try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"]), "main.c")

        // Accepting it creates the library on its own branch and leaves main alone.
        device.sheet.offerSuggestedBranch = { _ in true }
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { _, _ in }
        await device.sheet.connect()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(device.sheet.branchField.stringValue, GitSyncSetup.suggestedBranch)
        XCTAssertEqual(device.selection.gitCoordinates?.branch, GitSyncSetup.suggestedBranch)
        XCTAssertEqual(try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"]), "main.c")
        XCTAssertTrue(try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", GitSyncSetup.suggestedBranch])
            .contains("snippets-sync.json"))
    }

    func testNewRecoveryCodeReplacesTheEnvelopeAndRemoveKeepsTheKey() async throws {
        let device = try makeDevice("recovery", seed: [])
        var codes: [String] = []
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { code, _ in codes.append(code) }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        var authenticated = 0
        device.sheet.authenticateOwner = { _ in authenticated += 1 }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        let coordinates = try XCTUnwrap(device.selection.gitCoordinates)

        await device.sheet.replaceRecoveryCode()
        XCTAssertEqual(authenticated, 1)
        XCTAssertEqual(codes.count, 2)
        XCTAssertNotEqual(codes[0], codes[1])
        let envelope = Data(try git(["--git-dir", bare.path, "show", "main:keys/recovery.json"]).utf8)
        let material = try XCTUnwrap(try device.selection.gitKeys.material(for: coordinates.keyScope))
        XCTAssertEqual(try GitSyncRecovery.open(
            envelope, kit: GitSyncRecovery.Kit(code: codes[1], datasetID: coordinates.datasetID)), material)
        XCTAssertThrowsError(try GitSyncRecovery.open(
            envelope, kit: GitSyncRecovery.Kit(code: codes[0], datasetID: coordinates.datasetID)))

        // Reconnecting the same repository without retyping the token reuses it.
        device.sheet.tokenField.stringValue = ""
        await device.sheet.connect()
        XCTAssertEqual(device.sheet.statusText, "Connected.")

        let setup = GitSyncSetup(selection: device.selection, coordinator: device.coordinator)
        try setup.disconnect()
        XCTAssertNil(device.selection.gitCoordinates)
        XCTAssertFalse(device.selection.hasGitCredential)
        XCTAssertNotNil(try device.selection.gitKeys.material(for: coordinates.keyScope))
    }

    func testALostPushResponseStillYieldsAUsableLibraryAndItsCode() async throws {
        let device = try makeDevice("lost", seed: [])
        var codes: [String] = []
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { code, _ in codes.append(code) }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        device.sheet.authenticateOwner = { _ in }
        fill(device.sheet, token: Self.token)
        GitBackendURLProtocol.dropResponseOfNextPush(host: host)
        await device.sheet.connect()
        let coordinates = try XCTUnwrap(device.selection.gitCoordinates, "the landed library must be connected")
        XCTAssertEqual(codes.count, 1)
        let envelope = Data(try git(["--git-dir", bare.path, "show", "main:keys/recovery.json"]).utf8)
        let material = try XCTUnwrap(try device.selection.gitKeys.material(for: coordinates.keyScope))
        XCTAssertEqual(try GitSyncRecovery.open(
            envelope, kit: GitSyncRecovery.Kit(code: codes[0], datasetID: coordinates.datasetID)), material)

        // The same ambiguity while replacing the code must still hand back the new one.
        GitBackendURLProtocol.dropResponseOfNextPush(host: host)
        await device.sheet.replaceRecoveryCode()
        XCTAssertEqual(codes.count, 2)
        let replaced = Data(try git(["--git-dir", bare.path, "show", "main:keys/recovery.json"]).utf8)
        XCTAssertEqual(try GitSyncRecovery.open(
            replaced, kit: GitSyncRecovery.Kit(code: codes[1], datasetID: coordinates.datasetID)), material)
    }

    func testActiveGitCannotBeRetargetedToAnotherLibrary() async throws {
        let device = try makeDevice("active", seed: [])
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { _, _ in }
        var errors: [String] = []
        device.sheet.presentError = { _, message in errors.append(message) }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        let switched = await device.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = switched else { return XCTFail("\(switched)") }
        let active = try XCTUnwrap(device.selection.gitCoordinates)

        // An empty second branch would become a new library: refused while Git is active.
        device.sheet.branchField.stringValue = "other"
        device.sheet.tokenField.stringValue = Self.token
        await device.sheet.connect()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.otherLibraryActive(active.displayLocation).errorDescription])
        XCTAssertEqual(device.selection.gitCoordinates, active)
        XCTAssertThrowsError(try git(["--git-dir", bare.path, "rev-parse", "--verify", "other"]))

        // Reconnecting the same library (for example with a new token) still works.
        device.sheet.branchField.stringValue = "main"
        device.sheet.tokenField.stringValue = ""
        await device.sheet.connect()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(device.sheet.statusText, "Connected.")
        device.coordinator.stop()
    }

    /// The status tells the user to reconnect a deleted or replaced library; Settings
    /// must then allow exactly that on the same branch, never a different destination.
    func testDeletedActiveLibraryCanBeRecreatedOnTheSameBranch() async throws {
        let device = try makeDevice("recreate", seed: [Self.snippet])
        var creations = 0
        device.sheet.confirmCreation = { _ in creations += 1; return .encrypted }
        device.sheet.presentRecoveryCode = { _, _ in }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        let switched = await device.coordinator.switchProvider(to: .git)
        guard case .completed(.idle) = switched else { return XCTFail("\(switched)") }
        let original = try XCTUnwrap(device.selection.gitCoordinates)

        try git(["--git-dir", bare.path, "update-ref", "-d", "refs/heads/main"])
        let broken = await device.coordinator.requestSync(trigger: .manual)
        guard case .completed(.needsAttention(let detail)) = broken else { return XCTFail("\(broken)") }
        XCTAssertEqual(detail, "git_repository_not_initialized")

        device.sheet.tokenField.stringValue = ""
        await device.sheet.connect()
        XCTAssertEqual(creations, 2)
        let recreated = try XCTUnwrap(device.selection.gitCoordinates)
        XCTAssertNotEqual(recreated.datasetID, original.datasetID)
        XCTAssertEqual(device.selection.provider, .git)
        let resumed = await device.coordinator.requestSync(trigger: .manual)
        guard case .completed(.idle) = resumed else {
            return XCTFail("\(resumed) · \(device.coordinator.statusDescription)")
        }
        XCTAssertEqual(try recordFiles().count, 1, "the local library is merged into the new one")
        device.coordinator.stop()
    }

    func testTokenIsBoundToItsRepositoryAndAPendingSwitchPinsTheLocation() async throws {
        let device = try makeDevice("binding", seed: [])
        device.sheet.confirmCreation = { _ in .encrypted }
        device.sheet.presentRecoveryCode = { _, _ in }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        var coordinates = try XCTUnwrap(device.selection.gitCoordinates)
        XCTAssertEqual(try device.selection.storedGitToken(), Self.token)

        // Coordinates for another repository (as after a crash between the token and
        // coordinate writes) never receive this repository's token.
        var moved = coordinates
        moved.repository = .https(URL(string: "http://\(host!)/elsewhere.git")!)
        let suite = try XCTUnwrap(defaultsNames.last)
        UserDefaults(suiteName: suite)?.set(moved.repository.spec,
                                            forKey: SyncBackendSelectionStore.gitRepositoryDefaultsKey)
        XCTAssertNil(try device.selection.storedGitToken())
        XCTAssertFalse(device.selection.gitIsReady)
        UserDefaults(suiteName: suite)?.set(coordinates.repository.spec,
                                            forKey: SyncBackendSelectionStore.gitRepositoryDefaultsKey)

        // An unfinished switch receipt pins Git's location.
        let receipt = try device.selection.prepareProviderSwitch(to: .git)
        defer { try? FileManager.default.removeItem(at: SnippetStorageLocations.syncProviderSwitchFileURL) }
        XCTAssertEqual(receipt.target, .git)
        coordinates.branch = "elsewhere"
        XCTAssertThrowsError(try device.selection.configureGit(coordinates, token: Self.token)) { error in
            guard case SyncBackendSelectionStore.Failure.gitConfigurationInUse = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(device.selection.gitCoordinates?.branch, "main")
    }

    // MARK: - Fixture

    private final class Device {
        let selection: SyncBackendSelectionStore
        let store: SnippetStore
        let coordinator: SyncCoordinator
        var sheet: MacGitSyncViewController! = nil
        var onSwitchRequest: () -> Void = {}
        var credentials: KeychainSecretStore!

        init(selection: SyncBackendSelectionStore, store: SnippetStore, coordinator: SyncCoordinator) {
            self.selection = selection
            self.store = store
            self.coordinator = coordinator
        }
    }

    /// A stand-in `ssh` that runs the remote command in `repos/`, so
    /// `git@fixture.invalid:library.git` reaches `bare`. It fails like ssh while
    /// `ssh-fail` exists (exit status, then stderr).
    private func fakeSSH() throws -> GitSSHSupport {
        let script = root.appendingPathComponent("bin/ssh")
        try FileManager.default.createDirectory(
            at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        #!/bin/sh
        root="$(cd "$(dirname "$0")/.." && pwd)"
        printf '%s\\n' "$*" >> "$root/ssh.log"
        if [ -f "$root/ssh-fail" ]; then
          status=$(head -n 1 "$root/ssh-fail"); tail -n +2 "$root/ssh-fail" >&2; exit "$status"
        fi
        for last; do :; done
        cd "$root/repos" || exit 255
        export HOME="$root" PATH=/usr/bin:/bin GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
        exec /bin/sh -c "$last"

        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var connector = GitSystemSSHConnector()
        connector.executable = script
        return GitSSHSupport(connector: connector, device: nil)
    }

    private func makeDevice(_ name: String, seed: [Snippet], ssh: GitSSHSupport? = nil) throws -> Device {
        let support = root.appendingPathComponent("device-\(name)", isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, support.path, 1)
        SnippetStorageLocations.createAllDirectories()
        try SnippetLibraryCodec.encode(seed).write(to: SnippetStorageLocations.snippetsFileURL, options: .atomic)
        let defaultsName = "GitSyncSettingsMac-\(UUID().uuidString)"
        defaultsNames.append(defaultsName)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [GitBackendURLProtocol.self]
        let credentials = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let selection = SyncBackendSelectionStore(
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName)),
            keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            bootstrapSecrets: KeychainSecretStore(tier: .deviceOnly, inMemory: true),
            snippetsCloudEnabled: false,
            gitKeys: GitSyncKeyStore(keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true)),
            gitCredentials: credentials,
            gitSessionConfiguration: sessionConfiguration,
            gitAllowsInsecureLoopback: true,
            gitSSH: ssh)
        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let store = SnippetStore(configuration: .macOSDefault)
        let vault = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let secureStore = SecureSnippetStore(session: vault, keychain: keychain, deviceID: store.deviceID)
        store.secureProvider = secureStore
        let coordinator = SyncCoordinator(
            library: SnippetLibraryBridge(store: store, secureStore: secureStore),
            keys: SyncKeyStore(
                keychain: keychain, gitKeys: selection.gitKeys,
                gitScope: { selection.provider == .git ? .some(selection.gitCoordinates?.keyScope) : nil }),
            device: store.deviceID,
            backendSelection: selection)
        store.syncDelegate = coordinator
        let device = Device(selection: selection, store: store, coordinator: coordinator)
        device.credentials = credentials
        device.sheet = MacGitSyncViewController(selection: selection, coordinator: coordinator) {
            [weak device] in device?.onSwitchRequest()
        }
        _ = device.sheet.view
        // A modal alert would wait forever for a click; an unexpected one fails instead.
        device.sheet.confirmPrivateRepository = { XCTFail("unexpected private-repository prompt"); return false }
        device.sheet.confirmPlainTextJoin = { XCTFail("unexpected plain-text join prompt"); return false }
        return device
    }

    private func fill(_ sheet: MacGitSyncViewController, token: String) {
        sheet.urlField.stringValue = "http://\(host!)/library.git"
        sheet.branchField.stringValue = "main"
        sheet.usernameField.stringValue = "tester"
        sheet.tokenField.stringValue = token
    }

    private func recordFiles() throws -> [Substring] {
        try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"])
            .split(separator: "\n").filter { $0.hasPrefix("records/") }
    }

    @discardableResult
    private func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Other", "-c", "user.email=other@example.invalid"] + arguments
        process.environment = GitBackendURLProtocol.environment(home: root)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "git", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: text])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let token = "test-token-\(UUID().uuidString)"
    private static let snippet = Snippet(
        id: UUID(uuidString: "617a0002-0000-4000-8000-000000000002")!,
        name: "Settings Git", keyword: "settings-git", content: "git-settings-mac-3b1f4c2e",
        tags: [], isEnabled: true, isPinned: false,
        createdAt: Date(timeIntervalSince1970: 1_786_579_200),
        updatedAt: Date(timeIntervalSince1970: 1_786_579_200))
}

/// Answers requests for registered hosts by running `git http-backend` as CGI.
final class GitBackendURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var repositories: [String: (root: URL, token: String)] = [:]
    /// Apply the next push, then drop its response: the "did it land?" ambiguity.
    nonisolated(unsafe) private static var dropNextPushResponse: Set<String> = []

    static func dropResponseOfNextPush(host: String) {
        lock.withLock { _ = dropNextPushResponse.insert(host) }
    }

    static func register(host: String, projectRoot: URL, token: String) {
        lock.withLock { repositories[host] = (projectRoot, token) }
    }

    static func unregister(host: String) {
        lock.withLock { repositories[host] = nil }
    }

    static func environment(home: URL) -> [String: String] {
        var environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        if let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] {
            environment["DEVELOPER_DIR"] = developer
        }
        return environment
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { repositories[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        DispatchQueue.global().async { [self] in
            do {
                let (status, headers, body) = try respond()
                let drop = Self.lock.withLock { () -> Bool in
                    guard request.httpMethod == "POST", request.url?.lastPathComponent == "git-receive-pack",
                          let host = request.url?.host, Self.dropNextPushResponse.contains(host) else { return false }
                    Self.dropNextPushResponse.remove(host)
                    return true
                }
                if drop {
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                let response = HTTPURLResponse(
                    url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: body)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    private func respond() throws -> (Int, [String: String], Data) {
        let url = request.url!
        guard let repository = Self.lock.withLock({ Self.repositories[url.host!] }) else {
            return (404, [:], Data())
        }
        let expected = "Basic " + Data("tester:\(repository.token)".utf8).base64EncodedString()
        guard request.value(forHTTPHeaderField: "Authorization") == expected else {
            return (401, ["Content-Type": "text/plain"], Data("unauthorized".utf8))
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(buffer, count: count)
            }
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-cgi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let input = scratch.appendingPathComponent("stdin")
        try body.write(to: input)
        var environment = Self.environment(home: scratch)
        environment["GIT_PROJECT_ROOT"] = repository.root.path
        environment["GIT_HTTP_EXPORT_ALL"] = "1"
        environment["PATH_INFO"] = url.path
        environment["QUERY_STRING"] = url.query ?? ""
        environment["REQUEST_METHOD"] = request.httpMethod ?? "GET"
        environment["REMOTE_USER"] = "tester"
        environment["REMOTE_ADDR"] = "127.0.0.1"
        environment["CONTENT_TYPE"] = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        environment["CONTENT_LENGTH"] = String(body.count)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["http-backend"]
        process.environment = environment
        process.standardInput = try FileHandle(forReadingFrom: input)
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let raw = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) ?? raw.range(of: Data("\n\n".utf8)) else {
            return (500, [:], Data())
        }
        var status = 200
        var headers: [String: String] = [:]
        for line in String(decoding: raw[..<separator.lowerBound], as: UTF8.self)
            .components(separatedBy: .newlines) where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon])
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name.lowercased() == "status" { status = Int(value.prefix(3)) ?? 500 } else { headers[name] = value }
        }
        return (status, headers, Data(raw[separator.upperBound...]))
    }
}
#endif
