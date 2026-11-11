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
    private var devices: [Device] = []

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
        for device in devices { await retire(device) }
        devices = []
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
        await retire(first)

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
        await retire(second)
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
        await retire(first)

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
        await retire(second)
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
        await retire(first)

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
        await retire(second)
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

        XCTAssertEqual(device.vaultAuthentications, 0, "a new library's vault is minted without a prompt")
        await device.sheet.replaceRecoveryCode()
        XCTAssertEqual(device.vaultAuthentications, 1, "wrapping the vault key under the new code asks for the owner")
        XCTAssertEqual(authenticated, 0, "and that is the only prompt")
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
        await retire(device)
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
        await retire(device)
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


    // MARK: - Secure snippets

    /// The reason the library publishes its vault: a device that has nothing but the
    /// recovery code opens secure snippets, and its own secure snippets open elsewhere.
    func testSecureSnippetsOpenOnOtherMacsWithOnlyTheRecoveryCode() async throws {
        try await secureSnippetsTravel(mode: .encrypted)
    }

    func testSecureSnippetsOpenOnOtherMacsInAPlainTextLibrary() async throws {
        try await secureSnippetsTravel(mode: .plainText)
    }

    private func secureSnippetsTravel(mode: GitLibraryMode) async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first, mode: mode)
        XCTAssertEqual(first.vaultAuthentications, 0, "a device without secure snippets is not asked for anything")
        XCTAssertTrue(try treeFiles().contains("keys/vault.json"))
        XCTAssertEqual(first.sheet.setupStatus, .ready)
        try await switchToGit(first)
        let firstSecret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("second", seed: [])
        await join(second, code: code, mode: mode)
        XCTAssertEqual(second.sheet.statusText, "Connected.")
        XCTAssertEqual(second.secureStore.document?.kid, first.secureStore.document?.kid)
        XCTAssertEqual(second.secureStore.libraryVaultAvailability, .ready)
        XCTAssertEqual(second.sheet.setupStatus, .ready)
        try await switchToGit(second)
        XCTAssertEqual(second.secureStore.shells.map(\.name), ["Server Password"])
        let opened = try await secureContent(second, firstSecret)
        XCTAssertEqual(opened, Self.firstSecret)
        let secondSecret = try await addSecure(second, name: "Door Code", keyword: "door", body: Self.secondSecret)
        try await sync(second)
        await retire(second)

        let third = try makeDevice("third", seed: [])
        await join(third, code: code, mode: mode)
        try await switchToGit(third)
        let thirdFirst = try await secureContent(third, firstSecret)
        let thirdSecond = try await secureContent(third, secondSecret)
        XCTAssertEqual([thirdFirst, thirdSecond], [Self.firstSecret, Self.secondSecret])
        await retire(third)

        // Secure snippets are ciphertext under records/ in either mode, and nothing in
        // any commit names them or holds their bodies.
        let files = try treeFiles()
        XCTAssertEqual(files.filter { $0.hasPrefix("records/") }.count, mode == .plainText ? 2 : 3)
        let history = try git(["--git-dir", bare.path, "log", "-p", "--all", "--format=%s"])
        for hidden in [Self.firstSecret, Self.secondSecret, "Server Password", "Door Code", "srvpw"] {
            XCTAssertFalse(history.contains(hidden), "\(hidden) must not be readable in the repository")
        }
        XCTAssertEqual(history.contains(Self.snippet.content), mode == .plainText)
    }

    /// A device that already has secure snippets brings its vault into the library it
    /// creates, after one prompt; a new recovery code keeps opening them, and the
    /// recovery key saved for the vault earlier still works on that device.
    func testAnExistingVaultJoinsItsLibraryAndSurvivesANewRecoveryCode() async throws {
        let first = try makeDevice("owner", seed: [])
        var vaultRecoveryKey: String?
        try first.secureStore.createVaultIfNeeded { key in
            vaultRecoveryKey = key
            return true
        }
        let ownVault = try XCTUnwrap(first.secureStore.document)
        let secret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)

        let prompts = first.vaultAuthentications
        let code = try await createLibrary(first)
        XCTAssertEqual(first.vaultAuthentications, prompts + 1, "including existing secure snippets asks once")
        XCTAssertEqual(first.secureStore.document?.kid, ownVault.kid, "the library uses this device's vault")
        XCTAssertEqual(first.secureStore.document?.wrapRecovery, ownVault.wrapRecovery)
        try await switchToGit(first)

        var replaced: String?
        var ownerPrompts = 0
        first.sheet.presentRecoveryCode = { newCode, _ in replaced = newCode }
        first.sheet.authenticateOwner = { _ in ownerPrompts += 1 }
        await first.sheet.replaceRecoveryCode()
        let newCode = try XCTUnwrap(replaced)
        XCTAssertNotEqual(newCode, code)
        XCTAssertEqual(first.vaultAuthentications, prompts + 2)
        XCTAssertEqual(ownerPrompts, 0)
        XCTAssertEqual(try git(["--git-dir", bare.path, "log", "-1", "--format=%s", "main"]), "Replace recovery envelope")
        XCTAssertEqual(
            try git(["--git-dir", bare.path, "show", "--name-only", "--format=", "main"]).split(separator: "\n").sorted(),
            ["keys/recovery.json", "keys/vault.json"], "one commit replaces both envelopes")
        await retire(first)

        // The old code no longer opens the library; the new one opens everything.
        let second = try makeDevice("joiner", seed: [])
        var asked: [String?] = []
        second.sheet.promptForRecoveryCode = { problem in
            asked.append(problem)
            return asked.count == 1 ? code : newCode
        }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertEqual(asked, [nil, GitSyncSetup.Failure.incorrectRecoveryCode.localizedDescription])
        try await switchToGit(second)
        let opened = try await secureContent(second, secret)
        XCTAssertEqual(opened, Self.firstSecret)
        await retire(second)

        // The vault's own recovery key still restores the key on the device it was made for.
        use(first)
        first.vaultSession.lock()
        try first.secureStore.restoreKey(fromRecoveryKey: try XCTUnwrap(vaultRecoveryKey))
    }

    /// A device whose secure snippets are sealed under another vault is refused before
    /// anything is saved: adopting the library's vault would orphan them.
    func testADeviceWithAnotherVaultIsRefusedBeforeAnythingIsSaved() async throws {
        let first = try makeDevice("library", seed: [])
        let code = try await createLibrary(first)
        await retire(first)

        let second = try makeDevice("rival", seed: [])
        try second.secureStore.createVaultIfNeeded { _ in true }
        _ = try await addSecure(second, name: "Own Secret", keyword: "own", body: Self.secondSecret)
        let rival = try XCTUnwrap(second.secureStore.document)
        var errors: [String] = []
        second.sheet.promptForRecoveryCode = { _ in code }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { _, message in errors.append(message) }
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.differentVault(secureCount: 1).localizedDescription])
        XCTAssertTrue(errors[0].contains("1 secure snippet "))
        XCTAssertNil(second.selection.gitCoordinates)
        XCTAssertEqual(second.secureStore.document, rival, "the device's own vault is untouched")
        let scope = try XCTUnwrap(first.selection.gitCoordinates?.keyScope)
        XCTAssertFalse(second.selection.gitKeys.hasMaterial(for: scope), "not even the library key is kept")
    }

    /// A vault nothing was ever kept in is not in the way. Every Git library mints one
    /// when it is created, so a device that moves to another library usually has
    /// exactly that; it adopts the library's vault instead.
    func testAnUnusedVaultIsReplacedByTheLibrarysOnJoin() async throws {
        let first = try makeDevice("library", seed: [])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        let secret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("mover", seed: [])
        try second.secureStore.createVaultIfNeeded { _ in true }
        let unused = try XCTUnwrap(second.secureStore.document?.kid)
        await join(second, code: code)
        XCTAssertNotEqual(second.secureStore.document?.kid, unused)
        XCTAssertEqual(second.secureStore.document?.kid, first.secureStore.document?.kid)
        XCTAssertEqual(second.sheet.setupStatus, .ready)
        try await switchToGit(second)
        let opened = try await secureContent(second, secret)
        XCTAssertEqual(opened, Self.firstSecret)
        await retire(second)
    }

    /// A library created before `keys/vault.json` existed: the device that holds the
    /// vault publishes it with New Recovery Code, and a device that was waiting for the
    /// key gets it by entering that code.
    func testALibraryWithoutAVaultFileGetsOneFromTheDeviceThatHoldsTheVault() async throws {
        let first = try makeDevice("holder", seed: [])
        try first.secureStore.createVaultIfNeeded { _ in true }
        let secret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        let oldCode = try await createLibrary(first)
        try removeFromRepository("keys/vault.json")
        try await switchToGit(first)
        await retire(first)

        // Joined with the old code: the secure snippet has nowhere to go.
        let second = try makeDevice("waiting", seed: [])
        await join(second, code: oldCode)
        XCTAssertNil(second.secureStore.document)
        XCTAssertEqual(second.sheet.setupStatus, .needsSetup)
        let waiting = await second.coordinator.switchProvider(to: .git)
        guard case .completed(.waitingForVault) = waiting else { return XCTFail("\(waiting)") }
        XCTAssertTrue(second.coordinator.statusDescription.contains("Set Up Secure Snippets"))
        var errors: [String] = []
        second.sheet.presentError = { _, message in errors.append(message) }
        second.sheet.presentRecoveryCode = { _, _ in XCTFail("this device must not mint a rival vault") }
        await second.sheet.setUpSecureSnippets()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.vaultHeldElsewhere.localizedDescription])
        XCTAssertNil(second.secureStore.document)
        XCTAssertFalse(try treeFiles().contains("keys/vault.json"))
        await retire(second)

        // The holder issues a new code; that publishes its vault. (Setup only: the
        // retired device's sync stays stopped.)
        use(first)
        var newCode: String?
        first.sheet.presentRecoveryCode = { issued, _ in newCode = issued }
        first.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        first.sheet.authenticateOwner = { _ in XCTFail("the vault unlock is the owner check") }
        await first.sheet.replaceRecoveryCode()
        let code = try XCTUnwrap(newCode)
        XCTAssertTrue(try treeFiles().contains("keys/vault.json"))

        // The waiting device: the old code is refused for secure snippets, the new one opens them.
        resume(second)
        var asked: [String?] = []
        second.sheet.promptForRecoveryCode = { problem in
            asked.append(problem)
            return asked.count == 1 ? oldCode : code
        }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        await second.sheet.setUpSecureSnippets()
        XCTAssertEqual(asked, [nil, GitSyncSetup.Failure.incorrectVaultRecoveryCode.localizedDescription])
        XCTAssertEqual(second.sheet.statusText, "Secure snippets are ready on this Mac.")
        XCTAssertEqual(second.sheet.setupStatus, .ready)
        XCTAssertEqual(second.secureStore.document?.kid, first.secureStore.document?.kid)
        guard case .idle = second.coordinator.state else {
            return XCTFail("the waiting snippet did not apply: \(second.coordinator.statusDescription)")
        }
        let opened = try await secureContent(second, secret)
        XCTAssertEqual(opened, Self.firstSecret)
        await retire(second)
    }

    /// The same older library with no secure snippets anywhere: the first device that
    /// wants them mints the library's vault, after the owner check, with a new code.
    func testALibraryWithoutAnyVaultGetsOneWithANewRecoveryCode() async throws {
        let first = try makeDevice("creator", seed: [Self.snippet])
        let oldCode = try await createLibrary(first)
        try removeFromRepository("keys/vault.json")
        try await switchToGit(first)
        await retire(first)

        let second = try makeDevice("starter", seed: [])
        await join(second, code: oldCode)
        XCTAssertEqual(second.sheet.setupStatus, .needsSetup)

        // Before this device has synced with the library it cannot know that no other
        // device holds secure snippets, so nothing is minted yet.
        var errors: [String] = []
        var ownerPrompts = 0
        var issued: String?
        second.sheet.presentError = { _, message in errors.append(message) }
        second.sheet.authenticateOwner = { _ in ownerPrompts += 1 }
        second.sheet.presentRecoveryCode = { code, _ in issued = code }
        await second.sheet.setUpSecureSnippets()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.syncBeforeSecureSetup.localizedDescription])
        XCTAssertEqual(ownerPrompts, 0)

        try await switchToGit(second)
        // "Make this secure" must not mint a vault of its own beside the library.
        XCTAssertThrowsError(try second.secureStore.prepareVaultCreationIfNeeded()) { error in
            guard case SecureSnippetStore.Failure.libraryVaultSetupRequired = error else { return XCTFail("\(error)") }
        }
        await second.sheet.setUpSecureSnippets()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(ownerPrompts, 1)
        let code = try XCTUnwrap(issued)
        XCTAssertNotEqual(code, oldCode)
        XCTAssertEqual(second.sheet.setupStatus, .ready)
        XCTAssertTrue(try treeFiles().contains("keys/vault.json"))
        let secret = try await addSecure(second, name: "Door Code", keyword: "door", body: Self.secondSecret)
        try await sync(second)
        await retire(second)

        let third = try makeDevice("later", seed: [])
        await join(third, code: code)
        try await switchToGit(third)
        let opened = try await secureContent(third, secret)
        XCTAssertEqual(opened, Self.secondSecret)
        await retire(third)
    }

    /// A code made by a build that rewrote only `keys/recovery.json` opens the library
    /// but not its vault. The device still joins; secure snippets say what they need.
    func testACodeThatOpensOnlyTheLibraryStillJoinsAndAsksForTheVaultCode() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        let secret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)
        // What the older build did: a new recovery envelope, the vault file left as it was.
        let coordinates = try XCTUnwrap(first.selection.gitCoordinates)
        let material = try XCTUnwrap(try first.selection.gitKeys.material(for: coordinates.keyScope))
        let libraryOnly = GitSyncRecovery.Kit(datasetID: coordinates.datasetID)
        try writeToRepository(
            "keys/recovery.json", try GitSyncRecovery.seal(material: material, kit: libraryOnly))

        let second = try makeDevice("second", seed: [])
        await join(second, code: libraryOnly.code)
        XCTAssertTrue(second.sheet.statusText.hasPrefix("Connected. Secure snippets still need the recovery code"))
        XCTAssertEqual(second.sheet.setupStatus, .needsRecoveryCode)
        XCTAssertEqual(second.secureStore.document?.kid, first.secureStore.document?.kid)
        try await switchToGit(second)
        XCTAssertEqual(second.secureStore.shells.map(\.name), ["Server Password"], "the snippet is filed, locked")
        second.sheet.reloadState()
        XCTAssertTrue(second.sheet.connectedText.contains("Secure snippets: locked."))

        // The code that wraps the vault key (the original one) unlocks them.
        second.sheet.promptForRecoveryCode = { _ in code }
        await second.sheet.setUpSecureSnippets()
        XCTAssertEqual(second.sheet.setupStatus, .ready)
        let opened = try await secureContent(second, secret)
        XCTAssertEqual(opened, Self.firstSecret)
        await retire(second)
    }

    // MARK: - Replacing the keys

    func testReplacingTheKeysMovesEveryDeviceToNewOnes() async throws {
        try await keysAreReplaced(mode: .encrypted)
    }

    func testReplacingTheKeysOfAPlainTextLibrary() async throws {
        try await keysAreReplaced(mode: .plainText)
    }

    /// One device replaces the library's keys. It keeps reading its secure snippets, the
    /// old recovery code opens nothing any more, and a device that was away reconnects
    /// with the new code: its secure snippets, including one it never uploaded, are
    /// re-sealed under the library's new vault key.
    private func keysAreReplaced(mode: GitLibraryMode) async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first, mode: mode)
        try await switchToGit(first)
        let shared = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("second", seed: [])
        await join(second, code: code, mode: mode)
        try await switchToGit(second)
        await retire(second)
        // Made after its last sync: the repository never sees it under the old keys.
        let own = try await addSecure(second, name: "Door Code", keyword: "door", body: Self.secondSecret)

        resume(first)
        let oldCoordinates = try XCTUnwrap(first.selection.gitCoordinates)
        let oldVault = try XCTUnwrap(first.secureStore.document)
        var shown: [String] = []
        var ownerPrompts = 0
        first.sheet.presentRecoveryCode = { newCode, _ in shown.append(newCode) }
        first.sheet.authenticateOwner = { _ in ownerPrompts += 1 }
        first.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        let prompts = first.vaultAuthentications
        await first.sheet.rotateKeys()
        XCTAssertEqual(shown.count, 1)
        let newCode = try XCTUnwrap(shown.first)
        XCTAssertNotEqual(newCode, code)
        XCTAssertEqual(first.vaultAuthentications, prompts + 1, "re-sealing the vault is the one owner check")
        XCTAssertEqual(ownerPrompts, 0)

        let coordinates = try XCTUnwrap(first.selection.gitCoordinates)
        XCTAssertNotEqual(coordinates.datasetID, oldCoordinates.datasetID)
        XCTAssertEqual(coordinates.mode, mode)
        XCTAssertTrue(first.selection.gitKeys.hasMaterial(for: coordinates.keyScope))
        XCTAssertFalse(first.selection.gitKeys.hasMaterial(for: oldCoordinates.keyScope), "the old library key is gone")
        let newVault = try XCTUnwrap(first.secureStore.document)
        XCTAssertNotEqual(newVault.kid, oldVault.kid)
        XCTAssertNotEqual(newVault.vaultSalt, oldVault.vaultSalt)
        XCTAssertNotEqual(newVault.record(shared)?.sealed, oldVault.record(shared)?.sealed)
        XCTAssertNotEqual(newVault.record(shared)?.contentHash, oldVault.record(shared)?.contentHash)
        XCTAssertNotEqual(newVault.wrapRecovery, oldVault.wrapRecovery)
        try await sync(first)
        let reopened = try await secureContent(first, shared)
        XCTAssertEqual(reopened, Self.firstSecret)
        XCTAssertEqual(first.store.snippets.map(\.content), [Self.snippet.content])

        // One ordinary commit replaced the library; the device then uploaded it again.
        let subjects = try git(["--git-dir", bare.path, "log", "--format=%s", "main"]).split(separator: "\n")
        XCTAssertEqual(subjects.filter { $0 == "Replace library keys" }.count, 1)
        XCTAssertEqual(subjects.first, "Sync 2 records")
        let manifest = try git(["--git-dir", bare.path, "show", "main:snippets-sync.json"])
        XCTAssertTrue(manifest.contains(coordinates.datasetID.uuidString.lowercased()))
        XCTAssertTrue(manifest.contains("\"schemaVersion\" : 2"))
        let files = try treeFiles()
        XCTAssertEqual(files.filter { $0.hasPrefix("keys/") }, ["keys/recovery.json", "keys/vault.json"])
        XCTAssertEqual(files.filter { $0.hasPrefix("records/") }.count, mode == .plainText ? 1 : 2)
        XCTAssertEqual(files.filter { $0.hasPrefix("snippets/") }.count, mode == .plainText ? 1 : 0)
        await retire(first)

        // The device that was away stops, and says what to do.
        resume(second)
        _ = await second.coordinator.requestSync(trigger: .manual)
        XCTAssertTrue(
            second.coordinator.statusDescription.contains("keys were replaced on another device"),
            second.coordinator.statusDescription)
        XCTAssertEqual(second.secureStore.document?.kid, oldVault.kid)

        var asked: [String?] = []
        var replacements = 0
        second.sheet.promptForRecoveryCode = { problem in
            asked.append(problem)
            return asked.count == 1 ? code : newCode
        }
        second.sheet.confirmReplacement = {
            replacements += 1
            return true
        }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        if mode == .plainText { second.sheet.confirmPlainTextJoin = { true } }
        let secondPrompts = second.vaultAuthentications
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertEqual(replacements, 1)
        XCTAssertEqual(
            asked, [nil, GitSyncSetup.Failure.incorrectRecoveryCode.localizedDescription],
            "the old code does not open the new library")
        XCTAssertEqual(second.sheet.statusText, "Connected.")
        XCTAssertEqual(second.vaultAuthentications, secondPrompts + 1, "moving its secure snippets asks once")
        XCTAssertEqual(second.selection.gitCoordinates?.datasetID, coordinates.datasetID)
        XCTAssertFalse(second.selection.gitKeys.hasMaterial(for: oldCoordinates.keyScope))
        XCTAssertEqual(second.secureStore.document?.kid, newVault.kid)
        XCTAssertEqual(second.secureStore.document?.vaultSalt, newVault.vaultSalt)
        try await sync(second)
        XCTAssertEqual(Set(second.secureStore.shells.map(\.name)), ["Server Password", "Door Code"])
        let secondShared = try await secureContent(second, shared)
        let secondOwn = try await secureContent(second, own)
        XCTAssertEqual([secondShared, secondOwn], [Self.firstSecret, Self.secondSecret])
        XCTAssertEqual(second.store.snippets.map(\.content), [Self.snippet.content], "nothing is duplicated")
        await retire(second)

        // What that device had kept to itself reaches the others under the new keys.
        resume(first)
        try await sync(first)
        XCTAssertEqual(Set(first.secureStore.shells.map(\.name)), ["Server Password", "Door Code"])
        let firstOwn = try await secureContent(first, own)
        XCTAssertEqual(firstOwn, Self.secondSecret)
        XCTAssertEqual(first.store.snippets.count, 1)
        await retire(first)

        // A new device: the old code is refused, the new one opens everything.
        let third = try makeDevice("third", seed: [])
        asked = []
        third.sheet.promptForRecoveryCode = { problem in
            asked.append(problem)
            return asked.count == 1 ? code : newCode
        }
        third.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        third.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        if mode == .plainText { third.sheet.confirmPlainTextJoin = { true } }
        fill(third.sheet, token: Self.token)
        await third.sheet.connect()
        XCTAssertEqual(asked, [nil, GitSyncSetup.Failure.incorrectRecoveryCode.localizedDescription])
        try await switchToGit(third)
        let thirdShared = try await secureContent(third, shared)
        let thirdOwn = try await secureContent(third, own)
        XCTAssertEqual([thirdShared, thirdOwn], [Self.firstSecret, Self.secondSecret])
        XCTAssertEqual(third.store.snippets.map(\.content), [Self.snippet.content])
        await retire(third)

        let history = try git(["--git-dir", bare.path, "log", "-p", "--all", "--format=%s"])
        for hidden in [Self.firstSecret, Self.secondSecret, "Server Password", "Door Code", code, newCode] {
            XCTAssertFalse(history.contains(hidden), "\(hidden) must not be readable in the repository")
        }
    }

    /// Replaces the keys from `device`, which must be the live one, and returns the code.
    private func replaceKeys(_ device: Device) async throws -> String {
        var shown: [String] = []
        device.sheet.presentRecoveryCode = { newCode, _ in shown.append(newCode) }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        await device.sheet.rotateKeys()
        XCTAssertEqual(shown.count, 1)
        return try XCTUnwrap(shown.first)
    }

    /// A secure snippet edited on a device that was away keeps the edit after the keys
    /// are replaced, on every device, and the version the library had is kept too.
    func testASecureEditMadeWhileAwaySurvivesNewKeys() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        let shared = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("second", seed: [])
        await join(second, code: code)
        try await switchToGit(second)
        await retire(second)
        _ = try await second.vaultSession.unlock(reason: "test")
        try second.secureStore.setContent(Self.secondSecret, for: shared)
        second.vaultSession.lock()

        resume(first)
        let newCode = try await replaceKeys(first)
        try await sync(first)
        await retire(first)

        resume(second)
        second.sheet.confirmReplacement = { true }
        await join(second, code: newCode)
        XCTAssertEqual(second.sheet.statusText, "Connected.")
        // Both versions are ciphertext; keeping the losing one takes an unlocked vault.
        XCTAssertTrue(second.coordinator.isWaitingForVault, second.coordinator.statusDescription)
        XCTAssertTrue(
            second.coordinator.statusDescription.contains("changed on two devices"),
            second.coordinator.statusDescription)
        let edited = try await secureContent(second, shared)
        XCTAssertEqual(edited, Self.secondSecret, "the edit made while away wins")
        // Unlocked now, the losing version becomes a snippet of its own.
        try await sync(second)
        let copies = second.secureStore.shells.filter { $0.id != shared }
        XCTAssertEqual(copies.count, 1, "the library's version is kept as a conflict copy")
        if let copy = copies.first {
            let kept = try await secureContent(second, copy.id)
            XCTAssertEqual(kept, Self.firstSecret)
        }
        // The copy is uploaded first; the snippet it was taken from follows it.
        try await settle(second)
        await retire(second)

        // The other device takes the copy once its own vault is unlocked.
        resume(first)
        _ = await first.coordinator.requestSync(trigger: .manual)
        _ = try await first.vaultSession.unlock(reason: "test")
        try await sync(first)
        let firstEdited = try await secureContent(first, shared)
        XCTAssertEqual(firstEdited, Self.secondSecret)
        XCTAssertEqual(first.secureStore.shells.count, 2)
        await retire(first)
    }

    /// A device that cannot open its own secure snippets cannot move them to the new
    /// key. It is told before anything is saved.
    func testADeviceWithoutItsVaultKeyIsToldBeforeFollowingNewKeys() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        _ = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("second", seed: [])
        await join(second, code: code)
        try await switchToGit(second)
        await retire(second)
        let stranded = try XCTUnwrap(second.secureStore.document)
        try second.vaultKeychain.deleteKey(keyID: stranded.kid)
        second.secureStore.reload()
        XCTAssertEqual(second.secureStore.libraryVaultAvailability, .keyMissing)
        let joined = try XCTUnwrap(second.selection.gitCoordinates)

        resume(first)
        let newCode = try await replaceKeys(first)
        try await sync(first)
        await retire(first)

        resume(second)
        var errors: [String] = []
        second.sheet.promptForRecoveryCode = { _ in newCode }
        second.sheet.confirmReplacement = { true }
        second.sheet.presentError = { _, message in errors.append(message) }
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.differentVault(secureCount: 1).localizedDescription])
        XCTAssertEqual(second.selection.gitCoordinates, joined, "still the old connection")
        XCTAssertEqual(second.secureStore.document, stranded, "its vault is untouched")
        await retire(second)
    }

    /// iCloud Keychain can deliver the new library key ahead of the user. Moving the
    /// device's secure snippets still takes the vault key, so the code is asked for.
    func testALibraryKeyThatArrivedByItselfStillAsksForTheCode() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        let shared = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        await retire(first)

        let second = try makeDevice("second", seed: [])
        await join(second, code: code)
        try await switchToGit(second)
        await retire(second)

        resume(first)
        let newCode = try await replaceKeys(first)
        try await sync(first)
        let scope = try XCTUnwrap(first.selection.gitCoordinates?.keyScope)
        let material = try XCTUnwrap(try first.selection.gitKeys.material(for: scope))
        await retire(first)

        resume(second)
        try second.selection.gitKeys.install(material, for: scope)
        var asked: [String?] = []
        second.sheet.promptForRecoveryCode = { problem in
            asked.append(problem)
            return newCode
        }
        second.sheet.confirmReplacement = { true }
        second.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        second.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(second.sheet, token: Self.token)
        await second.sheet.connect()
        XCTAssertEqual(asked, [nil])
        XCTAssertEqual(second.secureStore.document?.kid, first.secureStore.document?.kid)
        try await sync(second)
        let opened = try await secureContent(second, shared)
        XCTAssertEqual(opened, Self.firstSecret)
        await retire(second)
    }

    /// The response to the replacing push is lost. The repository holds the new
    /// library, so the device finishes the move and shows the code instead of keeping
    /// keys nobody was told about.
    func testALostResponseWhileReplacingTheKeysStillCompletes() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        let code = try await createLibrary(first)
        try await switchToGit(first)
        let secret = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        let old = try XCTUnwrap(first.selection.gitCoordinates)

        var shown: [String] = []
        first.sheet.presentRecoveryCode = { newCode, _ in shown.append(newCode) }
        first.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        GitBackendURLProtocol.dropResponseOfNextPush(host: host)
        await first.sheet.rotateKeys()
        let newCode = try XCTUnwrap(shown.first)
        XCTAssertNotEqual(newCode, code)
        XCTAssertNotEqual(first.selection.gitCoordinates?.datasetID, old.datasetID)
        try await sync(first)
        let reopened = try await secureContent(first, secret)
        XCTAssertEqual(reopened, Self.firstSecret)
        XCTAssertEqual(try recordFiles().count, 2)
        await retire(first)
    }

    /// Keys are replaced only for the library Git is syncing, and nothing is minted
    /// or pushed when the owner does not confirm.
    func testReplacingTheKeysNeedsActiveSyncAndTheOwner() async throws {
        let first = try makeDevice("first", seed: [Self.snippet])
        _ = try await createLibrary(first)
        var errors: [String] = []
        first.sheet.presentRecoveryCode = { _, _ in XCTFail("no code without a rotation") }
        first.sheet.presentError = { _, message in errors.append(message) }
        first.sheet.authenticateOwner = { _ in }
        await first.sheet.rotateKeys()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.syncBeforeRotation.localizedDescription])

        try await switchToGit(first)
        _ = try await addSecure(first, name: "Server Password", keyword: "srvpw", body: Self.firstSecret)
        try await sync(first)
        let before = try git(["--git-dir", bare.path, "rev-parse", "main"])
        let coordinates = try XCTUnwrap(first.selection.gitCoordinates)
        let vault = try XCTUnwrap(first.secureStore.document)
        errors = []
        first.vaultSession.lock()
        first.approvesVaultAuthentication = false
        await first.sheet.rotateKeys()
        XCTAssertEqual(errors, [GitSyncSetup.Failure.vaultAuthentication.localizedDescription])
        XCTAssertEqual(try git(["--git-dir", bare.path, "rev-parse", "main"]), before)
        XCTAssertEqual(first.selection.gitCoordinates, coordinates)
        XCTAssertEqual(first.secureStore.document, vault)
        await retire(first)
    }

    // MARK: - Secure fixture

    /// Creates a library from `device`'s sheet and returns its recovery code.
    private func createLibrary(_ device: Device, mode: GitLibraryMode = .encrypted) async throws -> String {
        var created: String?
        device.sheet.confirmCreation = { _ in mode }
        device.sheet.presentRecoveryCode = { code, _ in created = code }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
        return try XCTUnwrap(created)
    }

    private func join(_ device: Device, code: String, mode: GitLibraryMode = .encrypted) async {
        device.sheet.promptForRecoveryCode = { _ in code }
        device.sheet.confirmCreation = { _ in XCTFail("must join, not create"); return nil }
        device.sheet.presentError = { title, message in XCTFail("\(title): \(message)") }
        if mode == .plainText { device.sheet.confirmPlainTextJoin = { true } }
        fill(device.sheet, token: Self.token)
        await device.sheet.connect()
    }

    private func switchToGit(_ device: Device, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await device.coordinator.switchProvider(to: .git)
        guard case .completed(.idle(let lastSync)) = result, lastSync != nil else {
            XCTFail("did not sync: \(result) · \(device.coordinator.statusDescription)", file: file, line: line)
            throw CancellationError()
        }
    }

    private func sync(_ device: Device, file: StaticString = #filePath, line: UInt = #line) async throws {
        let result = await device.coordinator.requestSync(trigger: .manual)
        guard case .completed(.idle) = result else {
            XCTFail("did not sync: \(result) · \(device.coordinator.statusDescription)", file: file, line: line)
            throw CancellationError()
        }
    }

    /// Syncs until a round leaves the repository as it found it.
    private func settle(_ device: Device, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<6 {
            let before = try git(["--git-dir", bare.path, "rev-parse", "main"])
            try await sync(device, file: file, line: line)
            if try git(["--git-dir", bare.path, "rev-parse", "main"]) == before { return }
        }
        XCTFail("sync did not settle", file: file, line: line)
    }

    private func addSecure(_ device: Device, name: String, keyword: String, body: String) async throws -> UUID {
        _ = try await device.vaultSession.unlock(reason: "test")
        return try device.secureStore.addSecure(
            name: name, keyword: keyword, body: Data(body.utf8), tags: [], isEnabled: true, isPinned: false)
    }

    private func secureContent(_ device: Device, _ id: UUID) async throws -> String {
        _ = try await device.vaultSession.unlock(reason: "test")
        return try device.secureStore.content(for: id)
    }

    /// Storage locations resolve through one process-wide override; point it at the
    /// device about to act.
    private func use(_ device: Device) {
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, device.support.path, 1)
    }

    /// Stops a device's sync for good, and waits until it has.
    ///
    /// `stop()` alone restarts an enabled coordinator once its transport has shut down.
    /// A restarted one resolves its storage through the process-wide override, which by
    /// then names the next device's directory: it would compare its own vault with that
    /// device's files and write a halt into them. Only one device may be live at a time.
    private func retire(_ device: Device) async {
        let enabled = SyncCoordinator.runtimeEnabledOverride
        SyncCoordinator.runtimeEnabledOverride = false
        device.coordinator.stop()
        for _ in 0..<1_000 where !device.coordinator.isQuiescent {
            try? await Task.sleep(for: .milliseconds(10))
        }
        SyncCoordinator.runtimeEnabledOverride = enabled
    }

    /// Makes a retired device the live one again.
    private func resume(_ device: Device) {
        use(device)
        device.coordinator.start()
    }

    private func treeFiles() throws -> [Substring] {
        try git(["--git-dir", bare.path, "ls-tree", "-r", "--name-only", "main"]).split(separator: "\n")
    }

    /// Commits a change to the library branch the way another git client would.
    private func editRepository(_ message: String, _ edit: (URL) throws -> Void) throws {
        let work = root.appendingPathComponent("work-\(UUID().uuidString)", isDirectory: true)
        try git(["clone", "--quiet", bare.path, work.path])
        try edit(work)
        try git(["-C", work.path, "add", "-A"])
        try git(["-C", work.path, "commit", "--quiet", "-m", message])
        try git(["-C", work.path, "push", "--quiet", "origin", "HEAD:main"])
        try FileManager.default.removeItem(at: work)
    }

    private func removeFromRepository(_ path: String) throws {
        try editRepository("Remove \(path)") { try FileManager.default.removeItem(at: $0.appendingPathComponent(path)) }
    }

    private func writeToRepository(_ path: String, _ data: Data) throws {
        try editRepository("Write \(path)") { try data.write(to: $0.appendingPathComponent(path)) }
    }

    private static let firstSecret = "secure-body-7c1d9a40-first"
    private static let secondSecret = "secure-body-2e88b6f3-second"

    // MARK: - Fixture

    private final class Device {
        let selection: SyncBackendSelectionStore
        let store: SnippetStore
        let coordinator: SyncCoordinator
        var sheet: MacGitSyncViewController! = nil
        var onSwitchRequest: () -> Void = {}
        var credentials: KeychainSecretStore!
        /// Where this device keeps its vault keys.
        var vaultKeychain: KeychainSecretStore!
        var secureStore: SecureSnippetStore!
        var vaultSession: VaultSession!
        var support: URL!
        /// Device-owner prompts the vault raised (Touch ID in the app).
        var vaultAuthentications = 0
        /// What the owner answers to the next prompt.
        var approvesVaultAuthentication = true

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
        var countAuthentication: () -> Bool = { true }
        let vault = VaultSession(keychain: keychain, authenticationEvaluator: { _ in countAuthentication() })
        // The provider this device selected, not whatever the test host's own defaults say.
        let secureStore = SecureSnippetStore(
            session: vault, keychain: keychain,
            selectedSyncProvider: { selection.provider }, deviceID: store.deviceID)
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
        devices.append(device)
        device.credentials = credentials
        device.vaultKeychain = keychain
        device.secureStore = secureStore
        device.vaultSession = vault
        device.support = support
        countAuthentication = { [weak device] in
            device?.vaultAuthentications += 1
            return device?.approvesVaultAuthentication ?? true
        }
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
