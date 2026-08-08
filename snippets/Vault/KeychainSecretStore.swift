import Foundation
import Security

/// Holds the vault's library key in the macOS Keychain.
///
/// This is the primary home of `K_lib`. The wraps in `vault.json` are escape hatches;
/// on the machine that created a vault, this is what opens it.
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
        case authenticationFailed
        case userCancelled

        var description: String {
            switch self {
            case .unavailable(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "the keychain refused the request: \(detail) (\(status))"
            case .notFound: return "no vault key is stored on this Mac"
            case .invalidKeyLength(let count):
                return "the stored vault key must be 32 bytes; found \(count)"
            case .authenticationFailed: return "authentication failed"
            case .userCancelled: return "authentication was cancelled"
            }
        }
    }

    private let service = "com.khm.snippets.vault"
    let tier: Tier

    init(tier: Tier? = nil) {
        self.tier = tier ?? Self.detectTier()
    }

    // MARK: - Which tier this build actually gets

    /// Reads the running binary's own entitlements rather than guessing.
    ///
    /// A build flag would be wrong in both directions: a developer build signed without
    /// the capability would claim the synchronizable tier and fail at runtime, and a
    /// build made before the portal work would keep claiming the local tier long after
    /// the entitlement arrived. `SecCodeCopySelf` asks the only authority that matters.
    static func detectTier() -> Tier {
        guard let applicationIdentifier = selfEntitlement(
                  forKey: "com.apple.application-identifier") as? String,
              !applicationIdentifier.isEmpty,
              let groups = selfEntitlement(forKey: "keychain-access-groups") as? [String],
              let group = groups.first(where: { !$0.isEmpty && !$0.contains("*") })
        else { return .deviceOnly }
        return .synchronizable(accessGroup: group)
    }

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

    // MARK: - Storing and reading the key

    /// Writes the library key without a delete-first window. If replacement fails, the
    /// previous value is still present and the vault remains openable.
    func store(_ key: Data, keyID: String) throws {
        guard key.count == 32 else { throw Failure.invalidKeyLength(key.count) }
        let query = baseQuery(keyID: keyID)
        let values: [String: Any] = [
            kSecValueData as String: key,
            kSecAttrAccessible as String: accessibility,
        ]

        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = query
            for (name, value) in values { attributes[name] = value }
            let add = SecItemAdd(attributes as CFDictionary, nil)
            guard add == errSecSuccess else { throw Failure.unavailable(add) }
        default:
            throw Failure.unavailable(update)
        }
    }

    /// Reads the library key after `VaultSession` has authenticated the user. If this
    /// build newly gained the sync entitlement, an existing device-only item is copied
    /// into the new tier and verified before use.
    func loadKey(keyID: String) throws -> Data {
        if let current = try copyKey(matching: baseQuery(keyID: keyID)) { return current }

        if case .synchronizable = tier,
           let legacy = try copyKey(matching: deviceOnlyQuery(keyID: keyID)) {
            try store(legacy, keyID: keyID)
            guard let migrated = try copyKey(matching: baseQuery(keyID: keyID)), migrated == legacy else {
                throw Failure.unavailable(errSecNotAvailable)
            }
            return migrated
        }
        throw Failure.notFound
    }

    private func copyKey(matching base: [String: Any]) throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.unavailable(status) }
            guard data.count == 32 else { throw Failure.invalidKeyLength(data.count) }
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

    /// Whether a key exists, without reading its bytes. The legacy-tier fallback keeps
    /// an entitlement upgrade from making an existing vault look keyless.
    func hasKey(keyID: String) -> Bool {
        if contains(baseQuery(keyID: keyID)) { return true }
        if case .synchronizable = tier { return contains(deviceOnlyQuery(keyID: keyID)) }
        return false
    }

    /// Removes the key. The vault's ciphertext is untouched and stays openable with a
    /// recovery key or passphrase if the user set either up.
    func deleteKey(keyID: String) throws {
        if case .synchronizable = tier {
            let primary = baseQuery(keyID: keyID)
            let legacy = deviceOnlyQuery(keyID: keyID)

            // Before deleting the fallback, prove whether the preferred copy exists.
            // An entitlement may appear before the first unlock has migrated the key;
            // in that state the fallback is the only copy and a failing DP-keychain
            // delete must not strand restored ciphertext without a key.
            let primaryExists = try itemExists(primary)
            if primaryExists {
                // Delete the fallback first and the preferred sync copy last. If
                // either operation throws, at least one usable copy remains.
                try deleteItem(legacy)
                try deleteItem(primary)
            } else {
                try deleteItem(legacy)
            }
        } else {
            try deleteItem(baseQuery(keyID: keyID))
        }
    }

    private func deleteItem(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess, status != errSecItemNotFound {
            throw Failure.unavailable(status)
        }
    }

    // MARK: - Query construction

    /// `...ThisDeviceOnly` on the local tier, plain `...WhenUnlocked` on the
    /// synchronizable one — the `ThisDeviceOnly` variants are, by definition, refused
    /// for a synchronizable item.
    private var accessibility: CFString {
        tier.syncsBetweenDevices
            ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    }

    private func baseQuery(keyID: String) -> [String: Any] {
        var query = deviceOnlyQuery(keyID: keyID)

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

    private func deviceOnlyQuery(keyID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
        ]
    }

    private func contains(_ base: [String: Any]) -> Bool {
        (try? itemExists(base)) == true
    }

    private func itemExists(_ base: [String: Any]) throws -> Bool {
        var query = base
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
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
            return "Secure snippets stay on this Mac. Syncing them needs the iCloud Keychain entitlement."
        case .synchronizable:
            return "Secure snippets can sync to your other devices through iCloud Keychain."
        }
    }
}
