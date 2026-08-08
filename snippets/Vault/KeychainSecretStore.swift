import Foundation
import LocalAuthentication
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
///   Developer ID app can simply use it. The key is protected by the login keychain
///   and, with an access control, by Touch ID — but it never leaves this Mac.
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
        case authenticationFailed
        case userCancelled

        var description: String {
            switch self {
            case .unavailable(let status):
                let detail = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "the keychain refused the request: \(detail) (\(status))"
            case .notFound: return "no vault key is stored on this Mac"
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
        guard let groups = selfEntitlement(forKey: "keychain-access-groups") as? [String],
              let group = groups.first(where: { !$0.hasSuffix(".*") }) ?? groups.first
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

    /// Writes the library key, replacing any existing one for `keyID`.
    ///
    /// - Parameter requireBiometry: when true the item carries an access control, so
    ///   reading it prompts for Touch ID or the login password. When false the item is
    ///   readable whenever the keychain is unlocked — which is what the *keyword
    ///   matcher* needs, since it must run with the app in the background.
    func store(_ key: Data, keyID: String, requireBiometry: Bool) throws {
        var attributes = baseQuery(keyID: keyID)
        attributes[kSecValueData as String] = key

        if requireBiometry {
            var error: Unmanaged<CFError>?
            // `.userPresence` rather than `.biometryCurrentSet`: the latter invalidates
            // the item whenever the user adds or removes a fingerprint, which silently
            // destroys the only local copy of the key. Enrolling a finger must not
            // erase someone's secrets.
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .userPresence,
                &error
            ) else {
                throw Failure.unavailable(errSecParam)
            }
            attributes[kSecAttrAccessControl as String] = access
        } else {
            attributes[kSecAttrAccessible as String] = accessibility
        }

        SecItemDelete(baseQuery(keyID: keyID) as CFDictionary)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.unavailable(status) }
    }

    /// Reads the library key, prompting for Touch ID if the item requires it.
    ///
    /// - Parameter context: pass a reused `LAContext` to honour an unlock session
    ///   rather than prompting on every read. `VaultSession` owns that policy.
    func loadKey(keyID: String, reason: String, context: LAContext? = nil) throws -> Data {
        var query = baseQuery(keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        // The prompt text travels on the LAContext, not as `kSecUseOperationPrompt`,
        // which has been deprecated since macOS 11. Reusing the caller's context is
        // also what lets an unlock session suppress repeat prompts — passing a fresh
        // context here would silently defeat `VaultSession`'s reuse window.
        let authenticationContext = context ?? LAContext()
        authenticationContext.localizedReason = reason
        query[kSecUseAuthenticationContext as String] = authenticationContext

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw Failure.unavailable(status) }
            return data
        case errSecItemNotFound:
            throw Failure.notFound
        case errSecUserCanceled:
            throw Failure.userCancelled
        case errSecAuthFailed:
            throw Failure.authenticationFailed
        default:
            throw Failure.unavailable(status)
        }
    }

    /// Whether a key exists, without reading it and therefore without prompting.
    ///
    /// `kSecReturnData: false` is load-bearing: asking for the bytes would raise a
    /// Touch ID sheet, and this is called to decide whether to show UI at all.
    func hasKey(keyID: String) -> Bool {
        var query = baseQuery(keyID: keyID)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Removes the key. The vault's ciphertext is untouched and stays openable with a
    /// recovery key or passphrase if the user set either up.
    func deleteKey(keyID: String) throws {
        let status = SecItemDelete(baseQuery(keyID: keyID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
        ]

        switch tier {
        case .deviceOnly:
            // Deliberately NOT the data-protection keychain: without an
            // application-identifier it returns errSecMissingEntitlement (-34018) for
            // every operation, which is the failure this tier exists to avoid.
            break
        case .synchronizable(let accessGroup):
            query[kSecUseDataProtectionKeychain as String] = true
            query[kSecAttrAccessGroup as String] = accessGroup
            query[kSecAttrSynchronizable as String] = true
        }
        return query
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
