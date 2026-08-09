import CryptoKit
import Foundation

/// A portable, password-protected snapshot of both halves of the snippet library.
///
/// The ordinary JSON export remains deliberately plaintext and deliberately excludes
/// the vault. This is a different format for a different job: disaster recovery rather
/// than sharing snippets with another person.
///
/// Secure record bodies are never opened while exporting. `vault.json` is copied as
/// ciphertext and `K_lib` is wrapped under the random per-backup key. The entire payload
/// is then sealed as one AEAD message, which also hides the secure metadata that is
/// intentionally plaintext in the live vault.
nonisolated enum EncryptedSnippetBackup {
    static let formatIdentifier = "com.khm.snippets.encrypted-backup"
    static let currentSchemaVersion = 1
    static let preferredFilenameExtension = "snippetsbackup"

    private static let payloadAADDomain = "snip.backup.payload.v1"
    private static let vaultKeyInfoPrefix = "snip.backup.vault-key.v1|"
    private static let vaultKeyAADDomain = "snip.backup.vault-key-aad.v1"

    enum Failure: Error, Equatable, LocalizedError {
        case emptyPassphrase
        case invalidFormat
        case unsupportedSchemaVersion(Int)
        case wrongPassphrase
        case damagedBackup
        case invalidPayload(String)

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase:
                return "Enter a password to protect the encrypted backup."
            case .invalidFormat:
                return "This is not a Snippets encrypted backup."
            case .unsupportedSchemaVersion(let version):
                return "This backup uses format version \(version), which this version of Snippets cannot read."
            case .wrongPassphrase:
                return "That password does not unlock this backup."
            case .damagedBackup:
                return "The backup is damaged or has been modified. Nothing was imported."
            case .invalidPayload(let detail):
                return "The backup contains an invalid snippet library: \(detail)"
            }
        }
    }

    struct Opened {
        var snippets: [Snippet]
        var vault: VaultDocument?
        var vaultKey: SymmetricKey?

        var ordinaryCount: Int { snippets.count }
        var secureCount: Int { vault?.records.count ?? 0 }
        var totalCount: Int { ordinaryCount + secureCount }
    }

    private struct Container: Codable {
        var format: String
        var schemaVersion: Int
        var backupID: String
        var wrappedKey: PassphraseKDF.WrappedKey
        var payload: String
    }

    private struct Payload: Codable {
        var schemaVersion: Int
        var snippets: [Snippet]
        var vault: VaultDocument?
        var wrappedVaultKey: String?
    }

    private struct FormatProbe: Decodable {
        var format: String
    }

    /// Cheap format detection for the import UI. Authentication still happens in
    /// `open`; this never treats the untrusted header as proof of anything.
    static func isEncryptedBackup(_ data: Data) -> Bool {
        (try? JSONDecoder().decode(FormatProbe.self, from: data).format) == formatIdentifier
    }

    static func isEncryptedBackup(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return isEncryptedBackup(data)
    }

    /// Builds a backup without decrypting a secure record body.
    ///
    /// `iterations` is injectable only so the test suite does not pay the shipping KDF
    /// cost dozens of times. Production callers use the pinned default.
    static func seal(
        snippets: [Snippet],
        vault: VaultDocument?,
        vaultKey: SymmetricKey?,
        passphrase: String,
        iterations: Int = PassphraseKDF.iterations,
        backupID: String = "b-\(UUID().uuidString.lowercased())",
        exportKey: SymmetricKey = SymmetricKey(size: .bits256),
        keyNonce: SnippetCrypto.NonceSource = .system,
        vaultKeyNonce: SnippetCrypto.NonceSource = .system,
        payloadNonce: SnippetCrypto.NonceSource = .system
    ) throws -> Data {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }
        guard !backupID.isEmpty else { throw Failure.invalidPayload("the backup identifier is empty") }
        try validateLibrary(snippets: snippets, vault: vault)

        let wrappedExportKey = try PassphraseKDF.wrap(
            exportKey,
            passphrase: passphrase,
            salt: PassphraseKDF.makeSalt(),
            kid: backupID,
            iterations: iterations,
            nonces: keyNonce)

        let wrappedVaultKey: String?
        switch (vault, vaultKey) {
        case (nil, nil):
            wrappedVaultKey = nil
        case (.some(let document), .some(let libraryKey)):
            guard libraryKey.bitCount == SnippetCrypto.keyByteCount * 8 else {
                throw Failure.invalidPayload("the vault key has the wrong size")
            }
            guard let salt = document.vaultSaltBytes else {
                throw Failure.invalidPayload("the vault salt is not valid base64url")
            }
            var rawLibraryKey = libraryKey.withUnsafeBytes { Data($0) }
            defer { wipe(&rawLibraryKey) }
            wrappedVaultKey = try SnippetCrypto.seal(
                rawLibraryKey,
                key: vaultWrappingKey(
                    exportKey: exportKey,
                    salt: salt,
                    backupID: backupID,
                    vaultKeyID: document.kid),
                aad: vaultKeyAAD(backupID: backupID, vaultKeyID: document.kid),
                nonces: vaultKeyNonce)
        case (nil, .some):
            throw Failure.invalidPayload("a vault key is present without a vault")
        case (.some, nil):
            throw Failure.invalidPayload("the vault key is missing")
        }

        let payload = Payload(
            schemaVersion: currentSchemaVersion,
            snippets: snippets,
            vault: vault,
            wrappedVaultKey: wrappedVaultKey)
        let payloadData = try makeEncoder().encode(payload)
        let sealedPayload = try SnippetCrypto.seal(
            payloadData,
            key: exportKey,
            aad: payloadAAD(
                backupID: backupID,
                schemaVersion: currentSchemaVersion,
                wrappedKey: wrappedExportKey),
            nonces: payloadNonce)

        return try makeEncoder().encode(Container(
            format: formatIdentifier,
            schemaVersion: currentSchemaVersion,
            backupID: backupID,
            wrappedKey: wrappedExportKey,
            payload: sealedPayload))
    }

    /// Authenticates every layer before returning anything importable. A wrong password
    /// is kept distinct for useful UI; all ciphertext/authentication failures after that
    /// collapse to one damaged-backup error.
    static func open(_ data: Data, passphrase: String) throws -> Opened {
        guard !passphrase.isEmpty else { throw Failure.emptyPassphrase }

        let container: Container
        do {
            container = try JSONDecoder().decode(Container.self, from: data)
        } catch {
            throw Failure.invalidFormat
        }
        guard container.format == formatIdentifier else { throw Failure.invalidFormat }
        guard container.schemaVersion == currentSchemaVersion else {
            throw Failure.unsupportedSchemaVersion(container.schemaVersion)
        }
        guard !container.backupID.isEmpty else {
            throw Failure.invalidPayload("the backup identifier is empty")
        }

        let exportKey: SymmetricKey
        do {
            exportKey = try PassphraseKDF.unwrap(
                container.wrappedKey,
                passphrase: passphrase,
                kid: container.backupID)
        } catch PassphraseKDF.Failure.wrongPassphrase {
            throw Failure.wrongPassphrase
        } catch PassphraseKDF.Failure.emptyPassphrase {
            throw Failure.emptyPassphrase
        } catch {
            throw Failure.invalidFormat
        }

        var payloadData: Data
        do {
            payloadData = try SnippetCrypto.open(
                container.payload,
                key: exportKey,
                aad: payloadAAD(
                    backupID: container.backupID,
                    schemaVersion: container.schemaVersion,
                    wrappedKey: container.wrappedKey))
        } catch {
            throw Failure.damagedBackup
        }
        defer { wipe(&payloadData) }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: payloadData)
        } catch {
            throw Failure.damagedBackup
        }
        guard payload.schemaVersion == currentSchemaVersion else {
            throw Failure.unsupportedSchemaVersion(payload.schemaVersion)
        }
        try validateLibrary(snippets: payload.snippets, vault: payload.vault)

        let libraryKey: SymmetricKey?
        switch (payload.vault, payload.wrappedVaultKey) {
        case (nil, nil):
            libraryKey = nil
        case (.some(let document), .some(let envelope)):
            guard let salt = document.vaultSaltBytes else {
                throw Failure.invalidPayload("the vault salt is not valid base64url")
            }
            var recovered: Data
            do {
                recovered = try SnippetCrypto.open(
                    envelope,
                    key: vaultWrappingKey(
                        exportKey: exportKey,
                        salt: salt,
                        backupID: container.backupID,
                        vaultKeyID: document.kid),
                    aad: vaultKeyAAD(
                        backupID: container.backupID,
                        vaultKeyID: document.kid))
            } catch {
                throw Failure.damagedBackup
            }
            defer { wipe(&recovered) }
            guard recovered.count == SnippetCrypto.keyByteCount else {
                throw Failure.damagedBackup
            }
            let key = SymmetricKey(data: recovered)
            try verify(document, with: key)
            libraryKey = key
        case (nil, .some):
            throw Failure.invalidPayload("a wrapped vault key is present without a vault")
        case (.some, nil):
            throw Failure.invalidPayload("the wrapped vault key is missing")
        }

        return Opened(snippets: payload.snippets, vault: payload.vault, vaultKey: libraryKey)
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func payloadAAD(
        backupID: String,
        schemaVersion: Int,
        wrappedKey: PassphraseKDF.WrappedKey
    ) -> Data {
        SnippetCrypto.domainSeparated(payloadAADDomain, [
            Data(formatIdentifier.utf8),
            withUnsafeBytes(of: UInt64(schemaVersion).bigEndian) { Data($0) },
            Data(backupID.utf8),
            Data(wrappedKey.alg.utf8),
            withUnsafeBytes(of: UInt64(wrappedKey.iterations).bigEndian) { Data($0) },
            Data(wrappedKey.salt.utf8),
            Data(wrappedKey.envelope.utf8),
        ])
    }

    private static func vaultWrappingKey(
        exportKey: SymmetricKey,
        salt: Data,
        backupID: String,
        vaultKeyID: String
    ) -> SymmetricKey {
        var info = Data(vaultKeyInfoPrefix.utf8)
        info.append(Data(backupID.utf8))
        info.append(0)
        info.append(Data(vaultKeyID.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: exportKey,
            salt: salt,
            info: info,
            outputByteCount: SnippetCrypto.keyByteCount)
    }

    private static func vaultKeyAAD(backupID: String, vaultKeyID: String) -> Data {
        SnippetCrypto.domainSeparated(vaultKeyAADDomain, [
            Data(SnippetCrypto.wireVersion.utf8),
            Data(backupID.utf8),
            Data(vaultKeyID.utf8),
        ])
    }

    private static func validateLibrary(snippets: [Snippet], vault: VaultDocument?) throws {
        var ids = Set<UUID>()
        var keywords: [String: String] = [:]

        func accept(id: UUID, keyword: String, displayName: String) throws {
            guard ids.insert(id).inserted else {
                throw Failure.invalidPayload("duplicate snippet ID \(id.uuidString)")
            }
            let normalized = SnippetTagging.filterKey(for: Snippet.sanitizedKeyword(keyword))
            guard !normalized.isEmpty else { return }
            if let existing = keywords[normalized] {
                throw Failure.invalidPayload(
                    "keyword \\\(Snippet.sanitizedKeyword(keyword)) is used by both \(existing) and \(displayName)")
            }
            keywords[normalized] = displayName
        }

        for snippet in snippets {
            try accept(
                id: snippet.id,
                keyword: snippet.keyword,
                displayName: snippet.displayName)
        }
        if let vault {
            guard vault.schemaVersion <= VaultDocument.currentSchemaVersion else {
                throw Failure.invalidPayload("the vault is from a newer version of Snippets")
            }
            guard !vault.records.isEmpty else {
                throw Failure.invalidPayload("an empty vault must be omitted")
            }
            for record in vault.records {
                let name = record.name.trimmingCharacters(in: .whitespacesAndNewlines)
                try accept(
                    id: record.id,
                    keyword: record.keyword,
                    displayName: name.isEmpty ? "Untitled Snippet" : name)
            }
        }
    }

    private static func verify(_ document: VaultDocument, with libraryKey: SymmetricKey) throws {
        guard let salt = document.vaultSaltBytes else { throw Failure.damagedBackup }
        let keyring = SnippetCrypto.Keyring(libraryKey: libraryKey, salt: salt)

        for record in document.records {
            var plaintext: Data
            do {
                plaintext = try SnippetCrypto.open(
                    record.sealed,
                    for: SnippetCrypto.RecordContext(
                        scopeID: document.kid,
                        recordID: record.id),
                    keyring: keyring)
            } catch {
                throw Failure.damagedBackup
            }
            defer { wipe(&plaintext) }
            guard SnippetCrypto.contentHash(of: plaintext, keyring: keyring) == record.contentHash else {
                throw Failure.damagedBackup
            }
        }
    }

    /// Best-effort zeroing of the mutable storage this layer owns. Swift can still
    /// have made copies outside this buffer, so this is hygiene rather than a promise
    /// that every historical byte has disappeared.
    private static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            _ = memset_s(baseAddress, bytes.count, 0, bytes.count)
        }
        data.removeAll(keepingCapacity: false)
    }
}
