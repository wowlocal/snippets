#if os(macOS)
import AppKit
import XCTest

@testable import Snippets_Debug

@MainActor
private final class HistoryTestPasteboard: ClipboardHistoryPasteboardReading {
    var count = 1
    var text = "already copied before consent"
    var types = ["public.utf8-plain-text"]
    var countReads = 0
    var typeReads = 0
    var textReads = 0
    var duringRead: (() -> Void)?

    var changeCount: Int { countReads += 1; return count }
    var typeNames: [String] { typeReads += 1; return types }
    func readText() -> String? {
        textReads += 1
        let result = text
        duringRead?()
        return result
    }
    func copy(_ value: String, types: [String] = ["public.utf8-plain-text"]) {
        count += 1
        text = value
        self.types = types
    }
}

nonisolated private final class HistoryTestStorage: ClipboardHistoryPersisting, @unchecked Sendable {
    enum Failure: Error { case unreadable }
    private let lock = NSLock()
    private var records: [ClipboardHistoryEntry] = []
    private var loadCount = 0
    private var saveCount = 0
    private var clearCount = 0
    let failsLoad: Bool
    init(failsLoad: Bool = false) { self.failsLoad = failsLoad }
    var directoryExists: Bool { true }
    func prepareDirectory() throws {}
    func load() throws -> [ClipboardHistoryEntry] {
        try lock.withLock {
            loadCount += 1
            if failsLoad { throw Failure.unreadable }
            return records
        }
    }
    func save(_ entries: [ClipboardHistoryEntry]) throws {
        lock.withLock { saveCount += 1; records = entries }
    }
    func clear() throws {
        lock.withLock { clearCount += 1; records.removeAll() }
    }
    var snapshot: (entries: [ClipboardHistoryEntry], loads: Int, saves: Int, clears: Int) {
        lock.withLock { (records, loadCount, saveCount, clearCount) }
    }
}

@MainActor
final class ClipboardHistoryServiceTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "ClipboardHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func temporaryDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardHistoryTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testNoConsentMeansNoClipboardDiskOrKeychainAccess() async {
        let pasteboard = HistoryTestPasteboard()
        let storage = HistoryTestStorage()
        var providerCalls = 0
        let service = ClipboardHistoryService(
            defaults: makeDefaults(), storage: storage,
            pasteboardProvider: { providerCalls += 1; return pasteboard }, schedulesTimer: false)
        service.capturePendingCopy()
        service.acknowledgeInternalChange(1)
        await service.waitForPendingPersistence()
        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(providerCalls, 0)
        XCTAssertEqual(pasteboard.countReads, 0)
        XCTAssertEqual(pasteboard.textReads, 0)
        XCTAssertEqual(storage.snapshot.loads, 0)
        XCTAssertEqual(storage.snapshot.saves, 0)
    }

    func testConsentBaselinesCurrentCopyAndDisableStopsCapture() async {
        let pasteboard = HistoryTestPasteboard()
        let storage = HistoryTestStorage()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: storage, pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        service.capturePendingCopy()
        XCTAssertTrue(service.offerDismissed)
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(pasteboard.textReads, 0)
        pasteboard.copy("new consented copy")
        service.capturePendingCopy()
        await service.waitForPendingPersistence()
        XCTAssertEqual(service.entries.map(\.text), ["new consented copy"])
        service.setEnabled(false)
        let countReads = pasteboard.countReads
        pasteboard.copy("copied while off")
        service.capturePendingCopy()
        XCTAssertEqual(pasteboard.countReads, countReads)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        service.capturePendingCopy()
        XCTAssertEqual(service.entries.map(\.text), ["new consented copy"])
    }

    func testEnablingPublishesLoadingBeforeReadyFeedback() async {
        let pasteboard = HistoryTestPasteboard()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: HistoryTestStorage(),
            pasteboardProvider: { pasteboard }, schedulesTimer: false)
        var states: [(loading: Bool, capturing: Bool)] = []
        let token = NotificationCenter.default.addObserver(
            forName: ClipboardHistoryService.didChangeNotification, object: service, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if service.isEnabled { states.append((service.isLoading, service.isCapturing)) }
            }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        service.setEnabled(true)
        XCTAssertEqual(states.first?.loading, true)
        XCTAssertFalse(states.contains { !$0.loading && !$0.capturing })
        await service.waitForPendingPersistence()
        XCTAssertEqual(states.last?.capturing, true)
    }

    func testRejectedTypesAndAppsNeverReadText() async {
        let pasteboard = HistoryTestPasteboard()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: HistoryTestStorage(), pasteboardProvider: { pasteboard }, frontmostBundleID: { "example.private" }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        for marker in ClipboardHistoryCapturePolicy.ignoredTypes {
            pasteboard.copy("do not read", types: ["public.utf8-plain-text", marker])
            service.capturePendingCopy()
        }
        service.excludedBundleIDs = ["example.private"]
        pasteboard.copy("excluded")
        service.capturePendingCopy()
        XCTAssertEqual(pasteboard.textReads, 0)
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testGenerationChangesDuringReadAreRetriedWithoutCapturingMixedState() async {
        let pasteboard = HistoryTestPasteboard()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: HistoryTestStorage(), pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        pasteboard.copy("old generation")
        pasteboard.duringRead = { pasteboard.copy("new generation"); pasteboard.duringRead = nil }
        service.capturePendingCopy()
        XCTAssertTrue(service.entries.isEmpty)
        service.capturePendingCopy()
        XCTAssertEqual(service.entries.map(\.text), ["new generation"])
    }

    func testOwnedRestoreDoesNotHideSubsequentUserCopy() async {
        let pasteboard = HistoryTestPasteboard()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: HistoryTestStorage(), pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        pasteboard.copy("user copy before paste")
        service.capturePendingCopy()
        pasteboard.copy("temporary insertion", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
        service.capturePendingCopy()
        pasteboard.copy("user copy before paste")
        service.acknowledgeInternalChange(pasteboard.count)
        service.capturePendingCopy()
        XCTAssertEqual(pasteboard.textReads, 1)
        pasteboard.copy("another owned restore")
        service.acknowledgeInternalChange(pasteboard.count)
        pasteboard.copy("new real copy")
        service.capturePendingCopy()
        XCTAssertEqual(service.entries.map(\.text), ["new real copy", "user copy before paste"])
    }

    func testSessionSwitchAndSleepResumeWithFreshBaselines() async {
        let pasteboard = HistoryTestPasteboard()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: HistoryTestStorage(), pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        service.setSessionActive(false)
        pasteboard.copy("while inactive")
        service.capturePendingCopy()
        service.setSessionActive(true)
        service.capturePendingCopy()
        service.setSystemAwake(false)
        pasteboard.copy("while sleeping")
        service.capturePendingCopy()
        service.setSystemAwake(true)
        service.capturePendingCopy()
        XCTAssertTrue(service.entries.isEmpty)
        XCTAssertEqual(pasteboard.textReads, 0)
        pasteboard.copy("new active copy")
        service.capturePendingCopy()
        XCTAssertEqual(service.entries.map(\.text), ["new active copy"])
    }

    func testUnreadableHistoryFailsClosedUntilExplicitClear() async {
        let pasteboard = HistoryTestPasteboard()
        let storage = HistoryTestStorage(failsLoad: true)
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: storage, pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        pasteboard.copy("must not overwrite unreadable history")
        service.capturePendingCopy()
        XCTAssertNotNil(service.statusMessage)
        XCTAssertEqual(pasteboard.textReads, 0)
        XCTAssertEqual(storage.snapshot.saves, 0)
        XCTAssertEqual(storage.snapshot.clears, 0)
        service.setEnabled(false)
        service.clear()
        await service.waitForPendingPersistence()
        XCTAssertEqual(storage.snapshot.clears, 1)
    }

    func testShutdownDrainsWritesAndClearCannotResurrectQueuedCopies() async {
        let pasteboard = HistoryTestPasteboard()
        let storage = HistoryTestStorage()
        let service = ClipboardHistoryService(defaults: makeDefaults(), storage: storage, pasteboardProvider: { pasteboard }, schedulesTimer: false)
        service.setEnabled(true)
        await service.waitForPendingPersistence()
        pasteboard.copy("queued copy")
        service.capturePendingCopy()
        service.flushSynchronously()
        XCTAssertEqual(storage.snapshot.entries.map(\.text), ["queued copy"])
        service.clear()
        await service.waitForPendingPersistence()
        XCTAssertTrue(storage.snapshot.entries.isEmpty)
        XCTAssertTrue(service.entries.isEmpty)
    }

    func testEncryptedPersistenceRoundTripPermissionsAndAuthentication() throws {
        let directory = temporaryDirectory()
        let keychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let storage = EncryptedClipboardHistoryStorage(directory: directory, keychain: keychain)
        try storage.prepareDirectory()
        XCTAssertNil(try keychain.loadItem(account: "history-v1"))
        let entries = [ClipboardHistoryEntry(text: "private clipboard plaintext sentinel")]
        try storage.save(entries)
        let file = directory.appendingPathComponent("history.bin")
        var ciphertext = try Data(contentsOf: file)
        XCTAssertNil(ciphertext.range(of: Data(entries[0].text.utf8)))
        XCTAssertEqual(try storage.load(), entries)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int, 0o700)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        ciphertext[ciphertext.count - 1] ^= 1
        try ciphertext.write(to: file)
        XCTAssertThrowsError(try storage.load())
        XCTAssertEqual(try Data(contentsOf: file), ciphertext)
    }

    func testMissingKeyDoesNotMintOrOverwriteExistingHistory() throws {
        let directory = temporaryDirectory()
        let original = EncryptedClipboardHistoryStorage(directory: directory, keychain: KeychainSecretStore(tier: .deviceOnly, inMemory: true))
        try original.save([ClipboardHistoryEntry(text: "original")])
        let file = directory.appendingPathComponent("history.bin")
        let ciphertext = try Data(contentsOf: file)
        let missingKeychain = KeychainSecretStore(tier: .deviceOnly, inMemory: true)
        let missingKey = EncryptedClipboardHistoryStorage(directory: directory, keychain: missingKeychain)
        XCTAssertThrowsError(try missingKey.load())
        XCTAssertThrowsError(try missingKey.save([ClipboardHistoryEntry(text: "replacement")]))
        XCTAssertNil(try missingKeychain.loadItem(account: "history-v1"))
        XCTAssertEqual(try Data(contentsOf: file), ciphertext)
        try missingKey.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
#endif
