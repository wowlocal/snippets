import Foundation
import Testing
@testable import SnippetsCore

/// Account identity is part of the confirmed sync checkpoint, not a transport hint.
///
/// A CloudKit change token and archived CKRecord system fields are meaningful only for
/// the private database that issued them.  Reusing either after an Apple-ID switch can
/// make the first push authorize against unrelated ancestry, while accepting an empty
/// delta can make the old local library look agreed with the new account.  These tests
/// keep the account lookup separate from `fetchChanges`/`submit` so they can prove that
/// the engine decides — and durably records — the account boundary before either data
/// plane operation is allowed to run.
@MainActor
@Suite("Sync account binding")
struct SyncAccountBindingTests {

    private let accountA = SyncAccountIdentity(Data(repeating: 0xa1, count: 32))
    private let accountB = SyncAccountIdentity(Data(repeating: 0xb2, count: 32))

    @Test func freshInstallBindsDurablyBeforeItsFirstFetch() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        h.transport.beforeFetch = { cursor in
            #expect(cursor == nil)
            guard case .loaded(let checkpoint) = SyncBaseFile.load(from: h.baseURL) else {
                Issue.record("the account binding must be readable before fetch starts")
                return
            }
            #expect(checkpoint.accountIdentity == accountA)
            #expect(checkpoint.journalEstablished)
        }

        let result = await h.engine.sync()

        guard case .idle = result else {
            Issue.record("fresh account should complete its first round, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.fetchAttempts == 1)
        #expect(h.transport.submitAttempts == 0)
        #expect(try h.loadedBase().accountIdentity == accountA)
    }

    @Test func sameAccountRestartKeepsCursorEnvelopesVersionsAndAmbiguousJournal() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "confirmed", milliseconds: 1_000)
        let offered = envelope(id, name: "offered", milliseconds: 2_000)
        let desired = envelope(id, name: "desired", milliseconds: 3_000)
        let version = SyncRecordVersion(Data("server-v7".utf8))
        var base = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("cursor-7"),
            journalEstablished: true,
            accountIdentity: accountA)
        // Exercise a restart from bytes, rather than handing the engine an in-memory
        // value that could accidentally preserve fields omitted by Codable.
        try h.writeBase(base)
        let journal = SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: desired,
                offered: SyncJournal.Offered(
                    envelope: offered, generation: 1, recordVersion: version),
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 10)),
        ])
        try h.writeJournal(journal)
        h.library.envelopes[id] = desired
        h.transport.submitFailure = .unreachable(detail: "stop after observing restart")

        // Reconstruct after the files exist, exactly as a process restart does.
        h.rebuildEngine()
        let result = await h.engine.sync()

        guard case .offline = result else {
            Issue.record("injected submit failure should remain retryable, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.submitAttempts == 1)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.transport.submittedCursor == SyncCursor("cursor-7"))
        #expect(h.transport.submittedRecords.first?.recordVersion == version)
        base = try h.loadedBase()
        #expect(base.accountIdentity == accountA)
        #expect(base.cursor == SyncCursor("cursor-7"))
        #expect(base.envelope(id) == confirmed)
        #expect(base.recordVersion(id) == version)
        #expect(try h.loadedJournal() == journal)
    }

    @Test func pristineLegacyCheckpointCanBeBoundWithoutInventingRemoteAncestry() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        // This is the only unbound legacy shape that is unambiguous: no cursor, no
        // confirmed values/system fields, and no pending intent.
        try h.writeBase(SyncBase(schemaVersion: 1, journalEstablished: true))
        try h.writeJournal(SyncJournal())
        h.rebuildEngine()

        let result = await h.engine.sync()

        guard case .idle = result else {
            Issue.record("a pristine legacy checkpoint should migrate, got \(result)")
            return
        }
        #expect(try h.loadedBase().accountIdentity == accountA)
        #expect(h.transport.fetchAttempts == 1)
        #expect(h.transport.fetchedCursor == nil)
    }

    @Test func meaningfulLegacyCheckpointRequiresReviewBeforeAnyDataPlaneCall() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "legacy confirmed", milliseconds: 1_000)
        let offered = envelope(id, name: "legacy offered", milliseconds: 2_000)
        let version = SyncRecordVersion(Data("legacy-tag".utf8))
        let base = SyncBase(
            schemaVersion: 1,
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("legacy-cursor"),
            journalEstablished: true)
        let journal = SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: offered,
                offered: SyncJournal.Offered(
                    envelope: offered, generation: 1, recordVersion: version),
                generation: 1,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 11)),
        ])
        try h.writeBase(base)
        try h.writeJournal(journal)
        h.library.envelopes[id] = offered
        h.rebuildEngine()

        let result = await h.engine.sync()

        guard case .halted(.accountChanged, _) = result else {
            Issue.record("unattributable legacy ancestry must require review, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.library.readAttempts == 0)
        #expect(try h.loadedBase() == base)
        #expect(try h.loadedJournal() == journal)
    }

    @Test func accountSwitchHaltsBeforeReadingOrUploadingThePreviousLibrary() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "account A", milliseconds: 1_000)
        let edited = envelope(id, name: "account A edited locally", milliseconds: 2_000)
        let version = SyncRecordVersion(Data("account-a-system-fields".utf8))
        let base = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("account-a-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        let journal = SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: edited, offered: nil, generation: 1,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 12)),
        ])
        try h.writeBase(base)
        try h.writeJournal(journal)
        h.library.envelopes[id] = edited
        h.rebuildEngine()

        let result = await h.engine.sync()

        guard case .halted(.accountChanged, let detail) = result else {
            Issue.record("Apple-ID switch must be a sticky safety stop, got \(result)")
            return
        }
        #expect(!detail.lowercased().contains(String(repeating: "a1", count: 32)))
        #expect(!detail.lowercased().contains(String(repeating: "b2", count: 32)),
                "a persisted/loggable halt must not disclose stable account identities")
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.submitAttempts == 0,
                "old local records must not be uploaded into the new private database")
        #expect(h.transport.fetchAttempts == 0,
                "new-account records must not be mixed into the old local library")
        #expect(h.library.readAttempts == 0)
        #expect(try h.loadedBase() == base,
                "old cursor and system fields may be retained for review, never reused")
        #expect(try h.loadedJournal() == journal)

        // The stop survives restart. A regular poll cannot silently bless account B on
        // the next process launch.
        let attemptsBeforeRestart = h.transport.accountResolutionAttempts
        h.rebuildEngine()
        let restarted = await h.engine.sync()
        guard case .halted(.accountChanged, _) = restarted else {
            Issue.record("account-switch halt must survive restart, got \(restarted)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == attemptsBeforeRestart)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.transport.submitAttempts == 0)
    }

    @Test func accountlessTransportCannotReuseAnAccountBoundCheckpoint() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "account scoped", milliseconds: 1_000)
        let version = SyncRecordVersion(Data("cloudkit-system-fields".utf8))
        let base = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("cloudkit-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        try h.writeBase(base)
        try h.writeJournal(SyncJournal())
        h.library.envelopes[id] = confirmed
        h.transport.accountMode = .accountless
        h.transport.fetchAccountIdentity = nil
        h.transport.submitAccountIdentity = nil
        h.rebuildEngine()

        let result = await h.engine.sync()

        guard case .halted(.accountChanged, _) = result else {
            Issue.record("an unscoped backend must not inherit CloudKit credentials, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.library.readAttempts == 0)
        #expect(try h.loadedBase() == base)
    }

    @Test func explicitReviewRebindsOnlyAfterRemovingOldCursorSystemFieldsAndOffer() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "old confirmed", milliseconds: 1_000)
        let offered = envelope(id, name: "old ambiguous offer", milliseconds: 2_000)
        let desired = envelope(id, name: "latest desired", milliseconds: 3_000)
        let oldVersion = SyncRecordVersion(Data("old-account-change-tag".utf8))
        try h.writeBase(SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): oldVersion],
            cursor: SyncCursor("old-account-cursor"),
            journalEstablished: true,
            accountIdentity: accountA))
        try h.writeJournal(SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: desired,
                offered: SyncJournal.Offered(
                    envelope: offered, generation: 1, recordVersion: oldVersion),
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 13)),
        ]))
        h.library.envelopes[id] = desired
        h.rebuildEngine()

        guard case .halted(.accountChanged, _) = await h.engine.sync() else {
            Issue.record("fixture must first detect the account switch")
            return
        }

        h.engine.clearHaltAfterUserReview()
        guard case .idle = h.engine.state else {
            Issue.record("explicit review should authorize one reset attempt")
            return
        }
        h.transport.beforeSubmit = { records, cursor in
            #expect(cursor == nil)
            #expect(records.count == 1)
            #expect(records.first?.recordVersion == nil,
                    "an old account's CKRecord system fields must never cross the reset")
            guard case .loaded(let checkpoint) = SyncBaseFile.load(from: h.baseURL) else {
                Issue.record("reset checkpoint must be durable before submit")
                return
            }
            #expect(checkpoint.accountIdentity == accountB)
            #expect(checkpoint.cursor == nil)
            #expect(checkpoint.envelopes.isEmpty)
            #expect(checkpoint.recordVersions.isEmpty)
        }
        h.transport.submitFailure = .unreachable(detail: "inspect reviewed reset")

        let result = await h.engine.sync()

        guard case .offline = result else {
            Issue.record("injected post-reset submit failure should be retryable, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 2)
        #expect(h.transport.submitAttempts == 1)
        #expect(h.transport.fetchAttempts == 0)
        let sent = try #require(h.transport.submittedRecords.first)
        #expect(try WireCodec.open(sent, using: h.sealer) == desired,
                "review keeps the latest desired value, not the older frozen offer")
        #expect(sent.recordVersion == nil)

        let resetBase = try h.loadedBase()
        #expect(resetBase.accountIdentity == accountB)
        #expect(resetBase.cursor == nil)
        #expect(resetBase.envelopes.isEmpty)
        #expect(resetBase.recordVersions.isEmpty)
        let resetEntry = try #require(try h.loadedJournal().entry(id))
        #expect(resetEntry.desired == desired)
        #expect(resetEntry.offered?.envelope == desired)
        #expect(resetEntry.offered?.recordVersion == nil)
    }

    @Test func crashDuringReviewedAccountResetHaltsAgainWithoutContactingDataPlane() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "old confirmed", milliseconds: 1_000)
        let desired = envelope(id, name: "local latest", milliseconds: 2_000)
        let oldVersion = SyncRecordVersion(Data("old-system-fields".utf8))
        let originalBase = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): oldVersion],
            cursor: SyncCursor("old-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        let originalJournal = SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: desired,
                offered: SyncJournal.Offered(
                    envelope: confirmed, generation: 1, recordVersion: oldVersion),
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 14)),
        ])
        try h.writeBase(originalBase)
        try h.writeJournal(originalJournal)
        h.library.envelopes[id] = desired
        h.rebuildEngine()

        guard case .halted(.accountChanged, _) = await h.engine.sync() else {
            Issue.record("fixture must first detect the account switch")
            return
        }
        h.engine.clearHaltAfterUserReview()
        guard case .idle = h.engine.state else {
            Issue.record("review should clear the durable stop before reset")
            return
        }

        // Model a storage failure/power-loss boundary after Review was made durable but
        // before the journal-first account reset can be saved.  The next process may ask
        // for Review again; it must never guess that the reset succeeded.
        try? FileManager.default.removeItem(at: h.normalTemporaryDirectory)
        try Data("not a directory".utf8).write(to: h.normalTemporaryDirectory)

        let result = await h.engine.sync()

        guard case .halted = result else {
            Issue.record("failed account reset must return to a sticky stop, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 2)
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(try h.loadedBase() == originalBase)
        #expect(try h.loadedJournal() == originalJournal)

        // A crash/restart cannot retain the in-memory Review authorization.  Since the
        // halt write may itself have shared the failed staging directory, either the old
        // accountChanged halt remains durable or mismatch detection recreates it before
        // a data-plane call. Restore I/O and prove the latter end-to-end.
        try FileManager.default.removeItem(at: h.normalTemporaryDirectory)
        h.rebuildEngine()
        let restarted = await h.engine.sync()
        guard case .halted(.accountChanged, _) = restarted else {
            Issue.record("restart after failed reset must require Review again, got \(restarted)")
            return
        }
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
    }

    @Test func reviewedResetCapturesUnjournaledLiveAndDeletedLocalState() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let liveID = UUID()
        let deletedID = UUID()
        let live = envelope(liveID, name: "still live", milliseconds: 1_000)
        let deletedAncestor = envelope(deletedID, name: "deleted locally", milliseconds: 1_000)
        let base = SyncBase(
            envelopes: [
                SyncBase.key(liveID): live,
                SyncBase.key(deletedID): deletedAncestor,
            ],
            recordVersions: [
                SyncBase.key(liveID): SyncRecordVersion(Data("live-old-tag".utf8)),
                SyncBase.key(deletedID): SyncRecordVersion(Data("delete-old-tag".utf8)),
            ],
            cursor: SyncCursor("old-account-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        try h.writeBase(base)
        try h.writeJournal(SyncJournal())
        h.library.envelopes[liveID] = live
        // deletedID is deliberately absent and has no journal entry. Only the old base
        // can prove this absence is an intentional local deletion.
        h.rebuildEngine()

        guard case .halted(.accountChanged, _) = await h.engine.sync() else {
            Issue.record("fixture must detect account B before reading local state")
            return
        }
        h.engine.clearHaltAfterUserReview()
        h.transport.submitFailure = .unreachable(detail: "inspect captured reset intent")

        let result = await h.engine.sync()

        guard case .offline = result else {
            Issue.record("post-reset observation submit should be retryable, got \(result)")
            return
        }
        #expect(h.transport.submittedRecords.count == 2)
        #expect(h.transport.submittedRecords.allSatisfy { $0.recordVersion == nil })
        let submitted = try Dictionary(uniqueKeysWithValues: h.transport.submittedRecords.map {
            let opened = try WireCodec.open($0, using: h.sealer)
            return (opened.id, opened)
        })
        #expect(submitted[liveID] == live)
        #expect(submitted[deletedID]?.deleted == true)
        #expect(submitted[deletedID]?.fields == nil)
        let journal = try h.loadedJournal()
        #expect(journal.entry(liveID)?.desired == live)
        #expect(journal.entry(deletedID)?.desired.deleted == true)
        #expect(try h.loadedBase().accountIdentity == accountB)
        #expect(try h.loadedBase().cursor == nil)
        #expect(try h.loadedBase().recordVersions.isEmpty == true)
    }

    @Test func crashAfterJournalResetButBeforeBaseRebindRequiresReviewAgain() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let id = UUID()
        let old = envelope(id, name: "old confirmed", milliseconds: 1_000)
        let desired = envelope(id, name: "latest desired", milliseconds: 2_000)
        let oldVersion = SyncRecordVersion(Data("old-tag".utf8))
        let oldBase = SyncBase(
            envelopes: [SyncBase.key(id): old],
            recordVersions: [SyncBase.key(id): oldVersion],
            cursor: SyncCursor("old-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        // This is the durable intermediate state after the journal-first reset write:
        // latest desired is safe, while old account offers/CAS have already gone.
        let resetJournal = SyncJournal(entries: [
            SyncBase.key(id): SyncJournal.Entry(
                desired: desired,
                offered: nil,
                generation: 2,
                modifiedAt: Date(timeIntervalSinceReferenceDate: 30)),
        ])
        try h.writeBase(oldBase)
        try h.writeJournal(resetJournal)
        h.library.envelopes[id] = desired
        h.rebuildEngine()

        let first = await h.engine.sync()

        guard case .halted(.accountChanged, _) = first else {
            Issue.record("journal-first crash must require a new Review, got \(first)")
            return
        }
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(try h.loadedBase() == oldBase)
        #expect(try h.loadedJournal() == resetJournal)

        h.engine.clearHaltAfterUserReview()
        h.transport.submitFailure = .unreachable(detail: "observe idempotent retry")
        let retried = await h.engine.sync()

        guard case .offline = retried else {
            Issue.record("reviewed journal-first recovery should retry safely, got \(retried)")
            return
        }
        let sent = try #require(h.transport.submittedRecords.first)
        #expect(try WireCodec.open(sent, using: h.sealer) == desired)
        #expect(sent.recordVersion == nil)
        #expect(try h.loadedBase().accountIdentity == accountB)
    }

    @Test func accountResolutionFailureConsumesOneShotReviewAuthority() async throws {
        let h = try Harness(account: accountB)
        defer { h.remove() }

        let accountC = SyncAccountIdentity(Data(repeating: 0xc3, count: 32))
        let id = UUID()
        let confirmed = envelope(id, name: "account A", milliseconds: 1_000)
        let version = SyncRecordVersion(Data("account-a-tag".utf8))
        let base = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("account-a-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        try h.writeBase(base)
        try h.writeJournal(SyncJournal())
        h.library.envelopes[id] = confirmed
        h.rebuildEngine()
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        h.engine.now = { clock }

        guard case .halted(.accountChanged, _) = await h.engine.sync() else {
            Issue.record("fixture must first detect account B")
            return
        }
        h.engine.clearHaltAfterUserReview()
        h.transport.accountMode = .failure(.unreachable(
            detail: "account status temporarily unavailable"))

        let unavailable = await h.engine.sync()

        guard case .offline(let retryAfter) = unavailable else {
            Issue.record("account lookup failure should remain retryable, got \(unavailable)")
            return
        }
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(try h.loadedBase() == base)

        // The signed-in identity can change while status is unavailable. Review of B
        // must never become reusable authorization to reset into arbitrary account C.
        h.transport.accountMode = .identity(accountC)
        h.transport.fetchAccountIdentity = accountC
        h.transport.submitAccountIdentity = accountC
        clock = retryAfter.addingTimeInterval(1)

        let later = await h.engine.sync()

        guard case .halted(.accountChanged, _) = later else {
            Issue.record("failed preflight must consume Review authority, got \(later)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 3)
        #expect(h.transport.submitAttempts == 0)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.library.readAttempts == 0)
        #expect(try h.loadedBase() == base)
    }

    @Test func reviewingAnUnrelatedHaltDoesNotResetAccountCheckpoint() throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        let id = UUID()
        let confirmed = envelope(id, name: "keep", milliseconds: 1_000)
        let version = SyncRecordVersion(Data("keep-system-fields".utf8))
        let base = SyncBase(
            envelopes: [SyncBase.key(id): confirmed],
            recordVersions: [SyncBase.key(id): version],
            cursor: SyncCursor("keep-cursor"),
            journalEstablished: true,
            accountIdentity: accountA)
        try h.writeBase(base)
        try h.writeJournal(SyncJournal())
        h.rebuildEngine()
        h.engine.halt(.massDeletion, detail: "review deletion")

        h.engine.clearHaltAfterUserReview()

        guard case .idle = h.engine.state else {
            Issue.record("ordinary halt should retain its existing Resume behavior")
            return
        }
        #expect(try h.loadedBase() == base)
        #expect(try h.loadedJournal() == SyncJournal())
        #expect(h.transport.accountResolutionAttempts == 0)
    }

    @Test func signedOutAccountCanRecoverWithoutDeletingOrRebindingCheckpoint() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        h.transport.accountMode = .failure(.rejected(.authenticationRequired(
            detail: "sign in to iCloud")))

        let unavailable = await h.engine.sync()

        guard case .needsAuthentication = unavailable else {
            Issue.record("signed-out account should be recoverable auth state, got \(unavailable)")
            return
        }
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.transport.submitAttempts == 0)
        guard case .missing = SyncBaseFile.load(from: h.baseURL) else {
            Issue.record("a fresh signed-out launch must not invent an unbound checkpoint")
            return
        }

        h.transport.accountMode = .identity(accountA)
        let recovered = await h.engine.sync()

        guard case .idle = recovered else {
            Issue.record("sign-in should recover without Review/reset, got \(recovered)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 2)
        #expect(h.transport.fetchAttempts == 1)
        #expect(try h.loadedBase().accountIdentity == accountA)
    }

    @Test func temporarilyUnavailableAccountRetriesWithoutDestroyingBinding() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        try h.writeBase(SyncBase(journalEstablished: true, accountIdentity: accountA))
        try h.writeJournal(SyncJournal())
        h.rebuildEngine()
        var clock = Date(timeIntervalSinceReferenceDate: 100)
        h.engine.now = { clock }
        h.transport.accountMode = .failure(.unreachable(
            detail: "iCloud account status is temporarily unavailable"))

        let unavailable = await h.engine.sync()

        guard case .offline(let retryAfter) = unavailable else {
            Issue.record("temporary account outage should back off, got \(unavailable)")
            return
        }
        #expect(retryAfter > clock)
        #expect(try h.loadedBase().accountIdentity == accountA)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.transport.submitAttempts == 0)

        h.transport.accountMode = .identity(accountA)
        clock = retryAfter.addingTimeInterval(1)
        let recovered = await h.engine.sync()

        guard case .idle = recovered else {
            Issue.record("temporary account outage should recover automatically, got \(recovered)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 2)
        #expect(h.transport.fetchAttempts == 1)
        #expect(try h.loadedBase().accountIdentity == accountA)
    }

    @Test func submitReplyFromAnotherOrUnknownAccountCannotAcknowledgeAnOffer() async throws {
        let replies: [SyncAccountIdentity?] = [accountB, nil]

        for reply in replies {
            let h = try Harness(account: accountA)
            defer { h.remove() }

            let id = UUID()
            let confirmed = envelope(id, name: "confirmed A", milliseconds: 1_000)
            let offered = envelope(id, name: "offered A", milliseconds: 2_000)
            let oldVersion = SyncRecordVersion(Data("account-a-v1".utf8))
            let base = SyncBase(
                envelopes: [SyncBase.key(id): confirmed],
                recordVersions: [SyncBase.key(id): oldVersion],
                cursor: SyncCursor("account-a-cursor"),
                journalEstablished: true,
                accountIdentity: accountA)
            let journal = SyncJournal(entries: [
                SyncBase.key(id): SyncJournal.Entry(
                    desired: offered,
                    offered: SyncJournal.Offered(
                        envelope: offered, generation: 1, recordVersion: oldVersion),
                    generation: 1,
                    modifiedAt: Date(timeIntervalSinceReferenceDate: 20)),
            ])
            try h.writeBase(base)
            try h.writeJournal(journal)
            h.library.envelopes[id] = offered
            h.transport.submitAccountIdentity = reply
            h.rebuildEngine()

            let result = await h.engine.sync()

            guard case .halted(.accountChanged, _) = result else {
                Issue.record("unscoped/mismatched submit reply must halt, got \(result)")
                continue
            }
            #expect(h.transport.accountResolutionAttempts == 1)
            #expect(h.transport.submitAttempts == 1)
            #expect(h.transport.fetchAttempts == 0)
            #expect(try h.loadedBase() == base,
                    "accepted bytes from the wrong operation scope are not confirmation")
            #expect(try h.loadedJournal() == journal,
                    "the exact ambiguous account-A offer must remain retryable/reviewable")
        }
    }

    @Test func fetchReplyFromAnotherOrUnknownAccountCannotAdvanceOrApply() async throws {
        let replies: [SyncAccountIdentity?] = [accountB, nil]

        for reply in replies {
            let h = try Harness(account: accountA)
            defer { h.remove() }

            let localID = UUID()
            let remoteID = UUID()
            let local = envelope(localID, name: "local A", milliseconds: 1_000)
            let remote = envelope(remoteID, name: "must not mix", milliseconds: 2_000)
            let localVersion = SyncRecordVersion(Data("account-a-v1".utf8))
            let base = SyncBase(
                envelopes: [SyncBase.key(localID): local],
                recordVersions: [SyncBase.key(localID): localVersion],
                cursor: SyncCursor("account-a-cursor"),
                journalEstablished: true,
                accountIdentity: accountA)
            try h.writeBase(base)
            try h.writeJournal(SyncJournal())
            h.library.envelopes[localID] = local
            var wire = try WireCodec.seal(remote, using: h.sealer)
            wire.recordVersion = SyncRecordVersion(Data("foreign-v1".utf8))
            h.transport.fetchRecords = [wire]
            h.transport.fetchCursorReply = SyncCursor("foreign-cursor")
            h.transport.fetchAccountIdentity = reply
            h.rebuildEngine()

            let result = await h.engine.sync()

            guard case .halted(.accountChanged, _) = result else {
                Issue.record("unscoped/mismatched fetch reply must halt, got \(result)")
                continue
            }
            #expect(h.transport.accountResolutionAttempts == 1)
            #expect(h.transport.fetchAttempts == 1)
            #expect(h.transport.submitAttempts == 0)
            #expect(h.library.applyAttempts == 0)
            #expect(h.library.envelopes[remoteID] == nil)
            #expect(try h.loadedBase() == base,
                    "foreign cursor/envelope/system fields must not become confirmed")
            #expect(try h.loadedJournal() == SyncJournal())
        }
    }

    @Test func failedBindingWriteStopsBeforeFetchAndLeavesLegacyCheckpointUnbound() async throws {
        let h = try Harness(account: accountA)
        defer { h.remove() }

        let legacy = SyncBase(schemaVersion: 1, journalEstablished: true)
        try h.writeBase(legacy)
        try h.writeJournal(SyncJournal())
        let notADirectory = h.root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: notADirectory)
        h.rebuildEngine(temporaryDirectory: notADirectory)

        let result = await h.engine.sync()

        guard case .halted(.localLibraryQuarantined, _) = result else {
            Issue.record("binding fsync failure must fail closed, got \(result)")
            return
        }
        #expect(h.transport.accountResolutionAttempts == 1)
        #expect(h.transport.fetchAttempts == 0)
        #expect(h.transport.submitAttempts == 0)
        #expect(h.library.readAttempts == 0)
        #expect(try h.loadedBase() == legacy)
        #expect(try h.loadedBase().accountIdentity == nil,
                "an in-memory identity must not be published when its write failed")
    }

    @Test func damagedExplicitAccountBindingMakesTheWholeCheckpointUnreadable() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let baseURL = root.appendingPathComponent("base.json")
        let tmpURL = root.appendingPathComponent("Tmp", isDirectory: true)
        try SyncBaseFile.write(
            SyncBase(journalEstablished: true, accountIdentity: accountA),
            to: baseURL,
            temporaryDirectory: tmpURL)

        var object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: baseURL)) as? [String: Any])
        object["accountIdentity"] = NSNull()
        try JSONSerialization.data(withJSONObject: object).write(to: baseURL)

        guard case .unreadable = SyncBaseFile.load(from: baseURL) else {
            Issue.record("explicit null is damaged binding, not a legacy missing field")
            return
        }
    }

    // MARK: - Fixtures

    private func envelope(
        _ id: UUID,
        name: String,
        milliseconds: UInt64
    ) -> SyncEnvelope {
        SyncEnvelope(
            id: id,
            hlc: HLC(wallMs: milliseconds, counter: 0, device: "account1"),
            origin: "account1",
            secure: false,
            deleted: false,
            fields: SyncEnvelope.Fields(
                name: name,
                keyword: name,
                content: Data(name.utf8),
                tags: [],
                isEnabled: true,
                isPinned: false,
                createdAt: Date(timeIntervalSince1970: 1),
                updatedAt: Date(timeIntervalSince1970: 2)))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "sync-account-binding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @MainActor
    private final class Harness {
        let root: URL
        let baseURL: URL
        let journalURL: URL
        let stateURL: URL
        let lockURL: URL
        let normalTemporaryDirectory: URL
        let transport: AccountRecordingTransport
        let library = AccountLibrary()
        let sealer = SnippetCryptoSealer(
            keyring: SnippetCrypto.Keyring.generate(), scopeID: "account-binding-tests")
        var engine: SyncEngine!

        init(account: SyncAccountIdentity) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "sync-account-binding-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            baseURL = root.appendingPathComponent("base.json")
            journalURL = root.appendingPathComponent("journal.json")
            stateURL = root.appendingPathComponent("state.json")
            lockURL = root.appendingPathComponent("library.lock")
            normalTemporaryDirectory = root.appendingPathComponent("Tmp", isDirectory: true)
            transport = AccountRecordingTransport(account: account)
            rebuildEngine()
        }

        func rebuildEngine(temporaryDirectory: URL? = nil) {
            engine = SyncEngine(
                transport: transport,
                library: library,
                sealer: sealer,
                device: "account1",
                baseURL: baseURL,
                journalURL: journalURL,
                stateURL: stateURL,
                lockURL: lockURL,
                temporaryDirectory: temporaryDirectory ?? normalTemporaryDirectory)
        }

        func writeBase(_ base: SyncBase) throws {
            try SyncBaseFile.write(
                base, to: baseURL, temporaryDirectory: normalTemporaryDirectory)
        }

        func writeJournal(_ journal: SyncJournal) throws {
            try SyncJournalFile.write(
                journal, to: journalURL, temporaryDirectory: normalTemporaryDirectory)
        }

        func loadedBase() throws -> SyncBase {
            guard case .loaded(let base) = SyncBaseFile.load(from: baseURL) else {
                throw FixtureFailure.expectedReadableBase
            }
            return base
        }

        func loadedJournal() throws -> SyncJournal {
            guard case .loaded(let journal) = SyncJournalFile.load(from: journalURL) else {
                throw FixtureFailure.expectedReadableJournal
            }
            return journal
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private enum FixtureFailure: Error {
    case expectedReadableBase
    case expectedReadableJournal
}

@MainActor
private final class AccountLibrary: SyncLibraryAccess {
    var envelopes: [UUID: SyncEnvelope] = [:]
    private(set) var readAttempts = 0
    private(set) var applyAttempts = 0

    func currentEnvelopes(agreedBase: SyncBase) throws -> [UUID: SyncEnvelope] {
        readAttempts += 1
        return envelopes
    }

    func classifyRemote(_ envelopes: [SyncEnvelope]) -> RemoteClassification {
        RemoteClassification(
            applicable: envelopes, deferredIDs: [], incompatibleVaultIDs: [])
    }

    func applyRemote(_ envelopes: [SyncEnvelope]) throws -> ApplyOutcome {
        applyAttempts += 1
        for envelope in envelopes {
            self.envelopes[envelope.id] = envelope.deleted ? nil : envelope
        }
        return ApplyOutcome(changedIDs: envelopes.map(\.id))
    }

    func liveIDs() -> Set<UUID> { Set(envelopes.keys) }
}

nonisolated private final class AccountRecordingTransport: SyncTransport, @unchecked Sendable {
    enum AccountMode {
        case identity(SyncAccountIdentity)
        case accountless
        case failure(SyncTransportFailure)
    }

    let identifier = "icloud-test"
    let supportsPush = true
    let pollInterval: TimeInterval = 60
    let events = AsyncStream<SyncTransportEvent> { continuation in
        continuation.finish()
    }

    private let lock = NSLock()
    private var accountModeStorage: AccountMode
    private var accountResolutionAttemptsStorage = 0
    private var fetchAttemptsStorage = 0
    private var submitAttemptsStorage = 0
    private var fetchedCursorStorage: SyncCursor?
    private var submittedCursorStorage: SyncCursor?
    private var submittedRecordsStorage: [WireRecord] = []
    private var submitFailureStorage: SyncTransportFailure?
    private var fetchAccountIdentityStorage: SyncAccountIdentity?
    private var submitAccountIdentityStorage: SyncAccountIdentity?
    private var fetchRecordsStorage: [WireRecord] = []
    private var fetchCursorReplyStorage: SyncCursor?

    var beforeFetch: (@Sendable (SyncCursor?) -> Void)?
    var beforeSubmit: (@Sendable ([WireRecord], SyncCursor?) -> Void)?

    init(account: SyncAccountIdentity) {
        accountModeStorage = .identity(account)
        fetchAccountIdentityStorage = account
        submitAccountIdentityStorage = account
    }

    var accountMode: AccountMode {
        get { lock.withLock { accountModeStorage } }
        set { lock.withLock { accountModeStorage = newValue } }
    }

    var submitFailure: SyncTransportFailure? {
        get { lock.withLock { submitFailureStorage } }
        set { lock.withLock { submitFailureStorage = newValue } }
    }

    var fetchAccountIdentity: SyncAccountIdentity? {
        get { lock.withLock { fetchAccountIdentityStorage } }
        set { lock.withLock { fetchAccountIdentityStorage = newValue } }
    }

    var submitAccountIdentity: SyncAccountIdentity? {
        get { lock.withLock { submitAccountIdentityStorage } }
        set { lock.withLock { submitAccountIdentityStorage = newValue } }
    }

    var fetchRecords: [WireRecord] {
        get { lock.withLock { fetchRecordsStorage } }
        set { lock.withLock { fetchRecordsStorage = newValue } }
    }

    var fetchCursorReply: SyncCursor? {
        get { lock.withLock { fetchCursorReplyStorage } }
        set { lock.withLock { fetchCursorReplyStorage = newValue } }
    }

    var accountResolutionAttempts: Int {
        lock.withLock { accountResolutionAttemptsStorage }
    }

    var fetchAttempts: Int { lock.withLock { fetchAttemptsStorage } }
    var submitAttempts: Int { lock.withLock { submitAttemptsStorage } }
    var fetchedCursor: SyncCursor? { lock.withLock { fetchedCursorStorage } }
    var submittedCursor: SyncCursor? { lock.withLock { submittedCursorStorage } }
    var submittedRecords: [WireRecord] { lock.withLock { submittedRecordsStorage } }

    func resolveAccountIdentity() async throws -> SyncAccountIdentity? {
        let mode = lock.withLock { () -> AccountMode in
            accountResolutionAttemptsStorage += 1
            return accountModeStorage
        }
        switch mode {
        case .identity(let identity): return identity
        case .accountless: return nil
        case .failure(let failure): throw failure
        }
    }

    func fetchChanges(since cursor: SyncCursor?) async throws -> SyncFetch {
        let reply = lock.withLock { () -> (
            records: [WireRecord], cursor: SyncCursor?, account: SyncAccountIdentity?
        ) in
            fetchAttemptsStorage += 1
            fetchedCursorStorage = cursor
            return (
                fetchRecordsStorage,
                fetchCursorReplyStorage ?? cursor,
                fetchAccountIdentityStorage)
        }
        beforeFetch?(cursor)
        return SyncFetch(
            records: reply.records,
            cursor: reply.cursor,
            accountIdentity: reply.account)
    }

    func submit(
        _ records: [WireRecord],
        at cursor: SyncCursor?
    ) async throws -> SyncSubmission {
        let reply = lock.withLock { () -> (
            failure: SyncTransportFailure?, account: SyncAccountIdentity?
        ) in
            submitAttemptsStorage += 1
            submittedCursorStorage = cursor
            submittedRecordsStorage = records
            return (submitFailureStorage, submitAccountIdentityStorage)
        }
        beforeSubmit?(records, cursor)
        if let failure = reply.failure { throw failure }
        return SyncSubmission(
            results: records.map {
                SyncSubmitResult(
                    id: $0.id,
                    outcome: .accepted(
                        rev: $0.rev,
                        recordVersion: SyncRecordVersion(Data("accepted".utf8))))
            },
            cursor: cursor,
            accountIdentity: reply.account)
    }
}
