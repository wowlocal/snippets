import CryptoKit
import Foundation

// Compiled into the app and the test package. Pure CryptoKit: no keychain, no AppKit.

/// Proof that this Mac's owner turned on password-authenticated terminal reveals.
///
/// `snippets-cli reveal --terminal` lets someone without access to this Mac's desktop
/// (SSH, Rex) reveal a secure snippet by typing the macOS login password into the
/// terminal. That widens who can approve a disclosure: anyone who can run commands as
/// this user **and** knows the password can reveal every secure snippet. So the switch
/// that allows it must not be something a same-user process can flip on its own.
///
/// A preference (`defaults write`) or a bare Keychain marker would be exactly that. This
/// record is instead an HMAC under a subkey of the vault key `K_lib`, which only the app
/// can read and only after Touch ID or the login password in the system sheet. A process
/// that cannot open the vault cannot mint one, and a record minted for another vault,
/// another account or another Mac does not verify here.
///
/// The record is checked only *after* the terminal password has been verified and the
/// vault key loaded for that one reveal. Presence alone answers the cheap question "is
/// it switched on?" for Settings and the CLI's preflight; it never authorises anything.
nonisolated struct TerminalRevealAuthorization: Codable, Equatable, Sendable {

    /// What the record is bound to. All three must match at verification.
    struct Binding: Equatable, Sendable {
        /// The vault's `kid`. A replaced vault invalidates every earlier record.
        var vaultKID: String
        /// The macOS account the app runs as.
        var userID: UInt32
        /// A stable identifier of this Mac's hardware, so a record copied to another
        /// Mac sharing the same vault through iCloud Keychain does not verify there.
        /// Never logged, exported or synced: it lives only in this computation.
        var deviceID: String
    }

    static let currentVersion = 1
    static let nonceByteCount = 32
    static let tagByteCount = 32
    private static let keyInfo = "snip.terminal-reveal.v1"

    var v: Int
    /// Fresh per enablement, so turning the feature off and on again yields a record
    /// unrelated to the previous one.
    var nonce: Data
    var tag: Data

    static func issue(keyring: SnippetCrypto.Keyring, binding: Binding) -> TerminalRevealAuthorization {
        let nonce = Data((0..<nonceByteCount).map { _ in UInt8.random(in: 0...255) })
        let tag = Data(HMAC<SHA256>.authenticationCode(
            for: message(version: currentVersion, nonce: nonce, binding: binding),
            using: macKey(keyring)))
        return TerminalRevealAuthorization(v: currentVersion, nonce: nonce, tag: tag)
    }

    /// Constant-time verification. Any shape problem is simply "not authorised".
    func isValid(keyring: SnippetCrypto.Keyring, binding: Binding) -> Bool {
        guard v == Self.currentVersion,
              nonce.count == Self.nonceByteCount,
              tag.count == Self.tagByteCount,
              !binding.vaultKID.isEmpty,
              !binding.deviceID.isEmpty
        else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            tag,
            authenticating: Self.message(version: v, nonce: nonce, binding: binding),
            using: Self.macKey(keyring))
    }

    func encoded() throws -> Data { try JSONEncoder().encode(self) }

    static func decode(_ data: Data) -> TerminalRevealAuthorization? {
        try? JSONDecoder().decode(TerminalRevealAuthorization.self, from: data)
    }

    // MARK: - Construction

    /// A dedicated HKDF subkey: `K_lib` itself never keys anything directly, and this
    /// purpose must not share a key with record sealing or the content hash.
    private static func macKey(_ keyring: SnippetCrypto.Keyring) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: keyring.libraryKey,
            salt: keyring.salt,
            info: Data(keyInfo.utf8),
            outputByteCount: 32)
    }

    /// Every variable-length field is length-prefixed, so no two bindings can
    /// serialise to the same bytes (`kid="ab", device="c"` vs `kid="a", device="bc"`).
    private static func message(version: Int, nonce: Data, binding: Binding) -> Data {
        var data = Data()
        appendField(Data(keyInfo.utf8), to: &data)
        appendUInt32(UInt32(clamping: version), to: &data)
        appendField(nonce, to: &data)
        appendField(Data(binding.vaultKID.utf8), to: &data)
        appendUInt32(binding.userID, to: &data)
        appendField(Data(binding.deviceID.utf8), to: &data)
        return data
    }

    private static func appendField(_ field: Data, to data: inout Data) {
        appendUInt32(UInt32(clamping: field.count), to: &data)
        data.append(field)
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
