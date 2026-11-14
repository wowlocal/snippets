import CryptoKit
import Darwin
import Foundation
import IOKit
import LocalAuthentication
import OpenDirectory
import Security

/// Owns the per-Mac switch for terminal reveals and the password check behind them.
///
/// ## What this trades away, stated plainly
///
/// The desktop reveal needs someone at this Mac: a click on Snippets' own consent window
/// and then Touch ID or the login password in the system sheet. A terminal reveal needs
/// only a shell running as this user and the macOS login password. So while it is on,
/// **anything that can run commands as you and has learned your password can reveal
/// every secure snippet, one request at a time** — including a program that captured
/// the password when you typed it to reveal just one. Per-reveal authentication does not
/// make the password single-use, and the rate limit only slows extraction.
///
/// That is why it is off by default, enabled separately on each Mac, enabled only after
/// Touch ID or the login password in the system sheet, and recorded as an HMAC under the
/// vault key (`TerminalRevealAuthorization`) rather than as a preference another process
/// could write. Repeated wrong passwords switch it off again, and that count survives
/// an app restart.
///
/// ## Where the record lives
///
/// See `TerminalRevealKeychainStore`. The HMAC stops a same-user process *forging* the
/// switch; the store is what stops it *replaying* a genuine record after the owner turned
/// the feature off, or resetting the wrong-password count.
@MainActor
final class TerminalRevealAccess {

    static let didChangeNotification = Notification.Name("SnippetsTerminalRevealAccessDidChange")

    /// Consecutive wrong passwords after which the feature switches itself off and must
    /// be turned on again at this Mac. Low on purpose: a person mistyping five times in a
    /// row is rare, and a guesser holding a shell is exactly what this mode admits.
    static let maximumConsecutiveFailures = 5

    static let recordAccount = "terminal-reveal-v1"
    static let failuresAccount = "terminal-reveal-failures-v1"

    enum Failure: Error, CustomStringConvertible {
        case noVault
        case deviceUnidentified
        case authorizationInvalid
        case authorizationUnavailable
        case authorizationAbsent

        var description: String {
            switch self {
            case .noVault: "Set up Secure Snippets first."
            case .deviceUnidentified: "This Mac's hardware identifier could not be read."
            case .authorizationInvalid: "The terminal reveal authorization on this Mac is not valid."
            case .authorizationUnavailable: "Terminal access could not be confirmed right now."
            case .authorizationAbsent: "Terminal access is off on this Mac."
            }
        }
    }

    /// Outcome of checking the typed password with Open Directory.
    enum PasswordCheck: Sendable, Equatable {
        case accepted
        /// The password was wrong. Counts towards switching the feature off.
        case rejected
        /// The account could not authenticate at all right now (locked by policy,
        /// expired password, directory unavailable). Refused, but not counted: the
        /// person typing may well have the right password.
        case unavailable
    }

    /// Outcome of verifying the stored switch under the vault key.
    enum AuthorizationCheck: Equatable {
        case valid
        /// Present and readable but not ours: forged, replayed from another vault or
        /// Mac, or corrupt. Removed and logged as a revocation.
        case invalid
        /// Gone since the request started (turned off meanwhile).
        case absent
        /// Could not be read or evaluated right now (keychain error, no hardware id).
        /// Refused, but not treated as tampering.
        case unavailable
    }

    private let store: any TerminalRevealRecordStoring
    private let deviceIdentifier: () -> String?
    private let passwordVerifier: @Sendable (Data) async -> PasswordCheck

    init(
        store: any TerminalRevealRecordStoring = TerminalRevealKeychainStore(),
        deviceIdentifier: @escaping () -> String? = TerminalRevealAccess.platformUUID,
        passwordVerifier: @escaping @Sendable (Data) async -> PasswordCheck = { password in
            await Task.detached(priority: .userInitiated) {
                TerminalRevealAccess.verifyLoginPassword(password)
            }.value
        }
    ) {
        self.store = store
        self.deviceIdentifier = deviceIdentifier
        self.passwordVerifier = passwordVerifier
    }

    // MARK: - State

    /// Whether a well-formed record is present and the wrong-password limit has not been
    /// reached. Unverified: good enough for Settings and for the CLI's preflight, never
    /// for authorising a reveal (see `authorization`).
    var isEnabled: Bool {
        guard let data = try? store.load(account: Self.recordAccount),
              TerminalRevealAuthorization.decode(data) != nil
        else { return false }
        // The count is enforced here as well as by deleting the record, so a record
        // that could not be deleted still stops working.
        return consecutiveFailures < Self.maximumConsecutiveFailures
    }

    /// Wrong passwords since the last success or enablement. Unreadable counts as the
    /// limit: fail closed rather than hand out fresh guesses.
    var consecutiveFailures: Int {
        do {
            guard let data = try store.load(account: Self.failuresAccount) else { return 0 }
            return data.first.map(Int.init) ?? Self.maximumConsecutiveFailures
        } catch {
            return Self.maximumConsecutiveFailures
        }
    }

    /// Turns the feature on after a fresh system authentication. The one-use unlock ends
    /// any open in-app window, which is the price of not letting a stale unlock from an
    /// hour ago enable something this consequential.
    func enable(session: VaultSession, secureStore: SecureSnippetStore) async throws {
        guard let document = secureStore.document, let salt = document.vaultSaltBytes else {
            throw Failure.noVault
        }
        let binding = try binding(vaultKID: document.kid)
        try await session.withOneUseAuthentication(
            reason: "Allow secure snippets to be revealed from the terminal"
        ) {
            let record = TerminalRevealAuthorization.issue(
                keyring: try session.keyring(vaultSalt: salt), binding: binding)
            // Counter first: a record must never become valid alongside a stale count.
            try store.remove(account: Self.failuresAccount)
            try store.replace(try record.encoded(), account: Self.recordAccount)
        }
        Diagnostics.record(.vaultAction(.terminalRevealEnabled, count: nil))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    /// Turns the feature off. Needs no authentication: it only ever narrows access.
    /// Throws when the record is still there afterwards, so "off" is never claimed
    /// falsely; the failure counter is left alone so a lockout stays a lockout.
    func disable(revoked: Bool = false) throws {
        let wasPresent = (try? store.load(account: Self.recordAccount)) != nil
        defer {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
        }
        try store.remove(account: Self.recordAccount)
        if wasPresent || revoked {
            Diagnostics.record(.vaultAction(
                revoked ? .terminalRevealRevoked : .terminalRevealDisabled, count: nil))
        }
    }

    // MARK: - Reveal-time checks

    /// Checks the typed password for the account this app runs as.
    func checkPassword(_ password: Data) async -> PasswordCheck {
        await passwordVerifier(password)
    }

    /// Records a wrong password durably. Returns `true` when the feature is now off,
    /// including when the count could not be stored (fail closed).
    func recordRejectedPassword() -> Bool {
        let count = min(consecutiveFailures + 1, Self.maximumConsecutiveFailures)
        do {
            try store.replace(Data([UInt8(count)]), account: Self.failuresAccount)
        } catch {
            try? disable(revoked: true)
            return true
        }
        guard count >= Self.maximumConsecutiveFailures else { return false }
        try? disable(revoked: true)
        return true
    }

    func recordSuccess() {
        try? store.remove(account: Self.failuresAccount)
    }

    /// Verifies the stored record against the vault key now loaded for this one reveal.
    /// Read fresh from the store every time, never from a cache.
    func authorization(keyring: SnippetCrypto.Keyring, vaultKID: String) -> AuthorizationCheck {
        let data: Data
        do {
            guard let stored = try store.load(account: Self.recordAccount) else { return .absent }
            data = stored
        } catch {
            return .unavailable
        }
        guard let device = deviceIdentifier(), !device.isEmpty else { return .unavailable }
        guard let record = TerminalRevealAuthorization.decode(data) else { return .invalid }
        let binding = TerminalRevealAuthorization.Binding(
            vaultKID: vaultKID, userID: UInt32(getuid()), deviceID: device)
        return record.isValid(keyring: keyring, binding: binding) ? .valid : .invalid
    }

    private func binding(vaultKID: String) throws -> TerminalRevealAuthorization.Binding {
        guard let device = deviceIdentifier(), !device.isEmpty else { throw Failure.deviceUnidentified }
        return TerminalRevealAuthorization.Binding(
            vaultKID: vaultKID, userID: UInt32(getuid()), deviceID: device)
    }

    // MARK: - System boundaries

    /// The IOKit platform UUID. Read only to bind the authorization to this Mac; it is
    /// never logged, exported or written anywhere in the clear.
    nonisolated static func platformUUID() -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(
            service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String
    }

    /// Verifies the login password of the account this process runs as, through Open
    /// Directory: no `sudo`, no privileged helper, and the account's own policies
    /// (failed-attempt lockout, disabled or expired accounts) still apply. Blocking, so
    /// callers run it off the main actor.
    ///
    /// The record is looked up by the short name and then required to carry this
    /// process's numeric uid, so a directory with a colliding name cannot stand in.
    nonisolated static func verifyLoginPassword(_ password: Data) -> PasswordCheck {
        guard !password.isEmpty,
              password.count <= SnippetsIPC.Request.maximumPasswordBytes,
              let text = String(data: password, encoding: .utf8)
        else { return .rejected }
        do {
            let node = try ODNode(
                session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(
                withRecordType: kODRecordTypeUsers,
                name: NSUserName(),
                attributes: [kODAttributeTypeUniqueID])
            let uids = try record.values(forAttribute: kODAttributeTypeUniqueID)
                .compactMap { $0 as? String }
            guard uids == [String(getuid())] else { return .unavailable }
            try record.verifyPassword(text)
            return .accepted
        } catch let error as NSError {
            // Only "these credentials are wrong" counts as a guess. Never reflect the
            // error itself: it can describe the account.
            return error.code == Int(kODErrorCredentialsInvalid.rawValue) ? .rejected : .unavailable
        }
    }
}

// MARK: - Storage

/// Durable storage for the switch and the wrong-password count. Injected so tests never
/// touch the user's keychain.
protocol TerminalRevealRecordStoring {
    func load(account: String) throws -> Data?
    /// Leaves exactly one item, created by this app, holding `data`.
    func replace(_ data: Data, account: String) throws
    /// Leaves no item. Throws if one is still there afterwards.
    func remove(account: String) throws
}

/// A device-only keychain item that other same-user processes cannot read, plant or
/// roll back.
///
/// - **With the app's keychain access group** (every signed build that can sync): the
///   data-protection keychain, in that group, `kSecAttrSynchronizable = false`,
///   `AfterFirstUnlockThisDeviceOnly`. Only binaries entitled to the group can read,
///   create or delete items there, so a record cannot be copied out and replayed after
///   the owner turns the feature off, and the failure count cannot be reset. Never the
///   synchronizable tier: the choice is per Mac.
/// - **Without it** (entitlement-free builds): the login keychain. Items are always
///   deleted and re-created, never updated, because an update keeps the access list
///   of whatever item was there — and a same-user process can pre-create one open to
///   every application. Re-created items trust only this app. This tier is weaker: a
///   process that knows the login password can read the keychain file offline. The
///   docs say so.
struct TerminalRevealKeychainStore: TerminalRevealRecordStoring {
    enum Location: Equatable {
        case dataProtection(accessGroup: String)
        case loginKeychain
    }

    struct KeychainFailure: Error, CustomStringConvertible {
        let status: OSStatus
        var description: String { "the keychain refused the request (\(status))" }
    }

    let service = "com.khm.snippets.terminal-reveal"
    let location: Location

    init(location: Location? = nil) {
        if let location {
            self.location = location
        } else if case .synchronizable(let group) = KeychainSecretStore.detectTier() {
            self.location = .dataProtection(accessGroup: group)
        } else {
            self.location = .loginKeychain
        }
    }

    private func query(_ account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        switch location {
        case .dataProtection(let group):
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = group
            query[kSecAttrSynchronizable as String] = false
        case .loginKeychain:
            break
        }
        // A headless request must never raise a keychain dialog on a desktop nobody
        // is watching, blocking the main thread until someone answers it.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        return query
    }

    func load(account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainFailure(status: status)
        }
    }

    func replace(_ data: Data, account: String) throws {
        try remove(account: account)
        var attributes = query(account)
        // Only reads and deletes run headless; enabling happens at the desktop.
        attributes[kSecUseAuthenticationContext as String] = nil
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // errSecDuplicateItem means something re-created the item between the delete
        // and the add. Refuse rather than adopt an item this app did not create.
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
    }

    func remove(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainFailure(status: status)
        }
        // Prove it. An item whose access list refuses deletion must not let "off"
        // report success. Attributes only: no decryption, so no access prompt.
        var probe = query(account)
        probe[kSecReturnAttributes as String] = true
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        let remaining = SecItemCopyMatching(probe as CFDictionary, nil)
        guard remaining == errSecItemNotFound else { throw KeychainFailure(status: remaining) }
    }
}
