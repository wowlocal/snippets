// Proves the claim that removed "copy Vault/vault.json to the other Mac by hand".
//
//   swiftc -O snippets/Core/*.swift Tests/Harnesses/VaultIdentityTest.swift \
//          -o /tmp/vitest && /tmp/vitest
//
// `VaultIdentityStore` publishes the vault document with its records and its passphrase
// wrap removed, and a second Mac adopts that instead of minting a vault of its own. The
// whole feature rests on one property: an identity that has been through
// `VaultFile.encode` and back must reconstruct *exactly* the keyring the origin Mac
// sealed with. If the salt, the `kid`, or the wrap does not survive that trip, a user's
// second Mac silently receives snippets it cannot read — which is the failure this
// replaces, not an improvement on it.
//
// So this walks the real path with the real types: seal on A, publish, adopt on B, open.
// It also pins the two negatives that make the design necessary rather than merely nice
// — a Mac that mints its own vault cannot read A's records, and one that adopts but does
// not receive `K_lib` still gets in with the recovery key.
//
// Core only, no Keychain and no AppKit, so it runs unsigned and offline.
// `Tests/Harnesses/KeychainSelfTest.swift` covers the Keychain side of the same feature.

import CryptoKit
import Foundation

@main
struct VaultIdentityTest {
    static func main() {
        var failures = 0

        func check(_ label: String, _ ok: Bool) {
            print("  \(ok ? "PASS" : "FAIL")  \(label)")
            if !ok { failures += 1 }
        }

        do {
            // ---- Mac A: a vault, a recovery key, and one sealed secret ----------------

            let macA = SnippetCrypto.Keyring.generate()
            let kid = "k-\(UUID().uuidString.lowercased().prefix(12))"
            let recoveryKey = RecoveryKey.generate()

            let recoveryWrap = try KeyWrap.wrap(
                macA.libraryKey, under: recoveryKey, purpose: .recovery,
                kid: kid, salt: macA.salt)
            let passphraseWrap = try KeyWrap.wrap(
                macA.libraryKey, under: Data("a passphrase-derived wrap".utf8),
                purpose: .recovery, kid: kid, salt: macA.salt)

            let recordID = UUID()
            let secret = "correct horse battery staple"
            let context = SnippetCrypto.RecordContext(
                scopeID: kid, recordID: recordID, isDeleted: false)
            let sealed = try SnippetCrypto.seal(
                Data(secret.utf8), for: context, keyring: macA)

            let vaultOnA = VaultDocument(
                kid: kid,
                vaultSalt: SnippetCrypto.base64URL(macA.salt),
                kdf: VaultKDFParameters(
                    alg: PassphraseKDF.algorithm,
                    iterations: PassphraseKDF.iterations,
                    saltP: SnippetCrypto.base64URL(SnippetCrypto.randomBytes(16))),
                wrapPass: passphraseWrap,
                wrapRecovery: recoveryWrap,
                x: ["futureField": .string("must survive")])

            // ---- Publishing: exactly what VaultIdentityStore.publish does -------------

            var identity = vaultOnA
            identity.records = []
            identity.wrapPass = nil
            let published = try VaultFile.encode(identity)

            check("a published identity is small enough for a Keychain item",
                  published.count < 4096)

            // ---- Mac B adopts it ------------------------------------------------------

            let adopted = try VaultFile.decode(published)

            check("the kid survives publication", adopted.kid == kid)
            check("the salt survives publication", adopted.vaultSalt == vaultOnA.vaultSalt)
            check("the KDF parameters survive publication", adopted.kdf == vaultOnA.kdf)
            check("the recovery wrap survives publication", adopted.wrapRecovery == recoveryWrap)
            check("unknown document keys survive publication",
                  adopted.x["futureField"] == .string("must survive"))
            check("no records are published", adopted.records.isEmpty)

            // The one field deliberately withheld. A passphrase wrap exists to be
            // stronger than the iCloud account; publishing it into iCloud Keychain would
            // hand whoever reaches that account an offline guessing target.
            check("the passphrase wrap is NOT published", adopted.wrapPass == nil)

            guard let adoptedSalt = adopted.vaultSaltBytes else {
                check("the adopted salt decodes", false)
                exit(1)
            }
            check("the adopted salt decodes to the same bytes", adoptedSalt == macA.salt)

            // ---- The point: B opens A's record ----------------------------------------
            //
            // `K_lib` itself arrives over iCloud Keychain, which this harness cannot
            // exercise; standing in for it is the same 32 bytes. Everything else — the
            // scope, the salt, the derived record key, the AAD — comes from the adopted
            // document, which is the part that used to require a file copy.

            let macB = SnippetCrypto.Keyring(libraryKey: macA.libraryKey, salt: adoptedSalt)
            let openedOnB = try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: adopted.kid, recordID: recordID, isDeleted: false),
                keyring: macB)
            check("Mac B opens the record Mac A sealed",
                  String(data: openedOnB, encoding: .utf8) == secret)

            // ---- The negative that made the copy necessary ----------------------------
            //
            // A Mac that mints its own vault differs in both the key and the scope, and
            // this is what the old Settings text meant by "will receive snippets it
            // cannot decrypt". Pinned so nobody later concludes adoption was optional.

            let rival = SnippetCrypto.Keyring.generate()
            let rivalKID = "k-\(UUID().uuidString.lowercased().prefix(12))"
            do {
                _ = try SnippetCrypto.open(
                    sealed,
                    for: SnippetCrypto.RecordContext(
                        scopeID: rivalKID, recordID: recordID, isDeleted: false),
                    keyring: rival)
                check("a Mac that mints its own vault cannot read A's records", false)
            } catch {
                check("a Mac that mints its own vault cannot read A's records", true)
            }

            // Even with A's key, a rival scope fails — the kid is bound into the AAD, so
            // carrying the key alone was never enough. That is precisely why the identity
            // has to travel too.
            do {
                _ = try SnippetCrypto.open(
                    sealed,
                    for: SnippetCrypto.RecordContext(
                        scopeID: rivalKID, recordID: recordID, isDeleted: false),
                    keyring: macB)
                check("the right key under the wrong kid still fails", false)
            } catch {
                check("the right key under the wrong kid still fails", true)
            }

            // ---- The escape hatch, when iCloud Keychain did not deliver the key -------

            guard let adoptedWrap = adopted.wrapRecovery else {
                check("the adopted identity carries a recovery wrap", false)
                exit(1)
            }
            let recovered = try KeyWrap.unwrap(
                adoptedWrap, under: recoveryKey, purpose: .recovery,
                kid: adopted.kid, salt: adoptedSalt)
            check("the recovery key rebuilds K_lib from the published identity alone",
                  recovered.withUnsafeBytes { Data($0) }
                      == macA.libraryKey.withUnsafeBytes { Data($0) })

            let recoveredOnB = try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: adopted.kid, recordID: recordID, isDeleted: false),
                keyring: SnippetCrypto.Keyring(libraryKey: recovered, salt: adoptedSalt))
            check("a recovered Mac B opens the record too",
                  String(data: recoveredOnB, encoding: .utf8) == secret)

            // ---- The wire key, which needs no vault at all ----------------------------
            //
            // `SyncKeyStore` stores 32 bytes of key followed by 32 of salt and splits
            // them back apart. Reproduced rather than imported because that type lives in
            // the app target; what is being pinned is that the split is deterministic, so
            // two Macs holding the same item seal identically.

            var material = Data()
            material.append(SnippetCrypto.randomBytes(SnippetCrypto.keyByteCount))
            material.append(SnippetCrypto.randomBytes(SnippetCrypto.saltByteCount))

            func wireKeyring(_ material: Data) -> SnippetCrypto.Keyring {
                let split = material.index(
                    material.startIndex, offsetBy: SnippetCrypto.keyByteCount)
                return SnippetCrypto.Keyring(
                    libraryKey: SymmetricKey(data: material[material.startIndex..<split]),
                    salt: Data(material[split...]))
            }

            let wireID = UUID()
            let envelope = SyncEnvelopeIdentityStandIn(id: wireID)
            let onTheWire = try SnippetCrypto.seal(
                Data("an ordinary snippet, no vault anywhere".utf8),
                for: SnippetCrypto.RecordContext(
                    scopeID: "sync-v1", recordID: envelope.id, isDeleted: false),
                keyring: wireKeyring(material))

            let openedFromWire = try SnippetCrypto.open(
                onTheWire,
                for: SnippetCrypto.RecordContext(
                    scopeID: "sync-v1", recordID: envelope.id, isDeleted: false),
                keyring: wireKeyring(material))
            check("the wire key splits deterministically on both Macs",
                  String(data: openedFromWire, encoding: .utf8)
                      == "an ordinary snippet, no vault anywhere")
        } catch {
            print("  FAIL  threw: \(error)")
            failures += 1
        }

        print(failures == 0 ? "ALL VAULT IDENTITY CHECKS PASSED" : "\(failures) CHECK(S) FAILED")
        if failures > 0 { exit(1) }
    }
}

/// Only a record id. The wire envelope's own type lives in the app target's reach; what
/// matters here is that sealing needs nothing from a vault.
private struct SyncEnvelopeIdentityStandIn {
    var id: UUID
}
