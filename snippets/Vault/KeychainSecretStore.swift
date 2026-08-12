import Foundation
import Security

/// Injectable Security.framework boundary shared by the production keychain stores.
///
/// Keeping the exact C-shaped calls here lets tests inspect queries and updates without
/// touching a simulator's real keychain. Production uses `live`, which is only a thin
/// forwarding layer and does not change Security.framework's ownership rules.
nonisolated struct KeychainItemOperations: @unchecked Sendable {
    let copyMatching: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let update: (CFDictionary, CFDictionary) -> OSStatus
    let add: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus
    let delete: (CFDictionary) -> OSStatus

    init(
        copyMatching: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        update: @escaping (CFDictionary, CFDictionary) -> OSStatus,
        add: @escaping (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus,
        delete: @escaping (CFDictionary) -> OSStatus
    ) {
        self.copyMatching = copyMatching
        self.update = update
        self.add = add
        self.delete = delete
    }

    static let live = KeychainItemOperations(
        copyMatching: { query, result in SecItemCopyMatching(query, result) },
        update: { query, values in SecItemUpdate(query, values) },
        add: { attributes, result in SecItemAdd(attributes, result) },
        delete: { query in SecItemDelete(query) })
}

/// Holds the small items that have to reach a user's other Macs, in the macOS Keychain.
///
/// This is the primary home of `K_lib`. The wraps in `vault.json` are escape hatches;
/// on the machine that created a vault, this is what opens it. It also carries the wire
/// key and the vault's identity — see the note above `storeItem`.
///
/// ## Two tiers, chosen at runtime
///
/// macOS has two keychains, and only one of them is free:
///
/// - **The file-based login keychain** needs no entitlement at all. A non-sandboxed
///   Developer ID app can simply use it. The key is protected by the login keychain,
///   but it never leaves this Mac.
/// - **The data-protection keychain** is the only one that supports
///   `kSecAttrSynchronizable`, which is what makes iCloud Keychain carry the key to a
///   user's other Macs and to a future iPhone. It requires an `application-identifier`,
///   which in practice means `keychain-access-groups` plus an embedded provisioning
///   profile plus Keychain Sharing enabled on the App ID in the developer portal.
///
/// So the tier is decided by asking the running binary what it is actually entitled to,
/// rather than by a build flag. The same binary does the local-only tier today and the
/// synchronizable tier the moment the entitlement appears, with no code change and no
/// migration beyond re-storing one key. Secure snippets work fully in both; only
/// *syncing* them needs the second.
///
/// Touch ID is deliberately not an item attribute. `SecAccessControl` routes a generic
/// password through the data-protection keychain even when the query otherwise names
/// the login keychain, which makes the entitlement-free tier fail with
/// `errSecMissingEntitlement`. It is also incompatible with a synchronizable item. The
/// vault session evaluates the human-presence policy before asking this type for bytes.
@MainActor
final class KeychainSecretStore {

    enum Tier: Equatable {
        /// Login keychain. Works everywhere, never leaves this Mac.
        case deviceOnly
        /// Data-protection keychain with `kSecAttrSynchronizable`, in the given access
        /// group. Rides iCloud Keychain to the user's other devices.
        case synchronizable(accessGroup: String)

        var syncsBetweenDevices: Bool {
            if case .synchronizable = self { return true }
            return false
        }
    }

    enum Failure: Error, CustomStringConvertible {
        case unavailable(OSStatus)
        case notFound
        case invalidKeyLength(Int)
        case invalidItemLength(expected: Int, actual: Int)
        case authenticationFailed
        case userCancelled

        var description: String {
            switch self {
            case .unavailable(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "the keychain refused the request: \(detail) (\(status))"
            case .notFound: return "no vault key is stored on this device"
            case .invalidKeyLength(let count):
                return "the stored vault key must be 32 bytes; found \(count)"
            case .invalidItemLength(let expected, let actual):
                return "the stored keychain item must be \(expected) bytes; found \(actual)"
            case .authenticationFailed: return "authentication failed"
            case .userCancelled: return "authentication was cancelled"
            }
        }
    }

    private let service: String
    private let keychainOperations: KeychainItemOperations
    /// Instance-local test backend. Production always leaves this `nil` and reaches
    /// Security.framework; unsigned simulator tests can exercise vault ordering without
    /// requiring or mutating a real keychain access group.
    private var inMemoryItems: [String: Data]?
    let tier: Tier

    init(
        tier: Tier? = nil,
        service: String = "com.khm.snippets.vault",
        inMemory: Bool = false,
        keychainOperations: KeychainItemOperations = .live
    ) {
        self.tier = tier ?? Self.detectTier()
        self.service = service
        self.inMemoryItems = inMemory ? [:] : nil
        self.keychainOperations = keychainOperations
    }

    // MARK: - Which tier this build actually gets

    /// Reads the running binary's own entitlements rather than guessing.
    ///
    /// A build flag would be wrong in both directions: a developer build signed without
    /// the capability would claim the synchronizable tier and fail at runtime, and a
    /// build made before the portal work would keep claiming the local tier long after
    /// the entitlement arrived. `SecCodeCopySelf` asks the only authority that matters.
    static func detectTier() -> Tier {
        #if os(iOS)
        // SecCode is macOS-only. The iPad target injects the expanded access group
        // through Info.plist from the same build setting used by its entitlement.
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "SnippetsKeychainAccessGroup") as? String,
              !group.isEmpty,
              !group.contains("$(")
        else { return .deviceOnly }
        return .synchronizable(accessGroup: group)
        #else
        guard let applicationIdentifier = selfEntitlement(
                  forKey: "com.apple.application-identifier") as? String,
              !applicationIdentifier.isEmpty,
              let groups = selfEntitlement(forKey: "keychain-access-groups") as? [String],
              let group = groups.first(where: { !$0.isEmpty && !$0.contains("*") })
        else { return .deviceOnly }
        return .synchronizable(accessGroup: group)
        #endif
    }

    #if os(macOS)
    static func selfEntitlement(forKey key: String) -> Any? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let entitlements = dictionary["entitlements-dict"] as? [String: Any]
        else { return nil }

        return entitlements[key]
    }
    #endif

    // MARK: - Storing and reading items

    // Three kinds of item live here. They share the service and the tier and are told
    // apart only by their account name:
    //
    // - the vault library key `K_lib`, account = the vault's `kid`, 32 bytes;
    // - the wire key `K_sync`, account = `SyncKeyStore.account`, 64 bytes;
    // - the vault identity, account = `VaultIdentityStore.account`, a JSON document.
    //
    // Only the first is a secret this app's threat model is built around. The other two
    // are here because this is the one channel already known to reach the user's other
    // Macs, and because a second mechanism would be a second thing to get wrong. The
    // identity in particular holds nothing secret at all — a salt, KDF parameters, and
    // wraps that are themselves useless without the key that opens them.

    /// Writes an item without a delete-first window. If replacement fails, the previous
    /// value is still present.
    func storeItem(_ data: Data, account: String) throws {
        if inMemoryItems != nil {
            inMemoryItems?[account] = data
            return
        }
        let query = baseQuery(account: account)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility(for: account),
        ]

        let update = keychainOperations.update(query as CFDictionary, values as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            for (name, value) in values { attributes[name] = value }
            let add = keychainOperations.add(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw Failure.unavailable(add) }
        default:
            throw Failure.unavailable(update)
        }
    }

    /// Writes an item only if none exists, and returns whichever value ends up stored.
    ///
    /// This is how a value two Macs could each mint independently gets one winner:
    /// `SecItemAdd` reports `errSecDuplicateItem` rather than clobbering, so the loser
    /// adopts what is already there instead of overwriting it. It settles the race
    /// *within* a device only — two Macs that both add before iCloud Keychain has
    /// propagated either are outside what a keychain call can arbitrate. See
    /// `SyncKeyStore` for what is done about that.
    @discardableResult
    func addItemIfAbsent(_ data: Data, account: String) throws -> Data {
        if let existing = inMemoryItems?[account] { return existing }
        if inMemoryItems != nil {
            inMemoryItems?[account] = data
            return data
        }
        if let existing = try loadItem(account: account) { return existing }

        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = accessibility(for: account)

        let add = keychainOperations.add(attributes as CFDictionary, nil)
        switch add {
        case errSecSuccess:
            return data
        case errSecDuplicateItem:
            // Someone stored one between the read above and this add. Theirs wins;
            // returning ours would mean two devices sealing under different keys.
            guard let existing = try loadItem(account: account) else {
                throw Failure.unavailable(add)
            }
            return existing
        default:
            throw Failure.unavailable(add)
        }
    }

    /// Reads an item, or `nil` when there is none. If this build newly gained the sync
    /// entitlement, an existing device-only item is copied into the new tier and
    /// verified before use.
    ///
    /// - Parameter expectedByteCount: the size this item must be, when the caller knows
    ///   it. **Checked before the migration write, not after**, and that ordering is the
    ///   whole point of the parameter. The migration copies a device-only item into the
    ///   `kSecAttrSynchronizable` tier, from which iCloud Keychain hands it to every
    ///   other Mac on the account — so validating afterwards would mean a truncated local
    ///   key item (an interrupted keychain write, a partial backup restore) is propagated
    ///   over the good copies its siblings already hold, turning one unopenable vault into
    ///   all of them. An earlier version of this type enforced the length inside the read
    ///   itself for exactly that reason; this restores the guarantee without forcing every
    ///   item to be a 32-byte key.
    func loadItem(account: String, expectedByteCount: Int? = nil) throws -> Data? {
        func validated(_ data: Data) throws -> Data {
            if let expectedByteCount, data.count != expectedByteCount {
                throw Failure.invalidItemLength(
                    expected: expectedByteCount, actual: data.count)
            }
            return data
        }

        if let inMemoryItems {
            guard let value = inMemoryItems[account] else { return nil }
            return try validated(value)
        }

        let primaryQuery = baseQuery(account: account)
        if let current = try copyItem(matching: primaryQuery) {
            let data = try validated(current.data)
            try migrateAccessibilityIfNeeded(
                account: account,
                query: primaryQuery,
                currentAccessibility: current.accessibility)
            return data
        }

        guard case .synchronizable = tier,
              let legacy = try copyData(matching: deviceOnlyQuery(account: account))
        else { return nil }

        // Local damage stays local. Validation happens before the migration write.
        _ = try validated(legacy)

        try storeItem(legacy, account: account)
        guard let migrated = try copyData(matching: baseQuery(account: account)),
              migrated == legacy
        else {
            throw Failure.unavailable(errSecNotAvailable)
        }
        return try validated(migrated)
    }

    /// Whether an item exists, without reading its bytes. The legacy-tier fallback keeps
    /// an entitlement upgrade from making an existing vault look keyless.
    func hasItem(account: String) -> Bool {
        if let inMemoryItems { return inMemoryItems[account] != nil }
        if contains(baseQuery(account: account)) { return true }
        if case .synchronizable = tier { return contains(deviceOnlyQuery(account: account)) }
        return false
    }

    /// Removes an item from every tier it may be in.
    func deleteItem(account: String) throws {
        if inMemoryItems != nil {
            inMemoryItems?[account] = nil
            return
        }
        guard case .synchronizable = tier else {
            try deleteMatching(baseQuery(account: account))
            return
        }

        let primary = baseQuery(account: account)
        let legacy = deviceOnlyQuery(account: account)

        // Before deleting the fallback, prove whether the preferred copy exists.
        // An entitlement may appear before the first unlock has migrated the key;
        // in that state the fallback is the only copy and a failing DP-keychain
        // delete must not strand restored ciphertext without a key.
        if try itemExists(primary) {
            // Delete the fallback first and the preferred sync copy last. If
            // either operation throws, at least one usable copy remains.
            try deleteMatching(legacy)
            try deleteMatching(primary)
        } else {
            try deleteMatching(legacy)
        }
    }

    private func copyData(matching base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychainOperations.copyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.unavailable(status) }
            return data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled:
            throw Failure.userCancelled
        case errSecAuthFailed:
            throw Failure.authenticationFailed
        default:
            throw Failure.unavailable(status)
        }
    }

    private struct LoadedItem {
        var data: Data
        var accessibility: String?
    }

    /// Reads bytes and their protection class in one operation so a load can migrate
    /// only a stale protection attribute. The returned bytes are validated by the
    /// caller before any update is attempted.
    private func copyItem(matching base: [String: Any]) throws -> LoadedItem? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = keychainOperations.copyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let attributes = item as? [String: Any],
                  let data = attributes[kSecValueData as String] as? Data
            else { throw Failure.unavailable(status) }
            return LoadedItem(
                data: data,
                accessibility: attributes[kSecAttrAccessible as String] as? String)
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled:
            throw Failure.userCancelled
        case errSecAuthFailed:
            throw Failure.authenticationFailed
        default:
            throw Failure.unavailable(status)
        }
    }

    private func migrateAccessibilityIfNeeded(
        account: String,
        query: [String: Any],
        currentAccessibility: String?
    ) throws {
        let required = accessibility(for: account)
        guard currentAccessibility != required as String else { return }
        let status = keychainOperations.update(
            query as CFDictionary,
            [kSecAttrAccessible as String: required] as CFDictionary)
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }

    private func deleteMatching(_ query: [String: Any]) throws {
        let status = keychainOperations.delete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw Failure.unavailable(status)
        }
    }

    // MARK: - The library key

    // The length guard lives here rather than on the generic item path: 32 bytes is a
    // property of `K_lib` specifically, and a wrong-sized *key* is a corruption worth
    // refusing loudly, where a wrong-sized item in general is just an item.

    /// Writes the library key. See `storeItem` for the no-delete-first ordering.
    func store(_ key: Data, keyID: String) throws {
        guard key.count == 32 else { throw Failure.invalidKeyLength(key.count) }
        try storeItem(key, account: keyID)
    }

    /// Reads the library key after `VaultSession` has authenticated the user.
    func loadKey(keyID: String) throws -> Data {
        let data: Data
        do {
            guard let loaded = try loadItem(account: keyID, expectedByteCount: 32) else {
                throw Failure.notFound
            }
            data = loaded
        } catch Failure.invalidItemLength(_, let actual) {
            throw Failure.invalidKeyLength(actual)
        }
        guard data.count == 32 else { throw Failure.invalidKeyLength(data.count) }
        return data
    }

    func hasKey(keyID: String) -> Bool { hasItem(account: keyID) }

    /// Removes the key. The vault's ciphertext is untouched and stays openable with a
    /// recovery key or passphrase if the user set either up.
    func deleteKey(keyID: String) throws { try deleteItem(account: keyID) }

    // MARK: - Query construction

    /// Vault and identity items stay `WhenUnlocked`; only the fixed wire-key account is
    /// available after first unlock so CKSyncEngine can run while the device is locked.
    /// Local-tier variants remain device-only, while a synchronizable item cannot use a
    /// `ThisDeviceOnly` protection class by definition.
    private func accessibility(for account: String) -> CFString {
        if account == SyncKeyStore.account {
            return tier.syncsBetweenDevices
                ? kSecAttrAccessibleAfterFirstUnlock
                : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return tier.syncsBetweenDevices
            ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private func baseQuery(account: String) -> [String: Any] {
        var query = deviceOnlyQuery(account: account)

        switch tier {
        case .deviceOnly:
            // Deliberately NOT the data-protection keychain: without an
            // application-identifier it returns errSecMissingEntitlement (-34018).
            break
        case .synchronizable(let accessGroup):
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecAttrSynchronizable as String] = true
        }
        return query
    }

    private func deviceOnlyQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func contains(_ base: [String: Any]) -> Bool {
        (try? itemExists(base)) == true
    }

    private func itemExists(_ base: [String: Any]) throws -> Bool {
        var query = base
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = keychainOperations.copyMatching(query as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw Failure.unavailable(status)
        }
    }
}

extension KeychainSecretStore {
    /// One line for the settings pane, so the tier is visible rather than mysterious.
    var statusDescription: String {
        switch tier {
        case .deviceOnly:
            return "Secure snippets stay on this device. Syncing them needs the iCloud Keychain entitlement."
        case .synchronizable:
            return "Secure snippets can sync to your other devices through iCloud Keychain."
        }
    }
}
