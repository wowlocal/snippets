import CryptoKit
import Foundation

// Compiled into both Apple apps and the CorePackage test overlay. Foundation and
// CryptoKit only: no UI, Keychain, networking or diagnostics.

/// The server-generated Snippets Cloud account key (server ADR 0006).
///
/// The key is the only native sign-in secret and also the server's lookup handle, so a
/// client never generates one. It parses user input, validates a server response and
/// formats the key for display:
///
/// ```
/// body:      26 Crockford Base32 symbols (130 random bits, server generated)
/// check:      2 symbols = first ten bits of
///             SHA-256("snippets-account-key-check-v1\n" || body)
/// canonical: body + check, 28 uppercase symbols, no separators (the wire form)
/// display:   XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXXX
/// ```
///
/// A value only exists when its check symbols match, so a locally mistyped key can
/// never reach the network. `description`, `debugDescription` and reflection are
/// redacted: interpolating a key into a log message or error cannot disclose it.
nonisolated struct SnippetsCloudAccountKey: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    static let alphabet: [UInt8] = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
    static let bodyLength = 26
    static let canonicalLength = 28
    /// Longer pasted input is rejected before any normalization work.
    static let maximumInputBytes = 64
    private static let checkDomain = Array("snippets-account-key-check-v1\n".utf8)

    /// The 28-symbol canonical form. This is the only form sent to the server and the
    /// only form stored with the session.
    let canonical: String

    /// Seven groups of four symbols joined by `-`, for the save and reveal screens.
    var displayForm: String {
        let symbols = Array(canonical)
        return stride(from: 0, to: symbols.count, by: 4)
            .map { String(symbols[$0..<min($0 + 4, symbols.count)]) }
            .joined(separator: "-")
    }

    /// Normalizes typed or pasted input exactly as ADR 0006 specifies: reject more than
    /// 64 UTF-8 bytes; drop ASCII whitespace and `-`; uppercase ASCII; read `O` as `0`
    /// and `I`/`L` as `1`; then require 28 alphabet symbols with a matching check.
    /// Any other byte, including non-ASCII text and `U`, is a typing error.
    init?(normalizing input: String) {
        let bytes = Array(input.utf8)
        guard bytes.count <= Self.maximumInputBytes else { return nil }
        var symbols: [UInt8] = []
        symbols.reserveCapacity(Self.canonicalLength)
        for byte in bytes {
            switch byte {
            case 0x09...0x0D, 0x20, UInt8(ascii: "-"):
                continue
            default:
                break
            }
            var symbol = (0x61...0x7A).contains(byte) ? byte - 0x20 : byte
            switch symbol {
            case UInt8(ascii: "O"): symbol = UInt8(ascii: "0")
            case UInt8(ascii: "I"), UInt8(ascii: "L"): symbol = UInt8(ascii: "1")
            default: break
            }
            guard Self.alphabet.contains(symbol),
                  symbols.count < Self.canonicalLength else { return nil }
            symbols.append(symbol)
        }
        self.init(checkedSymbols: symbols)
    }

    /// Accepts only the exact canonical wire form, as a server response must use.
    init?(canonical value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == Self.canonicalLength,
              bytes.allSatisfy(Self.alphabet.contains) else { return nil }
        self.init(checkedSymbols: bytes)
    }

    /// Appends the check symbols to a 26-symbol body. Clients never generate keys; this
    /// exists so the ADR test vectors can be verified from their published bodies.
    init?(body value: String) {
        let bytes = Array(value.utf8)
        guard bytes.count == Self.bodyLength,
              bytes.allSatisfy(Self.alphabet.contains) else { return nil }
        self.init(checkedSymbols: bytes + Self.checkSymbols(body: bytes))
    }

    private init?(checkedSymbols symbols: [UInt8]) {
        guard symbols.count == Self.canonicalLength,
              Array(symbols[Self.bodyLength...])
                == Self.checkSymbols(body: symbols[..<Self.bodyLength]) else { return nil }
        canonical = String(decoding: symbols, as: UTF8.self)
    }

    private static func checkSymbols(body: some Collection<UInt8>) -> [UInt8] {
        var hash = SHA256()
        hash.update(data: checkDomain)
        hash.update(data: Array(body))
        let digest = Array(hash.finalize())
        let value = (Int(digest[0]) << 2) | (Int(digest[1]) >> 6)
        return [alphabet[value >> 5], alphabet[value & 31]]
    }

    var description: String { "SnippetsCloudAccountKey(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}

/// The signed-in account screen identifies an account by a short, non-secret prefix of
/// its server UUID. It is shown to the user but never written to diagnostics.
nonisolated enum SnippetsCloudAccountIdentifier {
    /// The first eight hex digits of the account UUID, uppercase, as `XXXX-XXXX`.
    static func displayForm(_ accountID: UUID) -> String {
        let hex = accountID.uuidString.uppercased().filter { $0 != "-" }.prefix(8)
        return "\(hex.prefix(4))-\(hex.suffix(4))"
    }
}
