import CryptoKit
import Foundation

// App target only — see the note at the top of `CloudKitRecordMapping.swift`.

/// Collapses any number of requests received during one round into one replay. Kept as
/// a small value type so its edge cases can be tested without constructing CloudKit.
nonisolated struct SyncRoundRequestCoalescer {
    private(set) var wantsReplay = false

    mutating func requestReplay() {
        wantsReplay = true
    }

    mutating func cancelReplay() {
        wantsReplay = false
    }

    mutating func finishRound(
        generation: UInt64,
        currentGeneration: UInt64
    ) -> Bool {
        defer { wantsReplay = false }
        return wantsReplay || generation != currentGeneration
    }
}

/// A trailing-edge debounce for outbound library changes.
///
/// Editors publish on every keystroke, and a shell script may invoke `snippets-cli`
/// once per input line. Starting a CloudKit round for every one of those mutations is
/// both wasteful and more likely to hit backend throttling. Resetting one one-shot timer
/// gives the whole burst a single round while keeping the ordinary interactive delay
/// short. The timer runs in common modes so an open menu or editor tracking loop cannot
/// strand a completed change until the next CKSyncEngine wake or health-check poll.
@MainActor
final class SyncTriggerDebouncer {
    private let delay: TimeInterval
    private let action: () -> Void
    private var timer: Timer?

    init(delay: TimeInterval, action: @escaping () -> Void) {
        precondition(delay >= 0)
        self.delay = delay
        self.action = action
    }

    var isPending: Bool { timer != nil }

    func request() {
        cancel()
        let next = Timer(timeInterval: delay, repeats: false) { [weak self] fired in
            MainActor.assumeIsolated {
                guard let self, self.timer === fired else { return }
                self.timer = nil
                self.action()
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// Arms exactly one retry at the deadline chosen by `SyncEngine` after a call-level
/// transport failure. CKSyncEngine/APNs replace polling as the normal scheduler, but a
/// missed network request still needs its exponential-backoff retry rather than waiting
/// for the six-hour health check.
@MainActor
final class SyncOfflineRetryScheduler {
    typealias Cancellation = () -> Void
    typealias Arm = (TimeInterval, @escaping () -> Void) -> Cancellation

    private let now: () -> Date
    private let arm: Arm
    private var cancellation: Cancellation?
    private var generation: UInt64 = 0
    private(set) var scheduledDeadline: Date?

    init(
        now: @escaping () -> Date = Date.init,
        arm: @escaping Arm = { delay, action in
            let timer = Timer(timeInterval: max(0, delay), repeats: false) { _ in
                MainActor.assumeIsolated { action() }
            }
            RunLoop.main.add(timer, forMode: .common)
            return { timer.invalidate() }
        }
    ) {
        self.now = now
        self.arm = arm
    }

    func update(for state: SyncEngine.State, action: @escaping () -> Void) {
        guard case .offline(let deadline) = state else {
            cancel()
            return
        }
        guard scheduledDeadline != deadline || cancellation == nil else { return }

        cancel()
        scheduledDeadline = deadline
        generation &+= 1
        let armedGeneration = generation
        cancellation = arm(max(0, deadline.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.generation == armedGeneration else { return }
            self.cancellation = nil
            self.scheduledDeadline = nil
            action()
        }
    }

    func cancel() {
        generation &+= 1
        cancellation?()
        cancellation = nil
        scheduledDeadline = nil
    }
}

/// Owns whether sync is running, and runs it.
///
/// ## Off is structural, not filtered
///
/// When the preference is off, nothing here constructs a transport, an engine, or a
/// sealer. No `CKContainer` is touched, no timer is scheduled, and **no
/// `Sync/base.json`** — the engine's own file, and the observable difference — is written.
///
/// Measured on a fresh support directory with the preference absent: `Sync/` contains
/// `library.lock`, `ipc.sock`, `Quarantine/` and a `state.json` reading
/// `"backend": "none"`, all of which predate sync and exist because the cross-process lock
/// and the CLI socket live there. `base.json` is absent, which is what proves the engine
/// never ran. That is what makes shipping this safe: a user who never opens the checkbox
/// gets the behaviour they already had, and the claim is checkable rather than a matter of
/// reading the code and trusting it.
///
/// `SyncEngine` states it the same way: `syncEngine == nil` is the honest representation
/// of "sync is off", and there is deliberately no placeholder transport that would run a
/// loop describing a synchronisation that is not happening.
///
/// ## Enabling it needs nothing but the checkbox
///
/// Every record on the wire is still sealed, plaintext snippets included. What changed is
/// which key does it: `SyncKeyStore`'s `K_sync`, not the vault's `K_lib`.
///
/// The old arrangement made sync a dependent of Secure Snippets — no vault meant no
/// keyring meant nothing could be pushed, and a *locked* vault meant background rounds
/// stopped until the user proved presence again. For a feature whose whole job is to run
/// unattended in the background, that was fatal, and it was buying nothing: the wire key
/// protects snippet bodies and metadata that already sit in the clear in `snippets.json`
/// and `vault.json` on this disk, and it never protected a secure snippet's content,
/// which reaches this layer already sealed under `K_rec`. See `SyncKeyStore` for the full
/// argument.
///
/// So this type no longer knows what a vault is. Secure records ride through it as opaque
/// bytes like everything else, and `VaultSession` is left to gate the one thing that
/// genuinely needs a human: reading a secret.
@MainActor
final class SyncCoordinator {

    private struct LocalRecoveryOnlySealer: SyncBlobSealing {
        private struct UnexpectedDataPlaneUse: Error {}

        func seal(_ plaintext: Data, for identity: WireIdentity) throws -> Data {
            _ = plaintext
            _ = identity
            throw UnexpectedDataPlaneUse()
        }

        func open(_ ciphertext: Data, for identity: WireIdentity) throws -> Data {
            _ = ciphertext
            _ = identity
            throw UnexpectedDataPlaneUse()
        }
    }

    /// Exists only so Core can replay the local quarantine transaction while cloud
    /// sync is off. Every data-plane method fails closed; the coordinator never starts
    /// a round on this engine and accepts only its Check Again action.
    nonisolated private struct LocalRecoveryOnlyTransport: SyncTransport {
        let identifier = "local-library-recovery"
        let supportsPush = false
        let pollInterval: TimeInterval = 24 * 60 * 60
        let events = AsyncStream<SyncTransportEvent> { $0.finish() }

        func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
            _ = cursor
            throw SyncTransportFailure.rejected(.permanent(
                detail: "local recovery transport cannot fetch"))
        }

        func submit(
            _ records: [WireRecord],
            at cursor: SyncCursor?
        ) async throws -> SyncSubmission {
            _ = records
            _ = cursor
            throw SyncTransportFailure.rejected(.permanent(
                detail: "local recovery transport cannot submit"))
        }
    }

    /// Off unless the user has said otherwise. `UserDefaults.bool(forKey:)` returns
    /// `false` for an absent key, so the default needs no registration — and an absent
    /// key and an explicit "off" behave identically, which is what we want.
    static let enabledDefaultsKey = SyncBackendSelectionStore.syncEnabledDefaultsKey

    /// Long enough to collapse a CLI loop or a run of editor keystrokes, while still
    /// making a completed local change visible to another device almost immediately.
    static let libraryChangeDebounceInterval: TimeInterval = 1

    #if DEBUG
    /// Process-only preference used by explicit debug launch modes. Keeping this out of
    /// UserDefaults makes a flagged verification launch unable to alter the next normal
    /// launch of the same app sandbox.
    static var runtimeEnabledOverride: Bool?
    #endif

    /// Why sync is not running.
    ///
    /// Down from four cases to three, because two of them — "set up Secure Snippets
    /// first" and "unlock Secure Snippets to start syncing" — described a dependency
    /// that no longer exists.
    enum Readiness: Equatable {
        case off
        /// A start prerequisite is temporarily unavailable: usually a locked Keychain,
        /// or rarely stale sync bookkeeping that could not yet be removed safely.
        case cannotStart(String)
        case ready
    }

    /// What happened when a caller asked for a round. This is deliberately separate
    /// from `SyncEngine.State`: a refresh gesture needs to know whether it started work,
    /// joined a future replay, or could not start at all.
    enum RequestDisposition: Equatable {
        case started
        case queued
        case notStarted(Readiness)
    }

    /// Completion of one requested round. A request made while another round is active
    /// completes after the single coalesced replay, not after the older round that was
    /// already in flight.
    enum RequestResult: Equatable {
        case completed(SyncEngine.State)
        case notStarted(Readiness)
    }

    private let library: any SyncLibraryAccess
    private let keys: SyncKeyStore
    private let device: String
    private let transportFactory: () throws -> any SyncTransport
    private let backendSelection: SyncBackendSelectionStore
    private let offlineRetryScheduler: SyncOfflineRetryScheduler

    private(set) var engine: SyncEngine?
    /// A transport-inert engine used only to complete primary-library review while the
    /// cloud preference is off or keychain/backend startup is unavailable. It never
    /// runs a round; it reuses Core's exact CAS, protocol-pair, and crash-fence logic.
    private var localRecoveryEngine: SyncEngine?
    private(set) var state: SyncEngine.State = .disabled

    /// UI deletions waiting for the shared journal to own their authenticated intent
    /// marker. This survives engine rebuilds within the process; a full process crash
    /// deliberately falls back to the conservative receiver confirmation.
    private var pendingUserDeletionIDs: Set<UUID> = []

    /// Compatibility hook used by the macOS settings window.
    var onStateChange: ((SyncEngine.State) -> Void)?

    /// iOS presents sync state in both Library and Settings, so those views subscribe
    /// independently instead of replacing one another's callback.
    private var stateObservers: [UUID: (SyncEngine.State) -> Void] = [:]

    private var transport: (any SyncTransport)?
    private var pollTimer: Timer?
    private var startRetryTimer: Timer?
    private var eventTask: Task<Void, Never>?
    /// A startup-level Repair action may rebuild base/journal while an older durable
    /// checkpoint halt still exists in state.json. Carry that exact user authority into
    /// the first successfully constructed engine so the same Repair is not requested
    /// twice. No other halt is cleared by this flag.
    private var continueCheckpointRepairAfterStart = false
    /// Retained until the round has actually returned. Cancellation is advisory across
    /// an awaited CloudKit call, so `engine == nil` is not proof that sync is quiescent.
    private var roundTask: Task<Void, Never>?
    /// Retains the retiring transport until its current round and backend-owned
    /// scheduler have both stopped. `start()` may not construct a replacement while
    /// this barrier exists: production CloudKit permits only one CKSyncEngine per
    /// database in a process.
    private var shutdownTask: Task<Void, Never>?
    /// The generation of `roundTask`. After `stop()` cancellation is advisory, so a new
    /// engine may exist while the old task is still draining. Requests for that new
    /// generation belong to the replay, never to the old round.
    private var roundGeneration: UInt64?
    /// Invalidates state callbacks and completions from engines stopped earlier.
    private var lifecycleGeneration: UInt64 = 0

    /// `SyncEngine.sync()` returns early when a round is already in flight, which
    /// *discards* the request rather than queueing it. For a poll timer that is harmless
    /// — the next tick retries — but for a user pressing "Sync Now" or a push hint
    /// arriving mid-round it would look like the button did nothing. So a dropped request
    /// is remembered and replayed once the round finishes.
    private var roundRequests = SyncRoundRequestCoalescer()
    /// A manual request queued behind a live/shutting-down round must retain the same
    /// promise as a direct Sync Now: one immediate attempt even if that round ends in
    /// backoff. Automatic triggers never set this bit.
    private var replayBypassesBackoff = false

    private typealias RequestCompletion = (RequestResult) -> Void
    private var currentRoundCompletions: [RequestCompletion] = []
    private var replayRoundCompletions: [RequestCompletion] = []

    /// The wire key bytes the running engine was built with, and why `readiness` can be
    /// a cheap computed property: the keychain is consulted when sync starts and once a
    /// round, never on every redraw of the settings pane.
    private var activeKeyMaterial: Data?
    private var startFailure: String?
    private var startIssue: StartIssue?
    /// Credential/root-key removal is a maintenance transaction, not merely a provider
    /// selection change. While it is active, the retiring transport must drain without
    /// the ordinary "still enabled" auto-restart constructing a replacement over the
    /// credentials that are about to be erased.
    private var cloudMutationInProgress = false

    #if DEBUG
    enum ProtocolRepairBoundary: CaseIterable, Equatable {
        case baseCommitted
        case journalCommitted
    }
    /// Fault-injection only. Throwing models process death after the named durable
    /// boundary; production has no hook and no alternate commit path.
    var protocolRepairBoundaryHook: ((ProtocolRepairBoundary) throws -> Void)?
    #endif

    private enum StartIssue: Equatable {
        case schemaTooNew(version: Int)
        case checkpointUnreadable
        case authenticationRequired
        case cloudKeyRequired
        case syncKeyUnreadable
        case cloudCredentialsUnreadable
        case providerSwitchUnreadable
        case retryablePrerequisite

        var description: String {
            switch self {
            case .schemaTooNew:
                "A newer Snippets version wrote the local sync state. Update Snippets."
            case .checkpointUnreadable:
                "The local sync checkpoint could not be read."
            case .authenticationRequired:
                "Sign in to the selected cloud service again."
            case .cloudKeyRequired:
                "Approve this device from a trusted device or restore the Snippets Cloud recovery kit."
            case .syncKeyUnreadable:
                "The stored sync encryption key could not be verified. Repair or restore the library key, then choose Check Again."
            case .cloudCredentialsUnreadable:
                "The saved cloud sign-in history cannot be verified. Reset it from Snippets Cloud settings."
            case .providerSwitchUnreadable:
                "The interrupted cloud-provider switch could not be verified. Update Snippets or restore the local sync state."
            case .retryablePrerequisite:
                "A local sync prerequisite is temporarily unavailable. Try again."
            }
        }

        var state: SyncEngine.State {
            switch self {
            case .schemaTooNew(let version):
                .halted(
                    .schemaTooNew,
                    detail: "Sync state schema \(version) is newer than this build.")
            case .checkpointUnreadable:
                .halted(
                    .checkpointUnreadable,
                    detail: "the local base or journal could not be verified")
            case .authenticationRequired:
                .needsAuthentication("sign_in_required")
            case .cloudKeyRequired:
                .needsAttention("cloud_key_required")
            case .syncKeyUnreadable:
                .needsAttention("sync_key_unreadable")
            case .cloudCredentialsUnreadable:
                .needsAttention("cloud_credentials_unreadable")
            case .providerSwitchUnreadable:
                .needsAttention("provider_switch_unreadable")
            case .retryablePrerequisite:
                .needsAttention("startup_prerequisite_unavailable")
            }
        }

        var recoveryAction: SyncRecoveryAction? {
            switch self {
            case .checkpointUnreadable: .repairCheckpoint
            case .syncKeyUnreadable: .checkAgain
            case .retryablePrerequisite: .retrySync
            case .schemaTooNew, .authenticationRequired, .cloudKeyRequired,
                 .cloudCredentialsUnreadable, .providerSwitchUnreadable: nil
            }
        }

        var retriesAutomatically: Bool {
            switch self {
            case .retryablePrerequisite: true
            case .schemaTooNew, .checkpointUnreadable, .authenticationRequired,
                 .cloudKeyRequired, .syncKeyUnreadable,
                 .cloudCredentialsUnreadable, .providerSwitchUnreadable: false
            }
        }
    }

    private lazy var libraryChangeDebouncer = SyncTriggerDebouncer(
        delay: Self.libraryChangeDebounceInterval
    ) { [weak self] in
        guard let self else { return }
        _ = self.syncNow(trigger: .localLibraryChange)
    }

    init(
        library: any SyncLibraryAccess,
        keys: SyncKeyStore,
        device: String,
        transportFactory: (() throws -> any SyncTransport)? = nil,
        backendSelection: SyncBackendSelectionStore? = nil,
        offlineRetryScheduler: SyncOfflineRetryScheduler? = nil
    ) {
        self.library = library
        self.keys = keys
        self.device = device
        let selection = backendSelection ?? SyncBackendSelectionStore()
        self.backendSelection = selection
        self.transportFactory = transportFactory ?? { try selection.makeTransport() }
        self.offlineRetryScheduler = offlineRetryScheduler ?? SyncOfflineRetryScheduler()
        if let locations = try? selection.protocolLocations() {
            try? locations.createDirectories()
            library.activateProtocolLocations(locations)
        }
        restoreLocalLibraryRecoveryIfNeeded()
    }

    // MARK: - The preference

    static var isEnabled: Bool {
        #if DEBUG
        if let runtimeEnabledOverride { return runtimeEnabledOverride }
        #endif
        let defaults = UserDefaults.standard
        if let value = defaults.object(forKey: enabledDefaultsKey) as? NSNumber {
            return value.boolValue
        }
        return defaults.bool(forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey)
    }

    private static func storeEnabledPreference(_ enabled: Bool) {
        #if DEBUG
        if runtimeEnabledOverride != nil {
            runtimeEnabledOverride = enabled
            return
        }
        #endif
        let defaults = UserDefaults.standard
        if !enabled {
            defaults.set(false, forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey)
        }
        defaults.set(enabled, forKey: enabledDefaultsKey)
        let rawSelection = defaults.string(forKey: SyncBackendSelectionStore.providerDefaultsKey)
        let selected = rawSelection.flatMap(SyncBackendSelectionStore.Provider.init(rawValue:))
        if enabled, rawSelection == nil || selected == .iCloud {
            defaults.set(true, forKey: SyncBackendSelectionStore.legacyICloudEnabledDefaultsKey)
        }
        _ = defaults.synchronize()
    }

    var readiness: Readiness {
        guard Self.isEnabled else { return .off }
        guard !cloudMutationInProgress else {
            return .cannotStart("Cloud account maintenance is in progress.")
        }
        if let startFailure { return .cannotStart(startFailure) }
        return .ready
    }

    /// Observable for lifecycle checks and focused tests; the timer itself remains an
    /// implementation detail.
    var hasPendingLibraryChangeSync: Bool { libraryChangeDebouncer.isPending }

    /// Destructive local maintenance may proceed only after an old round has returned,
    /// not merely after the checkbox was switched off.
    var isQuiescent: Bool { roundTask == nil && shutdownTask == nil }

    /// Whether a user-facing Sync Now can do useful work. A sticky/startup condition
    /// with its own recovery action must never be presented as a generic retry, and a
    /// non-actionable attention state belongs in Settings instead of a no-op loop.
    var canRequestManualSync: Bool {
        guard Self.isEnabled, !cloudMutationInProgress, recoveryAction == nil else {
            return false
        }
        switch state {
        case .needsAuthentication, .needsAttention, .waitingForVault, .halted:
            return false
        case .disabled, .idle, .syncing, .offline:
            return true
        }
    }

    var requiresSyncSettingsAttention: Bool {
        Self.isEnabled && recoveryAction == nil && !canRequestManualSync
    }

    @discardableResult
    func addStateObserver(_ observer: @escaping (SyncEngine.State) -> Void) -> UUID {
        let token = UUID()
        stateObservers[token] = observer
        observer(state)
        return token
    }

    func removeStateObserver(_ token: UUID) {
        stateObservers[token] = nil
    }

    /// Turns sync on or off and acts on it immediately.
    ///
    /// Writing the preference and starting are one call on purpose: two calls is how a
    /// checkbox ends up out of step with what is actually running.
    func setEnabled(_ enabled: Bool) {
        #if DEBUG
        if Self.runtimeEnabledOverride != nil {
            Self.storeEnabledPreference(enabled)
        } else {
            backendSelection.setSyncEnabled(enabled)
        }
        #else
        backendSelection.setSyncEnabled(enabled)
        #endif
        if enabled {
            start()
        } else {
            stop()
        }
    }

    // MARK: - Lifecycle

    /// Called once at launch. Does nothing at all unless the user opted in.
    func startIfEnabled() {
        guard Self.isEnabled else { return }
        start()
    }

    func start() {
        guard Self.isEnabled, !cloudMutationInProgress, engine == nil else { return }
        // Re-enabling is intentionally deferred while the prior transport drains. The
        // shutdown task calls start again after its awaited backend barrier completes.
        guard roundTask == nil, shutdownTask == nil else { return }
        // Initialization already restored a typed state-only quarantine. During this
        // coordinator's lifetime, a new primary quarantine publishes the independent
        // marker before its typed halt, so the cheap marker probe is sufficient to know
        // whether another state-file decode is needed here. This keeps the ordinary
        // launch path from decoding state.json twice before constructing the engine.
        if LibraryQuarantineMarker.exists() {
            restoreLocalLibraryRecoveryIfNeeded()
        }
        if let localRecoveryEngine {
            publish(localRecoveryEngine.state)
            return
        }

        let material: Data
        let sealer: SnippetCryptoSealer
        let transport: any SyncTransport
        let locations: SyncProtocolLocations
        do {
            locations = try backendSelection.protocolLocations()
            try locations.createDirectories()
            library.activateProtocolLocations(locations)
            try validateProtocolFilesForStartup(at: locations)
            material = try keys.materialMintingIfNeeded()
            sealer = SnippetCryptoSealer(
                keyring: try SyncKeyStore.keyring(from: material), scopeID: keys.scopeID)
            try discardAgreedBaseIfWireKeyChanged(material, at: locations)
            transport = try transportFactory()
        } catch {
            // Startup has not touched either the primary library or the backend. Keep
            // the failure in a closed, action-oriented vocabulary: raw error text can
            // contain implementation detail and, more importantly, cannot tell the UI
            // whether retrying, signing in, repairing, or updating is the safe action.
            let issue = Self.startIssue(for: error)
            let diagnosticArea: DiagnosticStorageArea = switch issue {
            case .schemaTooNew, .checkpointUnreadable, .providerSwitchUnreadable: .syncState
            case .authenticationRequired, .cloudKeyRequired, .syncKeyUnreadable,
                 .cloudCredentialsUnreadable, .retryablePrerequisite: .syncKey
            }
            Diagnostics.record(.storageFailure(
                area: diagnosticArea,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            startIssue = issue
            startFailure = issue.description
            if issue.retriesAutomatically {
                scheduleStartRetry()
            } else {
                startRetryTimer?.invalidate()
                startRetryTimer = nil
            }
            publish(issue.state)
            return
        }
        startRetryTimer?.invalidate()
        startRetryTimer = nil
        startFailure = nil
        startIssue = nil
        activeKeyMaterial = material

        let engine = SyncEngine(
            transport: transport,
            library: library,
            sealer: sealer,
            device: device,
            baseURL: locations.baseURL,
            journalURL: locations.journalURL,
            stateURL: SnippetStorageLocations.syncStateFileURL,
            libraryQuarantineMarkerURL: SnippetStorageLocations.libraryQuarantineMarkerURL,
            quarantineFolderURL: locations.quarantineFolderURL)
        engine.noteUserInitiatedDeletions(pendingUserDeletionIDs)
        engine.onSafetyHaltPersistenceFailure = {
            // Independent fail-closed channel: if state.json or its lock is unavailable,
            // this process remains halted in memory and the next launch does not build a
            // sync engine at all. Re-enabling the checkbox is then an explicit user act.
            Self.storeEnabledPreference(false)
            _ = UserDefaults.standard.synchronize()
        }
        let generation = lifecycleGeneration
        engine.onUserDeletionIntentsConsumed = { [weak self, weak engine] ids in
            MainActor.assumeIsolated {
                guard let self, engine != nil, self.lifecycleGeneration == generation else {
                    return
                }
                self.pendingUserDeletionIDs.subtract(ids)
            }
        }
        engine.onStateChange = { [weak self, weak engine] state in
            MainActor.assumeIsolated {
                guard let self, engine != nil, self.lifecycleGeneration == generation else { return }
                self.publish(state)
            }
        }

        self.transport = transport
        self.engine = engine

        if continueCheckpointRepairAfterStart {
            continueCheckpointRepairAfterStart = false
            if engine.recoveryAction == .repairCheckpoint {
                engine.performRecovery(.repairCheckpoint)
            }
        }

        // A safety halt restored from `Sync/state.json` is already the engine's state;
        // it does not transition during the no-op `sync()` below, so its callback will
        // not fire. Publish it explicitly or Settings would show `.disabled` after a
        // relaunch even though the engine correctly refuses to fetch.
        if engine.state.isHalted {
            publish(engine.state)
        }

        startPolling(every: transport.pollInterval)
        startEventPump(for: transport)
        _ = syncNow(trigger: .startup)
    }

    /// Retries a start that failed on the keychain.
    ///
    /// The poll timer is created *by* `start()`, so a start that fails leaves nothing
    /// running at all — no timer, no event pump, no engine. The old failure mode was
    /// benign about that because it could only be "no vault yet" or "vault locked", and
    /// `AppDelegate` drove a retry from `secureStore.onChange` when the user fixed it. A
    /// keychain refusal has no such trigger: `errSecInteractionNotAllowed` from a login
    /// keychain that is still locked at auto-login resolves itself minutes later with no
    /// library change to notice it, and until then nothing this Mac writes reaches any
    /// other one. So the retry has to be a timer of its own.
    ///
    /// A minute rather than the six-hour missed-push health check: this is cheap — one
    /// keychain read — and covers a user waiting for their session to finish unlocking.
    private func scheduleStartRetry() {
        guard startRetryTimer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.isEnabled, self.engine == nil else { return }
                self.start()
            }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        startRetryTimer = timer
    }

    func stop() {
        lifecycleGeneration &+= 1
        libraryChangeDebouncer.cancel()
        startRetryTimer?.invalidate()
        startRetryTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        eventTask?.cancel()
        eventTask = nil
        // Do not clear `roundTask` here. A CloudKit operation may take time to observe
        // cancellation, and local vault removal must wait until it has returned and the
        // transport's awaited shutdown has prevented further callbacks or automatic
        // scheduler work.
        let retiringRound = roundTask
        let retiringTransport = transport
        retiringRound?.cancel()
        engine = nil
        transport = nil
        activeKeyMaterial = nil
        roundRequests.cancelReplay()
        replayBypassesBackoff = false
        restoreLocalLibraryRecoveryIfNeeded()
        publish(localRecoveryEngine?.state ?? .disabled)
        finishAllRequests(with: .completed(.disabled))

        if shutdownTask == nil, retiringRound != nil || retiringTransport != nil {
            shutdownTask = Task { @MainActor [weak self, retiringRound, retiringTransport] in
                // SyncEngine owns the transport strongly, so first let its data-plane
                // call return. Then stop transport-owned automatic work and wait until
                // the backend confirms quiescence before a replacement can be built.
                if let retiringRound { await retiringRound.value }
                if let retiringTransport { await retiringTransport.shutdown() }

                guard let self else { return }
                self.shutdownTask = nil
                if Self.isEnabled, !self.cloudMutationInProgress { self.start() }
            }
        }
    }

    /// Runs credential or device-only cloud-root mutation only after both Core's round
    /// and transport-owned scheduler work have stopped. The closure is intentionally
    /// owned by the coordinator so callers cannot accidentally erase first and await
    /// shutdown afterwards. A second UI action is rejected instead of interleaving two
    /// sign-out/reset transactions.
    func withQuiescedCloudTransport<T>(
        _ operation: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        guard !cloudMutationInProgress else {
            throw CloudMaintenanceFailure.alreadyInProgress
        }
        cloudMutationInProgress = true
        stop()
        if let shutdownTask { await shutdownTask.value }

        do {
            let result = try await operation()
            cloudMutationInProgress = false
            if Self.isEnabled { start() }
            return result
        } catch {
            cloudMutationInProgress = false
            if Self.isEnabled { start() }
            throw error
        }
    }

    private enum CloudMaintenanceFailure: Error {
        case alreadyInProgress
    }

    /// Rebuilds the transport after Settings changed the selected provider. A provider
    /// choice never doubles as authority to clear an account/dataset review boundary;
    /// that confirmation remains an explicit, reason-specific action in Settings.
    func reloadProviderSelection() {
        stop()
        if Self.isEnabled, shutdownTask == nil { start() }
    }

    /// Moves the one active writer through a durable local selection transaction. The
    /// target owns a different base/journal, so its ordinary first round performs the
    /// loss-preserving merge. The source transport is fully shut down first and its
    /// remote state is never deleted.
    func switchProvider(
        to target: SyncBackendSelectionStore.Provider
    ) async -> RequestResult {
        guard target != backendSelection.provider else {
            return await requestSync(trigger: .manual)
        }
        guard !cloudMutationInProgress else {
            return .notStarted(.cannotStart("Cloud account maintenance is in progress."))
        }

        let prepared: SyncBackendSelectionStore.ProviderSwitchReceipt
        do {
            prepared = try backendSelection.prepareProviderSwitch(to: target)
        } catch {
            return .notStarted(.cannotStart("The target cloud provider could not be prepared."))
        }

        cloudMutationInProgress = true
        stop()
        if let shutdownTask { await shutdownTask.value }
        do {
            try backendSelection.commitPreparedProviderSwitch(prepared)
            let locations = try backendSelection.protocolLocations()
            try locations.createDirectories()
            library.activateProtocolLocations(locations)
            // This API is reached only from the explicit “Switch and Sync” action. A
            // provider may be chosen while the old sync toggle is off; turning the new
            // provider on here makes the promised verification round real and lets the
            // durable switch receipt retire instead of leaving a half-finished choice.
            if !backendSelection.syncEnabled {
                backendSelection.setSyncEnabled(true)
            }
        } catch {
            cloudMutationInProgress = false
            if Self.isEnabled { start() }
            return .notStarted(.cannotStart("The provider switch could not be committed."))
        }
        cloudMutationInProgress = false
        guard Self.isEnabled else { return .notStarted(.off) }
        start()
        return await requestSync(trigger: .manual)
    }

    /// Re-evaluates after the shape of the library changed underneath — most usefully,
    /// after a vault was created or adopted, which adds records sync had nothing to say
    /// about a moment ago. Safe to call repeatedly; `start()` is a no-op once running.
    func libraryStructureChanged() {
        scheduleLibraryChangeSync()
    }

    /// Receives ordinary store mutations, including changes adopted from
    /// `snippets-cli`. CloudKit-applied writes deliberately use `.remoteSync`: the
    /// current round already owns those bytes, so turning them into another outbound
    /// request would create a fetch/replay loop.
    func libraryDidChange(_ source: SnippetStore.ChangeSource) {
        switch source {
        case .local, .external:
            scheduleLibraryChangeSync()
        case .remoteSync:
            break
        }
    }

    /// Records the user's delete action before the debounced sync round snapshots the
    /// library. The marker is embedded only in the tombstone; no identifier is logged.
    func userDidDeleteSnippets(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingUserDeletionIDs.formUnion(ids)
        engine?.noteUserInitiatedDeletions(ids)
    }

    /// Undo/recreation must revoke the old intent so a later unrelated absence cannot
    /// inherit authority from an earlier delete cycle.
    func userDidRestoreSnippets(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        pendingUserDeletionIDs.subtract(ids)
        engine?.cancelUserInitiatedDeletions(ids)
    }

    private func scheduleLibraryChangeSync() {
        // The maintenance completion always starts a full ordinary round, so dropping
        // its redundant debounce is safe and prevents a timer from attempting to reopen
        // the transport while credentials are being revoked or erased.
        guard Self.isEnabled, !cloudMutationInProgress else { return }
        libraryChangeDebouncer.request()
    }

    // MARK: - Running a round

    /// Requests a round without requiring a caller to infer completion from state
    /// transitions. That distinction matters for pull-to-refresh: a disabled or failed
    /// start never emits `.syncing`, while a request queued behind an existing round must
    /// wait for the replay it asked for rather than completing with the older round.
    func requestSync(
        trigger: DiagnosticSyncTrigger = .manual
    ) async -> RequestResult {
        await withCheckedContinuation { continuation in
            _ = enqueueSyncRequest(trigger: trigger) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Fire-and-forget compatibility entry point used by timers and the macOS UI.
    @discardableResult
    func syncNow(
        trigger: DiagnosticSyncTrigger = .manual
    ) -> RequestDisposition {
        enqueueSyncRequest(trigger: trigger, completion: nil)
    }

    @discardableResult
    private func enqueueSyncRequest(
        trigger: DiagnosticSyncTrigger,
        completion: RequestCompletion?
    ) -> RequestDisposition {
        let bypassesBackoff: Bool
        switch trigger {
        case .manual: bypassesBackoff = true
        default: bypassesBackoff = false
        }
        // Any round requested before the trailing timer fires includes the same current
        // library state. Consume the pending debounce so it cannot manufacture a second,
        // redundant round immediately afterwards.
        libraryChangeDebouncer.cancel()

        guard Self.isEnabled else {
            let unavailable = Readiness.off
            completion?(.notStarted(unavailable))
            return .notStarted(unavailable)
        }

        if shutdownTask != nil {
            queueReplay(bypassingBackoff: bypassesBackoff)
            if let completion { replayRoundCompletions.append(completion) }
            return .queued
        }

        guard engine != nil else {
            // A start that failed — the keychain would not answer — is retried here
            // rather than only at launch. Without this the only way back was to relaunch
            // or toggle the checkbox, because the poll timer is started by `start()` and
            // so does not exist yet. `start()` ends by syncing, so this call is done.
            start()
            guard engine != nil else {
                let unavailable = readiness
                completion?(.notStarted(unavailable))
                return .notStarted(unavailable)
            }

            // `start()` requested its startup round. It may be the active round, or it
            // may be waiting behind a cancelled operation from an older generation.
            if roundGeneration == lifecycleGeneration {
                if let completion { currentRoundCompletions.append(completion) }
                return .started
            }
            queueReplay(bypassingBackoff: bypassesBackoff)
            if let completion { replayRoundCompletions.append(completion) }
            return .queued
        }
        // A rebuild also ends by syncing; running a second round here would be waste.
        if restartIfWireKeyChanged() {
            if shutdownTask != nil {
                queueReplay(bypassingBackoff: bypassesBackoff)
                if let completion { replayRoundCompletions.append(completion) }
                return .queued
            }
            guard engine != nil else {
                let unavailable = readiness
                completion?(.notStarted(unavailable))
                return .notStarted(unavailable)
            }
            if roundGeneration == lifecycleGeneration {
                if let completion { currentRoundCompletions.append(completion) }
                return .started
            }
            queueReplay(bypassingBackoff: bypassesBackoff)
            if let completion { replayRoundCompletions.append(completion) }
            return .queued
        }

        guard let engine else {
            let unavailable = readiness
            completion?(.notStarted(unavailable))
            return .notStarted(unavailable)
        }
        Diagnostics.record(.syncTriggered(trigger))
        if roundTask != nil {
            queueReplay(bypassingBackoff: bypassesBackoff)
            if let completion { replayRoundCompletions.append(completion) }
            return .queued
        }
        startRound(
            with: engine,
            completions: completion.map { [$0] } ?? [],
            bypassingBackoff: bypassesBackoff)
        return .started
    }

    private func queueReplay(bypassingBackoff: Bool) {
        roundRequests.requestReplay()
        replayBypassesBackoff = replayBypassesBackoff || bypassingBackoff
    }

    /// Runs the reason-specific action the UI presented. The engine rejects stale or
    /// mismatched actions before touching the durable safety stop.
    func performRecovery(_ action: SyncRecoveryAction) {
        if let startIssue, startIssue.recoveryAction == action {
            switch (startIssue, action) {
            case (.checkpointUnreadable, .repairCheckpoint):
                do {
                    try repairUnreadableProtocolCheckpoint()
                    self.startIssue = nil
                    startFailure = nil
                    continueCheckpointRepairAfterStart = true
                    start()
                } catch {
                    Diagnostics.record(.storageFailure(
                        area: .syncState,
                        operation: .write,
                        failure: DiagnosticFailure(error),
                        attempt: nil))
                    let repairedIssue = Self.startIssue(for: error)
                    self.startIssue = repairedIssue == .retryablePrerequisite
                        ? .checkpointUnreadable
                        : repairedIssue
                    startFailure = self.startIssue?.description
                    publish(self.startIssue?.state ?? .disabled)
                }
            case (.retryablePrerequisite, .retrySync):
                self.startIssue = nil
                startFailure = nil
                startRetryTimer?.invalidate()
                startRetryTimer = nil
                start()
            case (.syncKeyUnreadable, .checkAgain):
                self.startIssue = nil
                startFailure = nil
                start()
            default:
                break
            }
            return
        }
        if let localRecoveryEngine,
           localRecoveryEngine.recoveryAction == action {
            localRecoveryEngine.performRecovery(action)
            // Marker retirement is the commit point for primary recovery. The inert
            // engine may now be showing an unrelated halt that it intentionally
            // preserved; drop it so only a real transport-backed engine can act on that.
            if !LibraryQuarantineMarker.exists() {
                self.localRecoveryEngine = nil
                if Self.isEnabled {
                    start()
                } else {
                    publish(.disabled)
                }
                return
            }
            if localRecoveryEngine.state.isHalted {
                publish(localRecoveryEngine.state)
                return
            }
            // The independent marker outranks in-memory state. This also protects the
            // transient case where reconstructing state.json failed but its later clear
            // succeeded: never discard the only recovery UI while the store is locked.
            if LibraryQuarantineMarker.exists() {
                localRecoveryEngine.reassertPrimaryLibraryQuarantine()
                publish(localRecoveryEngine.state)
                return
            }
            self.localRecoveryEngine = nil
            if Self.isEnabled {
                start()
            } else {
                publish(.disabled)
            }
            return
        }
        engine?.performRecovery(action)
        if Self.isEnabled {
            _ = syncNow(trigger: .retry)
        } else {
            // Halt persistence failed and turned the opt-in off. Do not let the existing
            // in-memory engine bypass that preference after recovery; a later checkbox-on
            // constructs a fresh engine deliberately.
            stop()
        }
    }

    /// Recovery is derived from the engine's exact durable context, not just the broad
    /// halt reason. In particular, a legacy mass-deletion stop can only refresh its
    /// facts and can never expose the destructive confirmation.
    var recoveryAction: SyncRecoveryAction? {
        if let engineAction = engine?.recoveryAction { return engineAction }
        if let localAction = localRecoveryEngine?.recoveryAction { return localAction }
        guard Self.isEnabled else { return nil }
        return startIssue?.recoveryAction
    }

    /// Restores a local recovery affordance independently of the cloud opt-in. The
    /// independent marker is authoritative when state.json itself was lost; Core then
    /// recreates the typed halt before exposing Check Again.
    private func restoreLocalLibraryRecoveryIfNeeded() {
        guard engine == nil, localRecoveryEngine == nil else { return }
        let hasIndependentMarker = LibraryQuarantineMarker.exists()
        let hasTypedStateMarker: Bool
        switch SyncStateFile.load() {
        case .loaded(let persisted):
            hasTypedStateMarker = persisted.halt?.recoveryContext == .localLibraryQuarantine
        case .tooNew, .fresh:
            hasTypedStateMarker = false
        }
        guard hasIndependentMarker || hasTypedStateMarker else { return }

        guard let locations = try? backendSelection.protocolLocations() else { return }
        let candidate = SyncEngine(
            transport: LocalRecoveryOnlyTransport(),
            library: library,
            sealer: LocalRecoveryOnlySealer(),
            device: device,
            baseURL: locations.baseURL,
            journalURL: locations.journalURL,
            stateURL: SnippetStorageLocations.syncStateFileURL,
            libraryQuarantineMarkerURL: SnippetStorageLocations.libraryQuarantineMarkerURL,
            quarantineFolderURL: locations.quarantineFolderURL)
        if hasIndependentMarker {
            candidate.reassertPrimaryLibraryQuarantine()
        }
        guard candidate.state.isHalted else { return }
        let isPrimaryRecovery: Bool
        if case .halted(.localLibraryQuarantined, _) = candidate.state {
            isPrimaryRecovery = candidate.recoveryAction == .checkAgain
        } else {
            isPrimaryRecovery = false
        }
        let isFutureSchema: Bool
        if case .halted(.schemaTooNew, _) = candidate.state {
            isFutureSchema = true
        } else {
            isFutureSchema = false
        }
        // Never expose a transport-scoped action through this inert engine. A future
        // schema fence is the sole exception: it is intentionally non-actionable and
        // must remain visible while sync is off.
        guard isPrimaryRecovery || isFutureSchema else { return }
        localRecoveryEngine = candidate
        state = candidate.state
    }

    // MARK: - Internals

    /// Where the fingerprint of the wire key the base was built against is kept.
    ///
    /// `UserDefaults` rather than `Sync/state.json`, because this is a key-selection hint,
    /// not a merge ancestor or pending user intent. Keeping it separate also avoids
    /// inviting anyone to source the crypto scope from mutable bookkeeping; the keychain
    /// remains the sole authority for the actual key material.
    private static let wireKeyFingerprintDefaultsKey = "SnippetsSyncWireKeyFingerprint"

    private struct ProtocolResetFailure: Error {
        enum Kind {
            case schemaTooNew(version: Int)
            case checkpointUnreadable
            case retryablePrerequisite
        }

        var kind: Kind
    }

    private static func startIssue(for error: Error) -> StartIssue {
        if let failure = error as? ProtocolResetFailure {
            return switch failure.kind {
            case .schemaTooNew(let version): .schemaTooNew(version: version)
            case .checkpointUnreadable: .checkpointUnreadable
            case .retryablePrerequisite: .retryablePrerequisite
            }
        }
        if let failure = error as? SyncBackendSelectionStore.Failure {
            return switch failure {
            case .missingCredential, .invalidCredential: .authenticationRequired
            case .credentialResetRequired: .cloudCredentialsUnreadable
            case .invalidProviderSelection, .switchStateUnreadable:
                .providerSwitchUnreadable
            case .featureDisabled, .missingConfiguration,
                 .credentialCleanupRequired, .credentialStoreUnavailable:
                .retryablePrerequisite
            }
        }
        if let failure = error as? SyncKeyStore.Failure {
            return switch failure {
            case .keychainUnavailable: .retryablePrerequisite
            case .cloudBootstrapRequired: .cloudKeyRequired
            case .malformedMaterial, .cloudRecordUnreadable: .syncKeyUnreadable
            }
        }
        return .retryablePrerequisite
    }

    /// Validate the application-level checkpoint before constructing a transport. The
    /// engine also validates these files, but doing it here is what lets Settings offer
    /// an actual Repair action instead of constructing an inert engine whose generic
    /// resume can only rediscover the same malformed bytes.
    private func validateProtocolFilesForStartup(at locations: SyncProtocolLocations) throws {
        let baseOutcome = SyncBaseFile.load(from: locations.baseURL)
        let journalOutcome = SyncJournalFile.load(from: locations.journalURL)
        let stateOutcome = SyncStateFile.load()

        var futureVersions: [Int] = []
        if case .tooNew(let version) = baseOutcome { futureVersions.append(version) }
        if case .tooNew(let version) = journalOutcome { futureVersions.append(version) }
        if case .tooNew(let version) = stateOutcome { futureVersions.append(version) }
        if let version = futureVersions.max() {
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        }

        if case .unreadable = baseOutcome {
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }
        if case .unreadable = journalOutcome {
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }

        switch baseOutcome {
        case .missing:
            if case .loaded = journalOutcome {
                throw ProtocolResetFailure(kind: .checkpointUnreadable)
            }
        case .loaded(let base):
            if base.journalEstablished, case .missing = journalOutcome {
                throw ProtocolResetFailure(kind: .checkpointUnreadable)
            }
        case .tooNew, .unreadable:
            break
        }
    }

    /// Rebuilds only derived sync intent from the current primary library. The new base
    /// carries both a non-destructive full-merge marker and the exact reviewed primary
    /// snapshot. That snapshot is not remote confirmation: it exists solely so an edit
    /// or deletion made after Repair remains authoritative while the first full fetch is
    /// pending. Older journal-only intent is retained independently.
    private func repairUnreadableProtocolCheckpoint() throws {
        let locations = try backendSelection.protocolLocations()
        try locations.createDirectories()
        library.activateProtocolLocations(locations)
        let baseOutcome = SyncBaseFile.load(from: locations.baseURL)
        let journalOutcome = SyncJournalFile.load(from: locations.journalURL)
        let stateOutcome = SyncStateFile.load()

        if case .tooNew(let version) = baseOutcome {
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        }
        if case .tooNew(let version) = journalOutcome {
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        }
        if case .tooNew(let version) = stateOutcome {
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        }

        let priorBase: SyncBase? = if case .loaded(let loaded) = baseOutcome {
            loaded
        } else {
            nil
        }
        let current = try library.currentEnvelopes(agreedBase: priorBase ?? SyncBase())
        var repairedJournal = if case .loaded(let loaded) = journalOutcome {
            loaded
        } else {
            SyncJournal()
        }
        let recoveryBase: SyncBase
        if var activeReview = priorBase,
           activeReview.requiresNonDestructiveLibraryMerge,
           activeReview.nonDestructiveMergeMode == .reviewedLocalSnapshot {
            // A previous Repair may have committed base.json and crashed before its
            // journal. Its reviewed snapshot is already the durable boundary between
            // pre- and post-review intent. Re-snapshotting `current` here would turn a
            // later deletion into unknown absence under a new review epoch.
            activeReview.upgradeToCurrentSchema()
            activeReview.journalEstablished = true
            recoveryBase = activeReview
        } else {
            let preRecoveryConfirmed = priorBase.flatMap {
                prior -> [String: SyncEnvelope]? in
                if prior.requiresNonDestructiveLibraryMerge {
                    return prior.preRecoveryConfirmedEnvelopes
                }
                return prior.envelopes
            }
            recoveryBase = SyncBase(
                envelopes: Dictionary(uniqueKeysWithValues: current.values.map {
                    (SyncBase.key($0.id), $0)
                }),
                journalEstablished: true,
                accountIdentity: priorBase?.accountIdentity,
                datasetIdentity: priorBase?.datasetIdentity,
                requiresNonDestructiveLibraryMerge: true,
                nonDestructiveMergeMode: .reviewedLocalSnapshot,
                preRecoveryConfirmedEnvelopes: preRecoveryConfirmed,
                nonDestructiveReviewID: UUID())
        }
        try repairedJournal.reconcileAfterReviewedLocalSnapshot(
            current: current,
            reviewedSnapshot: recoveryBase,
            deviceID: device,
            now: Date())

        // Base first is the crash fence. Its non-destructive marker makes even an old,
        // still-readable journal safe after a crash; a missing/unreadable journal keeps
        // startup stopped. Writing the journal first would be unsafe when the old base
        // was readable: a crash could pair that deletion-capable ancestor with the new
        // empty-ancestor journal before the marker existed.
        try SyncBaseFile.write(
            recoveryBase,
            to: locations.baseURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        #if DEBUG
        try protocolRepairBoundaryHook?(.baseCommitted)
        #endif
        try SyncJournalFile.write(
            repairedJournal,
            to: locations.journalURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        #if DEBUG
        try protocolRepairBoundaryHook?(.journalCommitted)
        #endif
        try library.retainConflictPrerequisiteInstallReceipts(
            for: repairedJournal.activeConflictPrerequisiteCopyIDs)
    }

    /// Clears the agreed envelopes when the key that sealed them is no longer the key we
    /// hold, so everything is re-pushed under the new one. Scheduler progress belongs
    /// to the losing encryption epoch and is reset; per-record CloudKit CAS generations
    /// are independent of that payload key and remain the safe overwrite boundary.
    ///
    /// Without this, changing the sealing key is a silent, one-way data loss. `base.json`
    /// records each record as *agreed with the backend*, so `pendingChanges` skips them
    /// for ever; meanwhile every record already up there was sealed under the old key and
    /// fails to open on fetch, so it is quarantined and never applied. The snippets vanish
    /// from sync with no halt and nothing in the pane, and clearing the backend does not
    /// help — the base still claims they are agreed, so they are never re-uploaded.
    ///
    /// This is what makes the vault-key-to-`K_sync` change survivable, and it is not a
    /// one-off migration: it fires again for any future rekey, including the losing side
    /// of the mint race `SyncKeyStore` documents.
    ///
    /// A fingerprint, not the key: this value sits in `UserDefaults`, which is neither
    /// encrypted nor access-controlled, and the only question it has to answer is "same
    /// as last time".
    private func discardAgreedBaseIfWireKeyChanged(
        _ material: Data,
        at locations: SyncProtocolLocations
    ) throws {
        let fingerprint = SHA256.hash(data: material)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        let fingerprintDefaultsKey = locations.identifier == "icloud"
            ? Self.wireKeyFingerprintDefaultsKey
            : "\(Self.wireKeyFingerprintDefaultsKey).\(locations.identifier)"
        let previous = defaults.string(forKey: fingerprintDefaultsKey)
        guard previous != fingerprint else { return }

        // Absent means either a first run, which has no base to discard and costs
        // nothing, or an install from before the fingerprint existed — which is exactly
        // the vault-key era whose base must be discarded. Both want the same action.
        if previous != nil || FileManager.default.fileExists(
            atPath: locations.baseURL.path) {
            Diagnostics.record(.syncTriggered(.keyChanged))
        }
        // Journal offers are plaintext application envelopes, not the ciphertext handed
        // to CloudKit. Preserve them exactly: retrying the same offer under the winner
        // key both reseals the remote blob and retains the tentative ancestor needed for
        // a delete/newer edit that followed a lost acknowledgement.
        let confirmed: SyncBase
        let baseWasMissing: Bool
        switch SyncBaseFile.load(from: locations.baseURL) {
        case .loaded(let loaded):
            confirmed = loaded
            baseWasMissing = false
        case .missing:
            confirmed = SyncBase()
            baseWasMissing = true
        case .tooNew(let version):
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        case .unreadable:
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }

        var journal: SyncJournal
        let journalWasMissing: Bool
        switch SyncJournalFile.load(from: locations.journalURL) {
        case .missing(let empty):
            journal = empty
            journalWasMissing = true
        case .loaded(let loaded):
            journal = loaded
            journalWasMissing = false
        case .tooNew(let version):
            throw ProtocolResetFailure(kind: .schemaTooNew(version: version))
        case .unreadable:
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }

        guard !baseWasMissing || journalWasMissing else {
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }
        guard !journalWasMissing || !confirmed.journalEstablished else {
            throw ProtocolResetFailure(kind: .checkpointUnreadable)
        }

        // Truly fresh sync has nothing to reseal. Do not manufacture journal.json here:
        // the engine establishes base.json before journal.json on its first round.
        if baseWasMissing, journalWasMissing {
            defaults.set(fingerprint, forKey: fingerprintDefaultsKey)
            return
        }

        // Reconcile every journal generation before rewriting transport state. Besides
        // upgrading schema 1, this validates that deterministic prerequisite ids in an
        // active schema-2 dependency have not been occupied by an unrelated record.
        // Failing before either file is written is essential: retaining a frozen copy
        // snapshot and pairing it with the occupant's CAS generation could otherwise
        // overwrite that unrelated record after the scheduler reset.
        var current = try library.currentEnvelopes(
            agreedBase: journal.projectionKnowledge(over: confirmed))
        try journal.reconcileDependencies(current: current, confirmed: confirmed)
        if !confirmed.requiresNonDestructiveLibraryMerge {
            journal.reconcile(
                current: current,
                confirmed: confirmed,
                deviceID: device,
                now: Date())
        }
        // Publish later C1/T intent before any frozen C0 recovery can touch primary.
        try SyncJournalFile.write(
            journal,
            to: locations.journalURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        // The scheduler reset below can discard an old inbox. Carrier-only dependency
        // snapshots must first become deterministic primary vault copies, exactly like
        // reviewed account/checkpoint resets. This maintenance path runs before a
        // SyncEngine exists, so perform the same materialise→reproject→journal fence
        // here and refuse rekey while the vault is locked/incompatible.
        let carrierSources = journal.carrierSourcesAwaitingMaterialization
        if !carrierSources.isEmpty {
            let freshlyPrepared = try library.prepareConflictCopyEvidence(
                from: carrierSources)
            guard !freshlyPrepared.isEmpty else {
                throw ProtocolResetFailure(kind: .retryablePrerequisite)
            }
            try journal.recordConflictCopyEvidence(freshlyPrepared)
            // Publish exact random-nonce C0 before primary mutation. A crash here is
            // repaired by SyncEngine before its next push/reset attempt.
            try SyncJournalFile.write(
                journal,
                to: locations.journalURL,
                temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        }
        if journal.hasFrozenConflictPrerequisitesAwaitingPrimaryCheck {
            let primary = try library.currentSnapshot(
                agreedBase: journal.projectionKnowledge(over: confirmed))
            try journal.reconcileInstalledConflictPrerequisiteAbsence(
                current: primary.envelopes,
                installedHashes: primary.installedConflictPrerequisiteHashes,
                confirmed: confirmed,
                deviceID: device,
                now: Date())
            // Publish a receipt-proven deletion before replaying any frozen C0/C1.
            try SyncJournalFile.write(
                journal,
                to: locations.journalURL,
                temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
            let batch = journal.conflictPrerequisiteRecovery(
                primaryStates: primary.primaryStates,
                installedHashes: primary.installedConflictPrerequisiteHashes)
            let recovery = try library.materializeConflictPrerequisites(
                from: batch.sources,
                preparedConflictCopyEvidence: batch.evidence,
                heldConflictCopyIntents: batch.heldIntents,
                expectedPrimary: batch.expectedPrimary)
            guard recovery.deferredIDs.isEmpty,
                  recovery.incompatibleVaultIDs.isEmpty,
                  recovery.retryIDs.isEmpty else {
                throw ProtocolResetFailure(kind: .retryablePrerequisite)
            }
            let recovered = try library.currentEnvelopes(
                agreedBase: journal.projectionKnowledge(over: confirmed))
            try journal.reconcileDependencies(current: recovered, confirmed: confirmed)
            if !confirmed.requiresNonDestructiveLibraryMerge {
                journal.reconcile(
                    current: recovered,
                    confirmed: confirmed,
                    deviceID: device,
                    now: Date())
            }
            let recoveredPrimary = try library.currentSnapshot(
                agreedBase: journal.projectionKnowledge(over: confirmed))
            guard journal.conflictPrerequisiteRecovery(
                primaryStates: recoveredPrimary.primaryStates,
                installedHashes: recoveredPrimary.installedConflictPrerequisiteHashes)
                .sources.isEmpty else {
                throw ProtocolResetFailure(kind: .retryablePrerequisite)
            }
            current = recovered
        }
        if confirmed.requiresNonDestructiveLibraryMerge {
            try journal.prepareForNonDestructiveLibraryRecovery(
                current: current,
                confirmed: confirmed,
                deviceID: device,
                now: Date(),
                discoverSecureCarriers: library.supportsSecureConflictMaterialization)
        } else {
            try journal.prepareForTransportRekey(
                current: current,
                confirmed: confirmed,
                now: Date())
        }
        try SyncJournalFile.write(
            journal,
            to: locations.journalURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
        try library.retainConflictPrerequisiteInstallReceipts(
            for: journal.activeConflictPrerequisiteCopyIDs)

        // Journal first is intentional. A crash here leaves the old base in place and
        // the fingerprint unchanged, so start repeats the reset. The CKSyncEngine
        // scheduler checkpoint is discarded, but CloudKit record generations are not:
        // change tags are independent of the payload-encryption key and are exactly
        // what lets the resealed value replace old ciphertext without overwriting an
        // independent remote edit.
        try SyncBaseFile.write(SyncBase(
            envelopes: confirmed.requiresNonDestructiveLibraryMerge
                ? confirmed.envelopes
                : [:],
            recordVersions: confirmed.recordVersions,
            journalEstablished: true,
            accountIdentity: confirmed.accountIdentity,
            datasetIdentity: confirmed.datasetIdentity,
            requiresTransportFullResync: !confirmed.requiresNonDestructiveLibraryMerge,
            requiresNonDestructiveLibraryMerge:
                confirmed.requiresNonDestructiveLibraryMerge,
            nonDestructiveMergeMode: confirmed.nonDestructiveMergeMode,
            preRecoveryConfirmedEnvelopes:
                confirmed.preRecoveryConfirmedEnvelopes,
            nonDestructiveReviewID: confirmed.nonDestructiveReviewID),
            to: locations.baseURL,
            temporaryDirectory: SnippetStorageLocations.tmpFolderURL)

        // The projection sidecar remains untouched: it contains forward-compatible `x`
        // fields and local HLC/origin metadata independent of the transport key.
        defaults.set(fingerprint, forKey: fingerprintDefaultsKey)
    }

    /// Adopts a wire key that arrived from another Mac after this engine was built.
    ///
    /// The only way the stored key differs from the one in use is the race `SyncKeyStore`
    /// documents: two Macs each minted a key before iCloud Keychain had propagated
    /// either, and it has since converged on one of them. Continuing to seal under a key
    /// no other device holds would make this Mac's uploads permanently unreadable, so it
    /// rebuilds on the winner instead.
    ///
    /// `start()` fingerprints the new material and clears the confirmed envelopes before
    /// constructing the replacement engine, so records accepted under the losing key are
    /// re-pushed rather than remaining permanently suppressed by a stale agreed base.
    /// Scheduler state is deliberately discarded because its inbox is encrypted under
    /// the losing key. Per-record CloudKit generations are retained: they do not depend
    /// on that key and keep the reseal conditional on the exact remote ancestor.
    ///
    /// Skipped mid-round, so a rebuild can never race the engine it is replacing.
    ///
    /// Returns whether it restarted, because `start()` finishes by syncing and the caller
    /// must not then run a second round.
    @discardableResult
    private func restartIfWireKeyChanged() -> Bool {
        guard engine != nil, roundTask == nil, let activeKeyMaterial else { return false }
        guard let current = try? keys.material(), current != activeKeyMaterial else { return false }

        Diagnostics.record(.syncTriggered(.keyChanged))
        stop()
        start()
        return true
    }

    private func startRound(
        with engine: SyncEngine,
        completions: [RequestCompletion],
        bypassingBackoff: Bool = false
    ) {
        let generation = lifecycleGeneration
        roundGeneration = generation
        currentRoundCompletions.append(contentsOf: completions)
        let task = Task { @MainActor [weak self] in
            let finalState = await engine.sync(bypassingBackoff: bypassingBackoff)
            guard let self else { return }
            self.finishRound(generation: generation, finalState: finalState)
        }
        roundTask = task
    }

    private func finishRound(
        generation: UInt64,
        finalState: SyncEngine.State
    ) {
        roundTask = nil
        roundGeneration = nil

        if generation == lifecycleGeneration,
           case .idle(let lastSync) = finalState,
           lastSync != nil,
           backendSelection.interruptedProviderSwitch?.target == backendSelection.provider {
            // The target merge, pending journal and returned cursor are durable before
            // SyncEngine reports idle. Removing the marker last makes a crash on every
            // earlier boundary resume the target instead of guessing or dual-writing.
            try? backendSelection.completeProviderSwitch()
        }

        let completedRequests = currentRoundCompletions
        currentRoundCompletions.removeAll(keepingCapacity: true)
        for completion in completedRequests {
            completion(.completed(finalState))
        }

        // A stopped generation is only draining toward `shutdownTask`. It must not
        // consume replay intent queued by a rapid re-enable or complete those callers
        // with the retired engine's state. The shutdown barrier starts the replacement,
        // whose startup round will own that replay.
        guard generation == lifecycleGeneration else { return }

        // The safety-halt fallback can switch the persisted opt-in off from inside this
        // round. Keep the task retained until this point so destructive maintenance still
        // sees the real quiescence boundary, then tear the engine down completely. Merely
        // publishing `.disabled` leaves `engine != nil`, and a later checkbox-on makes
        // `start()` return early forever instead of constructing the fresh engine that
        // explicit re-enablement promises.
        guard Self.isEnabled else {
            stop()
            return
        }

        if engine?.requiresTransportRestart == true {
            // A peer finished a durable recovery claim. Its base/journal and the
            // transport-private scheduler checkpoint form one generation; rebuilding
            // only Core would let this old adapter write stale state over the reset.
            reloadProviderSelection()
            return
        }

        let replay = roundRequests.finishRound(
            generation: generation,
            currentGeneration: lifecycleGeneration)
        let bypassesBackoff = replayBypassesBackoff
        replayBypassesBackoff = false
        guard replay, let engine else {
            // Defensive: every queued completion should imply a requested replay, but
            // never leave an async caller suspended if future scheduling code violates
            // that invariant.
            let orphaned = replayRoundCompletions
            replayRoundCompletions.removeAll(keepingCapacity: true)
            for completion in orphaned {
                completion(.completed(finalState))
            }
            return
        }

        let replayCompletions = replayRoundCompletions
        replayRoundCompletions.removeAll(keepingCapacity: true)
        Diagnostics.record(.syncTriggered(.retry))
        startRound(
            with: engine,
            completions: replayCompletions,
            bypassingBackoff: bypassesBackoff)
    }

    private func finishAllRequests(with result: RequestResult) {
        let completions = currentRoundCompletions + replayRoundCompletions
        currentRoundCompletions.removeAll(keepingCapacity: true)
        replayRoundCompletions.removeAll(keepingCapacity: true)
        for completion in completions { completion(result) }
    }

    private func startPolling(every interval: TimeInterval) {
        pollTimer?.invalidate()
        // CKSyncEngine's subscription and silent pushes are primary. This infrequent
        // health check covers a missed push without restoring the old two-minute load.
        // `tolerance` lets the system coalesce it with other background work.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.syncNow(trigger: .poll) }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startEventPump(for transport: any SyncTransport) {
        // One consumer, because `AsyncStream` has a single continuation — a second
        // iteration would steal events rather than duplicate them.
        eventTask = Task { @MainActor [weak self] in
            for await event in transport.events {
                guard let self else { return }
                switch event {
                case .changesAvailable, .cursorInvalidated:
                    _ = self.syncNow(trigger: .poll)
                case .authenticationRequired:
                    // Deliberately still a fetch. The round begins by checking the account
                    // and will report the real state; acting on the hint directly would be
                    // a second, competing opinion about whether the user is signed in.
                    _ = self.syncNow(trigger: .retry)
                }
            }
        }
    }

    private func publish(_ newState: SyncEngine.State) {
        state = newState
        offlineRetryScheduler.update(for: newState) { [weak self] in
            _ = self?.syncNow(trigger: .retry)
        }
        Diagnostics.record(.syncState(
            Self.diagnosticState(for: newState),
            haltReason: Self.diagnosticHaltReason(for: newState)))
        onStateChange?(newState)
        for observer in stateObservers.values {
            observer(newState)
        }
    }

    private static func diagnosticState(for state: SyncEngine.State) -> DiagnosticSyncState {
        switch state {
        case .disabled: .disabled
        case .idle(let lastSync): lastSync == nil ? .idle : .synced
        case .syncing: .syncing
        case .offline, .waitingForVault: .waiting
        case .needsAuthentication, .needsAttention: .failed
        case .halted: .halted
        }
    }

    private static func diagnosticHaltReason(
        for state: SyncEngine.State
    ) -> DiagnosticSyncHaltReason? {
        guard case .halted(let reason, _) = state else { return nil }
        return switch reason {
        case .massDeletion: .destructiveChange
        case .backendRefused, .accountChanged, .checkpointUnreadable:
            .accountRequiresReview
        case .remoteDataReset: .destructiveChange
        case .schemaTooNew, .manifestIntegrityFailed,
             .localLibraryQuarantined, .vaultUnreadable: .incompatibleState
        }
    }

    // MARK: - Presentation

    /// One sentence for the settings pane. Deliberately here rather than in the view, so
    /// the state and the words for it cannot drift apart.
    var statusDescription: String {
        // Primary-file recovery remains actionable even when cloud sync is off. Render
        // that stop before the ordinary readiness shortcut would reduce it to "Off".
        if localRecoveryEngine != nil,
           case .halted(let reason, let detail) = state {
            return Self.userFacingHaltDescription(reason: reason, detail: detail)
        }
        if Self.isEnabled, let startIssue {
            if startIssue == .syncKeyUnreadable {
                return switch backendSelection.provider {
                case .iCloud:
                    "The iCloud sync encryption key could not be verified. First "
                        + "confirm that iCloud Passwords & Keychain is enabled for the "
                        + "intended Apple Account, or recover the key from a Mac that "
                        + "can still sync this library. Check Again only rechecks the "
                        + "key; it does not repair or replace it."
                case .snippetsCloud:
                    "The Snippets Cloud library key could not be verified. First "
                        + "approve this device from a trusted device or restore the "
                        + "Snippets Cloud recovery kit. Check Again only rechecks the "
                        + "key; it does not repair or replace it."
                }
            }
            return startIssue.description
        }
        if engine?.recoveryClaimNeedsTakeover == true {
            return "An earlier recovery attempt is still claimed by another process or "
                + "Mac. If it is no longer running, choose Take Over Recovery. That only "
                + "clears attempt ownership; the original action must be reviewed again."
        }
        switch readiness {
        case .off:
            return "Off. Your snippets stay on this device."
        case .cannotStart(let detail):
            return "Cannot start: \(detail)"
        case .ready:
            break
        }

        switch state {
        case .disabled:
            return "Starting\u{2026}"
        case .idle(let lastSync):
            guard let lastSync else { return "On. Nothing synced yet." }
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "On. Last synced at \(formatter.string(from: lastSync))."
        case .syncing:
            return "Syncing\u{2026}"
        case .offline(let retryAfter):
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return "Cannot reach \(backendSelection.provider.displayName). Trying again at \(formatter.string(from: retryAfter))."
        case .needsAuthentication(let detail):
            var sentence = "\(backendSelection.provider.displayName) needs attention: "
                + Self.userFacingAuthenticationDetail(detail)
            if !sentence.hasSuffix(".") { sentence += "." }
            return sentence
        case .needsAttention(let detail):
            var sentence = "Sync needs attention: \(Self.userFacingAttentionDetail(detail))"
            if !sentence.hasSuffix(".") { sentence += "." }
            return sentence + " Fix the reported condition, then try again."
        case .waitingForVault(let detail):
            return "Waiting: \(detail)."
        case .halted(let reason, let detail):
            return Self.userFacingHaltDescription(reason: reason, detail: detail)
        }
    }

    private static func userFacingHaltDescription(
        reason: SyncState.HaltReason,
        detail: String
    ) -> String {
        // The reason in words, then a closed user-facing account, then where to look.
        // Previously this interpolated enum and transport internals directly.
        var sentence = "Stopped because \(reason.title): "
            + userFacingHaltDetail(reason: reason, detail: detail)
        if !sentence.hasSuffix(".") { sentence += "." }
        if let guidance = reason.guidance { sentence += " \(guidance)" }
        return sentence
    }

    /// Transport details are retained for state-machine decisions, but a backend may
    /// express them as protocol tokens such as `record_too_large`. Settings presents a
    /// closed vocabulary instead of leaking those implementation codes into the UI.
    private static func userFacingAuthenticationDetail(_ detail: String) -> String {
        switch detail {
        case "sign_in_required", "authentication_required":
            return "Sign in to continue"
        case "invalid_access_token", "reauthentication_required":
            return "Your sign-in expired; sign in again"
        default:
            return "Sign in again to continue"
        }
    }

    private static func userFacingAttentionDetail(_ detail: String) -> String {
        switch detail {
        case "record_too_large", "payload_too_large":
            return "One snippet is too large for the cloud service"
        case "quota_exceeded":
            return "The cloud account is out of storage"
        case "forbidden":
            return "This account cannot update the selected cloud library"
        case "incompatible_version":
            return "Update Snippets before syncing again"
        case "startup_prerequisite_unavailable":
            return "A local sync prerequisite is temporarily unavailable"
        case "transport_restart_required":
            return "Another Snippets process completed recovery; reconnecting sync"
        case "cloud_key_required":
            return "Approve this device or restore the Snippets Cloud recovery kit"
        case "sync_key_unreadable":
            return "The stored sync encryption key could not be verified"
        case "not_found":
            return "The selected cloud library is no longer available"
        case "invalid_batch_size", "invalid_record_version", "invalid_request",
             "record_rejected":
            return "The cloud service rejected a change"
        case "internal_error":
            return "The cloud service could not accept a change"
        case "the snippet exceeds CloudKit limits",
             "this snippet is too large for CloudKit to store":
            return "One snippet is too large for the cloud service"
        case "the iCloud account is out of space":
            return "The cloud account is out of storage"
        case "the CloudKit record zone no longer exists":
            return "The cloud library is no longer available"
        case "the sync backend rejected this snippet":
            return "The cloud service rejected a change"
        default:
            return "The cloud service rejected a change"
        }
    }

    private static func userFacingHaltDetail(
        reason: SyncState.HaltReason,
        detail: String
    ) -> String {
        switch reason {
        case .massDeletion:
            return detail
        case .backendRefused:
            return userFacingAttentionDetail(detail)
        case .accountChanged:
            return "The signed-in cloud account no longer matches this device's saved checkpoint"
        case .checkpointUnreadable:
            return "Snippets could not verify this device's saved sync checkpoint"
        case .remoteDataReset:
            return "The cloud service reported that its stored library was reset"
        case .manifestIntegrityFailed:
            return "The saved sync integrity information did not verify"
        case .localLibraryQuarantined:
            return "Snippets preserved the unreadable library for recovery and did not sync an empty replacement"
        case .vaultUnreadable:
            return "Snippets could not verify the secure vault"
        case .schemaTooNew:
            return "This device cannot safely write the newer library format"
        }
    }

}

extension SyncCoordinator: SnippetStoreSyncDelegate {}
