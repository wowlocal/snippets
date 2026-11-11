import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// What a Git library says about its secure-snippet vault, so the library's one
/// recovery code also opens secure snippets on a new device.
///
/// A secure snippet's body is sealed under the vault key, which the library key never
/// protects. A device that joins with the recovery code therefore needs two more
/// things: which vault the library uses (`kid` and salt, the crypto scope of every
/// sealed body) and the vault key itself. `keys/vault.json` carries both: the identity,
/// and the vault key wrapped under the library's recovery code with `KeyWrap`
/// (purpose `recovery`, the wrap `vault.json` keeps as `wrapRecovery`).
///
/// The file is sealed under a key derived from the library key, with the dataset id in
/// the associated data. Only a device that already opened the library can read or
/// replace it, and it cannot be moved to another library.
///
/// The library key alone never yields the vault key: that takes the recovery code,
/// which no device stores. So background sync still cannot open a secure snippet. A
/// passphrase wrap is never published: a repository is exactly where an offline
/// guessing target must not go.
///
/// As with `GitSyncRecovery`, replacing the file does not revoke an older code: git
/// history keeps every earlier wrap.
nonisolated enum GitSyncVault {
    static let path = "keys/vault.json"
    static let algorithm = "snippets-git-vault-hkdf-sha256-aes256gcm-v1"
    static let schemaVersion = 1
    private static let maximumFileBytes = 8_192
    private static let materialByteCount = 64

    enum Failure: Error, Equatable, Sendable {
        /// Missing fields, another library's file, or values outside the format.
        case invalidEnvelope
        /// Written by a newer build. Never replace it from this one.
        case unsupportedVersion
        /// The library key does not open the file: another key, or tampering.
        case incorrectKey
    }

    /// The vault a library uses. Nothing here opens a secure snippet without the
    /// recovery code.
    struct Identity: Equatable, Sendable {
        /// The parameters of the optional passphrase wrap. They travel so that devices
        /// sharing one vault keep one identity; the passphrase wrap itself never does.
        struct KDF: Equatable, Sendable, Codable {
            let alg: String
            let iterations: Int
            let saltP: String

            init(alg: String, iterations: Int, saltP: String) {
                self.alg = alg
                self.iterations = iterations
                self.saltP = saltP
            }

            init(_ parameters: VaultKDFParameters) {
                self.init(alg: parameters.alg, iterations: parameters.iterations, saltP: parameters.saltP)
            }

            /// The same parameters as `vault.json` stores them.
            var vaultParameters: VaultKDFParameters {
                VaultKDFParameters(alg: alg, iterations: iterations, saltP: saltP)
            }
        }

        let kid: String
        /// base64url, unpadded, as in `VaultDocument.vaultSalt`.
        let vaultSalt: String
        let kdf: KDF
        /// The vault key under the library's recovery code.
        let wrapRecovery: String

        var vaultSaltBytes: Data? { SnippetCrypto.data(fromBase64URL: vaultSalt) }

        /// The shape every writer produces. A reader refuses anything else, so a file
        /// can never smuggle an oversized or unprintable value into `vault.json`.
        fileprivate var isWellFormed: Bool {
            Self.isToken(kid, limit: 128)
                && vaultSaltBytes?.count == SnippetCrypto.saltByteCount
                && Self.isToken(kdf.alg, limit: 64)
                && (1...100_000_000).contains(kdf.iterations)
                && Self.isToken(kdf.saltP, limit: 128)
                && SnippetCrypto.data(fromBase64URL: kdf.saltP) != nil
                && Self.isToken(wrapRecovery, limit: 1_024)
        }

        /// Printable ASCII without quotes or backslashes, so the canonical JSON below
        /// has one spelling in every encoder.
        private static func isToken(_ text: String, limit: Int) -> Bool {
            let bytes = Array(text.utf8)
            return !bytes.isEmpty && bytes.count <= limit && bytes.allSatisfy {
                (0x21...0x7e).contains($0) && $0 != UInt8(ascii: "\"") && $0 != UInt8(ascii: "\\")
            }
        }
    }

    private struct Payload: Codable {
        let kdf: Identity.KDF
        let kid: String
        let schemaVersion: Int
        let vaultSalt: String
        let wrapRecovery: String
    }

    private struct File: Codable {
        let algorithm: String
        let ciphertext: String
        let datasetID: String
        let schemaVersion: Int
    }

    /// The `keys/vault.json` bytes for `identity`, readable with the library key
    /// `material` (64 bytes: key, then salt). `nonce` is a test seam.
    static func seal(
        _ identity: Identity, material: Data, datasetID: UUID, nonce: AES.GCM.Nonce? = nil
    ) throws -> Data {
        guard identity.isWellFormed else { throw Failure.invalidEnvelope }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let plaintext = try encoder.encode(Payload(
            kdf: identity.kdf, kid: identity.kid, schemaVersion: schemaVersion,
            vaultSalt: identity.vaultSalt, wrapRecovery: identity.wrapRecovery))
        let aad = associatedData(datasetID)
        let sealed = try AES.GCM.seal(
            plaintext, using: try key(material: material, aad: aad), nonce: nonce, authenticating: aad)
        guard let combined = sealed.combined else { throw Failure.invalidEnvelope }
        let fileEncoder = JSONEncoder()
        fileEncoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try fileEncoder.encode(File(
            algorithm: algorithm, ciphertext: combined.base64EncodedString(),
            datasetID: datasetID.uuidString.lowercased(), schemaVersion: schemaVersion))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The identity inside `file`, authenticated by the library key and bound to
    /// `datasetID`.
    static func open(_ file: Data, material: Data, datasetID: UUID) throws -> Identity {
        guard file.count <= maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: file) as? [String: Any] else {
            throw Failure.invalidEnvelope
        }
        // Probe the version before the shape: a newer format may carry other keys, and
        // it must read as "update Snippets", never as a damaged file to overwrite.
        if let version = object["schemaVersion"] as? Int, version > schemaVersion {
            throw Failure.unsupportedVersion
        }
        guard Set(object.keys) == ["algorithm", "ciphertext", "datasetID", "schemaVersion"],
              let decoded = try? JSONDecoder().decode(File.self, from: file) else {
            throw Failure.invalidEnvelope
        }
        guard decoded.schemaVersion == schemaVersion,
              decoded.algorithm == algorithm,
              decoded.datasetID == datasetID.uuidString.lowercased(),
              let combined = Data(base64Encoded: decoded.ciphertext),
              combined.base64EncodedString() == decoded.ciphertext,
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw Failure.invalidEnvelope
        }
        let aad = associatedData(datasetID)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: try key(material: material, aad: aad), authenticating: aad)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.incorrectKey
        }
        guard let fields = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              Set(fields.keys) == ["kdf", "kid", "schemaVersion", "vaultSalt", "wrapRecovery"],
              let kdf = fields["kdf"] as? [String: Any],
              Set(kdf.keys) == ["alg", "iterations", "saltP"],
              let payload = try? JSONDecoder().decode(Payload.self, from: plaintext),
              payload.schemaVersion == schemaVersion else {
            throw Failure.invalidEnvelope
        }
        let identity = Identity(
            kid: payload.kid, vaultSalt: payload.vaultSalt, kdf: payload.kdf,
            wrapRecovery: payload.wrapRecovery)
        guard identity.isWellFormed else { throw Failure.invalidEnvelope }
        return identity
    }

    private static func associatedData(_ datasetID: UUID) -> Data {
        Data(["snippets-git-vault-v1", datasetID.uuidString.lowercased()].joined(separator: "\0").utf8)
    }

    /// A key of its own, so the file's key is never the one that seals records.
    private static func key(material: Data, aad: Data) throws -> SymmetricKey {
        guard material.count == materialByteCount else { throw Failure.invalidEnvelope }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: material.prefix(SnippetCrypto.keyByteCount)),
            salt: Data(material.suffix(SnippetCrypto.saltByteCount)),
            info: aad,
            outputByteCount: SnippetCrypto.keyByteCount)
    }
}
