import Foundation

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
//
// Foundation only. **No Security.framework here, on purpose** — see the protocol's
// doc comment: the real Keychain implementation lives app-side and is deliberately
// not part of this module.

/// Somewhere to keep a named 32-byte secret.
///
/// ## Why this is a protocol rather than a direct Keychain call
///
/// Not for tidiness, and not "in case we swap the backend one day". It is the only
/// way this module can be tested at all.
///
/// `swift test` builds an **unsigned** binary. An unsigned process has no keychain-
/// access-group entitlement, so every `SecItemAdd`/`SecItemCopyMatching` it makes
/// returns `errSecMissingEntitlement` (-34018) — not "item not found", which could be
/// handled, but a hard failure on every call. Any test that reached the real Keychain
/// would therefore fail on a clean checkout, on CI, and on the author's machine, for
/// a reason that has nothing to do with the code under test. Worse, the obvious
/// workaround — sign the test bundle — makes the tests write into the *developer's
/// own login keychain*, where they would collide with the running app's live secrets.
///
/// So the split is: everything in this module takes a `SecretStore`, tests pass
/// `InMemorySecretStore`, and the one `SecItem*` call site is app-side where it can be
/// exercised by a signed build.
///
/// ## What a secret is
///
/// Exactly `SecretStoreLimits.secretByteCount` bytes of key material — a wrapping key
/// for `VaultDocument.wrapCLI`, or similar. Never a passphrase, never anything a human
/// typed. `Data` rather than `SymmetricKey` so this file needs no CryptoKit and so the
/// bytes stay in one representation from the store to the AEAD call.
///
/// ## On zeroing
///
/// It cannot be done reliably in Swift and this protocol does not pretend otherwise.
/// `Data` may be copied by the runtime (CoW, bridging, growth) and `String` is worse —
/// small strings live inline in registers and stack slots that nothing can reach. The
/// mitigation that actually works is *scope*: keep key material as `Data`, hold it for
/// as short a time as possible, and convert to `String` only at the final hop where
/// the plaintext is handed to the pasteboard or the keystroke synthesizer.
nonisolated protocol SecretStore: Sendable {

    /// The secret stored under `name`, or `nil` if there is none.
    ///
    /// Absence is a return value rather than an error because it is the ordinary
    /// first-run state: the user has not opted into headless CLI reveal yet. Throwing
    /// is reserved for "the store itself did not work", which is a completely
    /// different thing to tell the user about.
    func secret(named name: String) throws -> Data?

    /// Stores `secret` under `name`, replacing any existing value.
    ///
    /// Implementations must reject anything that is not
    /// `SecretStoreLimits.secretByteCount` bytes — see `SecretStoreError.wrongLength`.
    func setSecret(_ secret: Data, named name: String) throws

    /// Removes the secret under `name`. Deleting one that is not there succeeds:
    /// the postcondition the caller wants is "there is no secret under this name".
    func deleteSecret(named name: String) throws
}

nonisolated enum SecretStoreLimits {
    /// 256 bits. Every key this project wraps or derives is this size.
    static let secretByteCount = 32
}

nonisolated enum SecretStoreError: Error, Equatable, CustomStringConvertible {
    case wrongLength(expected: Int, actual: Int)
    case emptyName
    /// The backing store failed. `status` carries an `OSStatus` where the
    /// implementation has one; this module never interprets it.
    case unavailable(detail: String, status: Int32?)

    var description: String {
        switch self {
        case .wrongLength(let expected, let actual):
            return "a stored secret must be exactly \(expected) bytes; got \(actual)"
        case .emptyName:
            return "a secret must be stored under a non-empty name"
        case .unavailable(let detail, let status):
            guard let status else { return detail }
            return "\(detail) (status \(status))"
        }
    }
}

nonisolated extension SecretStore {

    /// `secret(named:)`, but absence is an error.
    ///
    /// For the call sites where "there is no secret" is already known to be
    /// impossible — an unlock path reached only because `wrapCLI` is non-nil — so that
    /// a missing entry surfaces as a real error rather than an optional that gets
    /// `?? Data()`d into a silent authentication failure.
    func requireSecret(named name: String) throws -> Data {
        guard let secret = try secret(named: name) else {
            throw SecretStoreError.unavailable(
                detail: "no secret is stored under '\(name)'", status: nil)
        }
        return secret
    }

    /// Shared validation, so every implementation rejects the same inputs.
    ///
    /// Implementations call this first. Length is checked at the *store* rather than
    /// only at the reader because a 31-byte or 33-byte key written once is a vault
    /// that fails to unlock forever after, and the failure surfaces nowhere near the
    /// bug.
    func validate(_ secret: Data, named name: String) throws {
        guard !name.isEmpty else { throw SecretStoreError.emptyName }
        guard secret.count == SecretStoreLimits.secretByteCount else {
            throw SecretStoreError.wrongLength(
                expected: SecretStoreLimits.secretByteCount, actual: secret.count)
        }
    }
}

/// The `SecretStore` every test uses, and the one the app falls back to when the user
/// has declined keychain access.
///
/// Falling back to this rather than to a file is the point: secrets held here die with
/// the process. A "temporary" on-disk fallback is how key material ends up in a Time
/// Machine backup, which is one of the few things the vault's threat model actually
/// claims to defend against.
nonisolated final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    /// `swift test` runs suites in parallel and a store may be shared by a test's own
    /// concurrent work. An `NSLock` rather than an actor because `SecretStore` is
    /// synchronous — the call sites are inside synchronous file and merge paths that
    /// cannot suspend.
    private let lock = NSLock()
    private var storage: [String: Data]

    /// Set to make every operation fail, for exercising the "keychain unavailable"
    /// branch without a keychain. Reads and writes of this are lock-protected too, so
    /// a test may flip it while work is in flight.
    private var stubbedFailure: SecretStoreError?

    init(_ initial: [String: Data] = [:]) {
        storage = initial
    }

    func failEveryOperation(with failure: SecretStoreError?) {
        lock.lock()
        defer { lock.unlock() }
        stubbedFailure = failure
    }

    /// The names currently held, sorted. Diagnostics for tests; never a decision input.
    var storedNames: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.keys.sorted()
    }

    func secret(named name: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        if let stubbedFailure { throw stubbedFailure }
        return storage[name]
    }

    func setSecret(_ secret: Data, named name: String) throws {
        try validate(secret, named: name)
        lock.lock()
        defer { lock.unlock() }
        if let stubbedFailure { throw stubbedFailure }
        storage[name] = secret
    }

    func deleteSecret(named name: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if let stubbedFailure { throw stubbedFailure }
        storage[name] = nil
    }
}
