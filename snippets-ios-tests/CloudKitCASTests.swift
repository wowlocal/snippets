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
