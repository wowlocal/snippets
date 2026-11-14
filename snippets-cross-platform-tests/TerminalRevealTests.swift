#if os(macOS)
import XCTest
import CryptoKit
import Darwin
@testable import Snippets_Debug

/// Drives `ControlServer.revealWithPassword` with an in-memory keychain and a fake
/// password verifier, so neither the user's keychain nor their real account's login
/// policy (failed-attempt counters) is ever touched.
@MainActor
final class TerminalRevealTests: XCTestCase {
    private var root: URL!
    private var previousRoot: String?

    /// Counts calls and returns a scripted answer. `@unchecked` because the verifier is
    /// `@Sendable`; every access is under the lock.
    private final class FakeVerifier: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: TerminalRevealAccess.PasswordCheck = .accepted
        private var _calls = 0
        private var _lastPassword = Data()
        var answer: TerminalRevealAccess.PasswordCheck {
            get { lock.withLock { _answer } }
            set { lock.withLock { _answer = newValue } }
        }
        var calls: Int { lock.withLock { _calls } }
        var lastPassword: Data { lock.withLock { _lastPassword } }
        func check(_ password: Data) -> TerminalRevealAccess.PasswordCheck {
            lock.withLock {
                _calls += 1
                _lastPassword = password
                return _answer
            }
        }
    }

    /// The keychain stand-in. `failRemoval` models an item whose access list refuses
    /// deletion (one planted by another process).
    private final class MemoryStore: TerminalRevealRecordStoring {
        var items: [String: Data] = [:]
        var failRemoval = false
        func load(account: String) throws -> Data? { items[account] }
        func replace(_ data: Data, account: String) throws { items[account] = data }
        func remove(account: String) throws {
            if failRemoval, items[account] != nil {
                throw TerminalRevealKeychainStore.KeychainFailure(status: errSecInteractionNotAllowed)
            }
            items[account] = nil
        }
    }

    private struct Fixture {
        let server: ControlServer
        let access: TerminalRevealAccess
        let session: VaultSession
        let secure: SecureSnippetStore
        let store: MemoryStore
        let verifier: FakeVerifier
        let peer: PeerIdentity
        let descriptors: [Int32]
    }

    override func setUpWithError() throws {
        previousRoot = ProcessInfo.processInfo.environment[SnippetStorageLocations.rootOverrideEnvironmentKey]
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalReveal-\(UUID())")
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, root.path, 1)
        SnippetStorageLocations.createAllDirectories()
    }

    override func tearDownWithError() throws {
        if let previousRoot { setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, previousRoot, 1) }
        else { unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey) }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeFixture(device: String = "DEVICE-FIXTURE") async throws -> Fixture {
        let keychain = KeychainSecretStore(tier: .deviceOnly, service: "terminal-reveal-vault", inMemory: true)
        let session = VaultSession(keychain: keychain, authenticationEvaluator: { _ in true })
        let secure = SecureSnippetStore(session: session, keychain: keychain,
            selectedSyncProvider: { nil }, syncIsEnabled: { false }, deviceID: "aabbccdd")
        let pending = try XCTUnwrap(secure.prepareVaultCreationIfNeeded())
        _ = try secure.commitVaultCreation(pending)
        _ = try await session.unlock(reason: "Synthetic test")
        _ = try secure.addSecure(name: "Fixture", keyword: "fixture-token",
            body: Data("fictional-secret-only".utf8), tags: [], isEnabled: true, isPinned: false)
        session.lock()

        let verifier = FakeVerifier()
        let store = MemoryStore()
        let access = TerminalRevealAccess(
            store: store,
            deviceIdentifier: { device },
            passwordVerifier: { verifier.check($0) })
        let server = ControlServer(session: session, secureStore: secure, terminalAccess: access)

        // A real socketpair gives a kernel-reported peer uid equal to ours.
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
        let peer = PeerIdentity(descriptor: descriptors[0])
        XCTAssertEqual(peer.userID, getuid())
        return Fixture(server: server, access: access, session: session, secure: secure,
                       store: store, verifier: verifier, peer: peer,
                       descriptors: descriptors)
    }

    private func close(_ fixture: Fixture) {
        fixture.descriptors.forEach { Darwin.close($0) }
    }

    private let password = Data("fictional-password".utf8)

    func testOffByDefaultAndNoPasswordIsCheckedWhileOff() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        XCTAssertFalse(f.access.isEnabled)
        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertNil(response.content)
        XCTAssertEqual(f.verifier.calls, 0)
    }

    func testEnabledRevealReturnsContentAndLeavesTheVaultLocked() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        XCTAssertTrue(f.access.isEnabled)
        XCTAssertFalse(f.session.state.isUnlocked, "enabling must not leave the vault open")

        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .ok)
        XCTAssertEqual(response.content, "fictional-secret-only")
        XCTAssertEqual(f.verifier.calls, 1)
        XCTAssertEqual(f.verifier.lastPassword, password)
        XCTAssertFalse(f.session.state.isUnlocked, "the one-use key must not outlive the reveal")
        XCTAssertNil(response.message)
    }

    func testRejectedPasswordNeverOpensTheVaultAndFiveTurnItOff() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        f.verifier.answer = .rejected

        for attempt in 1..<TerminalRevealAccess.maximumConsecutiveFailures {
            let response = await f.server.revealWithPassword(
                keyword: "fixture-token", password: password, peer: f.peer)
            XCTAssertEqual(response.status, .denied, "attempt \(attempt)")
            XCTAssertNil(response.content)
            XCTAssertFalse(f.session.state.isUnlocked)
            XCTAssertTrue(f.access.isEnabled)
        }
        let last = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(last.status, .disabled)
        XCTAssertFalse(f.access.isEnabled, "repeated wrong passwords must remove the authorization")
        XCTAssertNil(f.store.items[TerminalRevealAccess.recordAccount])
    }

    func testAccountPolicyRefusalIsNotCountedAsAGuess() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        f.verifier.answer = .unavailable
        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(f.access.consecutiveFailures, 0)
        XCTAssertTrue(f.access.isEnabled)
    }

    func testAForgedSwitchIsRefusedAfterThePasswordAndRemoved() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        // What a same-user process could write: a well-formed record under a key it made up.
        let forged = TerminalRevealAuthorization.issue(
            keyring: SnippetCrypto.Keyring(libraryKey: SymmetricKey(size: .bits256), salt: Data(count: 16)),
            binding: .init(vaultKID: try XCTUnwrap(f.secure.document?.kid),
                           userID: UInt32(getuid()), deviceID: "DEVICE-FIXTURE"))
        try f.store.replace(try forged.encoded(), account: TerminalRevealAccess.recordAccount)
        XCTAssertTrue(f.access.isEnabled, "presence alone looks enabled")

        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertNil(response.content)
        XCTAssertFalse(f.access.isEnabled)
        XCTAssertFalse(f.session.state.isUnlocked)
    }

    func testARecordFromAnotherMacDoesNotVerify() async throws {
        let f = try await makeFixture(device: "DEVICE-A")
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        // Same vault, same stored record, different hardware identifier.
        let otherMac = TerminalRevealAccess(
            store: f.store, deviceIdentifier: { "DEVICE-B" },
            passwordVerifier: { _ in .accepted })
        let server = ControlServer(session: f.session, secureStore: f.secure, terminalAccess: otherMac)
        let response = await server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertNil(response.content)
    }

    func testUnknownKeywordAndEmptyPasswordAreRefusedWithoutAnyCheck() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        let missing = await f.server.revealWithPassword(keyword: "absent", password: password, peer: f.peer)
        XCTAssertEqual(missing.status, .notFound)
        let empty = await f.server.revealWithPassword(keyword: "fixture-token", password: Data(), peer: f.peer)
        XCTAssertEqual(empty.status, .denied)
        let huge = Data(repeating: 65, count: SnippetsIPC.Request.maximumPasswordBytes + 1)
        let oversized = await f.server.revealWithPassword(keyword: "fixture-token", password: huge, peer: f.peer)
        XCTAssertEqual(oversized.status, .denied)
        XCTAssertEqual(f.verifier.calls, 0)
    }

    func testDisablingRemovesTheRecord() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        try f.access.disable()
        XCTAssertFalse(f.access.isEnabled)
        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertEqual(f.verifier.calls, 0)
    }

    func testWrongPasswordCountSurvivesAnAppRestart() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        f.verifier.answer = .rejected
        for _ in 1..<TerminalRevealAccess.maximumConsecutiveFailures {
            _ = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        }
        // A new process: new access object and server over the same durable store.
        let restarted = TerminalRevealAccess(
            store: f.store, deviceIdentifier: { "DEVICE-FIXTURE" },
            passwordVerifier: { f.verifier.check($0) })
        XCTAssertEqual(restarted.consecutiveFailures, TerminalRevealAccess.maximumConsecutiveFailures - 1)
        let server = ControlServer(session: f.session, secureStore: f.secure, terminalAccess: restarted)
        let response = await server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .disabled)
        XCTAssertFalse(restarted.isEnabled)
    }

    func testLockoutHoldsEvenWhenTheRecordCannotBeDeleted() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        f.store.failRemoval = true
        f.verifier.answer = .rejected
        for _ in 0..<TerminalRevealAccess.maximumConsecutiveFailures {
            _ = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        }
        XCTAssertNotNil(f.store.items[TerminalRevealAccess.recordAccount], "deletion was refused")
        XCTAssertFalse(f.access.isEnabled, "the durable count must still switch it off")
        XCTAssertThrowsError(try f.access.disable(), "off must not be claimed while the record remains")
    }

    func testAWrongPasswordLeavesTheOwnersOpenWindowAlone() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        try await f.access.enable(session: f.session, secureStore: f.secure)
        _ = try await f.session.unlock(reason: "Owner at the desk")
        XCTAssertTrue(f.session.state.isUnlocked)
        f.verifier.answer = .rejected
        let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(response.status, .denied)
        XCTAssertTrue(f.session.state.isUnlocked, "an unverified request must not close the owner's window")
    }

    func testDisabledRequestsSpendTheSharedBudget() async throws {
        let f = try await makeFixture()
        defer { close(f) }
        for _ in 0..<5 {
            let response = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
            XCTAssertEqual(response.status, .disabled)
        }
        let sixth = await f.server.revealWithPassword(keyword: "fixture-token", password: password, peer: f.peer)
        XCTAssertEqual(sixth.status, .refused)
    }
}
#endif
