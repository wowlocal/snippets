#if os(macOS)
import AppKit
import CryptoKit
import Foundation

@MainActor
protocol ClipboardHistoryPasteboardReading: AnyObject {
    var changeCount: Int { get }
    var typeNames: [String] { get }
    func readText() -> String?
}

@MainActor
private final class SystemClipboardHistoryPasteboard: ClipboardHistoryPasteboardReading {
    var changeCount: Int { NSPasteboard.general.changeCount }
    var typeNames: [String] {
        // Inspect every item: one sensitive flavor rejects the entire copy.
        Array(Set((NSPasteboard.general.pasteboardItems ?? []).flatMap { $0.types.map(\.rawValue) }))
    }
    func readText() -> String? { NSPasteboard.general.string(forType: .string) }
}

/// All blocking I/O and encryption runs on a serial worker queue. Nothing
/// in a newly initialized, disabled service touches the clipboard, disk, or Keychain.
@MainActor
final class ClipboardHistoryService {
    static let didChangeNotification = Notification.Name("ClipboardHistoryServiceDidChange")
    static let enabledPreferenceKey = "SnippetsClipboardHistoryEnabled"
    static let offerDismissedPreferenceKey = "SnippetsClipboardHistoryOfferDismissed"
    static let exclusionsPreferenceKey = "SnippetsClipboardHistoryExcludedBundleIDs"
    static let retentionDays = ClipboardHistory.retentionDays
    static let internalPasteboardType = NSPasteboard.PasteboardType(ClipboardHistoryCapturePolicy.internalType)

    private(set) var isEnabled: Bool
    private(set) var offerDismissed: Bool
    private(set) var entries: [ClipboardHistoryEntry] = []
    private(set) var statusMessage: String?
    private(set) var isLoading = false
    var isCapturing: Bool { isEnabled && loaded && sessionActive && systemAwake }
    var onWillCreateStorageDirectory: (() -> Void)?
    var onDidCreateStorageDirectory: (() -> Void)?

    var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Self.exclusionsPreferenceKey) ?? [] }
        set {
            let normalized = Array(Set(newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            defaults.set(normalized, forKey: Self.exclusionsPreferenceKey)
            notify()
        }
    }

    private let defaults: UserDefaults
    private let storage: any ClipboardHistoryPersisting
    private let pasteboardProvider: @MainActor () -> any ClipboardHistoryPasteboardReading
    private let frontmostBundleID: @MainActor () -> String?
    private let now: () -> Date
    private let schedulesTimer: Bool
    private var pasteboard: (any ClipboardHistoryPasteboardReading)?
    private var timer: Timer?
    private var observedChangeCount: Int?
    private var ignoredChangeCounts = Set<Int>()
    private var lifecycle: UInt64 = 0
    private var loaded = false
    private let storageQueue = DispatchQueue(label: "com.khm.snippets.clipboard-history", qos: .utility)
    private var pendingOperations = 0
    private var sessionActive = true
    private var systemAwake = true
    private var sessionObservers: [NSObjectProtocol] = []
    private let workspaceNotifications = NSWorkspace.shared.notificationCenter

    init(
        defaults: UserDefaults = .standard,
        storage: (any ClipboardHistoryPersisting)? = nil,
        pasteboardProvider: @escaping @MainActor () -> any ClipboardHistoryPasteboardReading = { SystemClipboardHistoryPasteboard() },
        frontmostBundleID: @escaping @MainActor () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier },
        now: @escaping () -> Date = Date.init,
        schedulesTimer: Bool = true
    ) {
        self.defaults = defaults
        self.storage = storage ?? EncryptedClipboardHistoryStorage()
        self.pasteboardProvider = pasteboardProvider
        self.frontmostBundleID = frontmostBundleID
        self.now = now
        self.schedulesTimer = schedulesTimer
        isEnabled = defaults.bool(forKey: Self.enabledPreferenceKey)
        offerDismissed = defaults.bool(forKey: Self.offerDismissedPreferenceKey)
        if isEnabled { start() }
    }

    deinit {
        timer?.invalidate()
        for observer in sessionObservers { workspaceNotifications.removeObserver(observer) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledPreferenceKey)
        if enabled {
            offerDismissed = true
            defaults.set(true, forKey: Self.offerDismissedPreferenceKey)
            start()
        } else {
            lifecycle &+= 1
            timer?.invalidate()
            timer = nil
            pasteboard = nil
            observedChangeCount = nil
            ignoredChangeCounts.removeAll()
            loaded = false
            isLoading = false
            statusMessage = nil
        }
        notify()
    }

    func dismissOffer() {
        guard !offerDismissed else { return }
        offerDismissed = true
        defaults.set(true, forKey: Self.offerDismissedPreferenceKey)
        notify()
    }

    func clear() {
        // This explicit action may remove an unreadable encrypted history without
        // opening it or minting a replacement key. Older writes finish first.
        entries.removeAll()
        lifecycle &+= 1
        let generation = lifecycle
        let storage = storage
        loaded = false
        isLoading = true
        statusMessage = nil
        enqueue({ try storage.clear() }) { [weak self] result in
            guard let self, self.lifecycle == generation else { return }
            self.isLoading = false
            switch result {
            case .success:
                self.loaded = self.isEnabled
                if self.isEnabled { self.start() }
            case .failure:
                self.statusMessage = "Could not delete clipboard history. Try again."
            }
            self.notify()
        }
        notify()
    }

    func delete(id: UUID) {
        guard loaded, entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        persist()
        notify()
    }

    func search(_ query: String) -> [ClipboardHistoryEntry] {
        expireEntriesIfNeeded()
        return ClipboardHistory.search(query, in: entries)
    }

    /// Flush the copy that a 0.5 s polling interval has not seen, before borrowing
    /// the pasteboard. Call acknowledgeInternalChange only for a confirmed owned write.
    func capturePendingCopy() {
        guard isCapturing, let pasteboard else { return }
        expireEntriesIfNeeded()
        let changeCount = pasteboard.changeCount
        guard changeCount != observedChangeCount else { return }
        if ignoredChangeCounts.remove(changeCount) != nil {
            observedChangeCount = changeCount
            return
        }
        let types = pasteboard.typeNames
        guard ClipboardHistoryCapturePolicy.permits(
            types: types, sourceBundleID: frontmostBundleID(), excludedBundleIDs: excludedBundleIDs
        ) else {
            if pasteboard.changeCount == changeCount { observedChangeCount = changeCount }
            return
        }
        let text = pasteboard.readText()
        // A provider can fulfill promised text while another process changes the
        // clipboard. Retry that newer generation next poll, never record a mixture.
        guard pasteboard.changeCount == changeCount else { return }
        observedChangeCount = changeCount
        guard let text, ClipboardHistory.accepts(text) else { return }
        entries = ClipboardHistory.recording(text, in: entries, now: now())
        persist()
        notify()
    }

    func acknowledgeInternalChange(_ changeCount: Int) {
        guard isEnabled else { return }
        // Remember the exact generation, never set the baseline to today's count:
        // a real user copy arriving after a restore must still be captured.
        if ignoredChangeCounts.count >= 32 { ignoredChangeCounts.removeAll() }
        ignoredChangeCounts.insert(changeCount)
    }

    /// Test and orderly-shutdown hook; never blocks the main thread.
    func waitForPendingPersistence() async {
        while pendingOperations > 0 {
            await withCheckedContinuation { continuation in
                storageQueue.async {
                    DispatchQueue.main.async { continuation.resume() }
                }
            }
        }
    }

    /// Mutations are enqueued before returning to AppKit, so this termination-only
    /// barrier drains encrypted writes without depending on another MainActor turn.
    func flushSynchronously() {
        storageQueue.sync {}
    }

    private func start() {
        installSessionObservers()
        lifecycle &+= 1
        let generation = lifecycle
        loaded = false
        isLoading = true
        statusMessage = nil
        let clipboard = pasteboardProvider()
        pasteboard = clipboard
        // Enabling starts with future copies. Existing clipboard content is not read.
        observedChangeCount = clipboard.changeCount
        ignoredChangeCounts.removeAll()
        do {
            if !storage.directoryExists {
                onWillCreateStorageDirectory?()
                defer { onDidCreateStorageDirectory?() }
                try storage.prepareDirectory()
            }
        } catch {
            isLoading = false
            statusMessage = "Clipboard history storage is unavailable. Turn history off and on to retry."
            notify()
            return
        }
        let storage = storage
        enqueue({ try storage.load() }) { [weak self] result in
            guard let self, self.isEnabled, self.lifecycle == generation else { return }
            self.isLoading = false
            switch result {
            case .success(let saved):
                self.entries = ClipboardHistory.retaining(saved, now: self.now())
                self.loaded = true
                if self.entries != saved { self.persist() }
                self.startTimer()
            case .failure:
                self.entries = []
                self.statusMessage = "Clipboard history could not be opened. Its saved data was kept. Turn history off and on to retry, or clear history."
            }
            self.notify()
        }
    }

    private func startTimer() {
        timer?.invalidate()
        guard schedulesTimer, isCapturing else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.capturePendingCopy() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setSessionActive(_ active: Bool) {
        guard active != sessionActive else { return }
        sessionActive = active
        updateSessionMonitoring()
    }

    func setSystemAwake(_ awake: Bool) {
        guard awake != systemAwake else { return }
        systemAwake = awake
        updateSessionMonitoring()
    }

    private func updateSessionMonitoring() {
        timer?.invalidate()
        timer = nil
        guard isEnabled, sessionActive, systemAwake else { return }
        // Never collect copies made while another user session was active or while
        // this Mac was sleeping; returning to this session starts a fresh baseline.
        observedChangeCount = pasteboard?.changeCount
        ignoredChangeCounts.removeAll()
        startTimer()
        notify()
    }

    private func installSessionObservers() {
        guard sessionObservers.isEmpty else { return }
        for (name, active) in [(NSWorkspace.sessionDidBecomeActiveNotification, true), (NSWorkspace.sessionDidResignActiveNotification, false)] {
            sessionObservers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSessionActive(active) }
            })
        }
        for (name, awake) in [(NSWorkspace.didWakeNotification, true), (NSWorkspace.willSleepNotification, false)] {
            sessionObservers.append(workspaceNotifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemAwake(awake) }
            })
        }
    }

    private func expireEntriesIfNeeded() {
        guard loaded else { return }
        let oldest = now().addingTimeInterval(-Double(ClipboardHistory.retentionDays) * 86_400)
        guard let last = entries.last, last.copiedAt <= oldest else { return }
        entries.removeAll { $0.copiedAt <= oldest }
        persist()
        notify()
    }

    private func persist() {
        let saved = entries
        let storage = storage
        let generation = lifecycle
        enqueue({ try storage.save(saved) }) { [weak self] result in
            guard let self, self.lifecycle == generation else { return }
            switch result {
            case .success: self.statusMessage = nil
            case .failure: self.statusMessage = "Recent clipboard history could not be saved. Turn history off and on to retry."
            }
            self.notify()
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func enqueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value,
        completion: @escaping @MainActor (Result<Value, Error>) -> Void
    ) {
        pendingOperations += 1
        storageQueue.async { [weak self] in
            let result = Result(catching: operation)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingOperations -= 1
                completion(result)
            }
        }
    }
}

nonisolated protocol ClipboardHistoryPersisting: Sendable {
    var directoryExists: Bool { get }
    func prepareDirectory() throws
    func load() throws -> [ClipboardHistoryEntry]
    func save(_ entries: [ClipboardHistoryEntry]) throws
    func clear() throws
}

/// The only disk artifact is an authenticated encrypted binary; no plaintext index,
/// metadata, source-app history, or content-derived filenames are written.
nonisolated final class EncryptedClipboardHistoryStorage: ClipboardHistoryPersisting {
    enum Failure: Error { case invalidFile, missingKey, invalidKey, invalidFormat }
    private struct Document: Codable {
        let version: Int
        let entries: [ClipboardHistoryEntry]
    }
    private static let domain = Data("com.khm.snippets.clipboard-history.v1".utf8)
    private static let account = "history-v1"
    private let directory: URL
    private let keychain: KeychainSecretStore
    private var file: URL { directory.appendingPathComponent("history.bin") }

    init(directory: URL = SnippetStorageLocations.supportFolderURL.appendingPathComponent("ClipboardHistory", isDirectory: true), keychain: KeychainSecretStore? = nil) {
        self.directory = directory
        self.keychain = keychain ?? KeychainSecretStore(
            tier: .deviceOnly,
            service: "com.khm.snippets.clipboard-history",
            itemAccessibility: .whenUnlocked)
    }

    var directoryExists: Bool { FileManager.default.fileExists(atPath: directory.path) }

    func prepareDirectory() throws {
        let manager = FileManager.default
        if directoryExists {
            let attributes = try manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidFile }
        } else {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }

    func load() throws -> [ClipboardHistoryEntry] {
        try prepareDirectory()
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 70 * 1_024 * 1_024 else { throw Failure.invalidFile }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard let material = try keychain.loadItem(account: Self.account, expectedByteCount: 32) else { throw Failure.missingKey }
        let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: material), authenticating: Self.domain)
        let document = try PropertyListDecoder().decode(Document.self, from: plaintext)
        guard document.version == 1 else { throw Failure.invalidFormat }
        return document.entries
    }

    func save(_ entries: [ClipboardHistoryEntry]) throws {
        try prepareDirectory()
        let existing = try keychain.loadItem(account: Self.account, expectedByteCount: 32)
        // Never replace the key of an existing unreadable history.
        guard existing != nil || !FileManager.default.fileExists(atPath: file.path) else { throw Failure.missingKey }
        let material: Data
        if let existing { material = existing }
        else {
            let candidate = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            material = try keychain.addItemIfAbsent(candidate, account: Self.account)
        }
        guard material.count == 32 else { throw Failure.invalidKey }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let plaintext = try encoder.encode(Document(version: 1, entries: entries))
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: material), authenticating: Self.domain)
        guard let ciphertext = sealed.combined else { throw Failure.invalidFormat }
        try AtomicFileWriter.write(ciphertext, to: file, temporaryDirectory: directory, permissions: 0o600)
    }

    func clear() throws {
        guard directoryExists else { return }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidFile }
        // Also remove an encrypted staging file left by an interrupted atomic write.
        // Never traverse or remove the enclosing snippet library directory.
        for candidate in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = candidate.lastPathComponent
            if name == "history.bin" || name.hasPrefix("history.bin.") {
                let type = try manager.attributesOfItem(atPath: candidate.path)[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeSymbolicLink else { throw Failure.invalidFile }
                try manager.removeItem(at: candidate)
            }
        }
    }
}
#endif
