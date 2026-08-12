import Darwin
import Foundation
import XCTest

@testable import Snippets

/// App-boundary coverage for key-aware secure conflict copies.
///
/// Pure Core tests pin the deterministic copy and resealing rules. These tests exercise
/// the production bridge that owns the real `SnippetStore`, vault session, and the one
/// `LibraryTransaction` which must commit the copy beside the selected survivor.
@MainActor
final class SyncSecureConflictBridgeIntegrationTests: XCTestCase {
    private static let sourceID = UUID(
        uuidString: "20000000-0000-4000-8000-000000000006")!
    private static let deviceA = "aaaaaaa1"
    private static let deviceB = "bbbbbbb2"

    private var rootURL: URL!
    private var previousSyncPreference: Any?
    private var previousRuntimeSyncOverride: Bool?

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SyncSecureConflictBridgeIntegrationTests-\(UUID().uuidString)",
            isDirectory: true)
        setenv(SnippetStorageLocations.rootOverrideEnvironmentKey, rootURL.path, 1)
        SnippetStorageLocations.createAllDirectories()
        previousSyncPreference = UserDefaults.standard.object(
            forKey: SyncCoordinator.enabledDefaultsKey)
        previousRuntimeSyncOverride = SyncCoordinator.runtimeEnabledOverride
        SyncCoordinator.runtimeEnabledOverride = nil
    }

    override func tearDownWithError() throws {
        unsetenv(SnippetStorageLocations.rootOverrideEnvironmentKey)
        if let previousSyncPreference {
            UserDefaults.standard.set(
                previousSyncPreference, forKey: SyncCoordinator.enabledDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SyncCoordinator.enabledDefaultsKey)
        }
        SyncCoordinator.runtimeEnabledOverride = previousRuntimeSyncOverride
        previousSyncPreference = nil
        previousRuntimeSyncOverride = nil
        if let rootURL { try? FileManager.default.removeItem(at: rootURL) }
        rootURL = nil
    }

    func testUnknownContentConflictV2IsDeferredWithoutApplyingItsPlainSurvivor() throws {
        let fixture = makeFixture()
        let extensionKey = "contentConflict.v2." + String(repeating: "a", count: 64)
        let survivorSnippet = Snippet(
            id: Self.sourceID,
            name: "Future conflict survivor",
            keyword: "future-conflict",
            content: "must wait for a newer client",
            tags: ["future"],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2))
        let envelope = SyncEnvelope.plain(
            survivorSnippet,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceB),
            origin: Self.deviceB,
            x: [
                extensionKey: .object([
                    "version": .int(2),
                    "opaque": .utf8(Data("future materialization contract".utf8)),
                ]),
            ])
        XCTAssertTrue(SyncMerge.hasUnknownContentConflictVersion(envelope))

        let classification = try fixture.bridge.prepareRemote([envelope])
        let outcome = try fixture.bridge.applyRemote(classification.applicable)

        XCTAssertTrue(classification.applicable.isEmpty,
                      "an older client must not apply a survivor whose loser it cannot materialize")
        XCTAssertEqual(classification.deferredIDs, [Self.sourceID])
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
        XCTAssertTrue(outcome.changedIDs.isEmpty)
        XCTAssertFalse(fixture.store.snippets.contains { $0.id == Self.sourceID })
        XCTAssertTrue(try diskSnippets().isEmpty,
                      "future conflict state must remain remote and retryable, not become local loss")
    }

    func testLockedVaultDefersKnownVariantWithoutPromptOrPrimaryFileMutation() async throws {
        var authenticationCount = 0
        let fixture = makeFixture(authenticationEvaluator: { _ in
            authenticationCount += 1
            return true
        })
        let scenario = try await makeSeededScenario(fixture)
        fixture.session.lock()
        let countBeforePrepare = authenticationCount
        let vaultBeforePrepare = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBeforePrepare = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        let classification = try fixture.bridge.prepareRemote([scenario.survivor])

        XCTAssertTrue(classification.applicable.isEmpty)
        XCTAssertEqual(classification.deferredIDs, [scenario.sourceID])
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
        XCTAssertEqual(authenticationCount, countBeforePrepare,
                       "background sync must never trigger device-owner authentication")
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                       vaultBeforePrepare)
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBeforePrepare)
    }

    func testVaultExpiryBetweenApplyPreflightAndKeyReacquisitionDefersEntireBatch()
        async throws
    {
        let fixture = makeFixture()
        let scenario = try await makeSeededScenario(fixture)
        let copyRecord = try materializedCopyRecord(for: scenario)
        let copyEnvelope = try projectedEnvelope(for: copyRecord, scenario: scenario)
        let unrelatedID = UUID(
            uuidString: "20000000-0000-4000-8000-000000000007")!
        let unrelated = SyncEnvelope.plain(
            Snippet(
                id: unrelatedID,
                name: "Unrelated incoming snippet",
                keyword: "unrelated-incoming",
                content: "this applicable peer must wait with the expiring-key batch",
                tags: ["plain"],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 4)),
            hlc: HLC(wallMs: 400, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let batch = [scenario.survivor, copyEnvelope, unrelated]

        let classification = try fixture.bridge.prepareRemote(batch)
        XCTAssertEqual(Set(classification.applicable.map(\.id)), Set(batch.map(\.id)))
        XCTAssertTrue(classification.deferredIDs.isEmpty)
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)

        let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBefore = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)
        let deadline: Date
        guard case .unlocked(let until) = fixture.session.state else {
            return XCTFail("the seeded fixture must start with an unlocked vault")
        }
        deadline = until

        // `applyRemote` defensively prepares once more, then reacquires the key beside
        // its transaction. Keep that first read inside the window and put the second
        // exactly on the authoritative deadline so the race is deterministic.
        var keyReadCount = 0
        fixture.session.now = {
            keyReadCount += 1
            return keyReadCount == 1
                ? deadline.addingTimeInterval(-1)
                : deadline
        }

        let outcome = try fixture.bridge.applyRemote(classification.applicable)

        XCTAssertEqual(keyReadCount, 2)
        XCTAssertEqual(Set(outcome.deferredIDs), Set(batch.map(\.id)),
                       "no member of an unstarted batch may be confirmed as applied")
        XCTAssertTrue(outcome.changedIDs.isEmpty)
        XCTAssertTrue(outcome.incompatibleVaultIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                       vaultBefore)
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBefore)
        XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord])
        XCTAssertTrue(fixture.store.snippets.isEmpty)
        XCTAssertTrue(try diskSnippets().isEmpty)
    }

    func testUnlockedSecureLoserAndPlainSurvivorAreCommittedOnlyByApplyRemote() async throws {
        let fixture = makeFixture()
        let scenario = try await makeSeededScenario(fixture)
        let vaultBeforePrepare = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBeforePrepare = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        let classification = try fixture.bridge.prepareRemote([scenario.survivor])

        XCTAssertEqual(classification.applicable, [scenario.survivor])
        XCTAssertTrue(classification.deferredIDs.isEmpty)
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                       vaultBeforePrepare,
                       "preflight must not publish the copy in a transaction separate from its survivor")
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBeforePrepare)
        let beforeApply = try loadedVault()
        XCTAssertTrue(beforeApply.records.contains { $0.id == scenario.sourceID })
        XCTAssertFalse(beforeApply.records.contains { $0.id == scenario.variant.copyID })

        let outcome = try fixture.bridge.applyRemote(classification.applicable)

        XCTAssertEqual(outcome.changedIDs, [scenario.sourceID])
        XCTAssertTrue(outcome.deferredIDs.isEmpty)
        XCTAssertTrue(outcome.incompatibleVaultIDs.isEmpty)
        XCTAssertEqual(try diskSnippets(), [try XCTUnwrap(scenario.survivor.plainSnippet)])
        let afterApply = try loadedVault()
        XCTAssertFalse(afterApply.records.contains { $0.id == scenario.sourceID },
                       "the plain survivor now owns the original id")
        let copy = try XCTUnwrap(afterApply.record(scenario.variant.copyID))
        XCTAssertFalse(copy.isEnabled)
        XCTAssertTrue(copy.keyword.isEmpty)
        XCTAssertTrue(copy.tags.contains("conflict"))
        XCTAssertEqual(
            try SnippetCrypto.open(
                copy.sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: scenario.vaultKID,
                    recordID: scenario.variant.copyID),
                keyring: scenario.keyring),
            scenario.losingPlaintext,
            "the same apply call must retain the secure loser under its copy id")
    }

    func testRivalVaultVariantIsIncompatibleAndDoesNotMutateEitherPrimaryFile() async throws {
        let fixture = makeFixture()
        let localScenario = try await makeSeededScenario(fixture)
        let rivalKeyring = SnippetCrypto.Keyring.generate()
        let rivalScenario = try makeScenario(
            sourceID: localScenario.sourceID,
            vaultKID: "rival-vault-kid",
            keyring: rivalKeyring)
        let vaultBeforePrepare = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBeforePrepare = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        let classification = try fixture.bridge.prepareRemote([rivalScenario.survivor])

        XCTAssertTrue(classification.applicable.isEmpty)
        XCTAssertTrue(classification.deferredIDs.isEmpty)
        XCTAssertEqual(classification.incompatibleVaultIDs, [localScenario.sourceID])
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                       vaultBeforePrepare)
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBeforePrepare)
    }

    func testIncomingUnrelatedEnvelopeAtDeterministicCopyIDFailsClosedBeforeAnyWrite() async throws {
        let fixture = makeFixture()
        let scenario = try await makeSeededScenario(fixture)
        let unrelated = SyncEnvelope.plain(
            Snippet(
                id: scenario.variant.copyID,
                name: "Unrelated occupant",
                keyword: "unrelated",
                content: "must not overwrite or be overwritten",
                tags: ["unrelated"],
                createdAt: Date(timeIntervalSince1970: 10),
                updatedAt: Date(timeIntervalSince1970: 11)),
            hlc: HLC(wallMs: 500, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let vaultBeforePrepare = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBeforePrepare = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

        XCTAssertThrowsError(
            try fixture.bridge.prepareRemote([scenario.survivor, unrelated]),
            "an authoritative incoming id must participate in deterministic copy collision checks")

        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                       vaultBeforePrepare,
                       "fail-closed preflight may not append the generated copy")
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBeforePrepare)
        let retainedVault = try loadedVault()
        XCTAssertEqual(retainedVault.records.count, 1)
        XCTAssertEqual(retainedVault.records.map(\.id), [scenario.sourceID])
        XCTAssertTrue(try diskSnippets().isEmpty)
    }

    func testFreshInstallAdoptsAvailableSharedVaultForPlainSurvivorVariant() async throws {
        let keychain = makeKeychain(tier: .synchronizable(accessGroup: "test.shared"))
        let keyring = SnippetCrypto.Keyring.generate()
        let sharedKID = "shared-step6-vault"
        let sharedIdentity = VaultDocument(
            kid: sharedKID,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data(repeating: 0x71, count: 16))))
        try keychain.store(
            keyring.libraryKey.withUnsafeBytes { Data($0) },
            keyID: sharedKID)
        XCTAssertTrue(VaultIdentityStore(keychain: keychain).publish(sharedIdentity))
        let scenario = try makeScenario(
            sourceID: Self.sourceID,
            vaultKID: sharedKID,
            keyring: keyring)
        SyncCoordinator.runtimeEnabledOverride = false
        let fixture = makeFixture(keychain: keychain)
        XCTAssertNil(fixture.secureStore.document)
        SyncCoordinator.runtimeEnabledOverride = true

        let classification = try fixture.bridge.prepareRemote([scenario.survivor])

        XCTAssertEqual(fixture.secureStore.document?.kid, sharedKID,
                       "a plain survivor still announces the secure vault in its variant")
        XCTAssertTrue(classification.applicable.isEmpty,
                      "the newly adopted vault remains locked and must defer without prompting")
        XCTAssertEqual(classification.deferredIDs, [scenario.sourceID])
        XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty,
                      "a temporarily locked shared vault is not a rival identity")
        XCTAssertEqual(try loadedVault().kid, sharedKID)
        XCTAssertTrue(try diskSnippets().isEmpty)
    }

    func testMatchingIncomingCopyProvenanceIsAcceptedInEitherArrivalOrder() async throws {
        for survivorFirst in [true, false] {
            resetPrimaryFiles()
            let fixture = makeFixture()
            let scenario = try await makeSeededScenario(fixture)
            let firstMaterialization = try SyncSecureConflictMaterializer.materialize(
                envelope: scenario.survivor,
                keyring: scenario.keyring,
                vaultKID: scenario.vaultKID,
                existingSnippets: [],
                existingRecords: [scenario.sourceRecord])
            let copyRecord = try XCTUnwrap(
                firstMaterialization.records.first { $0.id == scenario.variant.copyID })
            let copyEnvelope = try XCTUnwrap(SyncLibraryProjection.currentEnvelopes(
                snippets: [],
                records: [copyRecord],
                deviceID: Self.deviceB,
                metadata: SyncBase(),
                agreedBase: SyncBase(),
                vaultKID: scenario.vaultKID)[scenario.variant.copyID])
            let batch = survivorFirst
                ? [scenario.survivor, copyEnvelope]
                : [copyEnvelope, scenario.survivor]

            let classification = try fixture.bridge.prepareRemote(batch)

            XCTAssertEqual(classification.applicable, batch)
            XCTAssertTrue(classification.deferredIDs.isEmpty)
            XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
            XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord],
                           "preflight remains non-mutating in both transport orders")
        }
    }

    func testCopyIDOccupantFilteredAsIncompatibleStillFailsCollisionBeforeAnyWrite()
        async throws
    {
        for survivorFirst in [true, false] {
            resetPrimaryFiles()
            let fixture = makeFixture()
            let scenario = try await makeSeededScenario(fixture)
            let incompatible = try secureEnvelope(
                id: scenario.variant.copyID,
                plaintext: Data("unrelated rival occupant".utf8),
                revision: 500,
                device: Self.deviceB,
                vaultKID: "rival-copy-occupant-vault",
                keyring: SnippetCrypto.Keyring.generate())
            let batch = survivorFirst
                ? [scenario.survivor, incompatible]
                : [incompatible, scenario.survivor]
            let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
            let libraryBefore = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)

            XCTAssertThrowsError(try fixture.bridge.prepareRemote(batch),
                                 "filtered records still occupy their authoritative incoming ids")
            XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBefore)
            XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                           libraryBefore)
            XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord])
        }
    }

    func testCorruptMatchingProvenanceCopyFailsApplyAndKeepsSourceAndSurvivorUnchanged()
        async throws
    {
        let fixture = makeFixture()
        let scenario = try await makeSeededScenario(fixture)
        let first = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: scenario.vaultKID,
            existingSnippets: [],
            existingRecords: [scenario.sourceRecord])
        var corruptVault = try loadedVault()
        var corruptCopy = try XCTUnwrap(first.records.first {
            $0.id == scenario.variant.copyID
        })
        corruptCopy.sealed = "corrupt-but-provenance-matching"
        corruptVault.records = [scenario.sourceRecord, corruptCopy]
        try VaultFile.write(corruptVault)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(reason: "Verify corrupt conflict copy")
        let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
        let libraryBefore = try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL)
        let classification = try fixture.bridge.prepareRemote([scenario.survivor])

        XCTAssertThrowsError(try fixture.bridge.applyRemote(classification.applicable))
        XCTAssertEqual(try Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBefore)
        XCTAssertEqual(try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                       libraryBefore)
        let retained = try loadedVault()
        XCTAssertNotNil(retained.record(scenario.sourceID))
        XCTAssertNotNil(retained.record(scenario.variant.copyID))
        XCTAssertTrue(try diskSnippets().isEmpty)
    }

    func testInvalidMatchingProvenanceCopyInSameBatchFailsBeforeAnyPrimaryWriteInEitherOrder()
        async throws
    {
        for damage in SameBatchCopyDamage.allCases {
            for survivorFirst in [true, false] {
                resetPrimaryFiles()
                let fixture = makeFixture()
                let scenario = try await makeSeededScenario(fixture)
                var incomingCopy = try materializedCopyRecord(for: scenario)
                switch damage {
                case .unauthenticatedSeal:
                    incomingCopy.sealed = "not-an-authenticated-vault-seal"
                case .authenticatedBodyWithMismatchedDeclaredHash:
                    incomingCopy.sealed = try SnippetCrypto.seal(
                        Data("authenticated later body with a stale declared hash".utf8),
                        for: SnippetCrypto.RecordContext(
                            scopeID: scenario.vaultKID,
                            recordID: scenario.variant.copyID),
                        keyring: scenario.keyring)
                    // Deliberately retain the pristine copy's contentHash. Matching
                    // provenance authenticates identity, not this different body.
                }
                let copyEnvelope = try projectedEnvelope(
                    for: incomingCopy, scenario: scenario)
                let batch = survivorFirst
                    ? [scenario.survivor, copyEnvelope]
                    : [copyEnvelope, scenario.survivor]
                let vaultBefore = try Data(
                    contentsOf: SnippetStorageLocations.vaultFileURL)
                let libraryBefore = try? Data(
                    contentsOf: SnippetStorageLocations.snippetsFileURL)

                var rejected = false
                do {
                    let classification = try fixture.bridge.prepareRemote(batch)
                    _ = try fixture.bridge.applyRemote(classification.applicable)
                } catch {
                    rejected = true
                }

                XCTAssertTrue(
                    rejected,
                    "\(damage) must fail closed when survivorFirst=\(survivorFirst)")
                XCTAssertEqual(
                    try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                    vaultBefore,
                    "the source and generated copy must commit atomically or not at all")
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                    libraryBefore,
                    "the plain survivor may not land before its same-batch copy validates")
                XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord])
                XCTAssertTrue(try diskSnippets().isEmpty)
            }
        }
    }

    func testNonLiveOrPlainMatchingProvenanceOccupantFailsBeforeAnyWriteInEitherOrder()
        async throws
    {
        for representation in InvalidMatchingOccupantRepresentation.allCases {
            for survivorFirst in [true, false] {
                resetPrimaryFiles()
                let fixture = makeFixture()
                let scenario = try await makeSeededScenario(fixture)
                let provenance = SyncMerge.conflictCopyProvenance(
                    sourceID: scenario.sourceID,
                    fingerprint: scenario.variant.fingerprint)
                let occupant: SyncEnvelope
                switch representation {
                case .plain:
                    occupant = SyncEnvelope.plain(
                        Snippet(
                            id: scenario.variant.copyID,
                            name: "Plain provenance impostor",
                            keyword: "plain-impostor",
                            content: "matching provenance cannot downgrade the secure copy",
                            tags: ["conflict"],
                            createdAt: Date(timeIntervalSince1970: 1),
                            updatedAt: Date(timeIntervalSince1970: 9)),
                        hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
                        origin: Self.deviceB,
                        x: [SyncMerge.plainConflictCopyExtensionKey: provenance])
                case .secureTombstone:
                    occupant = SyncEnvelope(
                        id: scenario.variant.copyID,
                        hlc: HLC(wallMs: 900, counter: 0, device: Self.deviceB),
                        origin: Self.deviceB,
                        secure: true,
                        deleted: true,
                        fields: nil,
                        x: [
                            SyncMerge.plainConflictCopyExtensionKey: provenance,
                            SyncEnvelope.vaultKeyIDExtensionKey: .string(
                                scenario.vaultKID),
                        ])
                }
                let batch = survivorFirst
                    ? [scenario.survivor, occupant]
                    : [occupant, scenario.survivor]
                let vaultBefore = try Data(
                    contentsOf: SnippetStorageLocations.vaultFileURL)
                let libraryBefore = try? Data(
                    contentsOf: SnippetStorageLocations.snippetsFileURL)

                var rejected = false
                do {
                    let classification = try fixture.bridge.prepareRemote(batch)
                    _ = try fixture.bridge.applyRemote(classification.applicable)
                } catch {
                    rejected = true
                }

                XCTAssertTrue(
                    rejected,
                    "a secure conflict copy occupant must be live+secure; got "
                        + "\(representation), survivorFirst=\(survivorFirst)")
                XCTAssertEqual(
                    try Data(contentsOf: SnippetStorageLocations.vaultFileURL),
                    vaultBefore)
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                    libraryBefore)
                XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord])
                XCTAssertTrue(try diskSnippets().isEmpty)
            }
        }
    }

    func testAuthenticatedMatchingProvenanceLaterEditIsAcceptedInEitherArrivalOrder()
        async throws
    {
        let laterBody = Data("legitimate authenticated edit of the conflict copy".utf8)
        for survivorFirst in [true, false] {
            resetPrimaryFiles()
            let fixture = makeFixture()
            let scenario = try await makeSeededScenario(fixture)
            var incomingCopy = try materializedCopyRecord(for: scenario)
            incomingCopy.sealed = try SnippetCrypto.seal(
                laterBody,
                for: SnippetCrypto.RecordContext(
                    scopeID: scenario.vaultKID,
                    recordID: scenario.variant.copyID),
                keyring: scenario.keyring)
            incomingCopy.contentHash = SnippetCrypto.contentHash(
                of: laterBody, keyring: scenario.keyring)
            incomingCopy.name = "User-renamed conflict copy"
            incomingCopy.hlc = HLC(wallMs: 600, counter: 0, device: Self.deviceB)
            incomingCopy.updatedAt = Date(timeIntervalSince1970: 6)
            let copyEnvelope = try projectedEnvelope(
                for: incomingCopy, scenario: scenario)
            let batch = survivorFirst
                ? [scenario.survivor, copyEnvelope]
                : [copyEnvelope, scenario.survivor]

            let classification = try fixture.bridge.prepareRemote(batch)
            _ = try fixture.bridge.applyRemote(classification.applicable)

            XCTAssertEqual(try diskSnippets(), [try XCTUnwrap(scenario.survivor.plainSnippet)])
            let retainedCopy = try XCTUnwrap(
                loadedVault().record(scenario.variant.copyID))
            XCTAssertEqual(retainedCopy.name, incomingCopy.name)
            XCTAssertEqual(retainedCopy.contentHash, incomingCopy.contentHash)
            XCTAssertEqual(
                try SnippetCrypto.open(
                    retainedCopy.sealed,
                    for: SnippetCrypto.RecordContext(
                        scopeID: scenario.vaultKID,
                        recordID: scenario.variant.copyID),
                    keyring: scenario.keyring),
                laterBody,
                "matching provenance plus a matching authenticated hash is a valid edit")
        }
    }

    func testMatchingProvenanceRivalVaultOccupantDoesNotAuthorizeSourceInEitherOrder()
        async throws
    {
        for survivorFirst in [true, false] {
            resetPrimaryFiles()
            let fixture = makeFixture()
            let scenario = try await makeSeededScenario(fixture)
            var rivalOccupant = try secureEnvelope(
                id: scenario.variant.copyID,
                plaintext: Data("rival vault occupant".utf8),
                revision: 700,
                device: Self.deviceB,
                vaultKID: "rival-vault-with-matching-provenance",
                keyring: SnippetCrypto.Keyring.generate())
            rivalOccupant.x[SyncMerge.plainConflictCopyExtensionKey] =
                SyncMerge.conflictCopyProvenance(
                    sourceID: scenario.sourceID,
                    fingerprint: scenario.variant.fingerprint)
            let batch = survivorFirst
                ? [scenario.survivor, rivalOccupant]
                : [rivalOccupant, scenario.survivor]
            let vaultBefore = try Data(contentsOf: SnippetStorageLocations.vaultFileURL)
            let libraryBefore = try? Data(
                contentsOf: SnippetStorageLocations.snippetsFileURL)

            var classification: RemoteClassification?
            do {
                let prepared = try fixture.bridge.prepareRemote(batch)
                classification = prepared
                _ = try fixture.bridge.applyRemote(prepared.applicable)
            } catch {
                // A structural/integrity rejection is one safe outcome. A classifier
                // may instead block both dependent records and let the engine surface
                // the rival-vault halt after applying an empty batch.
            }

            if let classification {
                XCTAssertTrue(
                    classification.applicable.isEmpty,
                    "provenance cannot authorize another vault when "
                        + "survivorFirst=\(survivorFirst)")
                XCTAssertEqual(
                    Set(classification.deferredIDs + classification.incompatibleVaultIDs),
                    Set([scenario.sourceID, scenario.variant.copyID]))
            }
            XCTAssertEqual(
                try Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBefore)
            XCTAssertEqual(
                try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                libraryBefore)
            XCTAssertEqual(try loadedVault().records, [scenario.sourceRecord])
            XCTAssertTrue(try diskSnippets().isEmpty)
        }
    }

    func testMatchingCopyDependencyDefersWithSourceWhileVaultIsLockedOrAbsent()
        async throws
    {
        for vaultAvailability in UnavailableVault.allCases {
            for survivorFirst in [true, false] {
                resetPrimaryFiles()
                let fixture = makeFixture()
                let scenario: SecurePlainConflictScenario
                switch vaultAvailability {
                case .locked:
                    scenario = try await makeSeededScenario(fixture)
                    fixture.session.lock()
                case .absent:
                    scenario = try makeScenario(
                        sourceID: Self.sourceID,
                        vaultKID: "not-yet-adopted-vault",
                        keyring: SnippetCrypto.Keyring.generate())
                }
                let copy = try materializedCopyRecord(for: scenario)
                let copyEnvelope = try projectedEnvelope(for: copy, scenario: scenario)
                let batch = survivorFirst
                    ? [scenario.survivor, copyEnvelope]
                    : [copyEnvelope, scenario.survivor]
                let vaultBefore = try? Data(
                    contentsOf: SnippetStorageLocations.vaultFileURL)
                let libraryBefore = try? Data(
                    contentsOf: SnippetStorageLocations.snippetsFileURL)

                let classification = try fixture.bridge.prepareRemote(batch)
                _ = try fixture.bridge.applyRemote(classification.applicable)

                XCTAssertTrue(
                    classification.applicable.isEmpty,
                    "the copy depends on its source while the vault is \(vaultAvailability)")
                XCTAssertEqual(
                    Set(classification.deferredIDs),
                    Set([scenario.sourceID, scenario.variant.copyID]))
                XCTAssertTrue(classification.incompatibleVaultIDs.isEmpty)
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBefore)
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                    libraryBefore)
                XCTAssertTrue(try diskSnippets().isEmpty)
            }
        }
    }

    func testUnrelatedCopyIDCollisionRejectsWhileVaultIsLockedOrAbsentWithoutWrites()
        async throws
    {
        for vaultAvailability in UnavailableVault.allCases {
            for survivorFirst in [true, false] {
                resetPrimaryFiles()
                let fixture = makeFixture()
                let scenario: SecurePlainConflictScenario
                switch vaultAvailability {
                case .locked:
                    scenario = try await makeSeededScenario(fixture)
                    fixture.session.lock()
                case .absent:
                    scenario = try makeScenario(
                        sourceID: Self.sourceID,
                        vaultKID: "not-yet-adopted-vault",
                        keyring: SnippetCrypto.Keyring.generate())
                }
                let unrelated = SyncEnvelope.plain(
                    Snippet(
                        id: scenario.variant.copyID,
                        name: "Unrelated copy-id occupant",
                        keyword: "unrelated-copy-id",
                        content: "must never land while the source waits",
                        tags: ["unrelated"],
                        createdAt: Date(timeIntervalSince1970: 1),
                        updatedAt: Date(timeIntervalSince1970: 8)),
                    hlc: HLC(wallMs: 800, counter: 0, device: Self.deviceB),
                    origin: Self.deviceB)
                let batch = survivorFirst
                    ? [scenario.survivor, unrelated]
                    : [unrelated, scenario.survivor]
                let vaultBefore = try? Data(
                    contentsOf: SnippetStorageLocations.vaultFileURL)
                let libraryBefore = try? Data(
                    contentsOf: SnippetStorageLocations.snippetsFileURL)

                var rejected = false
                do {
                    let classification = try fixture.bridge.prepareRemote(batch)
                    _ = try fixture.bridge.applyRemote(classification.applicable)
                } catch {
                    rejected = true
                }

                XCTAssertTrue(
                    rejected,
                    "copy-id authority is structural even while the vault is \(vaultAvailability)")
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.vaultFileURL), vaultBefore)
                XCTAssertEqual(
                    try? Data(contentsOf: SnippetStorageLocations.snippetsFileURL),
                    libraryBefore)
                XCTAssertTrue(try diskSnippets().isEmpty)
            }
        }
    }

    func testInterruptedPlainLoserToSecureSurvivorApplyRetainsLoserOrGeneratedCopy()
        throws
    {
        try XCTSkipIf(getuid() == 0, "read-only rename fault injection is meaningless as root")

        let source = Snippet(
            id: Self.sourceID,
            name: "Plain losing edit",
            keyword: "plain-loser",
            content: "the losing body that must remain recoverable",
            tags: ["plain"],
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2))
        let ancestor = SyncEnvelope.plain(
            Snippet(
                id: Self.sourceID,
                name: "Ancestor",
                keyword: "ancestor",
                content: "ancestor body",
                tags: [],
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 1)),
            hlc: HLC(wallMs: 100, counter: 0, device: Self.deviceA),
            origin: Self.deviceA)
        let losingSource = SyncEnvelope.plain(
            source,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.deviceA),
            origin: Self.deviceA)
        let keyring = SnippetCrypto.Keyring.generate()
        let vaultKID = "crash-window-vault"
        let secureWinner = try secureEnvelope(
            id: Self.sourceID,
            plaintext: Data("secure winning body".utf8),
            revision: 300,
            device: Self.deviceB,
            vaultKID: vaultKID,
            keyring: keyring)
        let merge = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor, local: losingSource, remote: secureWinner)
        let survivor = try XCTUnwrap(merge.survivor)
        let generatedCopy = try XCTUnwrap(merge.conflictCopies.first)
        let generatedSnippet = try XCTUnwrap(generatedCopy.plainSnippet)
        let survivorRecord = try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: survivor))
        XCTAssertTrue(survivor.secure)
        XCTAssertEqual(merge.conflictCopies.count, 1)
        XCTAssertEqual(generatedSnippet.content, source.content)

        let faultRoot = rootURL.appendingPathComponent(
            "promotion-copy-crash", isDirectory: true)
        let readOnlyLibraryDirectory = faultRoot.appendingPathComponent(
            "read-only-library", isDirectory: true)
        let libraryURL = readOnlyLibraryDirectory.appendingPathComponent("snippets.json")
        let vaultURL = faultRoot.appendingPathComponent("vault.json")
        let lockURL = faultRoot.appendingPathComponent("library.lock")
        let temporaryDirectory = faultRoot.appendingPathComponent("Tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: readOnlyLibraryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory, withIntermediateDirectories: true)
        try SnippetLibraryCodec.encode([source]).write(to: libraryURL)
        let emptyVault = VaultDocument(
            kid: vaultKID,
            vaultSalt: SnippetCrypto.base64URL(keyring.salt),
            kdf: VaultKDFParameters(
                alg: PassphraseKDF.algorithm,
                iterations: PassphraseKDF.iterations,
                saltP: SnippetCrypto.base64URL(Data(repeating: 0x51, count: 16))))
        try VaultFile.write(
            emptyVault, to: vaultURL, temporaryDirectory: temporaryDirectory)
        try SyncStateFile.write(
            .fresh(),
            to: SnippetStorageLocations.syncStateFileURL,
            temporaryDirectory: temporaryDirectory)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: readOnlyLibraryDirectory.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: readOnlyLibraryDirectory.path)
        }

        XCTAssertThrowsError(
            try LibraryTransaction.perform(
                libraryURL: libraryURL,
                vaultURL: vaultURL,
                stateURL: SnippetStorageLocations.syncStateFileURL,
                lockURL: lockURL,
                temporaryDirectory: temporaryDirectory,
                lockTimeout: 2
            ) { contents in
                var vault = try XCTUnwrap(contents.vault)
                vault.records = [survivorRecord]
                contents.vault = vault
                contents.snippets = [generatedSnippet]
            },
            "the injected library rename fault must interrupt the transaction before completion")
        let interruptedVaultIDs = Set(
            VaultFile.load(from: vaultURL).value?.records.map(\.id) ?? [])
        let interruptedPlainIDs = Set(
            try LibraryWriter.read(from: libraryURL).snippets.map(\.id))
        XCTAssertTrue(
            interruptedPlainIDs.contains(Self.sourceID)
                || interruptedPlainIDs.contains(generatedCopy.id),
            "at every write boundary the losing plain body has a durable owner")
        XCTAssertTrue(
            interruptedVaultIDs.isEmpty || interruptedVaultIDs == [Self.sourceID],
            "the fault may precede or follow the vault rename; both are safe boundaries")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: readOnlyLibraryDirectory.path)
        let keychain = makeKeychain()
        let recoveringStore = SecureSnippetStore(
            session: VaultSession(
                keychain: keychain,
                authenticationEvaluator: { _ in true }),
            keychain: keychain,
            deviceID: Self.deviceB,
            vaultURL: vaultURL,
            libraryURL: libraryURL,
            lockURL: lockURL,
            temporaryDirectory: temporaryDirectory)

        _ = recoveringStore.reconcileInterruptedMove()

        let recoveredPlainIDs = Set(
            try LibraryWriter.read(from: libraryURL).snippets.map(\.id))
        XCTAssertTrue(
            recoveredPlainIDs.contains(Self.sourceID)
                || recoveredPlainIDs.contains(generatedCopy.id),
            "startup recovery may keep old S or finish C, but cannot discard both copies "
                + "of the losing plain body")
    }

    // MARK: - Fixtures

    private func makeFixture(
        authenticationEvaluator: @escaping VaultSession.AuthenticationEvaluator = { _ in true },
        keychain: KeychainSecretStore? = nil
    ) -> BridgeFixture {
        let keychain = keychain ?? makeKeychain()
        let session = VaultSession(
            keychain: keychain,
            authenticationEvaluator: authenticationEvaluator)
        let store = SnippetStore(configuration: .iOS)
        let secureStore = SecureSnippetStore(
            session: session,
            keychain: keychain,
            deviceID: store.deviceID)
        store.secureProvider = secureStore
        return BridgeFixture(
            store: store,
            secureStore: secureStore,
            session: session,
            bridge: SnippetLibraryBridge(store: store, secureStore: secureStore))
    }

    private func makeKeychain(
        tier: KeychainSecretStore.Tier = .deviceOnly
    ) -> KeychainSecretStore {
        KeychainSecretStore(
            tier: tier,
            service: "com.khm.snippets.tests.\(UUID().uuidString.lowercased())",
            inMemory: true)
    }

    private func resetPrimaryFiles() {
        for url in [
            SnippetStorageLocations.snippetsFileURL,
            SnippetStorageLocations.vaultFileURL,
            SnippetStorageLocations.syncLibraryMetadataFileURL,
            SnippetStorageLocations.syncBaseFileURL,
            SnippetStorageLocations.syncJournalFileURL,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeSeededScenario(
        _ fixture: BridgeFixture
    ) async throws -> SecurePlainConflictScenario {
        let pending = try XCTUnwrap(
            fixture.secureStore.prepareVaultCreationIfNeeded())
        let document = try fixture.secureStore.commitVaultCreation(pending)
        _ = try await fixture.session.unlock(reason: "Prepare secure conflict bridge fixture")
        let keyring = try fixture.secureStore.unlockedKeyringForSync()
        let scenario = try makeScenario(
            sourceID: Self.sourceID,
            vaultKID: document.kid,
            keyring: keyring)
        var seeded = document
        seeded.records = [scenario.sourceRecord]
        try VaultFile.write(seeded)
        fixture.secureStore.reload(notifyChange: false)
        _ = try await fixture.session.unlock(reason: "Unlock seeded secure conflict fixture")
        return scenario
    }

    private func materializedCopyRecord(
        for scenario: SecurePlainConflictScenario
    ) throws -> VaultRecord {
        let result = try SyncSecureConflictMaterializer.materialize(
            envelope: scenario.survivor,
            keyring: scenario.keyring,
            vaultKID: scenario.vaultKID,
            existingSnippets: [],
            existingRecords: [scenario.sourceRecord])
        return try XCTUnwrap(result.records.first {
            $0.id == scenario.variant.copyID
        })
    }

    private func projectedEnvelope(
        for record: VaultRecord,
        scenario: SecurePlainConflictScenario
    ) throws -> SyncEnvelope {
        try XCTUnwrap(SyncLibraryProjection.currentEnvelopes(
            snippets: [],
            records: [record],
            deviceID: Self.deviceB,
            metadata: SyncBase(),
            agreedBase: SyncBase(),
            vaultKID: scenario.vaultKID)[record.id])
    }

    private func makeScenario(
        sourceID: UUID,
        vaultKID: String,
        keyring: SnippetCrypto.Keyring
    ) throws -> SecurePlainConflictScenario {
        let ancestor = try secureEnvelope(
            id: sourceID,
            plaintext: Data("ancestor secret".utf8),
            revision: 100,
            device: Self.deviceA,
            vaultKID: vaultKID,
            keyring: keyring)
        let losingPlaintext = Data("secure losing edit".utf8)
        let losingSource = try secureEnvelope(
            id: sourceID,
            plaintext: losingPlaintext,
            revision: 200,
            device: Self.deviceA,
            vaultKID: vaultKID,
            keyring: keyring)
        let winningSnippet = Snippet(
            id: sourceID,
            name: "Plain survivor",
            keyword: "plain-survivor",
            content: "winning plain edit",
            tags: ["plain"],
            isEnabled: true,
            isPinned: true,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 3))
        let winningSource = SyncEnvelope.plain(
            winningSnippet,
            hlc: HLC(wallMs: 300, counter: 0, device: Self.deviceB),
            origin: Self.deviceB)
        let outcome = try SyncMerge.mergeEnvelopeOutcome(
            base: ancestor,
            local: losingSource,
            remote: winningSource)
        let survivor = try XCTUnwrap(outcome.survivor)
        let variant = try XCTUnwrap(
            SyncMerge.secureContentConflictVariants(in: survivor).first)
        XCTAssertFalse(survivor.secure)
        XCTAssertTrue(outcome.conflictCopies.isEmpty)
        XCTAssertEqual(variant.sourceID, sourceID)
        XCTAssertEqual(variant.fields, losingSource.fields)
        let sourceRecord = try XCTUnwrap(
            SyncLibraryProjection.vaultRecord(from: losingSource))
        return SecurePlainConflictScenario(
            sourceID: sourceID,
            vaultKID: vaultKID,
            keyring: keyring,
            losingPlaintext: losingPlaintext,
            sourceRecord: sourceRecord,
            survivor: survivor,
            variant: variant)
    }

    private func secureEnvelope(
        id: UUID,
        plaintext: Data,
        revision: UInt64,
        device: String,
        vaultKID: String,
        keyring: SnippetCrypto.Keyring
    ) throws -> SyncEnvelope {
        let sealed = try SnippetCrypto.seal(
            plaintext,
            for: SnippetCrypto.RecordContext(scopeID: vaultKID, recordID: id),
            keyring: keyring)
        return SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: true,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: "Secure source",
                keyword: "secure-source",
                content: Data(sealed.utf8),
                tags: ["secure"],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: Double(revision) / 100)),
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string(
                    SnippetCrypto.contentHash(of: plaintext, keyring: keyring)),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(vaultKID),
            ])
    }

    private func diskSnippets() throws -> [Snippet] {
        guard FileManager.default.fileExists(
            atPath: SnippetStorageLocations.snippetsFileURL.path)
        else { return [] }
        return try SnippetLibraryCodec.decode(
            Data(contentsOf: SnippetStorageLocations.snippetsFileURL))
    }

    private func loadedVault() throws -> VaultDocument {
        guard case .loaded(let vault) = VaultFile.load() else {
            throw BridgeFixtureFailure.expectedReadableVault
        }
        return vault
    }
}

@MainActor
private struct BridgeFixture {
    let store: SnippetStore
    let secureStore: SecureSnippetStore
    let session: VaultSession
    let bridge: SnippetLibraryBridge
}

private struct SecurePlainConflictScenario {
    let sourceID: UUID
    let vaultKID: String
    let keyring: SnippetCrypto.Keyring
    let losingPlaintext: Data
    let sourceRecord: VaultRecord
    let survivor: SyncEnvelope
    let variant: SyncMerge.SecureContentConflictVariant
}

private enum BridgeFixtureFailure: Error {
    case expectedReadableVault
}

private enum SameBatchCopyDamage: CaseIterable {
    case unauthenticatedSeal
    case authenticatedBodyWithMismatchedDeclaredHash
}

private enum InvalidMatchingOccupantRepresentation: CaseIterable {
    case plain
    case secureTombstone
}

private enum UnavailableVault: CaseIterable {
    case locked
    case absent
}
