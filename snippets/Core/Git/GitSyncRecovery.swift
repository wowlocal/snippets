import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// Compiled into the apps and the test package. Not part of `snippets-cli`.

/// The offline way to give another device a Git library's key.
///
/// The library key (`K_sync` material: 32-byte key plus 32-byte HKDF salt) never goes to
/// the host in the clear. The repository holds `keys/recovery.json`, the portable key
/// bundle sealed under a key derived from a 128-bit recovery code that only the user has.
/// A device that receives the key some other way (iCloud Keychain on Apple devices)
/// never needs the code.
///
/// The code reuses `RecoveryKey`'s format: 27 Crockford symbols with a full check
/// symbol, so a typo is reported as a typo instead of as a wrong code. It is bound to
/// the library's random dataset id, not to the host, so moving the repository to another
/// host keeps the same code valid while a code can never open a different library.
///
/// Replacing the envelope does not revoke an older code: git history keeps every
/// envelope. Revoking a leaked code means creating a new library.
nonisolated enum GitSyncRecovery {
    static let path = "keys/recovery.json"
    static let algorithm = "snippets-git-recovery-hkdf-sha256-aes256gcm-v1"
    static let schemaVersion = 1
    private static let maximumFileBytes = 8_192

    enum Failure: Error, Equatable, Sendable {
        /// Not a well-formed recovery code (length, alphabet or check symbol).
        case invalidCode
        /// A well-formed code that does not open this library's envelope.
        case incorrectCode
        /// The repository's envelope is missing, malformed, or for another library.
        case invalidEnvelope
    }

    struct Kit: Equatable, Sendable {
        let datasetID: UUID
        let secret: Data

        init(datasetID: UUID, secret: Data = RecoveryKey.generate()) {
            precondition(secret.count == RecoveryKey.byteCount)
            self.datasetID = datasetID
            self.secret = secret
        }

        /// Accepts what a person types: case, spaces, dashes and the classic
        /// misreadings are normalized by `RecoveryKey.decode`.
        init(code: String, datasetID: UUID) throws {
            guard let secret = try? RecoveryKey.decode(code) else { throw Failure.invalidCode }
            self.init(datasetID: datasetID, secret: secret)
        }

        /// `XXXX-XXXX-XXXX-XXXX-XXXX-XXXX-XXX`.
        var code: String { (try? RecoveryKey.formatted(secret)) ?? "" }
    }

    private struct File: Codable {
        let algorithm: String
        let ciphertext: String
        let datasetID: String
        let schemaVersion: Int
    }

    /// The `keys/recovery.json` bytes for `material` under `kit`.
    static func seal(material: Data, kit: Kit) throws -> Data {
        let bundle = try LibraryKeyBootstrap.PortableKeyBundle(material: material)
        let aad = associatedData(kit.datasetID)
        let sealed = try AES.GCM.seal(try bundle.jsonData, using: key(for: kit, aad: aad), authenticating: aad)
        guard let combined = sealed.combined else { throw Failure.invalidEnvelope }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var data = try encoder.encode(File(
            algorithm: algorithm, ciphertext: combined.base64EncodedString(),
            datasetID: kit.datasetID.uuidString.lowercased(), schemaVersion: schemaVersion))
        data.append(UInt8(ascii: "\n"))
        return data
    }

    /// The 64-byte material inside `file`, or `incorrectCode` if `kit` does not open it.
    static func open(_ file: Data, kit: Kit) throws -> Data {
        guard file.count <= maximumFileBytes,
              let object = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
              Set(object.keys) == ["algorithm", "ciphertext", "datasetID", "schemaVersion"],
              let decoded = try? JSONDecoder().decode(File.self, from: file),
              decoded.schemaVersion == schemaVersion,
              decoded.algorithm == algorithm,
              decoded.datasetID == kit.datasetID.uuidString.lowercased(),
              let combined = Data(base64Encoded: decoded.ciphertext),
              combined.base64EncodedString() == decoded.ciphertext,
              let box = try? AES.GCM.SealedBox(combined: combined) else {
            throw Failure.invalidEnvelope
        }
        let aad = associatedData(kit.datasetID)
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(box, using: key(for: kit, aad: aad), authenticating: aad)
        } catch {
            throw Failure.incorrectCode
        }
        guard let bundle = try? LibraryKeyBootstrap.PortableKeyBundle(jsonData: plaintext) else {
            throw Failure.invalidEnvelope
        }
        return bundle.material
    }

    private static func associatedData(_ datasetID: UUID) -> Data {
        Data(["snippets-git-recovery-v1", datasetID.uuidString.lowercased()].joined(separator: "\0").utf8)
    }

    private static func key(for kit: Kit, aad: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: kit.secret),
            salt: Data("snippets-git-recovery-salt-v1".utf8),
            info: aad,
            outputByteCount: 32)
    }
}
