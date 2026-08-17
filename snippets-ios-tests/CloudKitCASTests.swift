import CloudKit
import ObjectiveC.runtime
import XCTest

@testable import Snippets

@MainActor
final class CloudKitCASTests: XCTestCase {

    private let snippetID = UUID(uuidString: "34343434-3434-4434-8434-343434343434")!

    private func zone(_ name: String = CloudKitSchema.zoneName) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: name, ownerName: CKCurrentUserDefaultName)
    }

    /// CloudKit does not expose a public initializer for a server-returned record. Keep
    /// the SDK-runtime detail needed by these unit tests isolated here, and skip the
    /// positive-path assertions if a future runtime stops representing the tag this way.
    private func assignServerChangeTag(
        _ tag: String = "unit-test-server-change-tag",
        to record: CKRecord
    ) throws {
        guard let ivar = class_getInstanceVariable(CKRecord.self, "_etag") else {
            throw XCTSkip("this CloudKit runtime does not expose an isolated test tag hook")
        }
        object_setIvar(record, ivar, tag as NSString)
        guard record.recordChangeTag == tag else {
            throw XCTSkip("this CloudKit runtime did not retain the isolated test tag")
        }
    }

    private func rawSystemFieldsVersion(of record: CKRecord) -> SyncRecordVersion {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return SyncRecordVersion(archiver.encodedData)
    }

    private func wire(
        id: UUID? = nil,
        version: SyncRecordVersion? = nil,
        rev: String = "opaque-revision"
    ) -> WireRecord {
        WireRecord(
            id: id ?? snippetID,
            rev: rev,
            deleted: false,
            blob: Data("sealed-payload".utf8),
            recordVersion: version)
    }

    func testSystemFieldsArchiveRoundTripsIdentityTypeAndZone() throws {
        let zoneID = zone()
        let recordID = CloudKitRecordMapping.recordID(for: snippetID, in: zoneID)
        let record = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: recordID)
        try assignServerChangeTag(to: record)
        record[CloudKitSchema.Field.rev] = "opaque-revision" as CKRecordValue
        record[CloudKitSchema.Field.deleted] = false as CKRecordValue
        record[CloudKitSchema.Field.blob] = Data("ciphertext".utf8) as CKRecordValue

        let version = try CloudKitRecordVersion.archive(record)
        let restored = try CloudKitRecordVersion.restore(
            version,
            expectedRecordID: recordID)

        XCTAssertFalse(version.data.isEmpty)
        XCTAssertEqual(restored.recordID, recordID)
        XCTAssertEqual(restored.recordType, CloudKitSchema.recordType)
        XCTAssertEqual(restored.recordID.zoneID, zoneID)
        XCTAssertEqual(restored.recordChangeTag, record.recordChangeTag)

        let restoredForUpdate = try CloudKitRecordMapping.makeRecord(
            from: wire(version: version),
            in: zoneID)
        XCTAssertEqual(restoredForUpdate.recordID, recordID)
        XCTAssertEqual(restoredForUpdate.recordType, CloudKitSchema.recordType)
        XCTAssertEqual(restoredForUpdate.recordChangeTag, record.recordChangeTag)

        let mapped = try CloudKitRecordMapping.makeWireRecord(from: record)
        let mappedVersion = try XCTUnwrap(mapped.recordVersion)
        let mappedRestored = try CloudKitRecordVersion.restore(
            mappedVersion,
            expectedRecordID: recordID)
        XCTAssertEqual(mappedRestored.recordID, recordID)
        XCTAssertEqual(mappedRestored.recordType, CloudKitSchema.recordType)
    }

    func testSystemFieldsRestoreRejectsWrongIdentityTypeZoneAndInvalidArchive() throws {
        let expectedZone = zone()
        let expectedID = CloudKitRecordMapping.recordID(for: snippetID, in: expectedZone)
        let otherID = CKRecord.ID(
            recordName: UUID().uuidString.lowercased(),
            zoneID: expectedZone)
        let wrongIdentity = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: otherID)
        try assignServerChangeTag("wrong-identity-tag", to: wrongIdentity)
        let wrongIdentityVersion = try CloudKitRecordVersion.archive(wrongIdentity)
        XCTAssertThrowsError(try CloudKitRecordVersion.restore(
            wrongIdentityVersion,
            expectedRecordID: expectedID))

        let wrongType = CKRecord(recordType: "OtherRecordType", recordID: expectedID)
        try assignServerChangeTag("wrong-type-tag", to: wrongType)
        let wrongTypeVersion = try CloudKitRecordVersion.archive(wrongType)
        XCTAssertThrowsError(try CloudKitRecordVersion.restore(
            wrongTypeVersion,
            expectedRecordID: expectedID))
        XCTAssertNoThrow(try CloudKitRecordVersion.restore(
            wrongTypeVersion,
            expectedRecordID: expectedID,
            expectedRecordType: "OtherRecordType"))

        let otherZoneID = CloudKitRecordMapping.recordID(
            for: snippetID,
            in: zone("OtherZone"))
        let wrongZone = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: otherZoneID)
        try assignServerChangeTag("wrong-zone-tag", to: wrongZone)
        let wrongZoneVersion = try CloudKitRecordVersion.archive(wrongZone)
        XCTAssertThrowsError(try CloudKitRecordVersion.restore(
            wrongZoneVersion,
            expectedRecordID: expectedID))

        XCTAssertThrowsError(try CloudKitRecordVersion.restore(
            SyncRecordVersion(Data("not-a-keyed-archive".utf8)),
            expectedRecordID: expectedID))
    }

    func testAbsentOrInvalidCachedVersionSafelyBuildsAFreshConditionalCreate() throws {
        let zoneID = zone()
        let expectedID = CloudKitRecordMapping.recordID(for: snippetID, in: zoneID)

        let fresh = try CloudKitRecordMapping.makeRecord(
            from: wire(version: nil),
            in: zoneID)
        XCTAssertEqual(fresh.recordID, expectedID)
        XCTAssertEqual(fresh.recordType, CloudKitSchema.recordType)
        XCTAssertNil(fresh.recordChangeTag)
        XCTAssertEqual(fresh[CloudKitSchema.Field.rev] as? String, "opaque-revision")
        XCTAssertEqual(fresh[CloudKitSchema.Field.deleted] as? Bool, false)
        XCTAssertEqual(
            fresh[CloudKitSchema.Field.blob] as? Data,
            Data("sealed-payload".utf8))
        XCTAssertThrowsError(try CloudKitRecordVersion.archive(fresh)) { error in
            guard let failure = error as? CloudKitRecordVersion.Failure,
                  case .missingChangeTag = failure else {
                return XCTFail("fresh archive failed for the wrong reason: \(error)")
            }
        }
        XCTAssertThrowsError(try CloudKitRecordMapping.makeWireRecord(from: fresh))
        XCTAssertThrowsError(try CloudKitRecordVersion.restore(
            rawSystemFieldsVersion(of: fresh),
            expectedRecordID: expectedID)) { error in
            guard let failure = error as? CloudKitRecordVersion.Failure,
                  case .missingChangeTag = failure else {
                return XCTFail("fresh restore failed for the wrong reason: \(error)")
            }
        }

        let invalid = try CloudKitRecordMapping.makeRecord(
            from: wire(version: SyncRecordVersion(Data("bad archive".utf8))),
            in: zoneID)
        XCTAssertEqual(invalid.recordID, expectedID)
        XCTAssertNil(invalid.recordChangeTag)

        let otherRecord = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: CKRecord.ID(
                recordName: UUID().uuidString.lowercased(),
                zoneID: zoneID))
        try assignServerChangeTag("other-record-tag", to: otherRecord)
        let mismatched = try CloudKitRecordMapping.makeRecord(
            from: wire(version: try CloudKitRecordVersion.archive(otherRecord)),
            in: zoneID)
        XCTAssertEqual(mismatched.recordID, expectedID)
        XCTAssertNil(mismatched.recordChangeTag)
    }

    func testRecordMappingAlwaysReturnsValidatedSystemFieldsVersion() throws {
        let zoneID = zone()
        let sourceWire = wire()
        let record = try CloudKitRecordMapping.makeRecord(from: sourceWire, in: zoneID)
        try assignServerChangeTag(to: record)

        let mapped = try CloudKitRecordMapping.makeWireRecord(from: record)

        XCTAssertEqual(mapped.id, sourceWire.id)
        XCTAssertEqual(mapped.rev, sourceWire.rev)
        XCTAssertEqual(mapped.deleted, sourceWire.deleted)
        XCTAssertEqual(mapped.blob, sourceWire.blob)
        let version = try XCTUnwrap(mapped.recordVersion)
        let restored = try CloudKitRecordVersion.restore(
            version,
            expectedRecordID: record.recordID)
        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored.recordType, CloudKitSchema.recordType)
    }

    func testInboundServerRecordOverBlobLimitIsRejectedBeforeWireInbox() throws {
        let zoneID = zone()
        let record = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: CloudKitRecordMapping.recordID(for: snippetID, in: zoneID))
        try assignServerChangeTag("oversized-inbound-record", to: record)
        record[CloudKitSchema.Field.rev] = "oversized-revision" as CKRecordValue
        record[CloudKitSchema.Field.deleted] = false as CKRecordValue
        record[CloudKitSchema.Field.blob] = Data(
            repeating: 0xA5,
            count: CloudKitSchema.maxBlobBytes + 1) as CKRecordValue

        XCTAssertThrowsError(
            try CloudKitRecordMapping.makeWireRecord(
                from: record,
                expectedZoneID: zoneID)
        ) { error in
            guard case CloudKitRecordMapping.Failure.blobTooLarge(
                let bytes, let recordName
            ) = error else {
                return XCTFail("oversized inbound blob failed for the wrong reason: \(error)")
            }
            XCTAssertEqual(bytes, CloudKitSchema.maxBlobBytes + 1)
            XCTAssertEqual(recordName, self.snippetID.uuidString.lowercased())
        }
    }

    func testServerRecordChangedCarriesAuthoritativeRemoteWireRecord() throws {
        let zoneID = zone()
        let remoteRecord = try CloudKitRecordMapping.makeRecord(from: wire(), in: zoneID)
        try assignServerChangeTag("authoritative-remote-tag", to: remoteRecord)
        let error = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: remoteRecord])

        let failure: Result<CKRecord, any Error> = .failure(error)
        let rejection = CloudKitTransport.submissionOutcome(
            for: wire(),
            result: failure,
            expectedZoneID: zoneID)

        guard case .rejected(.conflict(remote: let authoritative?)) = rejection else {
            return XCTFail("valid serverRecordChanged must carry the authoritative record")
        }
        XCTAssertEqual(authoritative.id, snippetID)
        XCTAssertEqual(authoritative.rev, "opaque-revision")
        XCTAssertEqual(authoritative.blob, Data("sealed-payload".utf8))
        let version = try XCTUnwrap(authoritative.recordVersion)
        XCTAssertNoThrow(try CloudKitRecordVersion.restore(
            version,
            expectedRecordID: remoteRecord.recordID))

        let untaggedRemote = try CloudKitRecordMapping.makeRecord(from: wire(), in: zoneID)
        let untaggedError = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: untaggedRemote])
        let untaggedFailure: Result<CKRecord, any Error> = .failure(untaggedError)
        guard case .rejected(.conflict(remote: nil)) =
                CloudKitTransport.submissionOutcome(
                    for: wire(),
                    result: untaggedFailure,
                    expectedZoneID: zoneID) else {
            return XCTFail("an untagged server record must not become authoritative")
        }

        let malformedRemote = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: remoteRecord.recordID)
        let malformedError = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: malformedRemote])
        let malformedFailure: Result<CKRecord, any Error> = .failure(malformedError)
        guard case .rejected(.conflict(remote: nil)) =
                CloudKitTransport.submissionOutcome(
                    for: wire(),
                    result: malformedFailure,
                    expectedZoneID: zoneID) else {
            return XCTFail("an unusable server record must fail safely without invented data")
        }
    }

    func testFreshCreateFailureUsesIssuedWireToPreserveAuthoritativeConflict() throws {
        let zoneID = zone()
        let offered = wire(version: nil, rev: "fresh-create")
        let failedFreshRecord = try CloudKitRecordMapping.makeRecord(
            from: offered,
            in: zoneID)
        XCTAssertNil(failedFreshRecord.recordChangeTag,
                     "the failed attempted create has no server generation to map")

        let authoritativeWire = wire(version: nil, rev: "remote-winner")
        let authoritativeRecord = try CloudKitRecordMapping.makeRecord(
            from: authoritativeWire,
            in: zoneID)
        try assignServerChangeTag("authoritative-create-conflict", to: authoritativeRecord)
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: authoritativeRecord])

        let result = CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failedFreshRecord,
            error: conflict,
            issued: [offered.id: offered],
            zoneID: zoneID)

        guard case .rejected(let id, .conflict(remote: let remote?))? = result else {
            return XCTFail(
                "an issued fresh-create conflict must not degrade to omission/rate-limit")
        }
        XCTAssertEqual(id, offered.id)
        XCTAssertEqual(remote.id, offered.id)
        XCTAssertEqual(remote.rev, authoritativeWire.rev)
        XCTAssertEqual(remote.blob, authoritativeWire.blob)
        XCTAssertNotNil(remote.recordVersion)
    }

    func testPartialFailureUnwrapsIssuedRecordConflict() throws {
        let zoneID = zone()
        let offered = wire(version: nil, rev: "fresh-create")
        let failedRecord = try CloudKitRecordMapping.makeRecord(from: offered, in: zoneID)
        let authoritativeWire = wire(version: nil, rev: "remote-winner")
        let authoritativeRecord = try CloudKitRecordMapping.makeRecord(
            from: authoritativeWire,
            in: zoneID)
        try assignServerChangeTag("nested-authoritative-conflict", to: authoritativeRecord)
        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: authoritativeRecord])
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [failedRecord.recordID: conflict]])

        let result = CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failedRecord,
            error: partial,
            issued: [offered.id: offered],
            zoneID: zoneID)

        guard case .rejected(let id, .conflict(remote: let remote?))? = result else {
            return XCTFail("the partial-failure envelope must preserve its record conflict")
        }
        XCTAssertEqual(id, offered.id)
        XCTAssertEqual(remote.rev, authoritativeWire.rev)
        XCTAssertNotNil(remote.recordVersion)
    }

    func testPartialFailureWithoutMatchingItemRemainsRetryable() throws {
        let zoneID = zone()
        let offered = wire(version: nil, rev: "issued")
        let failedRecord = try CloudKitRecordMapping.makeRecord(from: offered, in: zoneID)
        let unrelatedID = CloudKitRecordMapping.recordID(for: UUID(), in: zoneID)
        let partial = CKError(
            .partialFailure,
            userInfo: [CKPartialErrorsByItemIDKey: [unrelatedID: CKError(.unknownItem)]])

        let result = CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failedRecord,
            error: partial,
            issued: [offered.id: offered],
            zoneID: zoneID)

        guard case .rejected(_, let rejection)? = result else {
            return XCTFail("an incomplete item result must be retried, not omitted")
        }
        XCTAssertTrue(rejection.isRetryable)
    }

    func testOnlyIncompleteSendEnvelopesUseDelegateItemOutcomes() {
        XCTAssertTrue(CloudKitErrorMapping.isIncompleteOperationResult(
            CKError(.partialFailure)))
        XCTAssertFalse(CloudKitErrorMapping.isIncompleteOperationResult(
            CKError(.serverRecordChanged)))

        guard case .unreachable = CloudKitErrorMapping.failure(
            for: CKError(.partialFailure)) else {
            return XCTFail("an incomplete fetch result must remain retryable")
        }
    }

    func testNestedZoneLossStillRequiresExplicitRecoveryPolicy() throws {
        let zoneID = zone()
        let offered = wire(version: nil, rev: "zone-loss")
        let failedRecord = try CloudKitRecordMapping.makeRecord(from: offered, in: zoneID)

        for code in [CKError.Code.zoneNotFound, .userDeletedZone] {
            let partial = CKError(
                .partialFailure,
                userInfo: [
                    CKPartialErrorsByItemIDKey: [failedRecord.recordID: CKError(code)],
                ])
            XCTAssertTrue(CloudKitSyncEngineDriver.failedSaveInvalidatesZone(
                failedRecord: failedRecord,
                error: partial,
                zoneID: zoneID))
        }

        let unrelatedID = CloudKitRecordMapping.recordID(for: UUID(), in: zoneID)
        let unrelated = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [unrelatedID: CKError(.zoneNotFound)],
            ])
        XCTAssertFalse(CloudKitSyncEngineDriver.failedSaveInvalidatesZone(
            failedRecord: failedRecord,
            error: unrelated,
            zoneID: zoneID))
    }

    func testOuterSendPartialFailureStillDetectsNestedZoneLoss() {
        let zoneID = zone()
        let recordID = CloudKitRecordMapping.recordID(for: snippetID, in: zoneID)

        for code in [CKError.Code.zoneNotFound, .userDeletedZone] {
            let partial = CKError(
                .partialFailure,
                userInfo: [
                    CKPartialErrorsByItemIDKey: [recordID: CKError(code)],
                ])
            XCTAssertTrue(CloudKitErrorMapping.containsZoneInvalidation(
                partial,
                for: zoneID))
        }

        let foreignZoneID = zone("ForeignZone")
        let foreignRecordID = CloudKitRecordMapping.recordID(
            for: UUID(),
            in: foreignZoneID)
        let unrelated = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [foreignRecordID: CKError(.zoneNotFound)],
            ])
        XCTAssertFalse(CloudKitErrorMapping.containsZoneInvalidation(
            unrelated,
            for: zoneID))

        let zoneEnvelope = CKError(
            .partialFailure,
            userInfo: [
                CKPartialErrorsByItemIDKey: [zoneID: CKError(.userDeletedZone)],
            ])
        XCTAssertTrue(CloudKitErrorMapping.containsZoneInvalidation(
            zoneEnvelope,
            for: zoneID),
            "fetch and zone-save envelopes must use the same reset policy")
    }

    func testFetchPartialFailurePreservesScopedAuthenticationAndPermanentPolicy() {
        let zoneID = zone()
        let cases: [(CKError.Code, (SyncTransportFailure) -> Bool)] = [
            (.notAuthenticated, { failure in
                guard case .rejected(.authenticationRequired) = failure else { return false }
                return true
            }),
            (.badContainer, { failure in
                guard case .rejected(.permanent) = failure else { return false }
                return true
            }),
        ]

        for (code, matchesExpectedPolicy) in cases {
            let envelope = CKError(
                .partialFailure,
                userInfo: [
                    CKPartialErrorsByItemIDKey: [zoneID: CKError(code)],
                ])
            guard let scoped = CloudKitErrorMapping.zoneError(
                in: envelope,
                for: zoneID) else {
                XCTFail("expected a scoped error for \(code)")
                continue
            }
            XCTAssertTrue(matchesExpectedPolicy(CloudKitErrorMapping.failure(for: scoped)))
        }
    }

    func testFetchPartialFailurePolicyDoesNotDependOnDictionaryOrder() {
        let zoneID = zone()
        let firstID = CloudKitRecordMapping.recordID(for: UUID(), in: zoneID)
        let secondID = CloudKitRecordMapping.recordID(for: UUID(), in: zoneID)

        for decisiveCode in [CKError.Code.notAuthenticated, .badContainer] {
            for decisiveFirst in [true, false] {
                var partials: [CKRecord.ID: any Error] = [:]
                let ordered: [(CKRecord.ID, CKError)] = decisiveFirst
                    ? [(firstID, CKError(decisiveCode)),
                       (secondID, CKError(.networkFailure))]
                    : [(firstID, CKError(.networkFailure)),
                       (secondID, CKError(decisiveCode))]
                for (recordID, error) in ordered { partials[recordID] = error }
                let envelope = CKError(
                    .partialFailure,
                    userInfo: [CKPartialErrorsByItemIDKey: partials])

                guard let scoped = CloudKitErrorMapping.zoneError(
                    in: envelope,
                    for: zoneID) else {
                    XCTFail("expected a scoped error for \(decisiveCode)")
                    continue
                }
                switch (decisiveCode, CloudKitErrorMapping.failure(for: scoped)) {
                case (.notAuthenticated, .rejected(.authenticationRequired)),
                     (.badContainer, .rejected(.permanent)):
                    break
                default:
                    XCTFail("transient failure masked \(decisiveCode)")
                }
            }
        }
    }

    func testFailedSendCallbackOutsideIssuedLeaseOrZoneIsIgnored() throws {
        let zoneID = zone()
        let offered = wire(version: nil, rev: "issued")
        let failed = try CloudKitRecordMapping.makeRecord(from: offered, in: zoneID)
        let error = CKError(.serverRecordChanged)

        XCTAssertNil(CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failed,
            error: error,
            issued: [:],
            zoneID: zoneID),
            "a callback for an unissued UUID has no authority over the active lease")

        let other = wire(id: UUID(), version: nil, rev: "other-issued")
        XCTAssertNil(CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failed,
            error: error,
            issued: [other.id: other],
            zoneID: zoneID))

        XCTAssertNil(CloudKitSyncEngineDriver.failedSentResult(
            failedRecord: failed,
            error: error,
            issued: [offered.id: offered],
            zoneID: zone("ForeignZone")),
            "a callback from another zone must be ignored even for the same UUID")
    }

    func testZoneLossErrorsArePermanentWhileRecordAndTokenMissesRemainRetryable() {
        let zoneLossCodes: [CKError.Code] = [.zoneNotFound, .userDeletedZone]
        for code in zoneLossCodes {
            let rejection = CloudKitErrorMapping.rejection(for: CKError(code))
            XCTAssertFalse(rejection.isRetryable, "\(code) must require zone review")
            guard case .permanent = rejection else {
                XCTFail("\(code) must map to a permanent rejection")
                continue
            }
        }

        let recoverableCodes: [CKError.Code] = [
            .changeTokenExpired, .unknownItem, .partialFailure,
        ]
        for code in recoverableCodes {
            let rejection = CloudKitErrorMapping.rejection(for: CKError(code))
            XCTAssertTrue(rejection.isRetryable, "\(code) remains recoverable in the mapper")
            guard case .rateLimited = rejection else {
                XCTFail("\(code) must retain a retryable mapper result")
                continue
            }
        }
    }

    func testSubmissionOutcomeNeverAcceptsWithoutValidReturnedSavedRecord() throws {
        let zoneID = zone()
        let offered = wire()

        let missing = CloudKitTransport.submissionOutcome(
            for: offered,
            result: nil,
            expectedZoneID: zoneID)
        assertNotAccepted(missing)
        if case .rejected(let rejection) = missing {
            XCTAssertTrue(rejection.isRetryable)
        }

        let malformed = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: CloudKitRecordMapping.recordID(for: snippetID, in: zoneID))
        let malformedResult: Result<CKRecord, any Error> = .success(malformed)
        assertNotAccepted(CloudKitTransport.submissionOutcome(
            for: offered,
            result: malformedResult,
            expectedZoneID: zoneID))

        let wrongIDRecord = try CloudKitRecordMapping.makeRecord(
            from: wire(id: UUID()),
            in: zoneID)
        try assignServerChangeTag("wrong-id-tag", to: wrongIDRecord)
        let wrongIDResult: Result<CKRecord, any Error> = .success(wrongIDRecord)
        assertNotAccepted(CloudKitTransport.submissionOutcome(
            for: offered,
            result: wrongIDResult,
            expectedZoneID: zoneID))

        let returned = try CloudKitRecordMapping.makeRecord(from: offered, in: zoneID)
        let freshSuccess: Result<CKRecord, any Error> = .success(returned)
        let freshOutcome = CloudKitTransport.submissionOutcome(
            for: offered,
            result: freshSuccess,
            expectedZoneID: zoneID)
        assertNotAccepted(freshOutcome)
        guard case .rejected(let freshRejection) = freshOutcome else {
            return XCTFail("an unsaved returned record must be retryable, not accepted")
        }
        XCTAssertTrue(freshRejection.isRetryable)

        try assignServerChangeTag("saved-result-tag", to: returned)
        let success: Result<CKRecord, any Error> = .success(returned)
        let accepted = CloudKitTransport.submissionOutcome(
            for: offered,
            result: success,
            expectedZoneID: zoneID)
        guard case .accepted(let rev, let returnedVersion) = accepted else {
            return XCTFail("a valid explicit saved-record result should be accepted")
        }
        XCTAssertEqual(rev, offered.rev)
        XCTAssertNoThrow(try CloudKitRecordVersion.restore(
            returnedVersion,
            expectedRecordID: returned.recordID))

        let conflict = CKError(
            .serverRecordChanged,
            userInfo: [CKRecordChangedErrorServerRecordKey: returned])
        let failure: Result<CKRecord, any Error> = .failure(conflict)
        guard case .rejected(.conflict(remote: let remote?)) =
                CloudKitTransport.submissionOutcome(
                    for: offered,
                    result: failure,
                    expectedZoneID: zoneID) else {
            return XCTFail("a returned conflict must not be mislabeled accepted")
        }
        XCTAssertEqual(remote.id, offered.id)
        XCTAssertNotNil(remote.recordVersion)
    }

    private func assertNotAccepted(
        _ outcome: SyncSubmitOutcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .accepted = outcome {
            XCTFail("outcome must not be accepted", file: file, line: line)
        }
    }
}
