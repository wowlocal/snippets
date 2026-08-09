import CryptoKit
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
        /// A start prerequisite is temporarily unavailable: usually a locked Keychain,
        /// or rarely stale sync bookkeeping that could not yet be removed safely.
        case cannotStart(String)
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
    private var startRetryTimer: Timer?
    private var eventTask: Task<Void, Never>?
    /// Retained until the round has actually returned. Cancellation is advisory across
    /// an awaited CloudKit call, so `engine == nil` is not proof that sync is quiescent.
    private var roundTask: Task<Void, Never>?
    /// Invalidates state callbacks and completions from engines stopped earlier.
    private var lifecycleGeneration: UInt64 = 0

    /// `SyncEngine.sync()` returns early when a round is already in flight, which
    /// *discards* the request rather than queueing it. For a poll timer that is harmless
    /// — the next tick retries — but for a user pressing "Sync Now" or a push hint
    /// arriving mid-round it would look like the button did nothing. So a dropped request
    /// is remembered and replayed once the round finishes.
    private var wantsAnotherRound = false

    /// The wire key bytes the running engine was built with, and why `readiness` can be
    /// a cheap computed property: the keychain is consulted when sync starts and once a
    /// round, never on every redraw of the settings pane.
    private var activeKeyMaterial: Data?
    private var startFailure: String?

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
        if let startFailure { return .cannotStart(startFailure) }
        return .ready
    }

    /// Destructive local maintenance may proceed only after an old round has returned,
    /// not merely after the checkbox was switched off.
    var isQuiescent: Bool { roundTask == nil }

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
            try discardAgreedBaseIfWireKeyChanged(material)
        } catch {
            // Not a halt: no remote or library data was changed. The keychain may not be
            // answering, or the stale agreed base may not yet be removable. Both are
            // start prerequisites worth retrying rather than running under ambiguous
            // crypto state. `readiness` carries the detail to Settings.
            Diagnostics.record(.storageFailure(
                area: .syncKey,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: nil))
            startFailure = "\(error)"
            scheduleStartRetry()
            publish(.disabled)
            return
        }
        startRetryTimer?.invalidate()
        startRetryTimer = nil
        startFailure = nil
        activeKeyMaterial = material

        let transport = CloudKitTransport()
        let engine = SyncEngine(
            transport: transport, library: library, sealer: sealer, device: device)
        engine.onSafetyHaltPersistenceFailure = {
            // Independent fail-closed channel: if state.json or its lock is unavailable,
            // this process remains halted in memory and the next launch does not build a
            // sync engine at all. Re-enabling the checkbox is then an explicit user act.
            UserDefaults.standard.set(false, forKey: Self.enabledDefaultsKey)
            _ = UserDefaults.standard.synchronize()
        }
        let generation = lifecycleGeneration
        engine.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.lifecycleGeneration == generation else { return }
                self.publish(state)
            }
        }

        self.transport = transport
        self.engine = engine

        // A safety halt restored from `Sync/state.json` is already the engine's state;
        // it does not transition during the no-op `sync()` below, so its callback will
        // not fire. Publish it explicitly or Settings would show `.disabled` after a
        // relaunch even though the engine correctly refuses to fetch.
        if engine.state.isHalted { publish(engine.state) }

        startPolling(every: transport.pollInterval)
        startEventPump(for: transport)
        syncNow(trigger: .startup)
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
    /// A minute rather than the two-minute poll: this is cheap — one keychain read — and
    /// the window it covers is a user waiting for their session to finish unlocking.
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
        startRetryTimer?.invalidate()
        startRetryTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil
        eventTask?.cancel()
        eventTask = nil
        // Do not clear `roundTask` here. A CloudKit operation may take time to observe
        // cancellation, and local vault removal must wait until it has returned and the
        // engine's cancellation barriers have prevented further mutations.
        roundTask?.cancel()
        engine = nil
        transport = nil
        activeKeyMaterial = nil
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
        syncNow(trigger: .localLibraryChange)
    }

    // MARK: - Running a round

    func syncNow(trigger: DiagnosticSyncTrigger = .manual) {
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
        Diagnostics.record(.syncTriggered(trigger))
        if roundTask != nil {
            wantsAnotherRound = true
            return
        }
        let generation = lifecycleGeneration
        let task = Task { @MainActor [weak self] in
            _ = await engine.sync()
            guard let self else { return }
            self.finishRound(generation: generation)
        }
        roundTask = task
    }

    /// The only way out of a halt, and it goes through the engine's deliberately
    /// awkwardly-named method so the intent stays visible: a halt means a human looked.
    func clearHaltAfterUserReview() {
        engine?.clearHaltAfterUserReview()
        if Self.isEnabled {
            syncNow(trigger: .retry)
        } else {
            // Halt persistence failed and turned the opt-in off. Do not let the existing
            // in-memory engine bypass that preference after Review; a later checkbox-on
            // constructs a fresh engine deliberately.
            stop()
        }
    }

    // MARK: - Internals

    /// Where the fingerprint of the wire key the base was built against is kept.
    ///
    /// `UserDefaults` rather than `Sync/state.json`, because this is local derived state
    /// whose worst failure is one extra reconcile — the same reasoning that lets the base
    /// itself be disposable — and because putting it in the state file would invite
    /// someone to source the crypto scope from there, which that file's own documentation
    /// spends a paragraph forbidding.
    private static let wireKeyFingerprintDefaultsKey = "SnippetsSyncWireKeyFingerprint"

    /// Throws away the agreed base when the key that sealed it is no longer the key we
    /// hold, so everything is re-pushed under the new one.
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
    private func discardAgreedBaseIfWireKeyChanged(_ material: Data) throws {
        let fingerprint = SHA256.hash(data: material)
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.wireKeyFingerprintDefaultsKey)
        guard previous != fingerprint else { return }

        // Absent means either a first run, which has no base to discard and costs
        // nothing, or an install from before the fingerprint existed — which is exactly
        // the vault-key era whose base must be discarded. Both want the same action.
        if previous != nil || FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path) {
            Diagnostics.record(.syncTriggered(.keyChanged))
        }
        // Only the agreed ancestor belongs to the old wire key. The projection sidecar
        // contains forward-compatible `x` fields and local HLC/origin metadata; deleting
        // it would make the next upload strip fields this build does not understand.
        try AtomicFileWriter.removeDurablyIfPresent(
            SnippetStorageLocations.syncBaseFileURL)
        // Record the winner only after the stale base is durably absent. If removal
        // fails, the next start retries rather than blessing a base sealed by another key.
        defaults.set(fingerprint, forKey: Self.wireKeyFingerprintDefaultsKey)
    }

    /// Adopts a wire key that arrived from another Mac after this engine was built.
    ///
    /// The only way the stored key differs from the one in use is the race `SyncKeyStore`
    /// documents: two Macs each minted a key before iCloud Keychain had propagated
    /// either, and it has since converged on one of them. Continuing to seal under a key
    /// no other device holds would make this Mac's uploads permanently unreadable, so it
    /// rebuilds on the winner instead.
    ///
    /// `start()` fingerprints the new material and clears `base.json` before constructing
    /// the replacement engine, so records accepted under the losing key are re-pushed
    /// rather than remaining permanently suppressed by a stale agreed base.
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

    private func finishRound(generation: UInt64) {
        roundTask = nil

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

        let replay = wantsAnotherRound || generation != lifecycleGeneration
        wantsAnotherRound = false
        guard replay, engine != nil else { return }
        syncNow(trigger: .retry)
    }

    private func startPolling(every interval: TimeInterval) {
        pollTimer?.invalidate()
        // Load-bearing rather than a backstop: with no APNs entitlement there are no
        // CloudKit push subscriptions, so this timer is the only thing that makes a remote
        // change arrive. `tolerance` lets the system coalesce it with other timers, which
        // matters for a laptop's battery at a two-minute cadence.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncNow(trigger: .poll) }
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
                    self.syncNow(trigger: .poll)
                case .authenticationRequired:
                    // Deliberately still a fetch. The round begins by checking the account
                    // and will report the real state; acting on the hint directly would be
                    // a second, competing opinion about whether the user is signed in.
                    self.syncNow(trigger: .retry)
                }
            }
        }
    }

    private func publish(_ newState: SyncEngine.State) {
        state = newState
        Diagnostics.record(.syncState(
            Self.diagnosticState(for: newState),
            haltReason: Self.diagnosticHaltReason(for: newState)))
        onStateChange?(newState)
    }

    private static func diagnosticState(for state: SyncEngine.State) -> DiagnosticSyncState {
        switch state {
        case .disabled: .disabled
        case .idle(let lastSync): lastSync == nil ? .idle : .synced
        case .syncing: .syncing
        case .offline, .waitingForVault: .waiting
        case .needsAuthentication: .failed
        case .halted: .halted
        }
    }

    private static func diagnosticHaltReason(
        for state: SyncEngine.State
    ) -> DiagnosticSyncHaltReason? {
        guard case .halted(let reason, _) = state else { return nil }
        return switch reason {
        case .massDeletion: .destructiveChange
        case .backendRefused: .accountRequiresReview
        case .schemaTooNew, .manifestIntegrityFailed,
             .localLibraryQuarantined, .vaultUnreadable: .incompatibleState
        }
    }

    // MARK: - Presentation

    /// One sentence for the settings pane. Deliberately here rather than in the view, so
    /// the state and the words for it cannot drift apart.
    var statusDescription: String {
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
