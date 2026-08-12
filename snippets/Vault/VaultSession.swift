import CryptoKit
import Foundation
import LocalAuthentication
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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

    typealias AuthenticationEvaluator = @MainActor (_ reason: String) async throws -> Bool

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
            case .noKey: return "no vault key is available on this device"
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

    /// The longest the vault may stay open on one authentication, however much it is
    /// used. Without this the sliding window has no ceiling at all.
    nonisolated static let maximumWindow: TimeInterval = 30 * 60

    private(set) var state: State = .locked
    var onStateChange: ((State) -> Void)?

    /// Injected so the expiry is testable without waiting five minutes.
    var now: () -> Date = { Date() }

    private let keychain: KeychainSecretStore
    private let duration: TimeInterval
    private let authenticationEvaluator: AuthenticationEvaluator?
    private var keyID: String?

    /// The plaintext key, held only while unlocked.
    ///
    /// Swift cannot guarantee this is scrubbed from memory when dropped — `SymmetricKey`
    /// does zero its own buffer on deinit, but any `Data` or `String` derived from it
    /// along the way is copied by value and out of reach. The honest claim is "we do not
    /// keep it around", not "it is gone".
    private var libraryKey: SymmetricKey?

    /// When the user last actually proved presence. Distinct from the window deadline,
    /// which slides; this does not.
    private var authenticatedAt: Date?
    private var expiryTimer: Timer?
    private var isLocking = false
    private var isDeliveringPreLock = false

    /// Kept so a screen lock or explicit lock can cancel authentication already in
    /// flight. Once the session is open, `libraryKey` itself supplies the reuse window.
    private var authenticationContext: LAContext?

    /// - Parameter keychain: injected so tests can avoid the real keychain entirely.
    ///   Defaulted to `nil` rather than to `KeychainSecretStore()`, because a default
    ///   argument is evaluated at the call site — outside this type's actor — and
    ///   constructing a `@MainActor` type there does not typecheck.
    init(
        keychain: KeychainSecretStore? = nil,
        duration: TimeInterval = VaultSession.defaultDuration,
        authenticationEvaluator: AuthenticationEvaluator? = nil,
        lifecycleNotificationCenter: NotificationCenter = .default
    ) {
        self.keychain = keychain ?? KeychainSecretStore()
        self.duration = duration
        self.authenticationEvaluator = authenticationEvaluator
        observeSystemLockEvents(lifecycleNotificationCenter: lifecycleNotificationCenter)
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
                guard extendWindow() else { throw Failure.locked }
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
        // A fresh context should require fresh user presence. Make that contract
        // explicit rather than relying on LocalAuthentication's default reuse value.
        context.touchIDAuthenticationAllowableReuseDuration = 0
        authenticationContext = context

        do {
            let authenticated: Bool
            if let authenticationEvaluator {
                // Tests inject the smallest possible seam around LocalAuthentication.
                // Keychain reads and all session state transitions still use the
                // production path, so ordering and key lifetime remain exercised.
                authenticated = try await authenticationEvaluator(reason)
            } else {
                authenticated = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: reason)
            }
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

        var data: Data
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
        defer { SecureMemory.wipe(&data) }

        let key = SymmetricKey(data: data)
        libraryKey = key
        // Set BEFORE extendWindow, which reads it to compute the ceiling. A fresh touch
        // is what restarts the half-hour, so this is the one place it may move.
        authenticatedAt = now()
        guard extendWindow() else { throw Failure.locked }
        return key
    }

    /// Authenticates and exposes the unlocked vault to one synchronous operation only.
    ///
    /// Unlike `unlock`, this deliberately ignores the five-minute reveal window: an
    /// explicit secure expansion is a new disclosure and must ask every time. The
    /// previous key/context are discarded before the prompt, and the newly loaded key
    /// is discarded on every exit (success, cancellation, or thrown error).
    func withOneUseAuthentication<T>(
        reason: String,
        operation: @MainActor () throws -> T
    ) async throws -> T {
        // A retained context is normal while the session is already unlocked. A
        // context while still locked, however, belongs to an in-flight prompt; do not
        // invalidate somebody else's user-visible authentication attempt.
        if authenticationContext != nil, !state.isUnlocked {
            throw Failure.locked
        }

        lock()
        defer { lock() }
        _ = try await unlock(reason: reason)
        return try operation()
    }

    /// The key, if the vault is already open. Never prompts.
    ///
    /// This is what the expansion path uses: raising a modal authentication sheet while
    /// the user is mid-keystroke in another application is only safe after an explicit
    /// suggestion selection. `SnippetExpansionEngine` owns that authenticated path and
    /// revalidates the target and trigger after the prompt before inserting anything.
    func currentKey() throws -> SymmetricKey {
        guard case .unlocked(let until) = state, let libraryKey else {
            throw Failure.locked
        }
        // `lock()` gives editors one synchronous, in-process chance to persist an
        // already-visible secure edit before it destroys this key. A delayed expiry
        // timer may arrive just after its deadline, so the normal deadline check below
        // would otherwise make that hook useless and discard the final debounce window.
        // This flag exists only while `.snippetsVaultWillLock` observers are running;
        // no later run-loop turn can reuse it.
        if isDeliveringPreLock { return libraryKey }
        guard until > now() else {
            // As in `unlock`, the deadline is authoritative even if the main run loop
            // has delayed delivery of the expiry timer. Drop the bytes and correct the
            // published state before refusing the read.
            lock()
            throw Failure.locked
        }
        // Reading or changing secure content is actual vault use. Keep the short idle
        // window sliding while that work continues, but never beyond the fixed ceiling
        // measured from the authentication above. Merely keeping the app/process alive
        // does not call this method and therefore does not keep the vault open.
        guard extendWindow() else { throw Failure.locked }
        return libraryKey
    }

    /// A keyring for the vault, valid only while unlocked.
    func keyring(vaultSalt: Data) throws -> SnippetCrypto.Keyring {
        SnippetCrypto.Keyring(libraryKey: try currentKey(), salt: vaultSalt)
    }

    // MARK: - Locking

    func lock() {
        guard !isLocking else { return }
        isLocking = true
        defer {
            isDeliveringPreLock = false
            isLocking = false
        }

        // Deliver this while `libraryKey` is still resident. Secure editors use the
        // hook to synchronously flush their pending debounce; the ordinary state-change
        // notification remains after key destruction and clears revealed UI. Posting
        // only for a genuinely open session avoids spurious saves during adoption and
        // the first half of one-use authentication.
        if state.isUnlocked, libraryKey != nil {
            isDeliveringPreLock = true
            NotificationCenter.default.post(name: .snippetsVaultWillLock, object: self)
            isDeliveringPreLock = false
        }

        expiryTimer?.invalidate()
        expiryTimer = nil
        libraryKey = nil
        // Cleared with the key: the next unlock is a new authentication and gets a new
        // half-hour, and leaving a stale value would let a re-unlock inherit an almost
        // exhausted ceiling.
        authenticatedAt = nil
        // Dropping the context is what actually ends the biometric reuse window; leaving
        // it alive would let a later prompt be skipped after we claimed to be locked.
        authenticationContext?.invalidate()
        authenticationContext = nil

        if case .noKey = state { return }
        transition(to: .locked)
    }

    @discardableResult
    private func extendWindow() -> Bool {
        // The five-minute window slides on every use, so a session that is merely
        // *active* never expires — leave a Mac unattended with the app busy and the
        // vault stays open indefinitely. The absolute cap is measured from the touch
        // that actually authenticated, so no amount of subsequent activity can extend
        // the vault beyond half an hour without the user proving presence again.
        let currentTime = now()
        let ceiling = (authenticatedAt ?? currentTime).addingTimeInterval(Self.maximumWindow)
        let deadline = min(currentTime.addingTimeInterval(duration), ceiling)
        let remaining = deadline.timeIntervalSince(currentTime)

        expiryTimer?.invalidate()
        guard remaining > 0 else {
            // The cap has already passed; re-authenticating is the only way forward.
            lock()
            return false
        }

        // This timer removes both the visible plaintext and the in-memory key.
        // Do not opt into coalescing slack at the security deadline. A blocked
        // main run loop can still delay delivery, which is why every key access
        // independently enforces the stored deadline above.
        let timer = Timer(timeInterval: remaining, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
        if state.isUnlocked {
            // A changed deadline is not a lock-state transition. Broadcasting it would
            // make every secure read ask the editor to rebind, whose decrypt would read
            // the key again and recursively renew forever. Keep the public deadline
            // accurate without announcing a semantic state change.
            state = .unlocked(until: deadline)
        } else {
            transition(to: .unlocked(until: deadline))
        }
        return true
    }

    private func transition(to newState: State) {
        guard newState != state else { return }
        state = newState
        switch newState {
        case .locked:
            Diagnostics.record(.vaultAction(.locked, count: nil))
        case .unlocked:
            Diagnostics.record(.vaultAction(.unlocked, count: nil))
        case .noKey:
            break
        }
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
    private func observeSystemLockEvents(lifecycleNotificationCenter: NotificationCenter) {
        #if os(macOS)
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
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.lock() }
            }
        }
        #elseif os(iOS)
        lifecycleNotificationCenter.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lock() }
        }
        #endif
    }
}


extension Notification.Name {
    static let snippetsVaultWillLock = Notification.Name("com.khm.snippets.vaultWillLock")
    static let snippetsVaultStateChanged = Notification.Name("com.khm.snippets.vaultStateChanged")
}
