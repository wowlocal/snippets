import Foundation
import CryptoKit
import Testing

@testable import SnippetsCore

// The seams between the three layers that were written separately: the crypto
// (`SnippetCrypto`, `PassphraseKDF`, `KeyWrap`, `RecoveryKey`), the file format
// (`VaultDocument`), and the wire (`SyncEnvelope`, `WireCodec`).
//
// Every other test file exercises one layer against its own fixtures. That is what let
// two of these seams ship broken while 275 tests stayed green: `VaultDocument` treats
// every blob as an opaque `String`, so its tests pass with `alg: "pbkdf2-hmac-sha256"`
// and a standard-base64 salt — neither of which the crypto layer will accept. The two
// specific failures are pinned by name below, because a comment saying "don't do that"
// is not a test.
//
// Nothing here is a unit test of anything. Each one is a whole trip: make a vault,
// write it, read it back, unlock it, use it.

// MARK: - Fixtures

private let vaultKID = "k-7f3a91c0"

private func scratchFolder(_ label: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("snippets-integration-\(label)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Everything the app holds after a vault is created, in the order it is produced.
private struct NewVault {
    var keyring: SnippetCrypto.Keyring
    var recoveryKey: Data
    var cliSecret: Data
    var document: VaultDocument

    /// The one place in the test suite that builds a vault the way the app must. If
    /// this function cannot be written using only public API, the API is wrong.
    init(passphrase: String, iterations: Int) throws {
        keyring = SnippetCrypto.Keyring.generate()
        recoveryKey = RecoveryKey.generate()
        cliSecret = SnippetCrypto.randomBytes(SecretStoreLimits.secretByteCount)

        let passphraseWrap = try PassphraseKDF.wrap(
            keyring.libraryKey,
            passphrase: passphrase,
            salt: PassphraseKDF.makeSalt(),
            kid: vaultKID,
            iterations: iterations)

        document = VaultDocument(
            kid: vaultKID,
            // base64url, from the crypto layer's own encoder, so the two cannot disagree.
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            // Derived from the wrap rather than restated, so `alg` cannot drift.
            kdf: VaultKDFParameters(passphraseWrap),
            wrapPass: passphraseWrap.envelope,
            wrapRecovery: try KeyWrap.wrap(
                keyring.libraryKey, under: recoveryKey,
                purpose: .recovery, kid: vaultKID, salt: keyring.salt),
            wrapCLI: try KeyWrap.wrap(
                keyring.libraryKey, under: cliSecret,
                purpose: .cli, kid: vaultKID, salt: keyring.salt),
            records: [])
    }
}

private func keyBytes(_ key: SymmetricKey) -> Data {
    key.withUnsafeBytes { Data($0) }
}

/// Cheap enough to run in every test; the pinned 600 000 is covered in `CryptoTests`.
private let fastIterations = 2_000

@Suite("Vault, crypto and wire together")
struct VaultIntegrationTests {

    // MARK: - The two seams that were broken

    /// A vault built through the public API must open with the passphrase that built it.
    ///
    /// This is the regression test for the worst defect in the merge. `VaultDocument`
    /// used to publish `pbkdf2HMACSHA256 = "pbkdf2-hmac-sha256"` next to
    /// `recommendedPBKDF2Iterations`, documented as advisory. `PassphraseKDF` speaks
    /// SHA-**512**. The natural call site — `VaultKDFParameters(alg: .pbkdf2HMACSHA256,
    /// …)` — therefore wrote a vault whose own unwrap path refuses it with
    /// `unsupportedAlgorithm`, and nothing anywhere failed until the user came back for
    /// their secrets and found the file permanently unopenable. Both constants are gone
    /// and `VaultKDFParameters(_:)` copies the algorithm out of the wrap itself.
    @Test func avaultBuiltThroughThePublicAPIUnlocksWithItsOwnPassphrase() throws {
        let vault = try NewVault(passphrase: "correct horse battery staple", iterations: fastIterations)

        let recovered = try PassphraseKDF.unwrap(
            try #require(vault.document.passphraseWrap), passphrase: "correct horse battery staple", kid: vault.document.kid)

        #expect(keyBytes(recovered) == keyBytes(vault.keyring.libraryKey))
        #expect(vault.document.kdf.alg == PassphraseKDF.algorithm)
    }

    /// The other one. `vaultSalt` and `saltP` were documented as "Base64", while
    /// `SnippetCrypto.data(fromBase64URL:)` deliberately rejects `+`, `/` and `=` so an
    /// envelope has exactly one spelling. A 16-byte salt in standard base64 always ends
    /// `==`, so the round trip returned `nil` — and a caller who wrote `?? Data()` would
    /// have derived every key in the vault under an empty salt.
    @Test func thesaltsRoundTripThroughTheEncodingTheCryptoLayerActuallyAccepts() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)

        let saltBack = try #require(
            vault.document.vaultSaltBytes,
            "vaultSalt must be base64url — the crypto layer will not decode anything else")
        #expect(saltBack == vault.keyring.salt)

        let kdfSalt = try #require(SnippetCrypto.data(fromBase64URL: vault.document.kdf.saltP))
        #expect(kdfSalt.count == PassphraseKDF.saltByteCount)

        for salt in [vault.document.vaultSalt, vault.document.kdf.saltP] {
            #expect(!salt.contains("="))
            #expect(!salt.contains("+"))
            #expect(!salt.contains("/"))
        }
    }

    // MARK: - All three doors

    /// Every door opens the same `K_lib`. A vault where the recovery key yields a
    /// *different* key than the passphrase is one the user can log into and still not
    /// read, which is worse than being locked out because it looks like data loss.
    @Test func allthreeDoorsRecoverTheIdenticalLibraryKey() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let expected = keyBytes(vault.keyring.libraryKey)
        let salt = try #require(vault.document.vaultSaltBytes)

        #expect(keyBytes(try PassphraseKDF.unwrap(
            try #require(vault.document.passphraseWrap), passphrase: "p", kid: vault.document.kid)) == expected)

        #expect(keyBytes(try KeyWrap.unwrap(
            try #require(vault.document.wrapRecovery), under: vault.recoveryKey,
            purpose: .recovery, kid: vault.document.kid, salt: salt)) == expected)

        let cliBlob = try #require(vault.document.wrapCLI)
        #expect(keyBytes(try KeyWrap.unwrap(
            cliBlob, under: vault.cliSecret,
            purpose: .cli, kid: vault.document.kid, salt: salt)) == expected)
    }

    /// The recovery key is the door the user reaches through a printed card, so the
    /// trip through its printed form is part of the door.
    @Test func therecoveryDoorWorksFromTheFormOfTheKeyTheUserActuallyHas() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let salt = try #require(vault.document.vaultSaltBytes)

        let printed = try RecoveryKey.formatted(vault.recoveryKey)
        // Typed back in the way people actually type: lower case, spaces for dashes.
        let retyped = try RecoveryKey.decode(printed.lowercased().replacingOccurrences(of: "-", with: " "))

        #expect(keyBytes(try KeyWrap.unwrap(
            try #require(vault.document.wrapRecovery), under: retyped,
            purpose: .recovery, kid: vault.document.kid, salt: salt))
            == keyBytes(vault.keyring.libraryKey))
    }

    /// Swapping the two wrap blobs must not work. Without purpose separation, a
    /// `wrapCLI` blob renamed to `wrapRecovery` in the file would open under the CLI
    /// secret — quietly making the weaker of the two doors the only one that matters.
    @Test func awrapBlobCannotBeMovedFromOneDoorToTheOther() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let salt = try #require(vault.document.vaultSaltBytes)
        let cliBlob = try #require(vault.document.wrapCLI)

        #expect(throws: KeyWrap.Failure.wrongKey(.recovery)) {
            try KeyWrap.unwrap(
                cliBlob, under: vault.cliSecret,
                purpose: .recovery, kid: vault.document.kid, salt: salt)
        }
        #expect(throws: KeyWrap.Failure.wrongKey(.cli)) {
            try KeyWrap.unwrap(
                try #require(vault.document.wrapRecovery), under: vault.recoveryKey,
                purpose: .cli, kid: vault.document.kid, salt: salt)
        }
    }

    /// Purpose separation is enforced twice — the purpose is in the HKDF `info` (so the
    /// two doors have different wrapping keys) *and* in the AAD. The test above passes
    /// while either one survives, so on its own it cannot tell whether both are working.
    /// These two pin each binding with the other held constant, the same way
    /// `IdentityBinding` pins the record id through the key and through the AAD
    /// separately. Both were found unpinned by deleting each in turn and watching the
    /// suite stay green.
    @Test func thepurposeBindsThroughTheAADEvenWhenTheWrappingKeyIsHeldConstant() throws {
        let material = RecoveryKey.generate()
        let salt = SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount)
        let key = try KeyWrap.wrappingKey(from: material, purpose: .recovery, salt: salt)
        let secret = SnippetCrypto.randomBytes(SnippetCrypto.keyByteCount)

        let envelope = try SnippetCrypto.seal(
            secret, key: key, aad: KeyWrap.additionalData(purpose: .recovery, kid: vaultKID))

        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(
                envelope, key: key, aad: KeyWrap.additionalData(purpose: .cli, kid: vaultKID))
        }
    }

    @Test func thepurposeBindsThroughTheWrappingKeyEvenWhenTheAADIsHeldConstant() throws {
        let material = RecoveryKey.generate()
        let salt = SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount)
        let aad = KeyWrap.additionalData(purpose: .recovery, kid: vaultKID)
        let secret = SnippetCrypto.randomBytes(SnippetCrypto.keyByteCount)

        let recoveryWrappingKey = try KeyWrap.wrappingKey(from: material, purpose: .recovery, salt: salt)
        let cliWrappingKey = try KeyWrap.wrappingKey(from: material, purpose: .cli, salt: salt)
        #expect(keyBytes(recoveryWrappingKey) != keyBytes(cliWrappingKey))

        let envelope = try SnippetCrypto.seal(secret, key: recoveryWrappingKey, aad: aad)

        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(envelope, key: cliWrappingKey, aad: aad)
        }
    }

    /// Every wrap of `K_lib` authenticates the vault it belongs to, so a blob left over
    /// from before a rekey fails at the door rather than unwrapping to a stale key that
    /// then fails to open every record — the same end state, reported somewhere the user
    /// can act on.
    @Test func awrapFromAnotherVaultIsRefusedByAllThreeDoors() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let salt = try #require(vault.document.vaultSaltBytes)
        let otherKID = "k-after-rekey"

        #expect(throws: PassphraseKDF.Failure.wrongPassphrase) {
            try PassphraseKDF.unwrap(try #require(vault.document.passphraseWrap), passphrase: "p", kid: otherKID)
        }
        #expect(throws: KeyWrap.Failure.wrongKey(.recovery)) {
            try KeyWrap.unwrap(
                try #require(vault.document.wrapRecovery), under: vault.recoveryKey,
                purpose: .recovery, kid: otherKID, salt: salt)
        }
    }

    /// Two vaults with the same recovery key must not share a wrapping key. The salt is
    /// what separates them, and it is mixed in at HKDF rather than only at the AAD.
    @Test func thesamerecoveryKeyAgainstAnotherVaultsSaltDoesNotOpenIt() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)

        #expect(throws: KeyWrap.Failure.wrongKey(.recovery)) {
            try KeyWrap.unwrap(
                try #require(vault.document.wrapRecovery), under: vault.recoveryKey,
                purpose: .recovery, kid: vault.document.kid,
                salt: SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount))
        }
    }

    // MARK: - A secret, all the way to disk and back

    /// The whole trip: seal a body, put it in a record, write the file, read it back,
    /// unlock with the passphrase, and get the original bytes out.
    @Test func asecretSurvivesTheFullRoundTripThroughTheRealFile() throws {
        let root = scratchFolder("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultURL = root.appendingPathComponent("vault.json")

        var vault = try NewVault(passphrase: "correct horse", iterations: fastIterations)
        let recordID = UUID()
        let plaintext = Data("hunter2".utf8)
        let context = SnippetCrypto.RecordContext(scopeID: "scope-a", recordID: recordID)
        let created = Date(timeIntervalSince1970: 1_785_312_000)

        vault.document.records = [
            VaultRecord(
                id: recordID, name: "AWS root password", keyword: "awsroot",
                tags: ["work"], isEnabled: true, isPinned: false,
                createdAt: created, updatedAt: created,
                hlc: HLC(wallMs: 1_785_312_000_000, counter: 0, device: "aabbccdd"),
                contentHash: SnippetCrypto.contentHash(of: plaintext, keyring: vault.keyring),
                sealed: try SnippetCrypto.seal(plaintext, for: context, keyring: vault.keyring)),
        ]

        try VaultFile.write(vault.document, to: vaultURL, temporaryDirectory: root)

        // A cold start: nothing but the file and what the user can type.
        let loaded = try #require(VaultFile.load(from: vaultURL).value)
        let libraryKey = try PassphraseKDF.unwrap(
            try #require(loaded.passphraseWrap), passphrase: "correct horse", kid: loaded.kid)
        let keyring = SnippetCrypto.Keyring(
            libraryKey: libraryKey, salt: try #require(loaded.vaultSaltBytes))

        let record = try #require(loaded.record(recordID))
        let opened = try SnippetCrypto.open(record.sealed, for: context, keyring: keyring)

        #expect(opened == plaintext)
        #expect(SnippetCrypto.plaintextString(opened) == "hunter2")
        // The stored hash was written by one keyring and verified by another rebuilt
        // from the file — which is the property that lets a locked vault still merge.
        #expect(SnippetCrypto.contentHash(of: opened, keyring: keyring) == record.contentHash)
    }

    /// The file on disk must contain no plaintext of the secret and no plaintext of the
    /// library key. The obvious property, and the one nobody checks until it is wrong.
    @Test func nothingsecretIsLegibleInTheFileThatGetsBackedUp() throws {
        let root = scratchFolder("legible")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultURL = root.appendingPathComponent("vault.json")

        var vault = try NewVault(passphrase: "correct horse", iterations: fastIterations)
        let recordID = UUID()
        let plaintext = Data("swordfish-9134".utf8)

        vault.document.records = [
            VaultRecord(
                id: recordID, name: "n", keyword: "k", createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                hlc: HLC(wallMs: 0, counter: 0, device: "aabbccdd"),
                contentHash: SnippetCrypto.contentHash(of: plaintext, keyring: vault.keyring),
                sealed: try SnippetCrypto.seal(
                    plaintext,
                    for: SnippetCrypto.RecordContext(scopeID: "s", recordID: recordID),
                    keyring: vault.keyring)),
        ]
        try VaultFile.write(vault.document, to: vaultURL, temporaryDirectory: root)

        let bytes = try Data(contentsOf: vaultURL)
        #expect(bytes.range(of: plaintext) == nil)
        #expect(bytes.range(of: keyBytes(vault.keyring.libraryKey)) == nil)
        #expect(bytes.range(of: vault.recoveryKey) == nil)
        #expect(bytes.range(of: vault.cliSecret) == nil)
        // The passphrase is never stored in any form at all.
        #expect(bytes.range(of: Data("correct horse".utf8)) == nil)

        // …and the metadata deliberately *is* legible. Asserted rather than assumed,
        // because it is the disclosed leak: if this ever stops being true the threat
        // model in `VaultDocument` needs rewriting, not quietly enjoying the win.
        #expect(bytes.range(of: Data("\"keyword\" : \"k\"".utf8)) != nil)
    }

    /// A record's ciphertext is bound to its record id, so moving a sealed blob onto
    /// another record in the file fails instead of revealing the first record's secret
    /// under the second record's name.
    @Test func asealedBodyCannotBeMovedOntoAnotherRecord() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let (first, second) = (UUID(), UUID())
        let sealed = try SnippetCrypto.seal(
            Data("secret".utf8),
            for: SnippetCrypto.RecordContext(scopeID: "s", recordID: first),
            keyring: vault.keyring)

        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(scopeID: "s", recordID: second),
                keyring: vault.keyring)
        }
    }

    // MARK: - Vault to wire

    /// A secure record goes out over the wire sealed, comes back, and yields the same
    /// bytes — using the same keyring the vault file is under.
    @Test func asecurerecordSurvivesTheTripToTheWireAndBack() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let sealer = SnippetCryptoSealer(keyring: vault.keyring, scopeID: "scope-a")
        let plaintext = Data("one time code 819244".utf8)
        let created = Date(timeIntervalSince1970: 1_785_312_000)

        let envelope = SyncEnvelope.secureRecord(
            id: UUID(), name: "OTP", keyword: "otp", plaintext: plaintext,
            createdAt: created, updatedAt: created,
            hlc: HLC(wallMs: 1_785_312_000_000, counter: 0, device: "aabbccdd"),
            origin: "aabbccdd")

        let wire = try WireCodec.seal(envelope, using: sealer)
        #expect(wire.blob.range(of: plaintext) == nil)

        let reopened = try WireCodec.open(wire, using: sealer)
        #expect(reopened.plaintext == plaintext)
        // A secure body must never come back as something the plaintext library would
        // accept — that is the path that types ciphertext into a chat window.
        #expect(reopened.plainSnippet == nil)
        #expect(reopened.vaultFields?.content == plaintext)
    }

    /// The two `contentHash` values in this codebase are different by design and must
    /// never be compared. `VaultRecord.contentHash` is an HMAC under `K_hash` because it
    /// is written to `vault.json` in the clear; `SyncEnvelope.contentHash` is a bare
    /// SHA-256 that only ever exists inside a sealed blob. Both files say so in prose.
    /// This is the assertion, so that "compare them" fails in CI rather than in a merge
    /// that decides every record changed on every sync.
    @Test func thetwoContentHashesAreDeliberatelyDifferentValues() throws {
        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let plaintext = Data("the same body".utf8)
        let created = Date(timeIntervalSince1970: 1_785_312_000)

        let vaultHash = SnippetCrypto.contentHash(of: plaintext, keyring: vault.keyring)
        let envelope = SyncEnvelope.secureRecord(
            id: UUID(), name: "n", keyword: "k", plaintext: plaintext,
            createdAt: created, updatedAt: created,
            hlc: HLC(wallMs: 1, counter: 0, device: "aabbccdd"), origin: "aabbccdd")

        #expect(vaultHash != envelope.contentHash)
        // Each is stable in its own terms, which is what makes them useful separately.
        #expect(vaultHash == SnippetCrypto.contentHash(of: plaintext, keyring: vault.keyring))
        #expect(vaultHash.count == SnippetCrypto.contentHashByteCount * 2)
        #expect(envelope.contentHash?.count == 64)
    }

    // MARK: - The CLI door, through the store that holds it

    /// The headless path end to end: the secret comes out of a `SecretStore`, opens the
    /// vault, and reads a record — no human present.
    @Test func theCLIDoorWorksFromASecretStoreWithNoHumanPresent() throws {
        var vault = try NewVault(passphrase: "p", iterations: fastIterations)
        let store = InMemorySecretStore()
        try store.setSecret(vault.cliSecret, named: "vault.cli")

        let recordID = UUID()
        let plaintext = Data("deploy-token-77".utf8)
        let context = SnippetCrypto.RecordContext(scopeID: "s", recordID: recordID)
        vault.document.records = [
            VaultRecord(
                id: recordID, name: "n", keyword: "k",
                createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                hlc: HLC(wallMs: 0, counter: 0, device: "aabbccdd"),
                contentHash: SnippetCrypto.contentHash(of: plaintext, keyring: vault.keyring),
                sealed: try SnippetCrypto.seal(plaintext, for: context, keyring: vault.keyring)),
        ]

        let libraryKey = try KeyWrap.unwrap(
            try #require(vault.document.wrapCLI),
            under: try store.requireSecret(named: "vault.cli"),
            purpose: .cli, kid: vault.document.kid,
            salt: try #require(vault.document.vaultSaltBytes))

        let keyring = SnippetCrypto.Keyring(
            libraryKey: libraryKey, salt: try #require(vault.document.vaultSaltBytes))
        let record = try #require(vault.document.record(recordID))

        #expect(try SnippetCrypto.open(record.sealed, for: context, keyring: keyring) == plaintext)
    }

    /// A `SecretStore` secret is exactly 32 bytes, and `KeyWrap` requires at least 16.
    /// The two floors have to be compatible or the CLI door cannot be built at all.
    @Test func thestoresSecretSizeIsAcceptableKeyMaterial() {
        #expect(SecretStoreLimits.secretByteCount >= KeyWrap.minimumMaterialByteCount)
        #expect(RecoveryKey.byteCount >= KeyWrap.minimumMaterialByteCount)
    }

    /// Passing something that is not key material — a UTF-8 passphrase, most likely —
    /// must be refused rather than silently producing a weak vault.
    @Test func shortmaterialIsRefusedRatherThanQuietlyWrappingUnderIt() throws {
        #expect(throws: KeyWrap.Failure.materialTooShort(6)) {
            try KeyWrap.wrap(
                SymmetricKey(size: .bits256), under: Data("hunter".utf8),
                purpose: .recovery, kid: vaultKID,
                salt: SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount))
        }
    }

    // MARK: - The format survives what the format promises to survive

    /// A vault written by this build, read by this build, byte-identical. The wraps and
    /// the sealed record are long base64url strings, which is exactly the kind of thing
    /// a JSON encoder round trip can mangle.
    @Test func arealvaultRoundTripsThroughTheFileByteForByte() throws {
        let root = scratchFolder("bytes")
        defer { try? FileManager.default.removeItem(at: root) }
        let vaultURL = root.appendingPathComponent("vault.json")

        let vault = try NewVault(passphrase: "p", iterations: fastIterations)
        try VaultFile.write(vault.document, to: vaultURL, temporaryDirectory: root)
        let first = try Data(contentsOf: vaultURL)

        let loaded = try #require(VaultFile.load(from: vaultURL).value)
        #expect(loaded == vault.document)

        try VaultFile.write(loaded, to: vaultURL, temporaryDirectory: root)
        #expect(try Data(contentsOf: vaultURL) == first)
    }
}
