import AppKit
import CryptoKit
import LocalAuthentication

/// Owns "is the vault open right now", and the library key while it is.
///
/// ## The auto-lock rules are shaped by what this app is
///
/// The obvious trigger — lock when the app resigns active — would be **catastrophic
/// here and correct almost anywhere else**. Snippets expands text *into other
/// applications*: by construction, every moment a secure snippet is actually useful is
/// a moment some other app is frontmost. Locking on resign-active would mean the vault
/// is open exactly when it cannot be used and shut the instant it can. So the triggers
/// below are the ones that genuinely mean "the user has stepped away": the screen
/// locked, the machine slept, the session ended, or the window simply expired.
///
/// ## What an unlock actually protects
///
/// Not much against someone sitting at the unlocked Mac — they can authenticate. The
/// window exists so that a secret is not readable for the rest of the login session
/// after one Touch ID tap hours ago, and so that "reveal" is a deliberate act rather
/// than ambient state. That is worth having and worth not overselling.
@MainActor
final class VaultSession {

    enum State: Equatable {
        /// No vault key exists on this Mac yet — the feature has never been set up, or
        /// the key was lost and only a recovery key or passphrase can bring it back.
        case noKey
        case locked
        case unlocked(until: Date)

        var isUnlocked: Bool { if case .unlocked = self { return true }; return false }
    }

    enum Failure: Error, CustomStringConvertible {
        case locked
        case noKey
        case authentication(String)
        case keychain(String)

        var description: String {
            switch self {
            case .locked: return "the vault is locked"
            case .noKey: return "no vault key is available on this Mac"
            case .authentication(let detail): return detail
            case .keychain(let detail): return detail
            }
        }
    }

    /// How long an unlock lasts. Long enough to expand several secrets in a row without
    /// re-authenticating; short enough that walking away closes it.
    ///
    /// `nonisolated` so it can be a default argument on `init`, which is evaluated at
    /// the call site and therefore outside this type's actor.
    nonisolated static let defaultDuration: TimeInterval = 5 * 60

    private(set) var state: State = .locked
    var onStateChange: ((State) -> Void)?

    /// Injected so the expiry is testable without waiting five minutes.
    var now: () -> Date = { Date() }

    private let keychain: KeychainSecretStore
    private let duration: TimeInterval
    private var keyID: String?

    /// The plaintext key, held only while unlocked.
    ///
    /// Swift cannot guarantee this is scrubbed from memory when dropped — `SymmetricKey`
    /// does zero its own buffer on deinit, but any `Data` or `String` derived from it
    /// along the way is copied by value and out of reach. The honest claim is "we do not
    /// keep it around", not "it is gone".
    private var libraryKey: SymmetricKey?
    private var expiryTimer: Timer?

    /// Kept so a screen lock or explicit lock can cancel authentication already in
    /// flight. Once the session is open, `libraryKey` itself supplies the reuse window.
    private var authenticationContext: LAContext?

    /// - Parameter keychain: injected so tests can avoid the real keychain entirely.
    ///   Defaulted to `nil` rather than to `KeychainSecretStore()`, because a default
    ///   argument is evaluated at the call site — outside this type's actor — and
    ///   constructing a `@MainActor` type there does not typecheck.
    init(keychain: KeychainSecretStore? = nil, duration: TimeInterval = VaultSession.defaultDuration) {
        self.keychain = keychain ?? KeychainSecretStore()
        self.duration = duration
        observeSystemLockEvents()
    }

    deinit {
        expiryTimer?.invalidate()
    }

    // MARK: - Lifecycle

    /// Points the session at a vault. Call whenever the vault is created or reloaded.
    func adopt(keyID: String?) {
        self.keyID = keyID
        lock()
        refreshAvailability()
    }

    private func refreshAvailability() {
        guard let keyID, keychain.hasKey(keyID: keyID) else {
            transition(to: .noKey)
            return
        }
        if !state.isUnlocked { transition(to: .locked) }
    }

    var keychainStatusDescription: String { keychain.statusDescription }
    var syncsBetweenDevices: Bool { keychain.tier.syncsBetweenDevices }

    // MARK: - Unlocking

    /// Prompts for Touch ID (or the login password) and opens the vault.
    ///
    /// `reason` is shown in the system sheet and should name what is about to happen —
    /// "Reveal “AWS root password”" beats "Snippets wants to authenticate". A prompt the
    /// user cannot connect to an action is a prompt they learn to approve reflexively.
    @discardableResult
    func unlock(reason: String) async throws -> SymmetricKey {
        guard let keyID else { throw Failure.noKey }

        if case .unlocked(let until) = state, let libraryKey {
            if until > now() {
                extendWindow()
                return libraryKey
            }
            // The timer can be delayed while the main run loop is busy. The deadline,
            // not delivery of that timer callback, is the authority.
            lock()
        }

        // Do not stack two system prompts if two callers arrive while the actor is
        // suspended in LocalAuthentication.
        guard authenticationContext == nil else { throw Failure.locked }

        let context = LAContext()
        authenticationContext = context

        do {
            let authenticated = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason)
            guard authenticated else {
                if authenticationContext === context { authenticationContext = nil }
                throw Failure.authentication("authentication was not approved")
            }
            guard authenticationContext === context else { throw Failure.locked }
        } catch let failure as Failure {
            throw failure
        } catch {
            if authenticationContext === context { authenticationContext = nil }
            throw Failure.authentication(error.localizedDescription)
        }

        let data: Data
        do {
            data = try keychain.loadKey(keyID: keyID)
        } catch KeychainSecretStore.Failure.notFound {
            authenticationContext = nil
            transition(to: .noKey)
            throw Failure.noKey
        } catch {
            authenticationContext = nil
            throw Failure.keychain("\(error)")
        }

        let key = SymmetricKey(data: data)
        libraryKey = key
        extendWindow()
        return key
    }

    /// The key, if the vault is already open. Never prompts.
    ///
    /// This is what the expansion path uses: raising a modal authentication sheet while
    /// the user is mid-keystroke in another application steals focus and eats the very
    /// keystrokes being expanded. The caller must decide what to do when locked —
    /// see `SecureExpansionCoordinator`.
    func currentKey() throws -> SymmetricKey {
        guard case .unlocked(let until) = state, let libraryKey else {
            throw Failure.locked
        }
        guard until > now() else {
            // As in `unlock`, the deadline is authoritative even if the main run loop
            // has delayed delivery of the expiry timer. Drop the bytes and correct the
            // published state before refusing the read.
            lock()
            throw Failure.locked
        }
        return libraryKey
    }

    /// A keyring for the vault, valid only while unlocked.
    func keyring(vaultSalt: Data) throws -> SnippetCrypto.Keyring {
        SnippetCrypto.Keyring(libraryKey: try currentKey(), salt: vaultSalt)
    }

    // MARK: - Locking

    func lock() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        libraryKey = nil
        // Dropping the context is what actually ends the biometric reuse window; leaving
        // it alive would let a later prompt be skipped after we claimed to be locked.
        authenticationContext?.invalidate()
        authenticationContext = nil

        if case .noKey = state { return }
        transition(to: .locked)
    }

    private func extendWindow() {
        let deadline = now().addingTimeInterval(duration)
        expiryTimer?.invalidate()
        // Tolerance lets the system coalesce this with other timers; a few seconds of
        // slop on a five-minute window is irrelevant and saves wakeups.
        let timer = Timer(timeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        transition(to: .unlocked(until: deadline))
    }

    private func transition(to newState: State) {
        guard newState != state else { return }
        state = newState
        onStateChange?(newState)
        // Broadcast as well as calling the closure: the editor has to re-hide a revealed
        // secret when the vault locks, and most locks are not initiated by the editor —
        // they come from a timer, the screen locking, or the machine sleeping.
        NotificationCenter.default.post(name: .snippetsVaultStateChanged, object: nil)
    }

    // MARK: - System triggers

    /// Deliberately NOT `NSApplication.didResignActiveNotification`. See the type's
    /// documentation: this app is backgrounded precisely when a secure snippet is being
    /// used, so resign-active would lock the vault at the only moment it matters.
    private func observeSystemLockEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }

        // Screen lock has no AppKit notification; it is only published on the
        // distributed centre, and it is the trigger that matches "the user walked away"
        // most exactly.
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
    }
}


extension Notification.Name {
    static let snippetsVaultStateChanged = Notification.Name("com.khm.snippets.vaultStateChanged")
}
