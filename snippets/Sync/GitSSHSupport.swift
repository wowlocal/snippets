import CryptoKit
import Foundation
import Security

/// How this platform reaches SSH remotes.
///
/// - macOS runs the system `ssh`, so the user's ssh-agent, `~/.ssh/config` and
///   `known_hosts` decide everything; Snippets stores no SSH secret.
/// - iOS has no ssh or agent. Snippets keeps one key per device (in the Secure Enclave
///   when the hardware has one) that the user adds to the repository, and asks before
///   trusting a host key the first time.
nonisolated struct GitSSHSupport: Sendable {
    let connector: any GitSSHConnector
    /// Nil on macOS.
    let device: GitSSHDeviceIdentity?

    #if os(macOS)
    static let systemSSH = GitSSHSupport(connector: GitSystemSSHConnector(), device: nil)
    #endif
}

/// A host key the connector saw but did not trust.
nonisolated struct GitSSHPresentedHostKey: Sendable, Equatable {
    /// `ssh-ed25519 AAAA…`, without a comment.
    let openSSHKey: String
    /// `SHA256:…`, as `ssh-keygen -lf` and the hosts' documentation print it.
    let fingerprint: String
    /// A different key was trusted for this host before.
    let replacesTrustedKey: Bool
    /// The host's name when this exact key is one it publishes (GitHub, GitLab, …), so
    /// the trust prompt can say the comparison was made. The user still confirms.
    var publishedBy: String? = nil
}

/// Host keys trusted on first use, after the user confirmed the fingerprint. Host keys
/// are public, so they live in preferences; a changed key is never accepted silently.
nonisolated final class GitSSHHostKeyStore: @unchecked Sendable {
    enum Verdict: Equatable { case trusted, unknown, changed }

    static let defaultsKey = "SnippetsGitSSHTrustedHostKeys"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var presented: [String: GitSSHPresentedHostKey] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// SHA-256 fingerprints the big hosts publish for their SSH host keys (checked against
    /// their documentation and a live scan). Only an exact match on port 22 counts.
    static let publishedFingerprints: [String: (name: String, fingerprints: Set<String>)] = [
        "github.com": ("GitHub", [
            "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
            "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
            "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
        ]),
        "gitlab.com": ("GitLab", [
            "SHA256:eUXGGm1YGsMAS7vkcx6JOJdOGHPem5gQp4taiCfCLB8",
            "SHA256:HbW3g8zUjNSksFbqTiUWPWg2Bq1x8xdGUrliXFzSnUw",
            "SHA256:ROQFvPThGrW4RuWLoL9tq9I9zJ42fK4XywyRtbOz/EQ",
        ]),
        "codeberg.org": ("Codeberg", [
            "SHA256:mIlxA9k46MmM6qdJOdMnAQpzGxF4WIVVL+fj+wZbw0g",
            "SHA256:T9FYDEHELhVkulEKKwge5aVhVTbqCW0MIRwAfpARs/E",
            "SHA256:6QQmYi4ppFS4/+zSZ5S4IU+4sa6rwvQ4PbhCtPEBekQ",
        ]),
        "bitbucket.org": ("Bitbucket", [
            "SHA256:ybgmFkzwOSotHTHLJgHO0QN8L0xErw6vd0VhFA9m3SM",
            "SHA256:FC73VB6C4OQLSCrjEayhMp9UMxS97caD/Yyi2bhW/J0",
            "SHA256:46OSHA1Rmj8E8ERTC6xkNcmGOw9oFxYr0WF6zWW8l1E",
        ]),
    ]

    static func publisher(of fingerprint: String, for location: GitSSHLocation) -> String? {
        guard location.port == nil || location.port == 22,
              let entry = publishedFingerprints[location.host.lowercased()],
              entry.fingerprints.contains(fingerprint) else { return nil }
        return entry.name
    }

    /// `host` or `[host]:port`, as OpenSSH writes `known_hosts`.
    static func hostID(_ location: GitSSHLocation) -> String {
        let host = location.host.lowercased()
        guard let port = location.port, port != 22 else { return host }
        return "[\(host)]:\(port)"
    }

    static func fingerprint(openSSHKey: String) -> String? {
        let fields = openSSHKey.split(separator: " ")
        guard fields.count >= 2, let blob = Data(base64Encoded: String(fields[1])) else { return nil }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Checks `openSSHKey` for `hostID`. An untrusted key is remembered so Settings can
    /// show its fingerprint and, if the user confirms, trust exactly that key.
    func check(hostID: String, openSSHKey: String) -> Verdict {
        let key = Self.keyOnly(openSSHKey)
        let trusted = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String])?[hostID]
        if trusted == key { return .trusted }
        let presentedKey = GitSSHPresentedHostKey(
            openSSHKey: key, fingerprint: Self.fingerprint(openSSHKey: key) ?? "unknown",
            replacesTrustedKey: trusted != nil)
        lock.withLock { presented[hostID] = presentedKey }
        return trusted == nil ? .unknown : .changed
    }

    func presentedKey(for location: GitSSHLocation) -> GitSSHPresentedHostKey? {
        guard var key = lock.withLock({ presented[Self.hostID(location)] }) else { return nil }
        key.publishedBy = Self.publisher(of: key.fingerprint, for: location)
        return key
    }

    /// Trusts the key last presented by this host, and only that key.
    @discardableResult
    func trustPresentedKey(for location: GitSSHLocation, fingerprint: String) -> Bool {
        let hostID = Self.hostID(location)
        guard let key = lock.withLock({ presented[hostID] }), key.fingerprint == fingerprint else { return false }
        var trusted = (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        trusted[hostID] = key.openSSHKey
        defaults.set(trusted, forKey: Self.defaultsKey)
        lock.withLock { presented[hostID] = nil }
        return true
    }

    func trustedKey(for location: GitSSHLocation) -> String? {
        (defaults.dictionary(forKey: Self.defaultsKey) as? [String: String])?[Self.hostID(location)]
    }

    private static func keyOnly(_ openSSHKey: String) -> String {
        openSSHKey.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

/// This device's SSH key and host-key trust, for platforms without a system ssh.
///
/// One ECDSA P-256 key per device, created on first use. On hardware with a Secure
/// Enclave the private key never leaves it; the Keychain holds only the enclave's
/// device-bound handle. Without one (the Simulator) it is a software key in the
/// device-only Keychain. Either way it is usable after first unlock, so background
/// sync works, and it never syncs to other devices: each device is added to the
/// repository separately and can be revoked separately.
nonisolated final class GitSSHDeviceIdentity: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case keyUnavailable
    }

    /// The private key in a form the SSH implementation can sign with.
    enum SigningKey: Sendable {
        case secureEnclave(SecureEnclave.P256.Signing.PrivateKey)
        case software(P256.Signing.PrivateKey)

        var publicKey: P256.Signing.PublicKey {
            switch self {
            case .secureEnclave(let key): key.publicKey
            case .software(let key): key.publicKey
            }
        }
    }

    static let keychainService = "com.khm.snippets.git-ssh"
    static let keyAccount = "git-ssh-device-key-v1"
    /// Names the device kind in the host's key list (`snippets-iphone`, `snippets-ipad`),
    /// so a lost device's key is easy to find and remove there.
    let comment: String

    let hostKeys: GitSSHHostKeyStore
    private let keychain: KeychainSecretStore
    private let allowsSecureEnclave: Bool
    private let lock = NSLock()
    private var cached: SigningKey?

    init(keychain: KeychainSecretStore? = nil, hostKeys: GitSSHHostKeyStore = GitSSHHostKeyStore(),
         allowsSecureEnclave: Bool = true, comment: String = "snippets-device") {
        self.comment = comment
        self.keychain = keychain ?? KeychainSecretStore(
            tier: .deviceOnly, service: Self.keychainService, itemAccessibility: .afterFirstUnlock)
        self.hostKeys = hostKeys
        self.allowsSecureEnclave = allowsSecureEnclave
    }

    private struct StoredKey: Codable {
        let schemaVersion: Int
        /// "secure-enclave" or "software".
        let kind: String
        let key: Data
    }

    /// The device key, created and stored on first use.
    func signingKey() throws -> SigningKey {
        try lock.withLock {
            if let cached { return cached }
            let key = try loadOrCreate()
            cached = key
            return key
        }
    }

    /// `ecdsa-sha2-nistp256 AAAA… snippets-device`, for the repository's deploy keys or
    /// the user's account SSH keys.
    func publicKey() throws -> String {
        Self.openSSHPublicKey(try signingKey().publicKey) + " " + comment
    }

    var hasKey: Bool { lock.withLock { cached != nil } || keychain.hasItem(account: Self.keyAccount) }

    /// Installs a known software key. Tests use it to authorize the device ahead of time.
    func installSoftwareKeyForTesting(_ key: P256.Signing.PrivateKey) throws {
        try store(StoredKey(schemaVersion: 1, kind: "software", key: key.rawRepresentation))
        lock.withLock { cached = .software(key) }
    }

    static func openSSHPublicKey(_ key: P256.Signing.PublicKey) -> String {
        func string(_ bytes: Data) -> Data {
            var length = UInt32(bytes.count).bigEndian
            return Data(bytes: &length, count: 4) + bytes
        }
        let blob = string(Data("ecdsa-sha2-nistp256".utf8)) + string(Data("nistp256".utf8))
            + string(key.x963Representation)
        return "ecdsa-sha2-nistp256 " + blob.base64EncodedString()
    }

    private func loadOrCreate() throws -> SigningKey {
        let data: Data?
        do { data = try keychain.loadItem(account: Self.keyAccount) }
        catch { throw Failure.keyUnavailable }
        if let data {
            guard let stored = try? JSONDecoder().decode(StoredKey.self, from: data), stored.schemaVersion == 1 else {
                throw Failure.keyUnavailable
            }
            switch stored.kind {
            case "secure-enclave":
                guard let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: stored.key) else {
                    throw Failure.keyUnavailable
                }
                return .secureEnclave(key)
            case "software":
                guard let key = try? P256.Signing.PrivateKey(rawRepresentation: stored.key) else {
                    throw Failure.keyUnavailable
                }
                return .software(key)
            default:
                throw Failure.keyUnavailable
            }
        }
        if allowsSecureEnclave, SecureEnclave.isAvailable,
           let access = SecAccessControlCreateWithFlags(
               nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, nil),
           let key = try? SecureEnclave.P256.Signing.PrivateKey(accessControl: access) {
            try store(StoredKey(schemaVersion: 1, kind: "secure-enclave", key: key.dataRepresentation))
            return .secureEnclave(key)
        }
        let key = P256.Signing.PrivateKey()
        try store(StoredKey(schemaVersion: 1, kind: "software", key: key.rawRepresentation))
        return .software(key)
    }

    private func store(_ stored: StoredKey) throws {
        do { try keychain.storeItem(try JSONEncoder().encode(stored), account: Self.keyAccount) }
        catch { throw Failure.keyUnavailable }
    }
}
