import Foundation
import CommonCrypto
import CryptoKit

// Compiled into the app, the CLI, and the test package — see `Snippet.swift`.
//
// CommonCrypto rather than CryptoKit: CryptoKit ships HKDF (a *key* derivation
// function, which assumes its input is already high-entropy) but no password-based
// KDF at all. `CCKeyDerivationPBKDF` is the only PBKDF Apple offers on macOS without
// vendoring a C implementation, and vendoring a hand-rolled Argon2 into a text
// expander is a worse risk than the one documented below.

/// Turns a human passphrase into a key that wraps `K_lib`.
///
/// The vault's root secret (`SnippetCrypto.Keyring.libraryKey`) is 256 random bits and
/// is never written to disk in the clear. What is written is that key sealed under a
/// key derived from the user's passphrase — so the passphrase, and the cost of
/// guessing it, is the whole security of a stolen `vault.json`.
///
/// ## PBKDF2 is not memory-hard, and that matters
///
/// Be honest about this: PBKDF2-HMAC-SHA512 is a serial chain of hash invocations
/// with a constant, tiny memory footprint. That is precisely the shape an attacker
/// parallelises best — a GPU runs tens of thousands of these lanes at once, and an
/// ASIC or FPGA does better still. Argon2id and scrypt exist specifically to deny
/// that advantage by forcing each guess to touch megabytes of RAM. **Apple ships
/// neither.** There is no memory-hard KDF in CryptoKit, CommonCrypto, or the Security
/// framework; every Apple-platform app that wants one vendors a C library.
///
/// What mitigates it here:
///
/// - **600 000 iterations of HMAC-SHA512.** SHA-512 is 64-bit-word arithmetic, which
///   is markedly less GPU-friendly than the SHA-256 that most PBKDF2 deployments use;
///   the gap is roughly an order of magnitude in the attacker's throughput. The count
///   matches the current OWASP guidance for PBKDF2-HMAC-SHA512 and costs a real Mac
///   roughly half a second — the ceiling is the user's patience at unlock, not our
///   ambition.
/// - **The passphrase is not the only door.** `RecoveryKey` wraps the same `K_lib`
///   under 128 bits of machine-generated entropy, so a user who does not trust
///   themselves to pick a strong passphrase has a path that is not guessable at all.
/// - **The realistic attacker is not offline.** Per the threat model in
///   `SnippetCrypto`, someone who can run code as this user has far cheaper options
///   than cracking a KDF. This defends the *powered-off Mac*, the Time Machine disk,
///   and the sync backend — cases where the attacker has the file and nothing else.
/// - **`alg` is recorded in the file.** Adding Argon2id later is purely additive:
///   write `alg: "argon2id"` records, keep reading `pbkdf2-hmac-sha512` ones, and
///   re-wrap opportunistically at the next successful unlock. Nothing needs to
///   migrate in a flag day, and no user is locked out by the upgrade.
nonisolated enum PassphraseKDF {

    // MARK: - Pinned parameters

    /// Recorded verbatim in every wrapped-key record. A future Argon2id implementation
    /// writes a different string here and the two coexist in the same file.
    static let algorithm = "pbkdf2-hmac-sha512"

    /// **Pinned.** Not a preference, not a tuning knob, not "however many fit in
    /// 500 ms on this machine". Calibrating iterations to the local CPU means a 2015
    /// MacBook writes a file that a 2026 Mac Studio can crack cheaply, and it makes
    /// the same passphrase produce different files on different machines, which is
    /// impossible to reason about later. When this number changes, it changes for
    /// everyone in one commit, and existing files keep working because each one
    /// records the count it was written with.
    static let iterations = 600_000

    /// The iteration count is read back out of a file that anybody can edit. Without
    /// a ceiling, a hostile or corrupted `vault.json` claiming two billion rounds
    /// wedges the unlock path in an uninterruptible C call. The AAD binds the count
    /// (see below), so an attacker cannot *lower* it either.
    static let maximumIterations = 20_000_000

    static let saltByteCount = 16
    static let derivedKeyByteCount = 32

    /// Domain tag for the wrapping AAD. Distinct from
    /// `SnippetCrypto.additionalDataDomain`, so a wrapped-key envelope and a record
    /// envelope can never be swapped for one another.
    static let additionalDataDomain = "snip.kdf.v1"

    // MARK: - Errors

    enum Failure: Error, Equatable, CustomStringConvertible {
        case emptyPassphrase
        case unsupportedAlgorithm(String)
        case invalidParameters(String)
        case derivationFailed(Int32)
        /// The AEAD tag rejected the unwrap. Almost always a mistyped passphrase; also
        /// what an edited `iterations` or `salt` produces, because both are bound into
        /// the AAD.
        case wrongPassphrase

        var description: String {
            switch self {
            case .emptyPassphrase:
                return "an empty passphrase cannot protect anything"
            case .unsupportedAlgorithm(let alg):
                return "wrapped key uses \"\(alg)\"; this build understands \"\(PassphraseKDF.algorithm)\""
            case .invalidParameters(let detail):
                return "wrapped key has unusable parameters: \(detail)"
            case .derivationFailed(let status):
                return "CCKeyDerivationPBKDF failed with status \(status)"
            case .wrongPassphrase:
                return "that passphrase does not unlock this vault"
            }
        }
    }

    // MARK: - The stored record

    /// Exactly what goes in `vault.json` beside the salt and the records.
    ///
    /// ## There is no verifier field, deliberately
    ///
    /// The obvious-looking design stores `SHA256(derivedKey)` so the app can say
    /// "wrong passphrase" without attempting a decryption. It buys nothing: the
    /// AES-GCM tag on `envelope` already fails, unforgeably, on a wrong key — that is
    /// what an AEAD tag *is*. And it costs something real. A verifier is a second,
    /// independent oracle over the same derived key, so an attacker gets two shots at
    /// finding an implementation slip, and a bare hash of the derived key is a
    /// checkable target that does not require touching the ciphertext at all. One
    /// gate, one answer.
    struct WrappedKey: Codable, Equatable, Sendable {
        /// `algorithm` above. Present so a future memory-hard KDF is additive.
        var alg: String
        /// The count this particular record was written with — never assumed.
        var iterations: Int
        /// base64url. Per-wrap, random, public.
        var salt: String
        /// A `SnippetCrypto` envelope over the 32 raw bytes of `K_lib`.
        var envelope: String
    }

    // MARK: - Derivation

    static func makeSalt() -> Data {
        SnippetCrypto.randomBytes(saltByteCount)
    }

    /// Binds the KDF parameters and the vault identity to the ciphertext.
    ///
    /// ## What each field actually earns, which is not what it looks like
    ///
    /// The obvious story is "authenticating `iterations` stops an attacker rewriting
    /// 600 000 to 1 and making every subsequent guess cost one HMAC". That story is
    /// wrong, and it was written here before anyone checked. `iterations` and `salt` are
    /// **inputs to `derive`**: change either and PBKDF2 produces a different key, so the
    /// unwrap already fails on the tag without any AAD at all. Removing both from this
    /// builder and re-running the suite changes nothing, which is how the overclaim was
    /// caught. `alg` is likewise refused by name in `unwrap` before this is reached.
    ///
    /// So the parameter fields are belt-and-braces over a binding the derivation already
    /// provides. They stay — they are three bytes of hashing and they keep the property
    /// true by construction if a future KDF ever ignores one of its inputs — but they
    /// are not the mechanism, and a comment claiming they are would send the next reader
    /// looking for a hole that is plugged somewhere else.
    ///
    /// **`kid` is the field that earns its place here.** Nothing derives from it, so
    /// without this it is an unauthenticated string and a wrap blob left over from
    /// before a rekey unwraps happily to a stale `K_lib` that then fails to open every
    /// record. `KeyWrap` binds it for the same reason, and binding it in exactly one of
    /// the two would be worse than binding it in neither: a reader comparing the
    /// passphrase door with the recovery door would find an asymmetry with no stated
    /// cause and "fix" it in whichever direction they guessed. All three wraps of
    /// `K_lib` authenticate the `kid` they belong to. See `KeyWrap` for what that does
    /// buy and what it does not (wholesale rollback of the entire file).
    static func additionalData(alg: String, iterations: Int, salt: Data, kid: String) -> Data {
        SnippetCrypto.domainSeparated(additionalDataDomain, [
            Data(alg.utf8),
            withUnsafeBytes(of: UInt64(iterations).bigEndian) { Data($0) },
            salt,
            Data(kid.utf8),
        ])
    }

    /// PBKDF2-HMAC-SHA512 over the NFC-normalised UTF-8 of the passphrase.
    ///
    /// Normalisation is not cosmetic. "é" can be one code point or two, and which one
    /// arrives depends on the keyboard layout, the input method, and whether the text
    /// came through a password manager's autofill. Two spellings of a visually
    /// identical passphrase derive two different keys, and the user gets "wrong
    /// passphrase" while staring at the right passphrase. NFC once, here, at the only
    /// place that matters.
    static func derive(passphrase: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var password = Array(passphrase.precomposedStringWithCanonicalMapping.utf8)
        // Best-effort scrub of the one copy we control. Swift makes no promise here —
        // `passphrase` itself is a `String` we cannot touch, the UI held it before us,
        // and the array may have been reallocated. See the note in `SnippetCrypto`.
        defer { password.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }

        guard !password.isEmpty else { throw Failure.emptyPassphrase }
        guard !salt.isEmpty else { throw Failure.invalidParameters("empty salt") }
        guard iterations > 0 else { throw Failure.invalidParameters("iterations must be positive") }
        guard iterations <= maximumIterations else {
            throw Failure.invalidParameters("\(iterations) iterations exceeds the \(maximumIterations) ceiling")
        }

        var derived = [UInt8](repeating: 0, count: derivedKeyByteCount)
        let status: Int32 = derived.withUnsafeMutableBytes { output in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: CChar.self),
                        passwordBytes.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        saltBytes.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        output.count)
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed(status) }

        let key = SymmetricKey(data: derived)
        _ = derived.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
        return key
    }

    // MARK: - Wrap and unwrap

    /// Seals `key` (the vault's `K_lib`) under `passphrase`.
    ///
    /// `salt` is a parameter rather than a default so that generating randomness is a
    /// visible decision at the call site — the same reason nothing in `Core/` calls
    /// `Date()` or `UUID()` from inside a function that is otherwise pure. Callers
    /// making a new wrap use `makeSalt()`.
    static func wrap(
        _ key: SymmetricKey,
        passphrase: String,
        salt: Data,
        kid: String,
        iterations: Int = PassphraseKDF.iterations,
        nonces: SnippetCrypto.NonceSource = .system
    ) throws -> WrappedKey {
        guard key.bitCount == SnippetCrypto.keyByteCount * 8 else {
            throw SnippetCrypto.Failure.wrongKeySize(key.bitCount / 8)
        }

        let wrapping = try derive(passphrase: passphrase, salt: salt, iterations: iterations)
        let aad = additionalData(alg: algorithm, iterations: iterations, salt: salt, kid: kid)
        let material = key.withUnsafeBytes { Data($0) }

        return WrappedKey(
            alg: algorithm,
            iterations: iterations,
            salt: SnippetCrypto.base64URL(salt),
            envelope: try SnippetCrypto.seal(material, key: wrapping, aad: aad, nonces: nonces))
    }

    /// Recovers `K_lib`, or throws. Never returns approximate bytes: a wrong
    /// passphrase fails the GCM tag, and there is no branch here that can produce a
    /// key the tag did not vouch for.
    static func unwrap(_ wrapped: WrappedKey, passphrase: String, kid: String) throws -> SymmetricKey {
        guard wrapped.alg == algorithm else { throw Failure.unsupportedAlgorithm(wrapped.alg) }
        guard let salt = SnippetCrypto.data(fromBase64URL: wrapped.salt), !salt.isEmpty else {
            throw Failure.invalidParameters("salt is not base64url")
        }

        let wrapping = try derive(
            passphrase: passphrase, salt: salt, iterations: wrapped.iterations)
        let aad = additionalData(
            alg: wrapped.alg, iterations: wrapped.iterations, salt: salt, kid: kid)

        let material: Data
        do {
            material = try SnippetCrypto.open(wrapped.envelope, key: wrapping, aad: aad)
        } catch SnippetCrypto.Failure.authenticationFailed {
            // The only failure that depends on what the user typed. Everything else
            // below is a structural problem with the file and is reported as such, so
            // "your passphrase is wrong" never gets shown for a truncated file.
            throw Failure.wrongPassphrase
        }

        guard material.count == SnippetCrypto.keyByteCount else {
            throw Failure.invalidParameters("wrapped key is \(material.count) bytes")
        }
        return SymmetricKey(data: material)
    }
}
