import Foundation
import CryptoKit

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
// Foundation and CryptoKit only, for the reasons given in `SnippetCrypto.swift`.

/// Wrapping `K_lib` under key material that is **already uniformly random** — the
/// recovery key, or the 32-byte secret in the login keychain.
///
/// ## Why this is not `PassphraseKDF`
///
/// `PassphraseKDF` exists to make guessing expensive, because a human chose the input
/// and the search space is small. Neither input here was chosen by a human:
/// `RecoveryKey.generate()` is 128 bits from the CSPRNG and a `SecretStore` secret is
/// 256. Running 600 000 rounds of PBKDF2 over a uniformly random 32-byte secret does
/// not make it harder to guess — the guesser is already facing 2^256 — it only adds
/// half a second to every `snippets-cli reveal`. Stretching is for low-entropy inputs
/// and nothing else.
///
/// So this path is one HKDF (to domain-separate, not to slow anybody down) and one
/// AEAD seal. The distinction matters enough to be a separate type rather than a flag,
/// because "should I stretch this?" answered wrongly in either direction is a real
/// bug: skip it for a passphrase and the vault is crackable, apply it to a random key
/// and the CLI is unusable.
///
/// ## HKDF does not create entropy, and this is where that shows
///
/// The recovery key is 16 bytes. The AES-256-GCM key derived from it is 32. That
/// expansion is not 256 bits of security — it is 128 bits of entropy spread across a
/// 256-bit key, and the recovery door is a **128-bit** door. That is far beyond any
/// feasible attack and is the standard strength for a written-down secret (it is what
/// makes a 26-character code short enough that a human will actually copy it onto
/// paper), but writing "AES-256" next to it and leaving the reader to assume 256 bits
/// of strength would be a lie by omission. The passphrase door is weaker still, and
/// bounded by the passphrase rather than by anything here.
///
/// ## What the AAD binds, and what it does not
///
/// Every wrap authenticates `{wire version, purpose, kid}`:
///
/// - **`purpose`** stops the two blobs being swapped for one another. Without it, a
///   `wrapCLI` blob renamed to `wrapRecovery` in the file would open under the CLI
///   secret and hand back a perfectly good `K_lib` — which quietly converts "an
///   attacker needs the recovery key" into "an attacker needs the keychain secret",
///   i.e. the weaker of the two doors always wins.
/// - **`kid`** makes a rekey cryptographically detectable rather than a string
///   comparison. After a rekey, an old wrap blob pasted back over the new one fails the
///   tag instead of unwrapping to a stale `K_lib` that then fails to open every record
///   — the same end state, but reported at the door instead of as "your vault is
///   corrupt".
///
/// It does **not** defend wholesale rollback: an attacker who replaces the entire
/// `vault.json` with an older copy — matching `kid`, wraps and records — gets a file
/// that is internally consistent and opens normally. Detecting that needs a signed
/// monotonic counter somewhere the attacker cannot reach, which this format does not
/// have. Say so rather than implying the AAD covers more than it does.
nonisolated enum KeyWrap {

    /// Distinct from `SnippetCrypto.additionalDataDomain` (`snip.aad.v1`) and
    /// `PassphraseKDF.additionalDataDomain` (`snip.kdf.v1`), so a record envelope, a
    /// passphrase wrap and a key wrap can never be substituted for one another even
    /// with the right key in hand.
    static let additionalDataDomain = "snip.wrap.v1"

    /// HKDF `info` prefix. Shares the version tag with the AAD domain deliberately: a
    /// format change has to move both together or neither.
    static let wrappingKeyInfoPrefix = "snip.wrap.v1|"

    /// A floor, not a recommendation. 16 bytes is `RecoveryKey.byteCount`; anything
    /// shorter is a caller passing something that is not key material — a UTF-8
    /// passphrase, a truncated buffer, a hex string they forgot to decode. Rejecting it
    /// here is the difference between a vault that is weak and one that fails loudly.
    static let minimumMaterialByteCount = 16

    /// Which door a blob belongs to. The raw values are baked into the AAD, so they are
    /// format, not naming — renaming a case makes every existing vault of that kind
    /// unopenable.
    enum Purpose: String, Sendable, Equatable, CaseIterable {
        /// `VaultDocument.wrapRecovery`, under `RecoveryKey` bytes.
        case recovery
        /// `VaultDocument.wrapCLI`, under a `SecretStore` secret.
        case cli
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case materialTooShort(Int)
        /// The AEAD tag rejected the unwrap: wrong material, or a blob from another
        /// purpose, another `kid`, or another vault. Coarse for the same reason
        /// `SnippetCrypto.Failure.authenticationFailed` is — see the note there.
        case wrongKey(Purpose)
        case invalidParameters(String)

        var description: String {
            switch self {
            case .materialTooShort(let count):
                return "key material is \(count) bytes; a wrap needs at least \(KeyWrap.minimumMaterialByteCount)"
            case .wrongKey(.recovery):
                return "that recovery key does not unlock this vault"
            case .wrongKey(.cli):
                return "the stored CLI secret does not unlock this vault"
            case .invalidParameters(let detail):
                return "key wrap has unusable parameters: \(detail)"
            }
        }
    }

    /// The bytes every wrap of this purpose authenticates. One builder, for exactly the
    /// reason spelled out on `SnippetCrypto.additionalData(for:)`.
    static func additionalData(purpose: Purpose, kid: String) -> Data {
        SnippetCrypto.domainSeparated(additionalDataDomain, [
            Data(SnippetCrypto.wireVersion.utf8),
            Data(purpose.rawValue.utf8),
            Data(kid.utf8),
        ])
    }

    /// Expands raw material into the AES key that actually wraps `K_lib`.
    ///
    /// `salt` is the vault's public `vaultSalt`, the same value the record keys are
    /// derived under. Two vaults that somehow ended up with the same recovery key still
    /// produce different wrapping keys, and the recovery blob from one cannot be opened
    /// against the other even before the AAD is consulted.
    ///
    /// The purpose is in the `info` string as well as in the AAD. Belt and braces on
    /// purpose separation is cheap here and the failure it prevents — one door's
    /// material opening the other door — is the kind that never shows up in testing
    /// because both doors work.
    static func wrappingKey(from material: Data, purpose: Purpose, salt: Data) throws -> SymmetricKey {
        guard material.count >= minimumMaterialByteCount else {
            throw Failure.materialTooShort(material.count)
        }
        guard !salt.isEmpty else { throw Failure.invalidParameters("empty salt") }

        var info = Data(wrappingKeyInfoPrefix.utf8)
        info.append(Data(purpose.rawValue.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material),
            salt: salt,
            info: info,
            outputByteCount: SnippetCrypto.keyByteCount)
    }

    /// Seals `libraryKey` under `material`, producing the string that goes in
    /// `VaultDocument.wrapRecovery` or `.wrapCLI`.
    static func wrap(
        _ libraryKey: SymmetricKey,
        under material: Data,
        purpose: Purpose,
        kid: String,
        salt: Data,
        nonces: SnippetCrypto.NonceSource = .system
    ) throws -> String {
        guard libraryKey.bitCount == SnippetCrypto.keyByteCount * 8 else {
            throw SnippetCrypto.Failure.wrongKeySize(libraryKey.bitCount / 8)
        }
        let wrapping = try wrappingKey(from: material, purpose: purpose, salt: salt)
        return try SnippetCrypto.seal(
            libraryKey.withUnsafeBytes { Data($0) },
            key: wrapping,
            aad: additionalData(purpose: purpose, kid: kid),
            nonces: nonces)
    }

    /// Recovers `K_lib`, or throws. As with `PassphraseKDF.unwrap`, there is no branch
    /// that can return bytes the AEAD tag did not vouch for.
    static func unwrap(
        _ envelope: String,
        under material: Data,
        purpose: Purpose,
        kid: String,
        salt: Data
    ) throws -> SymmetricKey {
        let wrapping = try wrappingKey(from: material, purpose: purpose, salt: salt)

        let recovered: Data
        do {
            recovered = try SnippetCrypto.open(
                envelope, key: wrapping, aad: additionalData(purpose: purpose, kid: kid))
        } catch SnippetCrypto.Failure.authenticationFailed {
            // The only failure that depends on what the user supplied. Structural
            // problems with the file keep their own errors, so "wrong recovery key"
            // is never shown for a truncated blob.
            throw Failure.wrongKey(purpose)
        }

        guard recovered.count == SnippetCrypto.keyByteCount else {
            throw Failure.invalidParameters("wrapped key is \(recovered.count) bytes")
        }
        return SymmetricKey(data: recovered)
    }
}
