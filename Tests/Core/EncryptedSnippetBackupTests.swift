import CryptoKit
import Foundation
import Testing

@testable import SnippetsCore

@Suite("Encrypted snippet backup")
struct EncryptedSnippetBackupTests {
    private let fastIterations = 2_000
    private let passphrase = "correct horse battery staple"

    @Test func roundTripKeepsBothLibrariesAndAllMetadataInsideCiphertext() throws {
        let ordinary = Snippet(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
            name: "Team greeting",
            keyword: "hello-team",
            content: "Hello colleagues",
            tags: ["Shared"],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 200))
        let secureBody = Data("swordfish-9134".utf8)
        let (vault, vaultKey) = try makeVault(body: secureBody)

        let data = try EncryptedSnippetBackup.seal(
            snippets: [ordinary],
            vault: vault,
            vaultKey: vaultKey,
            passphrase: passphrase,
            iterations: fastIterations)

        #expect(EncryptedSnippetBackup.isEncryptedBackup(data))
        for secret in [
            ordinary.name, ordinary.keyword, ordinary.content,
            vault.records[0].name, vault.records[0].keyword,
            String(decoding: secureBody, as: UTF8.self),
        ] {
            #expect(data.range(of: Data(secret.utf8)) == nil)
        }
        #expect(data.range(of: keyBytes(vaultKey)) == nil)
        #expect(data.range(of: Data(passphrase.utf8)) == nil)

        let opened = try EncryptedSnippetBackup.open(data, passphrase: passphrase)
        #expect(opened.snippets == [ordinary])
        #expect(opened.vault == vault)
        #expect(opened.ordinaryCount == 1)
        #expect(opened.secureCount == 1)
        #expect(opened.totalCount == 2)
        #expect(opened.vaultKey.map(keyBytes) == keyBytes(vaultKey))
    }

    @Test func ordinaryOnlyBackupsNeedNoVaultKey() throws {
        let snippet = Snippet(name: "Ordinary", keyword: "ordinary", content: "text")
        let data = try EncryptedSnippetBackup.seal(
            snippets: [snippet],
            vault: nil,
            vaultKey: nil,
            passphrase: passphrase,
            iterations: fastIterations)

        let opened = try EncryptedSnippetBackup.open(data, passphrase: passphrase)
        #expect(opened.snippets == [snippet])
        #expect(opened.vault == nil)
        #expect(opened.vaultKey == nil)
    }

    @Test func wrongPasswordIsRefusedWithoutReturningPartialData() throws {
        let data = try EncryptedSnippetBackup.seal(
            snippets: [Snippet(name: "A", keyword: "a", content: "body")],
            vault: nil,
            vaultKey: nil,
            passphrase: passphrase,
            iterations: fastIterations)

        #expect(throws: EncryptedSnippetBackup.Failure.wrongPassphrase) {
            try EncryptedSnippetBackup.open(data, passphrase: "wrong password")
        }
    }

    @Test func modifyingThePayloadFailsAuthentication() throws {
        let data = try EncryptedSnippetBackup.seal(
            snippets: [Snippet(name: "A", keyword: "a", content: "body")],
            vault: nil,
            vaultKey: nil,
            passphrase: passphrase,
            iterations: fastIterations)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var payload = try #require(json["payload"] as? String)
        let index = payload.index(before: payload.endIndex)
        payload.replaceSubrange(index...index, with: payload[index] == "A" ? "B" : "A")
        json["payload"] = payload
        let tampered = try JSONSerialization.data(withJSONObject: json)

        #expect(throws: EncryptedSnippetBackup.Failure.damagedBackup) {
            try EncryptedSnippetBackup.open(tampered, passphrase: passphrase)
        }
    }

    @Test func duplicateIdentityAcrossPlaintextAndVaultIsRefusedBeforeWritingAFile() throws {
        let id = UUID()
        let ordinary = Snippet(id: id, name: "Ordinary", keyword: "same", content: "body")
        let (vault, vaultKey) = try makeVault(body: Data("secret".utf8), recordID: id)

        #expect(throws: EncryptedSnippetBackup.Failure.self) {
            try EncryptedSnippetBackup.seal(
                snippets: [ordinary],
                vault: vault,
                vaultKey: vaultKey,
                passphrase: passphrase,
                iterations: fastIterations)
        }
    }

    @Test func anEmptyVaultIsOmittedRatherThanCarryingAnUnverifiableKey() throws {
        var (vault, vaultKey) = try makeVault(body: Data("secret".utf8))
        vault.records = []

        #expect(throws: EncryptedSnippetBackup.Failure.self) {
            try EncryptedSnippetBackup.seal(
                snippets: [],
                vault: vault,
                vaultKey: vaultKey,
                passphrase: passphrase,
                iterations: fastIterations)
        }
    }

    private func makeVault(
        body: Data,
        recordID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    ) throws -> (VaultDocument, SymmetricKey) {
        let ring = SnippetCrypto.Keyring.generate()
        let kid = "k-backup-tests"
        let record = VaultRecord(
            id: recordID,
            name: "Production password",
            keyword: "prod-secret",
            tags: ["Private"],
            isEnabled: true,
            isPinned: true,
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 400),
            hlc: HLC(wallMs: 400_000, counter: 0, device: "aabbccdd"),
            contentHash: SnippetCrypto.contentHash(of: body, keyring: ring),
            sealed: try SnippetCrypto.seal(
                body,
                for: SnippetCrypto.RecordContext(scopeID: kid, recordID: recordID),
                keyring: ring))
        let document = VaultDocument(
            kid: kid,
            vaultSalt: SnippetCrypto.base64URL(ring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(PassphraseKDF.makeSalt())),
            records: [record])
        return (document, ring.libraryKey)
    }

    private func keyBytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }
}
