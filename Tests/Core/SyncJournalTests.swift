import Foundation
import Testing

@testable import SnippetsCore

/// Contract tests for the durable, per-record sync outbox.
///
/// The journal is user intent, not disposable derived state. In particular, an
/// `offered` snapshot may already have committed remotely even though this process did
/// not receive its acknowledgement. Keeping that exact snapshot, separately from the
/// user's newer `desired` value, is what makes the ambiguity recoverable after restart.
@Suite("Sync journal", .timeLimit(.minutes(1)))
struct SyncJournalTests {

    private static let device = "aaaaaaa1"

    // MARK: - Fixtures

    private struct ScratchDirectory {
        let url: URL

        init(_ label: String) throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sync-journal-\(label)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func file(_ name: String) -> URL {
            url.appendingPathComponent(name, isDirectory: false)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    private func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", value))!
    }

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private func envelope(
        _ id: UUID,
        revision: UInt64,
        name: String = "name",
        content: String = "body",
        device: String = SyncJournalTests.device
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: revision, counter: 0, device: device),
            origin: device,
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: name,
                content: Data(content.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: time(1),
                updatedAt: time(Double(revision) / 1_000)))
    }

    private func secureEnvelope(
        _ id: UUID,
        revision: UInt64,
        content: String,
        vaultKID: String
    ) -> SyncEnvelope {
        SyncEnvelope.secureRecord(
            id: id,
            name: "secure",
            keyword: "secure",
            plaintext: Data(content.utf8),
            createdAt: time(1),
            updatedAt: time(Double(revision) / 1_000),
            hlc: HLC(wallMs: revision, counter: 0, device: Self.device),
            origin: Self.device,
            x: [
                SyncEnvelope.vaultContentHashExtensionKey: .string("keyed-content-hash"),
                SyncEnvelope.vaultKeyIDExtensionKey: .string(vaultKID),
                "futureMetadata": .string("must not enter a tombstone"),
            ])
    }

    private func base(_ envelopes: [SyncEnvelope] = []) -> SyncBase {
        var result = SyncBase()
        for envelope in envelopes { result.record(envelope) }
        return result
    }

    private func content(_ envelope: SyncEnvelope?) -> String? {
        envelope?.fields.flatMap { String(data: $0.content, encoding: .utf8) }
    }

    // MARK: - Offered snapshot versus desired intent

    @Test func offeredSnapshotIsFrozenAcrossNewerEditAndRestartUntilAcknowledged() throws {
        let scratch = try ScratchDirectory("offered-restart")
        defer { scratch.remove() }

        let snippetID = id(1)
        let created = envelope(snippetID, revision: 100, content: "offered body")
        let edited = envelope(snippetID, revision: 200, content: "new desired body")
        let confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: created], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        let firstEntry = try #require(journal.entry(snippetID))
        #expect(firstEntry.desired == created)
        #expect(firstEntry.offered == nil)

        let firstPending = journal.pending(confirmed: confirmed)
        #expect(firstPending == [created])
        journal.markOffered(firstPending)
        let frozenOffer = try #require(journal.entry(snippetID)?.offered)
        #expect(frozenOffer.envelope == created)
        #expect(frozenOffer.generation == firstEntry.generation)

        journal.reconcile(
            current: [snippetID: edited], confirmed: confirmed,
            deviceID: Self.device, now: time(20))
        let editedEntry = try #require(journal.entry(snippetID))
        #expect(editedEntry.desired == edited)
        #expect(editedEntry.generation > frozenOffer.generation)
        #expect(editedEntry.modifiedAt == time(20))
        #expect(editedEntry.offered == frozenOffer,
                "a local edit must not rewrite the bytes whose ACK is still ambiguous")
        #expect(journal.pending(confirmed: confirmed) == [created],
                "retry must reproduce the exact offered snapshot, not leap to newer intent")

        let url = scratch.file("journal.json")
        try SyncJournalFile.write(
            journal, to: url, temporaryDirectory: scratch.file("Tmp"))
        guard case .loaded(let restarted) = SyncJournalFile.load(from: url) else {
            Issue.record("expected the journal to survive restart")
            return
        }

        #expect(restarted == journal)
        #expect(restarted.entry(snippetID)?.offered == frozenOffer)
        #expect(restarted.entry(snippetID)?.desired == edited)
        #expect(restarted.pending(confirmed: confirmed) == [created])

        let projection = restarted.projectionKnowledge(over: confirmed)
        #expect(projection.envelope(snippetID) == created,
                "projection knows what may have committed, not the unsent newer edit")
    }

    @Test func generationAndModificationTimeChangeOnlyWhenDesiredChanges() throws {
        let snippetID = id(2)
        let first = envelope(snippetID, revision: 100, content: "one")
        let second = envelope(snippetID, revision: 200, content: "two")
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: first], confirmed: SyncBase(),
            deviceID: Self.device, now: time(10))
        let initial = try #require(journal.entry(snippetID))
        #expect(initial.modifiedAt == time(10))

        journal.reconcile(
            current: [snippetID: first], confirmed: SyncBase(),
            deviceID: Self.device, now: time(20))
        let unchanged = try #require(journal.entry(snippetID))
        #expect(unchanged.generation == initial.generation)
        #expect(unchanged.modifiedAt == initial.modifiedAt,
                "a no-op reconcile must not make the durable file look newly changed")

        journal.reconcile(
            current: [snippetID: second], confirmed: SyncBase(),
            deviceID: Self.device, now: time(30))
        let changed = try #require(journal.entry(snippetID))
        #expect(changed.generation > unchanged.generation)
        #expect(changed.modifiedAt == time(30))
    }

    // MARK: - Deletes after an ambiguous commit

    @Test func deleteAfterLostCreateAckIsDerivedFromOfferedEvenWithNoConfirmedBase() throws {
        let snippetID = id(10)
        let created = envelope(snippetID, revision: 100, content: "short lived")
        var confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: created], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        let pendingCreate = journal.pending(confirmed: confirmed)
        journal.markOffered(pendingCreate)
        let offered = try #require(journal.entry(snippetID)?.offered)

        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(20))
        let afterDelete = try #require(journal.entry(snippetID))
        #expect(afterDelete.offered == offered)
        #expect(afterDelete.desired.deleted)
        #expect(afterDelete.desired.fields == nil)
        #expect(afterDelete.desired.hlc > created.hlc,
                "a later delete needs its own causal position, not the create's HLC")
        #expect(afterDelete.generation > offered.generation)

        // The retried create is idempotently accepted. Only after its exact bytes are
        // durable in confirmed may ACK clear `offered` and expose the later tombstone.
        confirmed.record(offered.envelope)
        journal.acknowledge([snippetID], confirmed: confirmed)
        let readyToDelete = try #require(journal.entry(snippetID))
        #expect(readyToDelete.offered == nil)
        #expect(readyToDelete.desired == afterDelete.desired)
        #expect(journal.pending(confirmed: confirmed) == [afterDelete.desired])
    }

    @Test func secureDeleteAfterLostUpdateAckKeepsVaultScopeButNoBody() throws {
        let snippetID = id(11)
        let vaultKID = "vault-scope-one"
        let secret = "body that must not survive in a tombstone"
        let offeredUpdate = secureEnvelope(
            snippetID, revision: 500, content: secret, vaultKID: vaultKID)
        var journal = SyncJournal()
        let confirmed = SyncBase()

        journal.reconcile(
            current: [snippetID: offeredUpdate], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        let pendingUpdate = journal.pending(confirmed: confirmed)
        journal.markOffered(pendingUpdate)
        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(20))

        let entry = try #require(journal.entry(snippetID))
        let tombstone = entry.desired
        #expect(entry.offered?.envelope == offeredUpdate)
        #expect(tombstone.deleted)
        #expect(tombstone.secure)
        #expect(tombstone.fields == nil)
        #expect(tombstone.plaintext == nil)
        #expect(tombstone.contentHash == nil)
        #expect(tombstone.hlc > offeredUpdate.hlc)
        #expect(tombstone.x == [
            SyncEnvelope.vaultKeyIDExtensionKey: .string(vaultKID)
        ], "only the scope needed to authenticate a secure delete may survive")

        let encoded = try tombstone.canonicalData()
        #expect(encoded.range(of: Data(secret.utf8)) == nil)
        #expect(encoded.range(of: Data("keyed-content-hash".utf8)) == nil)
        #expect(encoded.range(of: Data("futureMetadata".utf8)) == nil)
    }

    @Test func freshInstallDoesNotInventTombstonesForUnknownRemoteRecords() {
        let unknownID = id(12)
        let remoteOnly = envelope(
            unknownID, revision: 100, content: "exists only on another device")
        let confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(10))

        #expect(journal.entry(unknownID) == nil)
        #expect(journal.pending(confirmed: confirmed).isEmpty)
        #expect(journal.projectionKnowledge(over: confirmed).envelope(unknownID) == nil)
        #expect(remoteOnly.deleted == false,
                "the remote addition is deliberately not represented as local absence")
    }

    @Test func unofferedCreateThenDeleteWithNoBaseCollapsesToNoRemoteOperation() throws {
        let snippetID = id(13)
        let localCreate = envelope(snippetID, revision: 100, content: "never left this device")
        let confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: localCreate], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        let createEntry = try #require(journal.entry(snippetID))
        #expect(createEntry.offered == nil)

        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(20))

        #expect(journal.entry(snippetID) == nil,
                "a create known never to have been offered needs no durable delete")
        #expect(journal.pending(confirmed: confirmed).isEmpty)
        #expect(journal.projectionKnowledge(over: confirmed).envelope(snippetID) == nil)
    }

    // MARK: - ACK and rejection fences

    @Test func acknowledgeRequiresExactConfirmedOfferAndKeepsNewerGenerationPending() throws {
        let snippetID = id(20)
        let offeredValue = envelope(snippetID, revision: 100, content: "offered")
        let latestValue = envelope(snippetID, revision: 200, content: "latest")
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: offeredValue], confirmed: SyncBase(),
            deviceID: Self.device, now: time(10))
        let firstPending = journal.pending(confirmed: SyncBase())
        journal.markOffered(firstPending)
        let offer = try #require(journal.entry(snippetID)?.offered)
        journal.reconcile(
            current: [snippetID: latestValue], confirmed: SyncBase(),
            deviceID: Self.device, now: time(20))
        let latestEntry = try #require(journal.entry(snippetID))
        #expect(latestEntry.generation > offer.generation)

        let wrongConfirmed = base([latestValue])
        journal.acknowledge([snippetID], confirmed: wrongConfirmed)
        #expect(journal.entry(snippetID)?.offered == offer,
                "an ACK must not clear intent before exact offered bytes reach durable base")

        let exactConfirmed = base([offeredValue])
        journal.acknowledge([snippetID], confirmed: exactConfirmed)
        let afterOldAck = try #require(journal.entry(snippetID))
        #expect(afterOldAck.offered == nil)
        #expect(afterOldAck.desired == latestValue,
                "ACK for an older generation must not clear the newer local edit")
        #expect(afterOldAck.generation == latestEntry.generation)
        #expect(journal.pending(confirmed: exactConfirmed) == [latestValue])

        let latestPending = journal.pending(confirmed: exactConfirmed)
        journal.markOffered(latestPending)
        let latestOffered = try #require(journal.entry(snippetID)?.offered?.envelope)
        var latestConfirmed = exactConfirmed
        latestConfirmed.record(latestOffered)
        journal.acknowledge([snippetID], confirmed: latestConfirmed)
        #expect(journal.entry(snippetID) == nil,
                "matching desired/offered generation is fully satisfied by confirmed")
    }

    @Test func explicitRejectionDropsOldOfferAndImmediatelyExposesLatestDesired() throws {
        let snippetID = id(21)
        let offeredValue = envelope(snippetID, revision: 100, content: "old offer")
        let latestValue = envelope(snippetID, revision: 200, content: "latest desired")
        let confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: offeredValue], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        let firstPending = journal.pending(confirmed: confirmed)
        journal.markOffered(firstPending)
        journal.reconcile(
            current: [snippetID: latestValue], confirmed: confirmed,
            deviceID: Self.device, now: time(20))
        #expect(journal.pending(confirmed: confirmed) == [offeredValue])

        journal.reject([snippetID])

        let entry = try #require(journal.entry(snippetID))
        #expect(entry.offered == nil)
        #expect(entry.desired == latestValue)
        #expect(journal.pending(confirmed: confirmed) == [latestValue])
    }

    @Test func transportRekeyStagesConfirmedSnapshotsWithoutReplacingJournalIntent() throws {
        let liveID = id(22)
        let tombstoneID = id(23)
        let lostAckID = id(27)
        let newerDesiredID = id(28)
        let live = envelope(liveID, revision: 100, content: "confirmed live")
        let tombstone = SyncEnvelope.tombstone(
            id: tombstoneID,
            secure: false,
            hlc: HLC(wallMs: 200, counter: 0, device: Self.device),
            origin: Self.device)
        let confirmedBeforeLostAck = envelope(
            lostAckID, revision: 100, content: "confirmed before lost ACK")
        let lostAckOffer = envelope(
            lostAckID, revision: 200, content: "already offered update")
        let lostAckDesired = envelope(
            lostAckID, revision: 300, content: "newer intent after lost ACK")
        let confirmedBeforeNewerIntent = envelope(
            newerDesiredID, revision: 100, content: "confirmed ancestor")
        let newerDesired = envelope(
            newerDesiredID, revision: 200, content: "newer unsent intent")
        let originalCursor = SyncCursor("41")
        let stagedAt = time(30)
        var confirmed = base([
            live,
            tombstone,
            confirmedBeforeLostAck,
            confirmedBeforeNewerIntent,
        ])
        confirmed.cursor = originalCursor
        confirmed.recordConfirmed(
            live,
            recordVersion: SyncRecordVersion(Data("live-before-rekey".utf8)))
        confirmed.recordConfirmed(
            tombstone,
            recordVersion: SyncRecordVersion(Data("tombstone-before-rekey".utf8)))
        confirmed.recordConfirmed(
            confirmedBeforeNewerIntent,
            recordVersion: SyncRecordVersion(Data("newer-intent-before-rekey".utf8)))
        var journal = SyncJournal(entries: [
            SyncBase.key(lostAckID): SyncJournal.Entry(
                desired: lostAckDesired,
                offered: SyncJournal.Offered(envelope: lostAckOffer, generation: 7),
                generation: 8,
                modifiedAt: time(20)),
            SyncBase.key(newerDesiredID): SyncJournal.Entry(
                desired: newerDesired,
                offered: nil,
                generation: 5,
                modifiedAt: time(25)),
        ])
        let lostAckBefore = try #require(journal.entry(lostAckID))
        let newerDesiredBefore = try #require(journal.entry(newerDesiredID))

        journal.stageConfirmedForTransportRekey(confirmed, now: stagedAt)

        let stagedLive = try #require(journal.entry(liveID))
        #expect(stagedLive.desired == live)
        #expect(stagedLive.offered?.envelope == live)
        #expect(stagedLive.offered?.generation == stagedLive.generation)
        #expect(stagedLive.modifiedAt == stagedAt)

        let stagedTombstone = try #require(journal.entry(tombstoneID))
        #expect(stagedTombstone.desired == tombstone)
        #expect(stagedTombstone.offered?.envelope == tombstone,
                "confirmed tombstones need resealing just like live records")
        #expect(stagedTombstone.offered?.generation == stagedTombstone.generation)
        #expect(stagedTombstone.modifiedAt == stagedAt)

        #expect(journal.entry(lostAckID) == lostAckBefore,
                "rekey must not replace the tentative ancestor from a lost ACK")
        let stagedNewerDesired = try #require(journal.entry(newerDesiredID))
        #expect(stagedNewerDesired.desired == newerDesiredBefore.desired)
        #expect(stagedNewerDesired.generation == newerDesiredBefore.generation)
        #expect(stagedNewerDesired.modifiedAt == newerDesiredBefore.modifiedAt)
        #expect(stagedNewerDesired.offered?.envelope == confirmedBeforeNewerIntent,
                "the confirmed ancestor is resealed before the newer desired value")

        // Replacing the scheduler epoch invalidates its cursor, not CloudKit's record
        // change tags. Those tags are independent of the wire-encryption key and are
        // what prevent resealed snapshots from overwriting an independent remote edit.
        let resetBase = SyncBase(recordVersions: confirmed.recordVersions)
        #expect(resetBase.envelopes.isEmpty)
        #expect(resetBase.cursor == nil)
        #expect(journal.entry(liveID)?.offered?.recordVersion
                == confirmed.recordVersion(liveID))
        #expect(journal.entry(tombstoneID)?.offered?.recordVersion
                == confirmed.recordVersion(tombstoneID))
        #expect(journal.entry(newerDesiredID)?.offered?.recordVersion
                == confirmed.recordVersion(newerDesiredID))
        #expect(resetBase.recordVersions == confirmed.recordVersions)
        #expect(journal.pending(confirmed: resetBase) == [
            live,
            tombstone,
            lostAckOffer,
            confirmedBeforeNewerIntent,
        ])

        let stagedOnce = journal
        journal.stageConfirmedForTransportRekey(confirmed, now: time(40))
        #expect(journal == stagedOnce, "rekey staging must be idempotent")
    }

    @Test func lostAckCreateThenDeleteSurvivesRekeyBaseReset() throws {
        let snippetID = id(29)
        let created = envelope(snippetID, revision: 100, content: "short lived")
        var confirmed = SyncBase(cursor: SyncCursor("17"))
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: created], confirmed: confirmed,
            deviceID: Self.device, now: time(10))
        journal.markOffered(journal.pending(confirmed: confirmed))
        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(20))
        let beforeRekey = try #require(journal.entry(snippetID))
        let tombstone = beforeRekey.desired
        #expect(beforeRekey.offered?.envelope == created)
        #expect(tombstone.deleted)

        // A lost create ACK means the confirmed base is empty. Staging that base and
        // then resetting it must still leave the immutable offered create as the retry.
        journal.stageConfirmedForTransportRekey(confirmed, now: time(30))
        confirmed = SyncBase()
        #expect(journal.entry(snippetID) == beforeRekey)
        #expect(journal.pending(confirmed: confirmed) == [created])

        // Once the retry proves the exact create durable, the fence opens and exposes
        // the causally later delete rather than dropping or skipping it.
        confirmed.record(created)
        journal.acknowledge([snippetID], confirmed: confirmed)
        let afterCreateAck = try #require(journal.entry(snippetID))
        #expect(afterCreateAck.offered == nil)
        #expect(afterCreateAck.desired == tombstone)
        #expect(journal.pending(confirmed: confirmed) == [tombstone])
    }

    @Test func metadataMissingProjectionRebasesFrozenMergedLocalOverStaleOffer() throws {
        let snippetID = id(33)
        let staleOfferedA = envelope(
            snippetID,
            revision: 200,
            name: "ancestor name",
            content: "local body A",
            device: Self.device)
        let confirmedB = envelope(
            snippetID,
            revision: 300,
            name: "remote name B",
            content: "ancestor body",
            device: "bbbbbbb2")
        let frozenMergedM = Snippet(
            id: snippetID,
            name: "remote name B",
            keyword: "remote name B",
            content: "local body A",
            createdAt: time(1),
            updatedAt: time(0.4))
        let confirmed = base([confirmedB])
        var journal = SyncJournal(entries: [
            SyncBase.key(snippetID): SyncJournal.Entry(
                desired: staleOfferedA,
                offered: SyncJournal.Offered(envelope: staleOfferedA, generation: 1),
                generation: 1,
                modifiedAt: time(0.2)),
        ])

        let knowledge = journal.projectionKnowledge(over: confirmed)
        #expect(knowledge.envelope(snippetID) == staleOfferedA,
                "the ambiguous offer intentionally overlays confirmed B")
        let projected = SyncLibraryProjection.currentEnvelopes(
            snippets: [frozenMergedM],
            records: [],
            deviceID: Self.device,
            metadata: SyncBase(),
            agreedBase: knowledge)
        let projectedM = try #require(projected[snippetID])
        #expect(!projectedM.deleted)
        #expect(projectedM != staleOfferedA)
        #expect(projectedM.fields?.name == "remote name B")
        #expect(content(projectedM) == "local body A")

        journal.reconcile(
            current: projected,
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(0.5))
        let rebased = try #require(journal.entry(snippetID))
        #expect(rebased.offered?.envelope == staleOfferedA)
        #expect(rebased.desired == projectedM)
        #expect(!rebased.desired.deleted,
                "the durable merged local file is a live rebase, never an inferred delete")

        // Once the repeated fetch authoritatively rejects stale A, M—not A and not a
        // tombstone—is the next value offered over confirmed B.
        journal.reject([snippetID])
        journal.reconcile(
            current: projected,
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(0.6))
        #expect(journal.entry(snippetID)?.offered == nil)
        #expect(journal.entry(snippetID)?.desired == projectedM)
        #expect(journal.pending(confirmed: confirmed) == [projectedM])
    }

    @Test func forgettingSecureIntentKeepsOrdinaryAndDemotedDesiredValues() throws {
        let secureID = id(24)
        let ordinaryID = id(25)
        let demotedID = id(26)
        let secure = secureEnvelope(
            secureID, revision: 100, content: "secure desired", vaultKID: "vault-one")
        let ordinary = envelope(ordinaryID, revision: 100, content: "ordinary desired")
        let secureBeforeDemotion = secureEnvelope(
            demotedID, revision: 100, content: "secure before demotion", vaultKID: "vault-one")
        let ordinaryAfterDemotion = envelope(
            demotedID, revision: 200, content: "ordinary after demotion")
        let confirmed = SyncBase()
        var journal = SyncJournal()

        journal.reconcile(
            current: [
                secureID: secure,
                ordinaryID: ordinary,
                demotedID: secureBeforeDemotion,
            ],
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(10))
        let initialPending = journal.pending(confirmed: confirmed)
        journal.markOffered(initialPending)
        journal.reconcile(
            current: [
                secureID: secure,
                ordinaryID: ordinary,
                demotedID: ordinaryAfterDemotion,
            ],
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(20))

        let ordinaryBefore = try #require(journal.entry(ordinaryID))
        let demotedBefore = try #require(journal.entry(demotedID))
        #expect(journal.entry(secureID)?.desired.secure == true)
        #expect(demotedBefore.offered?.envelope.secure == true)
        #expect(demotedBefore.desired == ordinaryAfterDemotion)
        #expect(!demotedBefore.desired.secure)

        journal.forgetSecureIntent()

        #expect(journal.entry(secureID) == nil,
                "intent still owned by the forgotten vault must be removed")
        #expect(journal.entry(ordinaryID) == ordinaryBefore,
                "ordinary desired and offered state does not belong to the vault")
        let demotedAfter = try #require(journal.entry(demotedID))
        #expect(demotedAfter.offered == nil,
                "the old secure transport snapshot is invalid after forgetting the vault")
        #expect(demotedAfter.desired == ordinaryAfterDemotion)
        #expect(demotedAfter.generation == demotedBefore.generation)
        #expect(demotedAfter.modifiedAt == demotedBefore.modifiedAt)
        #expect(journal.pending(confirmed: confirmed).contains(ordinaryAfterDemotion))

        let afterFirstForget = journal
        journal.forgetSecureIntent()
        #expect(journal == afterFirstForget, "secure-intent cleanup must be idempotent")
    }

    // MARK: - Causal recreation

    @Test func recreateAfterConfirmedTombstoneGetsAClockAboveTheDelete() throws {
        let snippetID = id(30)
        let ancestor = envelope(snippetID, revision: 100, content: "ancestor")
        var confirmed = base([ancestor])
        var journal = SyncJournal()

        journal.reconcile(
            current: [:], confirmed: confirmed,
            deviceID: Self.device, now: time(1))
        let deletion = try #require(journal.entry(snippetID)?.desired)
        #expect(deletion.deleted)
        #expect(deletion.hlc > ancestor.hlc)

        let pendingDeletion = journal.pending(confirmed: confirmed)
        journal.markOffered(pendingDeletion)
        confirmed.record(deletion)
        journal.acknowledge([snippetID], confirmed: confirmed)
        #expect(journal.entry(snippetID) == nil)

        // A restore can carry the old record's old HLC. Reconcile must restamp the
        // explicit recreation above the tombstone or every peer will keep it deleted.
        let restoredOldCopy = envelope(
            snippetID, revision: 100, name: "restored", content: "restored body")
        journal.reconcile(
            current: [snippetID: restoredOldCopy], confirmed: confirmed,
            deviceID: Self.device, now: time(1))

        let recreation = try #require(journal.entry(snippetID)?.desired)
        #expect(!recreation.deleted)
        #expect(content(recreation) == "restored body")
        #expect(recreation.hlc > deletion.hlc,
                "recreate is causally after delete even if wall time and input HLC are stale")
        #expect(recreation.origin == Self.device)
    }

    @Test func frozenRecreationRestampIsAFixedPointAcrossRepeatedReconcile() throws {
        let snippetID = id(31)
        let confirmedTombstone = SyncEnvelope.tombstone(
            id: snippetID,
            secure: false,
            hlc: HLC(wallMs: 500, counter: 0, device: "bbbbbbb2"),
            origin: "bbbbbbb2")
        let frozenRecreation = envelope(
            snippetID, revision: 100, name: "restored", content: "frozen local bytes")
        let confirmed = base([confirmedTombstone])
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: frozenRecreation],
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(0.1))
        let firstRestamp = try #require(journal.entry(snippetID))
        #expect(firstRestamp.desired.hlc > confirmedTombstone.hlc)
        #expect(content(firstRestamp.desired) == "frozen local bytes")

        for laterNow in [time(0.2), time(0.3)] {
            journal.reconcile(
                current: [snippetID: frozenRecreation],
                confirmed: confirmed,
                deviceID: Self.device,
                now: laterNow)
            let repeated = try #require(journal.entry(snippetID))
            #expect(repeated.desired == firstRestamp.desired,
                    "the frozen pre-tombstone input must not be restamped again")
            #expect(repeated.generation == firstRestamp.generation)
            #expect(repeated.modifiedAt == firstRestamp.modifiedAt)
        }
    }

    @Test func newerConfirmedEnvelopeReplacesOlderDesiredWithSamePayload() throws {
        let snippetID = id(32)
        let previousDesired = envelope(
            snippetID, revision: 100, name: "same", content: "same payload")
        let confirmedEnvelope = SyncEnvelope(
            schemaVersion: previousDesired.schemaVersion,
            id: snippetID,
            hlc: HLC(wallMs: 500, counter: 0, device: "bbbbbbb2"),
            origin: "bbbbbbb2",
            secure: previousDesired.secure,
            deleted: false,
            fields: previousDesired.fields,
            x: previousDesired.x)
        var journal = SyncJournal()

        journal.reconcile(
            current: [snippetID: previousDesired],
            confirmed: SyncBase(),
            deviceID: Self.device,
            now: time(0.1))
        #expect(journal.entry(snippetID)?.desired == previousDesired)

        let confirmed = base([confirmedEnvelope])
        journal.reconcile(
            current: [snippetID: confirmedEnvelope],
            confirmed: confirmed,
            deviceID: Self.device,
            now: time(0.2))

        #expect(journal.entry(snippetID) == nil,
                "exact current/confirmed B satisfies intent; older desired A must not pin it")
        #expect(journal.pending(confirmed: confirmed).isEmpty)
        #expect(journal.projectionKnowledge(over: confirmed).envelope(snippetID)
                == confirmedEnvelope)
    }

    // MARK: - Durable file boundary

    @Test func fileLoadDistinguishesMissingCorruptAndFutureJournal() throws {
        let scratch = try ScratchDirectory("load-outcomes")
        defer { scratch.remove() }
        let missing = scratch.file("missing.json")

        guard case .missing(let empty) = SyncJournalFile.load(from: missing) else {
            Issue.record("a missing journal must be a genuine empty journal")
            return
        }
        #expect(empty.entry(id(40)) == nil)
        #expect(empty.pending(confirmed: SyncBase()).isEmpty)

        let corrupt = scratch.file("corrupt.json")
        try Data("{not-json".utf8).write(to: corrupt)
        guard case .unreadable(let detail) = SyncJournalFile.load(from: corrupt) else {
            Issue.record("an existing corrupt journal must fail closed")
            return
        }
        #expect(!detail.isEmpty)

        let future = scratch.file("future.json")
        let futureVersion = SyncJournal.currentSchemaVersion + 1
        try Data("{\"schemaVersion\":\(futureVersion),\"entries\":{}}".utf8).write(to: future)
        guard case .tooNew(let version) = SyncJournalFile.load(from: future) else {
            Issue.record("a future journal must not be decoded as empty or overwritten")
            return
        }
        #expect(version == futureVersion)
    }

    @Test func syntacticallyValidTruncationsAreUnreadableRatherThanEmpty() throws {
        let scratch = try ScratchDirectory("valid-truncations")
        defer { scratch.remove() }
        let truncatedDocuments = [
            "{}",
            "{\"schemaVersion\":1}",
            "{\"schemaVersion\":1,\"entries\":null}",
        ]

        for (index, document) in truncatedDocuments.enumerated() {
            let url = scratch.file("truncated-\(index).json")
            try Data(document.utf8).write(to: url)
            guard case .unreadable = SyncJournalFile.load(from: url) else {
                Issue.record(
                    "syntactically valid truncation must fail closed: \(document)")
                continue
            }
        }
    }

    @Test func encodingIsDeterministicAndRoundTripsWithoutChangingIntent() throws {
        let scratch = try ScratchDirectory("deterministic")
        defer { scratch.remove() }
        let firstID = id(50)
        let secondID = id(51)
        let first = envelope(firstID, revision: 100, content: "first")
        let second = envelope(secondID, revision: 200, content: "second")
        let confirmed = SyncBase()

        var currentForward: [UUID: SyncEnvelope] = [:]
        currentForward[firstID] = first
        currentForward[secondID] = second
        var currentReverse: [UUID: SyncEnvelope] = [:]
        currentReverse[secondID] = second
        currentReverse[firstID] = first

        var forward = SyncJournal()
        forward.reconcile(
            current: currentForward, confirmed: confirmed,
            deviceID: Self.device, now: time(100))
        let pendingForward = forward.pending(confirmed: confirmed)
        forward.markOffered(pendingForward)
        var reverse = SyncJournal()
        reverse.reconcile(
            current: currentReverse, confirmed: confirmed,
            deviceID: Self.device, now: time(100))
        let pendingReverse = Array(reverse.pending(confirmed: confirmed).reversed())
        reverse.markOffered(pendingReverse)

        #expect(forward == reverse,
                "dictionary and batch iteration order must not enter durable semantics")
        #expect(forward.pending(confirmed: confirmed).map(\.id) == [firstID, secondID])

        let forwardURL = scratch.file("forward.json")
        let reverseURL = scratch.file("reverse.json")
        try SyncJournalFile.write(
            forward, to: forwardURL, temporaryDirectory: scratch.file("TmpA"))
        try SyncJournalFile.write(
            reverse, to: reverseURL, temporaryDirectory: scratch.file("TmpB"))
        let forwardData = try Data(contentsOf: forwardURL)
        let reverseData = try Data(contentsOf: reverseURL)
        #expect(forwardData == reverseData,
                "the same journal must have one byte representation")

        guard case .loaded(let decoded) = SyncJournalFile.load(from: forwardURL) else {
            Issue.record("expected a written journal to load")
            return
        }
        #expect(decoded == forward)
        #expect(decoded.pending(confirmed: confirmed) == [first, second])
    }
}
