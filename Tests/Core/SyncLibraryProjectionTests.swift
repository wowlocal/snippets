import Foundation
import Testing
@testable import SnippetsCore

@Suite("Sync library projection")
struct SyncLibraryProjectionTests {

    private let localDevice = "11111111"
    private let remoteDevice = "22222222"

    private func base(_ envelopes: SyncEnvelope...) -> SyncBase {
        var base = SyncBase()
        for envelope in envelopes { base.record(envelope) }
        return base
    }

    private func fields(content: Data = Data("body".utf8)) -> SyncEnvelope.Fields {
        SyncEnvelope.Fields(
            name: "Remote name",
            keyword: "remote",
            content: content,
            tags: ["prod", "database"],
            isEnabled: true,
            isPinned: true,
            createdAt: Date(timeIntervalSinceReferenceDate: 10),
            updatedAt: Date(timeIntervalSinceReferenceDate: 20))
    }

    @Test func applyingAPlainEnvelopeProjectsTheExactEnvelopeAndNeedsNoSecondPush() throws {
        let id = UUID()
        let remote = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 50_000, counter: 7, device: remoteDevice),
            origin: remoteDevice,
            secure: false,
            deleted: false,
            fields: fields(),
            x: ["future": ["kept": true]])
        let snippet = try #require(remote.plainSnippet)
        let agreed = base(remote)

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [snippet], records: [], deviceID: localDevice,
            metadata: agreed, agreedBase: agreed)

        #expect(projected[id] == remote)
        #expect(agreed.pendingChanges(from: projected).isEmpty,
                "an applied remote record must not echo back on the following round")
    }

    @Test func applyingASecureEnvelopePreservesTheVaultHMACAndNeedsNoSecondPush() throws {
        let id = UUID()
        let keyedPlaintextHash = "0123456789abcdef0123456789abcdef"
        let remote = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 60_000, counter: 3, device: remoteDevice),
            origin: remoteDevice,
            secure: true,
            deleted: false,
            fields: fields(content: Data("v1.nonce.ciphertext".utf8)),
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(keyedPlaintextHash),
                "future": ["kept": true],
            ])

        let record = try #require(try SyncLibraryProjection.vaultRecord(from: remote))
        #expect(record.contentHash == keyedPlaintextHash)
        #expect(record.contentHash != remote.contentHash,
                "the vault HMAC must never be replaced with SHA-256 of sealed bytes")

        let agreed = base(remote)
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [], records: [record], deviceID: localDevice,
            metadata: agreed, agreedBase: agreed)

        #expect(projected[id] == remote)
        #expect(agreed.pendingChanges(from: projected).isEmpty,
                "an applied secure record must not echo back on the following round")
    }

    /// A secure body is AEAD-bound to the originating vault's `kid`, but that AAD is not
    /// present in the sealed bytes. The encrypted extension stamp is therefore the only
    /// way a receiver can reject a record its local vault can never reveal.
    @Test func aLegacySecureProjectionIsStampedWithItsVaultKIDOnce() throws {
        let id = UUID()
        let kid = "k-shared-vault"
        let legacy = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 60_000, counter: 3, device: remoteDevice),
            origin: remoteDevice,
            secure: true,
            deleted: false,
            fields: fields(content: Data("v1.nonce.ciphertext".utf8)),
            x: [SyncEnvelope.vaultContentHashExtensionKey: .string("keyed-hash")])
        let record = try #require(try SyncLibraryProjection.vaultRecord(from: legacy))
        let agreed = base(legacy)

        let first = SyncLibraryProjection.currentEnvelopes(
            snippets: [], records: [record], deviceID: localDevice,
            metadata: agreed, agreedBase: agreed, vaultKID: kid)
        let stamped = try #require(first[id])
        #expect(stamped.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text == kid)
        #expect(agreed.pendingChanges(from: first) == [stamped],
                "an unstamped agreed record must be re-pushed once with its vault scope")

        let second = SyncLibraryProjection.currentEnvelopes(
            snippets: [], records: [record], deviceID: localDevice,
            metadata: base(stamped), agreedBase: agreed, vaultKID: kid)
        #expect(second[id] == stamped,
                "the scope backfill must stabilize instead of minting a new clock each read")
    }

    @Test func theLocalProjectionSidecarWinsWhenBackendMetadataIsOlderButFieldsMatch() {
        let id = UUID()
        let commonFields = fields()
        let backend = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 10_000, counter: 0, device: remoteDevice),
            origin: remoteDevice, secure: false, deleted: false, fields: commonFields)
        let mergedLocal = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 20_000, counter: 0, device: localDevice),
            origin: localDevice, secure: false, deleted: false, fields: commonFields,
            x: ["future": "local winner"])
        let snippet = mergedLocal.plainSnippet!

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [snippet], records: [], deviceID: localDevice,
            metadata: base(mergedLocal), agreedBase: base(backend))

        #expect(projected[id] == mergedLocal)
        #expect(base(backend).pendingChanges(from: projected) == [mergedLocal],
                "the merged local metadata still has to reach the backend")
    }

    @Test func aLocalEditIsStampedOnceAboveItsAncestorAndThenStaysStable() throws {
        let id = UUID()
        let remote = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 90_000, counter: 12, device: remoteDevice),
            origin: remoteDevice, secure: false, deleted: false, fields: fields())
        var edited = try #require(remote.plainSnippet)
        // Undo and file restores can move updatedAt backwards. The new clock still has
        // to outrank the version being edited.
        edited.name = "Locally edited"
        edited.updatedAt = .distantPast

        let first = SyncLibraryProjection.currentEnvelopes(
            snippets: [edited], records: [], deviceID: localDevice,
            metadata: base(remote), agreedBase: base(remote))
        let candidate = try #require(first[id])
        #expect(candidate.hlc > remote.hlc)
        #expect(candidate.origin == localDevice)

        let second = SyncLibraryProjection.currentEnvelopes(
            snippets: [edited], records: [], deviceID: localDevice,
            metadata: base(candidate), agreedBase: base(remote))
        #expect(second[id] == candidate,
                "reading twice before a push must not mint a second revision")
    }

    @Test func aLegacySecureEnvelopeNeverOverwritesAKnownHMACWithItsWireDigest() throws {
        let id = UUID()
        let sealed = "v1.nonce.same-ciphertext"
        let knownHMAC = "fedcba9876543210fedcba9876543210"
        let envelope = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 1, counter: 0, device: remoteDevice),
            origin: remoteDevice, secure: true, deleted: false,
            fields: fields(content: Data(sealed.utf8)))
        let existing = VaultRecord(
            id: id, name: "old", keyword: "old",
            createdAt: .distantPast, updatedAt: .distantPast,
            hlc: HLC.foreign(updatedAt: .distantPast),
            contentHash: knownHMAC, sealed: sealed)

        let imported = try #require(
            try SyncLibraryProjection.vaultRecord(from: envelope, preserving: existing))
        #expect(imported.contentHash == knownHMAC)
        #expect(imported.contentHash != envelope.contentHash)
    }

    @Test func invalidUTF8CannotBecomeAReplacementCharacterInTheVault() {
        let envelope = SyncEnvelope(
            id: UUID(),
            hlc: HLC(wallMs: 1, counter: 0, device: remoteDevice),
            origin: remoteDevice, secure: true, deleted: false,
            fields: fields(content: Data([0xFF])))

        #expect(throws: SyncLibraryProjection.Failure.self) {
            try SyncLibraryProjection.vaultRecord(from: envelope)
        }
    }

    @Test func mergingCarriesTheVaultHMACFromTheSelectedBodyNotTheOverallClockWinner() throws {
        let id = UUID()
        func envelope(
            name: String, body: String, hash: String, wall: UInt64, device: String
        ) -> SyncEnvelope {
            SyncEnvelope(
                id: id,
                hlc: HLC(wallMs: wall, counter: 0, device: device),
                origin: device,
                secure: true,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: name, keyword: "k", content: Data(body.utf8), tags: [],
                    isEnabled: true, isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(wall))),
                x: [SyncEnvelope.vaultContentHashExtensionKey: .string(hash)])
        }

        let ancestor = envelope(
            name: "before", body: "sealed-base", hash: "hash-base",
            wall: 1, device: remoteDevice)
        // Local wins the whole-record clock due to a rename, but its body did not move.
        let local = envelope(
            name: "renamed", body: "sealed-base", hash: "hash-base",
            wall: 30, device: localDevice)
        let remote = envelope(
            name: "before", body: "sealed-remote", hash: "hash-remote",
            wall: 20, device: remoteDevice)

        let merged = try #require(SyncMerge.mergeEnvelope(
            base: ancestor, local: local, remote: remote))
        #expect(merged.fields?.content == Data("sealed-remote".utf8))
        #expect(merged.x[SyncEnvelope.vaultContentHashExtensionKey]?.text == "hash-remote")
        #expect(merged.fields?.name == "renamed")
    }

    @Test func oneSidedPromotionAndDemotionKeepTheirBodyRepresentation() throws {
        let id = UUID()
        func envelope(
            secure: Bool, body: String, wall: UInt64,
            hash: String? = nil
        ) -> SyncEnvelope {
            var extensions: [String: CanonicalJSON.Value] = [:]
            if let hash {
                extensions[SyncEnvelope.vaultContentHashExtensionKey] = .string(hash)
            }
            return SyncEnvelope(
                id: id,
                hlc: HLC(wallMs: wall, counter: 0, device: localDevice),
                origin: localDevice,
                secure: secure,
                deleted: false,
                fields: SyncEnvelope.Fields(
                    name: "n", keyword: "k", content: Data(body.utf8), tags: [],
                    isEnabled: true, isPinned: false,
                    createdAt: Date(timeIntervalSince1970: 1),
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(wall))),
                x: extensions)
        }

        let originalPlain = envelope(secure: false, body: "plaintext", wall: 1)
        let promoted = envelope(
            secure: true, body: "v1.nonce.ciphertext", wall: 2, hash: "keyed-hash")
        let mergedPromotion = try #require(SyncMerge.mergeEnvelope(
            base: originalPlain, local: originalPlain, remote: promoted))
        #expect(mergedPromotion.secure)
        #expect(mergedPromotion.fields?.content == Data("v1.nonce.ciphertext".utf8))
        #expect(mergedPromotion.x[SyncEnvelope.vaultContentHashExtensionKey]?.text == "keyed-hash")

        let secureBase = promoted
        let demoted = envelope(secure: false, body: "plaintext", wall: 3)
        let mergedDemotion = try #require(SyncMerge.mergeEnvelope(
            base: secureBase, local: secureBase, remote: demoted))
        #expect(!mergedDemotion.secure)
        #expect(mergedDemotion.fields?.content == Data("plaintext".utf8))
        #expect(mergedDemotion.x[SyncEnvelope.vaultContentHashExtensionKey] == nil)
    }

    @Test func anEqualLegacySecureBodyAcceptsAKeyedHashBackfill() throws {
        let id = UUID()
        let commonFields = fields(content: Data("v1.same.seal".utf8))
        let legacy = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 20, counter: 0, device: localDevice),
            origin: localDevice, secure: true, deleted: false, fields: commonFields)
        let withHash = SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: 10, counter: 0, device: remoteDevice),
            origin: remoteDevice, secure: true, deleted: false, fields: commonFields,
            x: [SyncEnvelope.vaultContentHashExtensionKey: "keyed-hash"])

        let merged = try #require(SyncMerge.mergeEnvelope(
            base: legacy, local: legacy, remote: withHash))
        #expect(merged.hlc == legacy.hlc)
        #expect(merged.x[SyncEnvelope.vaultContentHashExtensionKey]?.text == "keyed-hash")
    }
}
