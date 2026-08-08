import Foundation

// App target only — see the note at the top of `CloudKitRecordMapping.swift`.

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
/// ## Why enabling it needs the vault
///
/// Every record on the wire is sealed — plaintext snippets included — and the sealing key
/// is the vault's `K_lib`, scoped by the vault's `kid`. So there is no such thing as
/// "sync the ordinary snippets without setting up secure ones": no vault means no
/// keyring, which means no `SyncBlobSealing`, which means nothing can be pushed. Saying
/// that plainly in the UI is better than a checkbox that silently does nothing.
@MainActor
final class SyncCoordinator {

    /// Off unless the user has said otherwise. `UserDefaults.bool(forKey:)` returns
    /// `false` for an absent key, so the default needs no registration — and an absent
    /// key and an explicit "off" behave identically, which is what we want.
    static let enabledDefaultsKey = "SnippetsICloudSyncEnabled"

    /// Why sync cannot start, in the order a user has to fix them.
    enum Readiness: Equatable {
        case off
        /// No vault on this Mac. There is nothing to seal with.
        case needsVault
        /// A vault exists but its key is not available right now.
        case needsUnlock
        case ready
    }

    private let library: any SyncLibraryAccess
    private let session: VaultSession
    private let secureStore: SecureSnippetStore
    private let device: String

    private(set) var engine: SyncEngine?
    private(set) var state: SyncEngine.State = .disabled

    /// Set by the settings pane so it can redraw. One observer is enough; a second would
    /// mean two things believe they own the presentation.
    var onStateChange: ((SyncEngine.State) -> Void)?

    private var transport: CloudKitTransport?
    private var pollTimer: Timer?
    private var eventTask: Task<Void, Never>?

    /// `SyncEngine.sync()` returns early when a round is already in flight, which
    /// *discards* the request rather than queueing it. For a poll timer that is harmless
    /// — the next tick retries — but for a user pressing "Sync Now" or a push hint
    /// arriving mid-round it would look like the button did nothing. So a dropped request
    /// is remembered and replayed once the round finishes.
    private var isRoundInFlight = false
    private var wantsAnotherRound = false

    init(
        library: any SyncLibraryAccess,
        session: VaultSession,
        secureStore: SecureSnippetStore,
        device: String
    ) {
        self.library = library
        self.session = session
        self.secureStore = secureStore
        self.device = device
    }

    // MARK: - The preference

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    var readiness: Readiness {
        guard Self.isEnabled else { return .off }
        guard secureStore.hasVault, secureStore.document != nil else { return .needsVault }
        guard case .unlocked = session.state else { return .needsUnlock }
        return .ready
    }

    /// Turns sync on or off and acts on it immediately.
    ///
    /// Writing the preference and starting are one call on purpose: two calls is how a
    /// checkbox ends up out of step with what is actually running.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
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
        guard Self.isEnabled, engine == nil else { return }

        let sealer: SnippetCryptoSealer
        do {
            sealer = try makeSealer()
        } catch {
            // Not a halt and not an error state: the user has opted in but the vault is
            // not open yet. `readiness` is what the pane reads to say which of the two it
            // is, and unlocking calls `start()` again.
            NSLog("Snippets: iCloud sync is on but cannot start yet: \(error)")
            publish(.disabled)
            return
        }

        let transport = CloudKitTransport()
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: device)
        engine.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.publish(state) }
        }

        self.transport = transport
        self.engine = engine

        startPolling(every: transport.pollInterval)
        startEventPump(for: transport)
        syncNow()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        eventTask?.cancel()
        eventTask = nil
        engine = nil
        transport = nil
        isRoundInFlight = false
        wantsAnotherRound = false
        publish(.disabled)
    }

    /// Re-evaluates after something outside changed — the vault was unlocked, or a vault
    /// was created. Safe to call repeatedly; `start()` is a no-op once running.
    func vaultStateChanged() {
        guard Self.isEnabled else { return }
        if engine == nil { start() }
    }

    // MARK: - Running a round

    func syncNow() {
        guard let engine else { return }
        if isRoundInFlight {
            wantsAnotherRound = true
            return
        }
        isRoundInFlight = true
        Task { @MainActor [weak self] in
            _ = await engine.sync()
            guard let self else { return }
            self.isRoundInFlight = false
            if self.wantsAnotherRound {
                self.wantsAnotherRound = false
                self.syncNow()
            }
        }
    }

    /// The only way out of a halt, and it goes through the engine's deliberately
    /// awkwardly-named method so the intent stays visible: a halt means a human looked.
    func clearHaltAfterUserReview() {
        engine?.clearHaltAfterUserReview()
        syncNow()
    }

    // MARK: - Internals

    private func makeSealer() throws -> SnippetCryptoSealer {
        guard let document = secureStore.document else {
            throw Failure.noVault
        }
        guard let salt = document.vaultSaltBytes else {
            throw Failure.malformedVault
        }
        // `scopeID` is the vault document's `kid`, never anything from `Sync/state.json` —
        // that file regenerates itself when unreadable, and binding ciphertext to a value
        // stored there would make every secure snippet undecryptable the first time it
        // went missing. The value that unlocks a file belongs in that file.
        return SnippetCryptoSealer(
            keyring: try session.keyring(vaultSalt: salt), scopeID: document.kid)
    }

    private enum Failure: Error, CustomStringConvertible {
        case noVault
        case malformedVault

        var description: String {
            switch self {
            case .noVault: return "no vault exists on this Mac, so there is no key to seal with"
            case .malformedVault: return "the vault document has no usable salt"
            }
        }
    }

    private func startPolling(every interval: TimeInterval) {
        pollTimer?.invalidate()
        // Load-bearing rather than a backstop: with no APNs entitlement there are no
        // CloudKit push subscriptions, so this timer is the only thing that makes a remote
        // change arrive. `tolerance` lets the system coalesce it with other timers, which
        // matters for a laptop's battery at a two-minute cadence.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func startEventPump(for transport: CloudKitTransport) {
        // One consumer, because `AsyncStream` has a single continuation — a second
        // iteration would steal events rather than duplicate them.
        eventTask = Task { @MainActor [weak self] in
            for await event in transport.events {
                guard let self else { return }
                switch event {
                case .changesAvailable, .cursorInvalidated:
                    self.syncNow()
                case .authenticationRequired:
                    // Deliberately still a fetch. The round begins by checking the account
                    // and will report the real state; acting on the hint directly would be
                    // a second, competing opinion about whether the user is signed in.
                    self.syncNow()
                }
            }
        }
    }

    private func publish(_ newState: SyncEngine.State) {
        state = newState
        onStateChange?(newState)
    }

    // MARK: - Presentation

    /// One sentence for the settings pane. Deliberately here rather than in the view, so
    /// the state and the words for it cannot drift apart.
    var statusDescription: String {
        switch readiness {
        case .off:
            return "Off. Your snippets stay on this Mac."
        case .needsVault:
            return "Waiting: iCloud sync encrypts every snippet with your secure-snippets key, "
                + "so it needs Secure Snippets set up first."
        case .needsUnlock:
            return "Waiting: unlock Secure Snippets to start syncing."
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
            return "Cannot reach iCloud. Trying again at \(formatter.string(from: retryAfter))."
        case .needsAuthentication(let detail):
            return "iCloud needs attention: \(detail)"
        case .halted(let reason, let detail):
            return "Stopped for safety (\(reason)): \(detail)"
        }
    }
}
