import Foundation
import Testing

@testable import SnippetsCore

/// Key-aware Step 6 contract.
///
/// Materialization and resolution are intentionally separate protocol facts. This
/// operation must atomically return the complete vault state containing a deterministic
/// copy, but it must leave the source variant exact and unresolved. Step 7 may resolve
/// it only after the copy is confirmed durable in the backend.
@Suite("Secure conflict materialization contract", .timeLimit(.minutes(1)))
struct SyncSecureConflictMaterializationContractTests {

    private func sourceRecord(
        _ scenario: SecureConflictVariantFixture.Scenario
    ) throws -> VaultRecord {
        try #require(
            try SyncLibraryProjection.vaultRecord(from: scenario.survivor))
    }

    private func expectedConflictName(
        _ fields: SyncEnvelope.Fields
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        let displayName = fields.name.isEmpty ? "Untitled" : fields.name
        return "\(displayName) (conflict \(formatter.string(from: fields.updatedAt)))"
    }

    private func provenance(
        _ variant: SyncMerge.SecureContentConflictVariant
    ) -> JSONValue {
        .object([
            "version": .integer(1),
            "sourceID": .string(variant.sourceID.uuidString.lowercased()),
            "fingerprint": .string(variant.fingerprint),
        ])
    }

    @Test func materializesExactDisabledCopyAndKeepsSourceVariantUnresolved() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let variant = scenario.variant
        let source = try sourceRecord(scenario)
        let originalEnvelope = scenario.survivor
        let originalVariant = try #require(
            originalEnvelope.x[variant.extensionKey])
        let originalVariantBytes = try CanonicalJSON.data(originalVariant)
        let sourceSeal = try #require(
            String(data: variant.fields.content, encoding: .utf8))

        let result = try SyncSecureConflictMaterializer.materialize(
            envelope: originalEnvelope,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [source])

        #expect(result.materializedIDs == [variant.copyID])
        #expect(result.records.count == 2,
                "source and copy must be returned as one transaction-sized state")
        let returnedSource = try #require(
            result.records.first(where: { $0.id == variant.sourceID }))
        let copy = try #require(
            result.records.first(where: { $0.id == variant.copyID }))

        #expect(returnedSource == source)
        #expect(returnedSource.x[variant.extensionKey]
            == source.x[variant.extensionKey])
        #expect(originalEnvelope == scenario.survivor,
                "the pure operation must not rewrite caller-owned source state")
        #expect(try CanonicalJSON.data(try #require(
            originalEnvelope.x[variant.extensionKey])) == originalVariantBytes)
        #expect(SyncMerge.hasUnresolvedContentConflict(originalEnvelope),
                "Step 6 must not resolve before backend confirmation in Step 7")
        #expect(!originalEnvelope.x.keys.contains(where: {
            $0.localizedCaseInsensitiveContains("resolved")
        }), "Step 6 must not emit a premature resolved marker")

        let fields = variant.fields
        #expect(copy.id == variant.copyID)
        #expect(copy.name == expectedConflictName(fields))
        #expect(copy.keyword.isEmpty)
        #expect(copy.tags == SnippetTagging.normalizedTags(fields.tags + ["conflict"]))
        #expect(!copy.isEnabled)
        #expect(!copy.isPinned)
        #expect(copy.createdAt == fields.createdAt)
        #expect(copy.updatedAt == fields.updatedAt)
        #expect(copy.hlc == variant.sourceHLC)
        #expect(copy.contentHash
            == variant.sourceExtensions[SyncEnvelope.vaultContentHashExtensionKey]?.text)
        #expect(copy.x == [
            SyncSecureConflictMaterializer.provenanceExtensionKey: provenance(variant),
        ])
        #expect(copy.sealed != sourceSeal,
                "the source ciphertext must be resealed rather than copied under another id")

        let sourceContext = SnippetCrypto.RecordContext(
            scopeID: SecureConflictVariantFixture.vaultKID,
            recordID: variant.sourceID)
        let copyContext = SnippetCrypto.RecordContext(
            scopeID: SecureConflictVariantFixture.vaultKID,
            recordID: variant.copyID)
        #expect(try SnippetCrypto.open(
            sourceSeal, for: sourceContext, keyring: scenario.keyring)
            == scenario.losingPlaintext)
        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(
                sourceSeal, for: copyContext, keyring: scenario.keyring)
        }
        #expect(try SnippetCrypto.open(
            copy.sealed, for: copyContext, keyring: scenario.keyring)
            == scenario.losingPlaintext)
        #expect(throws: SnippetCrypto.Failure.authenticationFailed) {
            try SnippetCrypto.open(
                copy.sealed, for: sourceContext, keyring: scenario.keyring)
        }

        // The complete returned vault state must still project the source's exact
        // unresolved dynamic member when both sync sidecars are absent.
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: result.records,
            deviceID: originalEnvelope.hlc.device,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: SecureConflictVariantFixture.vaultKID)
        let reprojectedSource = try #require(projected[variant.sourceID])
        #expect(try CanonicalJSON.data(try #require(
            reprojectedSource.x[variant.extensionKey])) == originalVariantBytes)
        #expect(SyncMerge.hasUnresolvedContentConflict(reprojectedSource))
    }

    @Test func matchingProvenanceMakesRetryIdempotentWithoutResealingOrRestoringEdits() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let variant = scenario.variant
        let first = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [try sourceRecord(scenario)])
        var editedRecords = first.records
        let copyIndex = try #require(
            editedRecords.firstIndex(where: { $0.id == variant.copyID }))
        let originalSeal = editedRecords[copyIndex].sealed
        editedRecords[copyIndex].name = "User renamed the materialized copy"
        editedRecords[copyIndex].tags = ["reviewed", "conflict"]
        editedRecords[copyIndex].updatedAt = Date(timeIntervalSince1970: 999)

        let retried = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: editedRecords)

        #expect(retried.records == editedRecords,
                "matching provenance must preserve later user edits byte-for-byte")
        #expect(retried.materializedIDs.isEmpty)
        let retriedCopy = try #require(
            retried.records.first(where: { $0.id == variant.copyID }))
        #expect(retriedCopy.sealed == originalSeal,
                "idempotent redelivery must not consume a nonce or reseal")
        #expect(retried.records.filter { $0.id == variant.copyID }.count == 1)
    }

    @Test func matchingProvenanceDoesNotAuthorizeCorruptExistingCopy() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let variant = scenario.variant
        let source = try sourceRecord(scenario)
        let first = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [source])
        var corruptRecords = first.records
        let copyIndex = try #require(
            corruptRecords.firstIndex(where: { $0.id == variant.copyID }))
        corruptRecords[copyIndex].sealed = "not-an-authenticated-vault-seal"

        #expect(throws: SyncSecureConflictMaterializer.Failure.malformedVariant) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [],
                existingRecords: corruptRecords)
        }
        #expect(corruptRecords.first(where: { $0.id == variant.sourceID }) == source,
                "a failed idempotence check cannot remove the still-authentic source")
        #expect(corruptRecords.count == 2,
                "the pure failure path cannot partially rewrite either occupant")
    }

    @Test func matchingProvenanceDoesNotAuthorizeCopyWithWrongAuthenticatedBody() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let variant = scenario.variant
        let first = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: SecureConflictVariantFixture.vaultKID,
            existingSnippets: [],
            existingRecords: [try sourceRecord(scenario)])
        var wrongRecords = first.records
        let copyIndex = try #require(
            wrongRecords.firstIndex(where: { $0.id == variant.copyID }))
        let wrongPlaintext = Data("authenticated but unrelated conflict body".utf8)
        wrongRecords[copyIndex].sealed = try SnippetCrypto.seal(
            wrongPlaintext,
            for: SnippetCrypto.RecordContext(
                scopeID: SecureConflictVariantFixture.vaultKID,
                recordID: variant.copyID),
            keyring: scenario.keyring)

        #expect(throws: SyncSecureConflictMaterializer.Failure.contentHashMismatch) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [],
                existingRecords: wrongRecords)
        }
    }

    @Test func mismatchedVaultKIDFailsBeforeCreatingAnyRecord() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let existing = [try sourceRecord(scenario)]

        #expect(throws: SyncSecureConflictMaterializer.Failure.incompatibleVault) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: "different-vault-kid",
                existingSnippets: [],
                existingRecords: existing)
        }
        #expect(existing.count == 1,
                "the pure failure path cannot partially append a copy")
    }

    @Test func copyIDCollisionFailsForEitherPlainOrUnrelatedSecureOccupant() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let variant = scenario.variant
        let source = try sourceRecord(scenario)
        let plainOccupant = Snippet(
            id: variant.copyID,
            name: "Unrelated plain snippet",
            keyword: "occupied",
            content: "must survive",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2))
        let secureOccupant = VaultRecord(
            id: variant.copyID,
            name: "Unrelated secure snippet",
            keyword: "secure-occupied",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2),
            hlc: HLC(wallMs: 1, counter: 0, device: "ccccccc3"),
            contentHash: "unrelated-hash",
            sealed: "unrelated-seal",
            x: [:])

        #expect(throws: SyncSecureConflictMaterializer.Failure.identifierCollision) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [plainOccupant],
                existingRecords: [source])
        }
        #expect(throws: SyncSecureConflictMaterializer.Failure.identifierCollision) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [],
                existingRecords: [source, secureOccupant])
        }
    }

    @Test func malformedReservedVariantMapsToClosedMaterializerFailure() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        let key = scenario.variant.extensionKey
        var object = try #require(scenario.survivor.x[key]?.object)
        object["copyID"] = .string(UUID().uuidString.lowercased())
        var malformed = scenario.survivor
        malformed.x[key] = .object(object)

        #expect(throws: SyncSecureConflictMaterializer.Failure.malformedVariant) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: malformed,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [],
                existingRecords: [])
        }
    }

    @Test func authenticatedPlaintextMustMatchVariantContentHash() throws {
        let scenario = try SecureConflictVariantFixture.makeScenario()
        var badSource = scenario.losingSource
        badSource.x[SyncEnvelope.vaultContentHashExtensionKey] = .string(
            "00000000000000000000000000000000")
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: scenario.ancestor,
            local: badSource,
            remote: scenario.winningSource)
        let envelope = try #require(outcome.survivor)

        #expect(throws: SyncSecureConflictMaterializer.Failure.contentHashMismatch) {
            try SyncSecureConflictMaterializer.materialize(
                envelope: envelope,
                keyring: scenario.keyring,
                vaultKID: SecureConflictVariantFixture.vaultKID,
                existingSnippets: [],
                existingRecords: [])
        }
    }
}
