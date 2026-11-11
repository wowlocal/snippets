import CryptoKit
import Foundation
import Testing
@testable import SnippetsCore

@Suite("Git library vault file")
struct GitSyncVaultTests {
    private static let material = Data((0..<64).map { UInt8($0) })
    private static let dataset = UUID(uuidString: "617a0001-0000-4000-8000-0000000000aa")!

    /// One vault, as a device that owns it would publish it under `secret`.
    private static func identity(
        key: SymmetricKey, salt: Data, kid: String = "k-0f1e2d3c-4b5", secret: Data,
        nonces: SnippetCrypto.NonceSource = .system
    ) throws -> GitSyncVault.Identity {
        GitSyncVault.Identity(
            kid: kid,
            vaultSalt: SnippetCrypto.base64URL(salt),
            kdf: .init(alg: PassphraseKDF.algorithm, iterations: PassphraseKDF.iterations, saltP: "AAECAwQFBgcICQoLDA0ODw"),
            wrapRecovery: try KeyWrap.wrap(
                key, under: secret, purpose: .recovery, kid: kid, salt: salt, nonces: nonces))
    }

    @Test func fileOpensOnlyWithItsLibraryKeyAndLibrary() throws {
        let keyring = SnippetCrypto.Keyring.generate()
        let identity = try Self.identity(
            key: keyring.libraryKey, salt: keyring.salt, secret: RecoveryKey.generate())
        let file = try GitSyncVault.seal(identity, material: Self.material, datasetID: Self.dataset)
        let text = try #require(String(data: file, encoding: .utf8))
        #expect(text.hasPrefix("{\n  \"algorithm\" : \"snippets-git-vault-hkdf-sha256-aes256gcm-v1\",\n  \"ciphertext\" : \""))
        #expect(text.hasSuffix("\",\n  \"datasetID\" : \"617a0001-0000-4000-8000-0000000000aa\",\n  \"schemaVersion\" : 1\n}\n"))
        // Nothing about the vault is readable without the library key.
        #expect(!text.contains(identity.kid) && !text.contains(identity.vaultSalt))
        #expect(!text.contains(identity.wrapRecovery))

        #expect(try GitSyncVault.open(file, material: Self.material, datasetID: Self.dataset) == identity)

        var otherKey = Self.material
        otherKey[0] ^= 1
        #expect(throws: GitSyncVault.Failure.incorrectKey) {
            _ = try GitSyncVault.open(file, material: otherKey, datasetID: Self.dataset)
        }
        var otherSalt = Self.material
        otherSalt[63] ^= 1
        #expect(throws: GitSyncVault.Failure.incorrectKey) {
            _ = try GitSyncVault.open(file, material: otherSalt, datasetID: Self.dataset)
        }
        // Another library's file is refused even under the same key.
        #expect(throws: GitSyncVault.Failure.invalidEnvelope) {
            _ = try GitSyncVault.open(file, material: Self.material, datasetID: UUID())
        }
        let moved = text.replacingOccurrences(
            of: "617a0001-0000-4000-8000-0000000000aa", with: "617a0001-0000-4000-8000-0000000000ab")
        #expect(throws: GitSyncVault.Failure.incorrectKey) {
            _ = try GitSyncVault.open(
                Data(moved.utf8), material: Self.material,
                datasetID: UUID(uuidString: "617a0001-0000-4000-8000-0000000000ab")!)
        }
        // A newer format reads as "update", never as damage to overwrite.
        let newer = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 2")
        #expect(throws: GitSyncVault.Failure.unsupportedVersion) {
            _ = try GitSyncVault.open(Data(newer.utf8), material: Self.material, datasetID: Self.dataset)
        }
        let newerShape = "{\"algorithm\":\"x\",\"schemaVersion\":2,\"wraps\":[]}"
        #expect(throws: GitSyncVault.Failure.unsupportedVersion) {
            _ = try GitSyncVault.open(Data(newerShape.utf8), material: Self.material, datasetID: Self.dataset)
        }
        for damaged in ["", "[]", "{}", String(text.dropLast(20)), text.replacingOccurrences(of: "-v1\"", with: "-v0\"")] {
            #expect(throws: GitSyncVault.Failure.invalidEnvelope) {
                _ = try GitSyncVault.open(Data(damaged.utf8), material: Self.material, datasetID: Self.dataset)
            }
        }
        #expect(throws: GitSyncVault.Failure.invalidEnvelope) {
            _ = try GitSyncVault.open(file, material: Self.material.prefix(63), datasetID: Self.dataset)
        }
    }

    @Test func onlyWellFormedIdentitiesAreWritten() throws {
        let keyring = SnippetCrypto.Keyring.generate()
        let good = try Self.identity(key: keyring.libraryKey, salt: keyring.salt, secret: RecoveryKey.generate())
        func variant(
            kid: String? = nil, vaultSalt: String? = nil, alg: String? = nil, iterations: Int? = nil,
            saltP: String? = nil, wrap: String? = nil
        ) -> GitSyncVault.Identity {
            GitSyncVault.Identity(
                kid: kid ?? good.kid, vaultSalt: vaultSalt ?? good.vaultSalt,
                kdf: .init(
                    alg: alg ?? good.kdf.alg, iterations: iterations ?? good.kdf.iterations,
                    saltP: saltP ?? good.kdf.saltP),
                wrapRecovery: wrap ?? good.wrapRecovery)
        }
        let bad = [
            variant(kid: ""), variant(kid: "k \"quoted\""), variant(kid: String(repeating: "k", count: 129)),
            variant(kid: "k-é"), variant(vaultSalt: "AAAA"), variant(vaultSalt: "not base64url!"),
            variant(alg: ""), variant(iterations: 0), variant(saltP: "+/=="), variant(wrap: ""),
            variant(wrap: "line\nbreak"), variant(wrap: String(repeating: "A", count: 1_025)),
        ]
        for identity in bad {
            #expect(throws: GitSyncVault.Failure.invalidEnvelope) {
                _ = try GitSyncVault.seal(identity, material: Self.material, datasetID: Self.dataset)
            }
        }
    }

    /// The whole point: a device that has nothing but the recovery code reaches the
    /// vault key, and the library key alone does not.
    @Test func oneRecoveryCodeOpensTheLibraryAndItsVaultKey() throws {
        let libraryMaterial = Data((0..<64).map { _ in UInt8.random(in: 0...255) })
        let vault = SnippetCrypto.Keyring.generate()
        let kit = GitSyncRecovery.Kit(datasetID: Self.dataset)
        let recoveryFile = try GitSyncRecovery.seal(material: libraryMaterial, kit: kit)
        let vaultFile = try GitSyncVault.seal(
            try Self.identity(key: vault.libraryKey, salt: vault.salt, secret: kit.secret),
            material: libraryMaterial, datasetID: Self.dataset)

        // The new device: the two files from the repository, and what the user typed.
        let typed = try GitSyncRecovery.Kit(code: kit.code.lowercased(), datasetID: Self.dataset)
        let opened = try GitSyncRecovery.open(recoveryFile, kit: typed)
        let identity = try GitSyncVault.open(vaultFile, material: opened, datasetID: Self.dataset)
        let salt = try #require(identity.vaultSaltBytes)
        let key = try KeyWrap.unwrap(
            identity.wrapRecovery, under: typed.secret, purpose: .recovery, kid: identity.kid, salt: salt)
        #expect(key.withUnsafeBytes { Data($0) } == vault.libraryKey.withUnsafeBytes { Data($0) })

        // A sealed body made on the first device opens on the second.
        let record = UUID()
        let context = SnippetCrypto.RecordContext(scopeID: identity.kid, recordID: record)
        let sealed = try SnippetCrypto.seal(Data("hunter2".utf8), for: context, keyring: vault)
        let joined = SnippetCrypto.Keyring(libraryKey: key, salt: salt)
        #expect(try SnippetCrypto.open(sealed, for: context, keyring: joined) == Data("hunter2".utf8))

        // Holding the library key (every syncing device does) is not enough.
        let other = GitSyncRecovery.Kit(datasetID: Self.dataset)
        #expect(throws: KeyWrap.Failure.wrongKey(.recovery)) {
            _ = try KeyWrap.unwrap(
                identity.wrapRecovery, under: other.secret, purpose: .recovery, kid: identity.kid, salt: salt)
        }
        #expect(throws: KeyWrap.Failure.wrongKey(.recovery)) {
            _ = try KeyWrap.unwrap(
                identity.wrapRecovery, under: opened.prefix(16), purpose: .recovery, kid: identity.kid, salt: salt)
        }
    }

    /// Fixed bytes shared with `snippets-linux` (`git_tests.rs`): both sides must open
    /// this file and unwrap this key. Change them together.
    @Test func knownAnswerMatchesTheLinuxMirror() throws {
        let key = SymmetricKey(data: Data((0..<32).map { UInt8(0x80 + $0) }))
        let salt = Data((0..<32).map { UInt8(0x40 + $0) })
        let secret = Data((0..<16).map { UInt8(0xa0 + $0) })
        let wrapNonce = Data((0..<12).map { UInt8(0x10 + $0) })
        let identity = try Self.identity(
            key: key, salt: salt, secret: secret, nonces: SnippetCrypto.NonceSource { wrapNonce })
        let file = try GitSyncVault.seal(
            identity, material: Self.material, datasetID: Self.dataset,
            nonce: try AES.GCM.Nonce(data: Data((0..<12).map { UInt8(0x20 + $0) })))
        #expect(try RecoveryKey.formatted(secret) == Self.knownCode)
        #expect(identity.wrapRecovery == Self.knownWrap)
        #expect(String(decoding: file, as: UTF8.self) == Self.knownFile)

        let opened = try GitSyncVault.open(Data(Self.knownFile.utf8), material: Self.material, datasetID: Self.dataset)
        #expect(opened == identity)
        let unwrapped = try KeyWrap.unwrap(
            opened.wrapRecovery, under: try RecoveryKey.decode(Self.knownCode), purpose: .recovery,
            kid: opened.kid, salt: salt)
        #expect(unwrapped.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
    }

    private static let knownCode = "M2GT-58X4-MPKA-FA59-NANT-SBDE-NWJ"
    private static let knownWrap =
        "v1.EBESExQVFhcYGRob.qUF4uXZngBvzSRgme_SKaRQDkG-x67b2_sbB8MU6aK6jjnoZqp7TQGXxuoj-7Mf_Vz_Yw697Ajxzygx1rVrF-Qy0RkQqGDiLVfEUNhedNvQr4o0l6Q_9hWxHiaxMkenw9HpreSqCE93FTxFr8siez0bnIPGvOCsVY8L7R_C2o7fEWIPVMRV1cDmXepTFGsf4lp_Wi8yAe4z0o7SwO_sLbuVXooNbn_3VVHyYWsgr6wtdsJC5ZJu5o3BJlNInXj08zidXd8pPj6sJoF8XHX9Y9BDxZ_XgUIkmK2DB_jyi7cIXTNJsEo0ApPvCQOrZTLYLgfRs7tia7CFlrLJrUHHluOjnQOHfRlRfZYN8y6MBqUU"
    private static let knownCiphertext =
        "ICEiIyQlJicoKSorul4Dv23bwTOhvOYKTu1b+0rWFeE2UdslKKtfLiTwkw4Q/aNUqUeyELUg84tqzJwhiQQlOtY9MBswBrDtosF2sCT2cE0McqvKBXTN9ppi/ZtjnlfXiG3yNd2DBGJHKMBCzoAf3Pipt/jhmrui2oUL6JFhWQR/tbcoC1kgdISIQO7tlMHMvClol2oPGArvEFk+GhHYVhdoIuGG/kO9Vt29GSbUq6wFi7YBXf4uZPMOeQP6OZh5mNLcY8nKqqnGPibPYxjKHXQ14Pl++Yhwzq3T612lwlt6hPHQSWnUChK9/8/W3SsYa+ulItytSDrG0rGWT01u8AdipQ9qG3OIlz3D/KlUJKrOhfgKpIGooirpC7+IhGqTisPc2koF9Lo3EC3WFlHNXGj/cUHXHkYIrM3OvtwfY4fxpMqaWzDyy4nd8xGOQhRK9KCCvkbian9NMKi/doF8+Yq3sokaNyOz5ixd80mYT47c4v2Kg9d/hURNrpDBgub2NbenZQsoyMvTmoelRgxST4VtNF8WAlkA9GRYDST6oXRrNkzqSo3tVMgkHIt8uxT5uZyYGksiiroicR3GbZ1qBd48/waDrljrtld4LODOWlrrAs90TOTcKAqiyPWPEWLrsO1ASsFdpeuNVZpuwd3GH8q5ySIKqJe9rP5ISGb3LR/osq3EshxTrRwwBPGfAJ9eEaGT85wpsiJfvd60bTh5VCAVnLNNCL47xkI/Drtv9PhBA4YDeCYS5BNUfGTGPYEs10IQhlnN9snawHg13t1hvxpO2ONSHVw1s+7afsptDD9Jrb6XixZsJx0="
    private static let knownFile = "{\n  \"algorithm\" : \"snippets-git-vault-hkdf-sha256-aes256gcm-v1\",\n"
        + "  \"ciphertext\" : \"" + knownCiphertext + "\",\n"
        + "  \"datasetID\" : \"617a0001-0000-4000-8000-0000000000aa\",\n  \"schemaVersion\" : 1\n}\n"
}
