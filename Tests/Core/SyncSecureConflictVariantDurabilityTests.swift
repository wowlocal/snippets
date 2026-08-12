import CryptoKit
import Foundation
import Testing

@testable import SnippetsCore

/// Shared, key-valid fixture for the projection and materialization contract suites.
///
/// Both edits are sealed under the source UUID. The higher-clock remote edit wins and
/// the local edit becomes the opaque `contentConflict.v1.<fingerprint>` member. Using
/// real vault seals here is important: a string that merely looks sealed cannot prove
/// the source-id/copy-id authentication boundary exercised by the companion red spec.
enum SecureConflictVariantFixture {

    static let sourceID = UUID(
        uuidString: "10000000-0000-4000-8000-000000000006")!
    static let deviceA = "aaaaaaa1"
    static let deviceB = "bbbbbbb2"
    static let vaultKID = "secure-conflict-durability-vault"

    struct Scenario {
        var keyring: SnippetCrypto.Keyring
        var ancestor: SyncEnvelope
        var losingSource: SyncEnvelope
        var winningSource: SyncEnvelope
        var losingPlaintext: Data
        var winningPlaintext: Data
        var survivor: SyncEnvelope
        var variant: SyncMerge.SecureContentConflictVariant
    }

    enum Failure: Error {
        case fixtureDidNotProduceOneSecureVariant
    }

    static func makeScenario() throws -> Scenario {
        let keyring = SnippetCrypto.Keyring.generate()
        let basePlaintext = Data("ancestor secret".utf8)
        let losingPlaintext = Data("losing secret from device A".utf8)
        let winningPlaintext = Data("winning secret from device B".utf8)

        let ancestor = try envelope(
            plaintext: basePlaintext, revision: 100, device: deviceA,
            keyring: keyring)
        let losingSource = try envelope(
            plaintext: losingPlaintext, revision: 200, device: deviceA,
            keyring: keyring)
        let winningSource = try envelope(
            plaintext: winningPlaintext, revision: 300, device: deviceB,
            keyring: keyring)

        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor, local: losingSource, remote: winningSource)
        guard let survivor = outcome.survivor,
              outcome.conflictCopies.isEmpty
        else { throw Failure.fixtureDidNotProduceOneSecureVariant }
        let variants = try SyncMerge.secureContentConflictVariants(in: survivor)
        guard variants.count == 1, let variant = variants.first,
              variant.sourceHLC == losingSource.hlc,
              variant.fields == losingSource.fields
        else { throw Failure.fixtureDidNotProduceOneSecureVariant }

        return Scenario(
            keyring: keyring,
            ancestor: ancestor,
            losingSource: losingSource,
            winningSource: winningSource,
            losingPlaintext: losingPlaintext,
            winningPlaintext: winningPlaintext,
            survivor: survivor,
            variant: variant)
    }

    private static func envelope(
        plaintext: Data,
        revision: UInt64,
        device: String,
        keyring: SnippetCrypto.Keyring
    ) throws -> SyncEnvelope {
        let context = SnippetCrypto.RecordContext(
            scopeID: vaultKID, recordID: sourceID)
        let sealed = try SnippetCrypto.seal(
            plaintext, for: context, keyring: keyring)
        return SyncEnvelope(
            id: sourceID,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: true,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Shared secure snippet",
                keyword: "shared-secure",
                content: Data(sealed.utf8),
                tags: ["vault", "shared"],
                isEnabled: true,
                isPinned: true,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 1_000)),
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(
                    SnippetCrypto.contentHash(of: plaintext, keyring: keyring)),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(vaultKID),
                "futureNested": .object([
                    "bytes": .utf8(Data("opaque-extension-value".utf8)),
                    "array": .array([.int(7), .double(2.5), .bool(true), .null]),
                ]),
            ])
    }
}

@Suite("Secure conflict variant durability", .timeLimit(.minutes(1)))
struct SyncSecureConflictVariantDurabilityTests {

    private func base(_ envelopes: SyncEnvelope...) -> SyncBase {
        var result = SyncBase()
        for envelope in envelopes { result.record(envelope) }
        return result
    }

    private func carrierKey(
        _ variant: SyncMerge.SecureContentConflictVariant
    ) -> String {
        let suffix = String(variant.extensionKey.dropFirst(
            SyncMerge.contentConflictExtensionPrefix.count))
        return SyncMerge.contentConflictOpaqueCarrierPrefix + suffix
    }

    @Test func vaultProjectionRoundTripKeepsExactDynamicVariantWithoutEitherSidecar() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let originalValue = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let originalBytes = try CanonicalJSON.data(originalValue)

        let imported = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        let carrier = try #require({ () -> String? in
            guard case .string(let value)? = imported.x[carrierKey(scenario.variant)]
            else { return nil }
            return value
        }())
        let carriedBytes = try #require(Data(base64Encoded: carrier))
        #expect(carriedBytes == originalBytes,
                "the vault file, not derived sync metadata, must durably own the opaque loser")

        // Deliberately project with no metadata/base recovery sidecar at all, and after
        // an ordinary metadata edit that forces a newly constructed envelope.
        var persisted = imported
        persisted.name = "Locally renamed while the sync sidecar is missing"
        persisted.updatedAt = Date(timeIntervalSince1970: 10)

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [persisted],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let restoredEnvelope = try #require(projected[scenario.survivor.id])
        let restoredValue = try #require(
            restoredEnvelope.x[scenario.variant.extensionKey])

        #expect(try CanonicalJSON.data(restoredValue) == originalBytes,
                "projection must preserve the canonical variant bytes through VaultRecord.x")
        let restoredVariants = try SyncMerge.secureContentConflictVariants(
            in: restoredEnvelope)
        #expect(restoredVariants == [scenario.variant])
        #expect(SyncMerge.hasUnresolvedContentConflict(restoredEnvelope))
    }

    @Test func vaultJSONRoundTripKeepsFingerprintSignificantNumberKinds() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let key = scenario.variant.extensionKey
        let storageKey = carrierKey(scenario.variant)
        let originalValue = try #require(scenario.survivor.x[key])
        let originalBytes = try CanonicalJSON.data(originalValue)
        let imported = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))

        // vault.json is the durability boundary. In particular, a whole-valued Date
        // is still a canonical JSON *double* inside `fields`; changing it to an integer
        // changes the fingerprint even though Foundation considers the numbers equal.
        let encoded = try JSONEncoder().encode(imported)
        let persisted = try JSONDecoder().decode(VaultRecord.self, from: encoded)
        #expect(persisted.x[storageKey] == imported.x[storageKey],
                "VaultRecord Codable must retain the exact canonical carrier bytes")

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [persisted],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let restoredEnvelope = try #require(projected[scenario.survivor.id])
        let restoredValue = try #require(restoredEnvelope.x[key])

        #expect(try CanonicalJSON.data(restoredValue) == originalBytes)
        #expect(try SyncMerge.secureContentConflictVariants(in: restoredEnvelope)
            == [scenario.variant])
    }

    @Test func malformedOpaqueVaultCarrierCannotSilentlyEraseAnUnresolvedVariant() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var record = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        let storageKey = carrierKey(scenario.variant)
        #expect(record.x[storageKey] != nil)
        record.x[storageKey] = .string("not-valid-base64!!!")

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [record],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let candidate = try #require(projected[scenario.survivor.id])

        #expect(SyncMerge.hasUnresolvedContentConflict(candidate),
                "a corrupt durable carrier must quarantine/fail closed, never look resolved")
        #expect(throws: SyncMerge.EnvelopeFailure.self) {
            try SyncMerge.validateContentConflictExtensions(in: candidate)
        }
    }

    @Test func malformedOpaqueVaultCarrierCannotHideBehindExactMetadata() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var record = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        record.x[carrierKey(scenario.variant)] = .string("not-valid-base64!!!")

        // Model a stale/derived sidecar that exactly describes the visible secure
        // fields but no longer contains the conflict member. An invalid primary-store
        // carrier must make that candidate non-exact and surface a malformed sentinel;
        // silently trusting metadata would turn corruption into apparent resolution.
        var metadataEnvelope = scenario.survivor
        metadataEnvelope.x[scenario.variant.extensionKey] = nil
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [record],
            deviceID: scenario.survivor.hlc.device,
            metadata: base(metadataEnvelope),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let candidate = try #require(projected[scenario.survivor.id])

        #expect(SyncMerge.hasUnresolvedContentConflict(candidate))
        #expect(throws: SyncMerge.EnvelopeFailure.self) {
            try SyncMerge.validateContentConflictExtensions(in: candidate)
        }
    }

    @Test func malformedKnownV1VariantFailsClosedAtVaultImport() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let key = scenario.variant.extensionKey
        var damagedObject = try #require(scenario.survivor.x[key]?.object)
        damagedObject["copyID"] = .string(UUID().uuidString.lowercased())

        var wrongCopyID = scenario.survivor
        wrongCopyID.x[key] = .object(damagedObject)

        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncLibraryProjection.vaultRecord(from: wrongCopyID)
        }
    }

    @Test func selfConsistentV1VariantWithUnapprovedSourceExtensionFailsBeforeVaultCarrier()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var object = try #require(
            scenario.survivor.x[scenario.variant.extensionKey]?.object)
        var sourceX = try #require(object["x"]?.object)
        sourceX["futureNested"] = .object([
            "secretAdjacentMetadata": .utf8(Data("must remain wire-only".utf8)),
        ])
        object["x"] = .object(sourceX)
        object["copyID"] = nil
        let fingerprint = SHA256.hash(
            data: try CanonicalJSON.data(.object(object)))
            .map { String(format: "%02x", $0) }.joined()
        let copyID = SyncMerge.deterministicUUID(
            namespace: scenario.variant.sourceID,
            name: "sync-content-conflict-v1|\(fingerprint)")
        object["copyID"] = .string(copyID.uuidString.lowercased())
        let key = SyncMerge.contentConflictV1ExtensionPrefix + fingerprint
        var selfConsistent = scenario.survivor
        selfConsistent.x[scenario.variant.extensionKey] = nil
        selfConsistent.x[key] = .object(object)

        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncMerge.secureContentConflictVariants(in: selfConsistent)
        }
        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncMerge.validateContentConflictExtensions(in: selfConsistent)
        }
        #expect(throws: (any Error).self) {
            try SyncLibraryProjection.vaultRecord(from: selfConsistent)
        }
    }

    @Test func structurallyWellFormedFutureVariantIsOpaquePreservedAndBlocksDeletion() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let futureKey = "contentConflict.v2." + String(repeating: "a", count: 64)
        let futureValue = CanonicalJSON.Value.object([
            "version": .int(2),
            "futurePayload": .object([
                "ciphertext": .utf8(Data("opaque-future-value".utf8)),
                "generation": .int(7),
            ]),
        ])
        let originalBytes = try CanonicalJSON.data(futureValue)
        var future = scenario.survivor
        future.x[futureKey] = futureValue

        let imported = try #require(try SyncLibraryProjection.vaultRecord(from: future))
        let encoded = try JSONEncoder().encode(imported)
        let persisted = try JSONDecoder().decode(VaultRecord.self, from: encoded)
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [persisted],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let restored = try #require(projected[scenario.survivor.id])
        let restoredValue = try #require(restored.x[futureKey])

        #expect(try CanonicalJSON.data(restoredValue) == originalBytes,
                "an older client must round-trip a future conflict payload without interpreting it")
        #expect(SyncMerge.hasUnresolvedContentConflict(restored),
                "unknown conflict versions remain unresolved until a newer client handles them")

        let confirmed = base(restored)
        #expect(confirmed.pendingChanges(from: [:]).isEmpty,
                "an older client must not tombstone the envelope carrying an unknown variant")
    }

    @Test func applyingResolvedEnvelopeRemovesVaultCarrierInsteadOfResurrectingVariant() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let imported = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        let storageKey = carrierKey(scenario.variant)
        #expect(imported.x[storageKey] != nil)

        // Step 7 will eventually deliver the same secure survivor with this one
        // confirmed variant removed. Applying that authoritative envelope must also
        // remove its primary-storage carrier; `preserving:` is for unrelated unknown
        // fields, not for stale protocol state.
        var resolved = scenario.survivor
        resolved.x[scenario.variant.extensionKey] = nil
        let updated = try #require(
            try SyncLibraryProjection.vaultRecord(from: resolved, preserving: imported))
        #expect(updated.x[storageKey] == nil,
                "a resolved variant must be removed from vault.json atomically with its envelope")

        // Both sync sidecars may be absent after a reset or recovery. The authoritative
        // vault file must not manufacture the removed member again on that path.
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [updated],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let restored = try #require(projected[scenario.survivor.id])
        #expect(restored.x[scenario.variant.extensionKey] == nil)
        #expect(!SyncMerge.hasUnresolvedContentConflict(restored))
    }

    @Test func materializedCopyDropsUnapprovedSourceExtensionsButRetainsProvenanceWithoutSidecars()
        throws
    {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        #expect(Set(scenario.variant.sourceExtensions.keys) == [
            SyncEnvelope.vaultContentHashExtensionKey,
            SyncEnvelope.vaultKeyIDExtensionKey,
        ], "the encrypted conflict snapshot exposes only the source facts needed to authenticate")
        let source = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        let result = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [source])

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: result.records,
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let copy = try #require(projected[scenario.variant.copyID])

        #expect(copy.x["futureNested"] == nil,
                "arbitrary source extensions must not cross into plaintext vault.json")
        #expect(copy.x[SyncSecureConflictMaterializer.provenanceExtensionKey] != nil,
                "another device must be able to recognize the deterministic copy provenance")

        // A second device importing only the ordinary copy must retain the safe fact in
        // vault.json. Neither base.json nor the projection cache is primary storage.
        let importedCopy = try #require(
            try SyncLibraryProjection.vaultRecord(from: copy))
        let roundTripped = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [importedCopy],
            deviceID: SecureConflictVariantFixture.deviceB,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let restoredCopy = try #require(roundTripped[scenario.variant.copyID])
        #expect(restoredCopy.x["futureNested"] == nil)
        #expect(restoredCopy.x[SyncSecureConflictMaterializer.provenanceExtensionKey] != nil)
    }

    @Test func tombstoneCarryingAContentVariantIsMalformedInsteadOfHidingASecretBody() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let value = try #require(
            scenario.survivor.x[scenario.variant.extensionKey])
        let malformed = SyncEnvelope.tombstone(
            id: scenario.variant.sourceID,
            secure: true,
            hlc: HLC(wallMs: 400, counter: 0, device: SecureConflictVariantFixture.deviceB),
            origin: SecureConflictVariantFixture.deviceB,
            x: [scenario.variant.extensionKey: value])

        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncMerge.secureContentConflictVariants(in: malformed)
        }
        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncLibraryProjection.vaultRecord(from: malformed)
        }
    }

    @Test func secureVariantFromARivalVaultScopeIsRejectedBeforeVaultProjection() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let rivalKID = "secure-conflict-rival-vault"
        let rivalContext = SnippetCrypto.RecordContext(
            scopeID: rivalKID,
            recordID: SecureConflictVariantFixture.sourceID)
        let rivalSeal = try SnippetCrypto.seal(
            scenario.losingPlaintext,
            for: rivalContext,
            keyring: scenario.keyring)
        var rivalFields = try #require(scenario.losingSource.fields)
        rivalFields.content = Data(rivalSeal.utf8)
        let rivalLoser = SyncEnvelope(
            id: scenario.losingSource.id,
            hlc: scenario.losingSource.hlc,
            origin: scenario.losingSource.origin,
            secure: true,
            deleted: false,
            fields: rivalFields,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(
                    SnippetCrypto.contentHash(
                        of: scenario.losingPlaintext,
                        keyring: scenario.keyring)),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(rivalKID),
            ])
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: scenario.ancestor,
            local: rivalLoser,
            remote: scenario.winningSource)
        let survivor = try #require(outcome.survivor)
        #expect(survivor.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                == SecureConflictVariantFixture.vaultKID)
        let rivalVariant = try #require(
            SyncMerge.secureContentConflictVariants(in: survivor).only)
        #expect(rivalVariant.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                == rivalKID)

        #expect(throws: (any Error).self) {
            try SyncLibraryProjection.vaultRecord(from: survivor)
        }
    }

    @Test func malformedVariantRecoveredFromVaultXRemainsInvalidInsteadOfBeingSanitized() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var record = try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
        record.x["contentConflict.future.corrupt"] = .object([
            "looksPlausible": .bool(true),
        ])

        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [record],
            deviceID: scenario.survivor.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let malformed = try #require(projected[scenario.survivor.id])

        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncMerge.validateContentConflictExtensions(in: malformed)
        }
        #expect(throws: SyncMerge.EnvelopeFailure.malformedContentConflict) {
            try SyncLibraryProjection.vaultRecord(from: malformed)
        }
    }

    @Test func baseDoesNotTurnLocalAbsenceIntoATombstoneWhileVariantIsUnresolved() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let confirmed = base(scenario.survivor)

        let pending = confirmed.pendingChanges(from: [:])

        #expect(pending.isEmpty,
                "a tombstone would erase the only ciphertext for the losing secure version")
        #expect(!pending.contains(where: { $0.deleted }))
        #expect(confirmed.envelope(scenario.survivor.id) == scenario.survivor,
                "deriving pending changes must not mutate confirmed ancestry")
    }

    @Test func journalKeepsAmbiguousLiveOfferWhenLocalRecordDisappears() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let emptyBase = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [scenario.survivor.id: scenario.survivor],
            confirmed: emptyBase,
            deviceID: scenario.survivor.hlc.device,
            now: Date(timeIntervalSince1970: 20))
        let firstPending = journal.pending(confirmed: emptyBase)
        #expect(firstPending == [scenario.survivor])
        journal.markOffered(firstPending, confirmed: emptyBase)

        journal.reconcile(
            current: [:],
            confirmed: emptyBase,
            deviceID: scenario.survivor.hlc.device,
            now: Date(timeIntervalSince1970: 30))

        let entry = try #require(journal.entry(scenario.survivor.id))
        #expect(entry.desired == scenario.survivor)
        #expect(entry.offered?.envelope == scenario.survivor)
        #expect(!entry.desired.deleted)
        #expect(entry.desired.fields != nil)
        #expect(SyncMerge.hasUnresolvedContentConflict(entry.desired))
        #expect(journal.pending(confirmed: emptyBase) == [scenario.survivor],
                "reconcile must retry the data-bearing offer, never replace it with a tombstone")
    }

    @Test func journalDoesNotMintATombstoneFromConfirmedUnresolvedVariant() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let confirmed = base(scenario.survivor)
        var journal = SyncJournal()

        journal.reconcile(
            current: [:],
            confirmed: confirmed,
            deviceID: scenario.survivor.hlc.device,
            now: Date(timeIntervalSince1970: 40))

        #expect(journal.entry(scenario.survivor.id) == nil,
                "confirmed data is already durable, so holding deletion needs no journal rewrite")
        #expect(journal.pending(confirmed: confirmed).isEmpty)
    }
}

private extension Array {
    var only: Element? { count == 1 ? self[0] : nil }
}
