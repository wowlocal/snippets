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
/// ## Enabling it needs nothing but the checkbox
///
/// Every record on the wire is still sealed, plaintext snippets included. What changed is
/// which key does it: `SyncKeyStore`'s `K_sync`, not the vault's `K_lib`.
///
/// The old arrangement made sync a dependent of Secure Snippets — no vault meant no
/// keyring meant nothing could be pushed, and a *locked* vault meant background rounds
/// stopped until the user proved presence again. For a feature whose whole job is to run
/// unattended every two minutes, that was fatal, and it was buying nothing: the wire key
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

    /// Off unless the user has said otherwise. `UserDefaults.bool(forKey:)` returns
    /// `false` for an absent key, so the default needs no registration — and an absent
    /// key and an explicit "off" behave identically, which is what we want.
    static let enabledDefaultsKey = "SnippetsICloudSyncEnabled"

    /// Why sync is not running.
    ///
    /// Down from four cases to three, because two of them — "set up Secure Snippets
    /// first" and "unlock Secure Snippets to start syncing" — described a dependency
    /// that no longer exists.
    enum Readiness: Equatable {
        case off
        /// The keychain would not give up a wire key, so there is nothing to seal with.
        /// Rare and not self-inflicted: a locked keychain, or a build whose entitlements
        /// the profile does not back.
        case keyUnavailable(String)
        case ready
    }

    private let library: any SyncLibraryAccess
    private let keys: SyncKeyStore
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

    /// The wire key bytes the running engine was built with, and why `readiness` can be
    /// a cheap computed property: the keychain is consulted when sync starts and once a
    /// round, never on every redraw of the settings pane.
    private var activeKeyMaterial: Data?
    private var keyFailure: String?

    init(
        library: any SyncLibraryAccess,
        keys: SyncKeyStore,
        device: String
    ) {
        self.library = library
        self.keys = keys
        self.device = device
    }

    // MARK: - The preference

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledDefaultsKey)
    }

    var readiness: Readiness {
        guard Self.isEnabled else { return .off }
        if let keyFailure { return .keyUnavailable(keyFailure) }
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

        let material: Data
        let sealer: SnippetCryptoSealer
        do {
            material = try keys.materialMintingIfNeeded()
            sealer = SnippetCryptoSealer(
                keyring: try SyncKeyStore.keyring(from: material), scopeID: keys.scopeID)
        } catch {
            // Not a halt: nothing has gone wrong with anybody's data. The keychain is
            // simply not answering, which on a signed build means the keychain is locked
            // or the profile does not back the entitlement. `readiness` carries the
            // detail to the pane rather than leaving a checkbox that appears to do
            // nothing.
            NSLog("Snippets: iCloud sync is on but has no key to seal with: \(error)")
            keyFailure = "\(error)"
            publish(.disabled)
            return
        }
        keyFailure = nil
        activeKeyMaterial = material

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
        activeKeyMaterial = nil
        isRoundInFlight = false
        wantsAnotherRound = false
        publish(.disabled)
    }

    /// Re-evaluates after the shape of the library changed underneath — most usefully,
    /// after a vault was created or adopted, which adds records sync had nothing to say
    /// about a moment ago. Safe to call repeatedly; `start()` is a no-op once running.
    func libraryStructureChanged() {
        guard Self.isEnabled else { return }
        // `syncNow` already starts a stopped engine, so there is one path rather than two
        // that have to be kept saying the same thing.
        syncNow()
    }

    // MARK: - Running a round

    func syncNow() {
        guard engine != nil else {
            // A start that failed — the keychain would not answer — is retried here
            // rather than only at launch. Without this the only way back was to relaunch
            // or toggle the checkbox, because the poll timer is started by `start()` and
            // so does not exist yet. `start()` ends by syncing, so this call is done.
            if Self.isEnabled { start() }
            return
        }
        // A rebuild also ends by syncing; running a second round here would be waste.
        if restartIfWireKeyChanged() { return }

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

    /// Adopts a wire key that arrived from another Mac after this engine was built.
    ///
    /// The only way the stored key differs from the one in use is the race `SyncKeyStore`
    /// documents: two Macs each minted a key before iCloud Keychain had propagated
    /// either, and it has since converged on one of them. Continuing to seal under a key
    /// no other device holds would make this Mac's uploads permanently unreadable, so it
    /// rebuilds on the winner instead.
    ///
    /// Records already pushed under the losing key stay unreadable — they are recorded in
    /// `base.json` as accepted, so they are not re-pushed until they next change. That is
    /// a stated limit rather than a repair, because the window it needs is two first-ever
    /// enables inside a minute of each other.
    ///
    /// Skipped mid-round, so a rebuild can never race the engine it is replacing.
    ///
    /// Returns whether it restarted, because `start()` finishes by syncing and the caller
    /// must not then run a second round.
    @discardableResult
    private func restartIfWireKeyChanged() -> Bool {
        guard engine != nil, !isRoundInFlight, let activeKeyMaterial else { return false }
        guard let current = try? keys.material(), current != activeKeyMaterial else { return false }

        NSLog("Snippets: the iCloud sync key changed; restarting under the shared one.")
        stop()
        start()
        return true
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
        case .keyUnavailable(let detail):
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
            return "Cannot reach iCloud. Trying again at \(formatter.string(from: retryAfter))."
        case .needsAuthentication(let detail):
            return "iCloud needs attention: \(detail)"
        case .waitingForVault(let detail):
            return "Waiting: \(detail)."
        case .halted(let reason, let detail):
            // The reason in words, then the backend's own account, then where to look.
            // Previously this interpolated the enum case, so the sentence a user met was
            // "Stopped for safety (manifestIntegrityFailed): …".
            var sentence = "Stopped: \(reason.title). \(detail)"
            if !sentence.hasSuffix(".") { sentence += "." }
            if let guidance = reason.guidance { sentence += " \(guidance)" }
            return sentence
        }
    }
}
