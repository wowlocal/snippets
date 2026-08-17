import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import SnippetsAndroidCore

@Test func bridgeCrudUsesFrozenLibraryShape() throws {
    let created = upsertSnippet("[]", "00000000-0000-0000-0000-000000000001",
                                "Greeting", " hello world ", "Hello", "[\"work\"]",
                                true, false)
    let response = try #require(created.data(using: .utf8))
    let object = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    let value = try #require(object["value"] as? String)
    let snippets = try SnippetLibraryCodec.decode(Data(value.utf8))
    #expect(snippets.count == 1)
    #expect(snippets[0].keyword == "hello-world")
}

@Test func wireRecordAdmissionUsesCoreSemanticsRatherThanSurfaceJSON() throws {
    let response = validateWireRecords(#"[{"id":"not-a-uuid"}]"#)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])

    #expect(object["ok"] as? Bool == false)
    #expect(object["error"] as? String == "invalid_json")
}

@Test func reconcileRoundTripsEncryptedWireRecords() throws {
    let library = upsertSnippet("[]", "00000000-0000-0000-0000-000000000002",
                                "Greeting", "hi", "Hello", "[]", true, false)
    let value = try bridgeValue(library)
    let key = Data(repeating: 7, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 9, count: 32).base64EncodedString()

    let first = reconcileLibrary(value, "[]", "[]", key, salt, "sync-v1", "01234567")
    let firstPayload = try bridgeValue(first)
    let firstObject = try #require(
        JSONSerialization.jsonObject(with: Data(firstPayload.utf8)) as? [String: Any])
    let records = try #require(firstObject["records"] as? String)

    let second = reconcileLibrary(value, value, records, key, salt, "sync-v1", "89abcdef")
    let secondPayload = try bridgeValue(second)
    let secondObject = try #require(
        JSONSerialization.jsonObject(with: Data(secondPayload.utf8)) as? [String: Any])
    #expect(secondObject["offers"] as? String == "[]")
    let secondRecords = try #require(secondObject["records"] as? String)
    #expect(try JSONDecoder().decode([WireRecord].self, from: Data(secondRecords.utf8))
            == JSONDecoder().decode([WireRecord].self, from: Data(records.utf8)),
            "switching providers must preserve the exact encrypted WireRecord fields")
}

@Test func reconcilePreservesOpaqueSecureRecordsWithoutOfferingADeletion() throws {
    let keyData = Data(repeating: 3, count: SnippetCrypto.keyByteCount)
    let saltData = Data(repeating: 5, count: 32)
    let key = keyData.base64EncodedString()
    let salt = saltData.base64EncodedString()
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: keyData), salt: saltData),
        scopeID: "sync-v1")
    let envelope = SyncEnvelope.secureRecord(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Opaque", keyword: "secret", plaintext: Data("private".utf8),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
        hlc: HLC(wallMs: 1_700_000_001_000, counter: 0, device: "01234567"),
        origin: "01234567")
    var record = try WireCodec.seal(envelope, using: sealer)
    record.recordVersion = SyncRecordVersion(Data("server-cas-7".utf8))
    let records = String(decoding: try JSONEncoder().encode([record]), as: UTF8.self)

    let response = reconcileLibrary("[]", "[]", records, key, salt, "sync-v1", "89abcdef")
    let payload = try bridgeValue(response)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)
    #expect(object["offers"] as? String == "[]")
    let preservedRecords = try #require(object["records"] as? String)
    #expect(try JSONDecoder().decode([WireRecord].self, from: Data(preservedRecords.utf8))
            == [record])
}

@Test func remoteSecurePromotionReplacesAnUnchangedPlainShadowWithoutDowngradingIt() throws {
    let id = "00000000-0000-0000-0000-000000000004"
    let plain = try bridgeValue(upsertSnippet(
        "[]", id, "Promoted", "promoted", "formerly ordinary", "[]", true, false))
    let keyData = Data(repeating: 13, count: SnippetCrypto.keyByteCount)
    let saltData = Data(repeating: 14, count: 32)
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: keyData), salt: saltData),
        scopeID: "sync-v1")
    let secure = SyncEnvelope.secureRecord(
        id: try #require(UUID(uuidString: id)),
        name: "Promoted", keyword: "promoted", plaintext: Data("private".utf8),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        hlc: HLC(wallMs: 1_700_000_100_000, counter: 0, device: "01234567"),
        origin: "01234567")
    var secureRecord = try WireCodec.seal(secure, using: sealer)
    secureRecord.recordVersion = SyncRecordVersion(Data("secure-cas".utf8))
    let records = String(
        decoding: try JSONEncoder().encode([secureRecord]), as: UTF8.self)

    let payload = try bridgeValue(reconcileLibrary(
        plain, plain, records,
        keyData.base64EncodedString(), saltData.base64EncodedString(),
        "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)
    #expect(object["offers"] as? String == "[]")
    let desired = try #require(object["records"] as? String)
    #expect(try JSONDecoder().decode([WireRecord].self, from: Data(desired.utf8))
            == [secureRecord],
            "Android must preserve the exact secure carrier and its CAS generation")
    #expect(object["deletionReview"] == nil,
            "promotion is not a deletion of the underlying remote record")
}

@Test func remoteSecurePromotionStopsBeforeOverwritingAnEditedPlainShadow() throws {
    let id = "00000000-0000-0000-0000-000000000005"
    let base = try bridgeValue(upsertSnippet(
        "[]", id, "Promoted", "promoted", "old ordinary value", "[]", true, false))
    let edited = try bridgeValue(upsertSnippet(
        base, id, "Promoted", "promoted", "unsynced Android edit", "[]", true, false))
    let keyData = Data(repeating: 15, count: SnippetCrypto.keyByteCount)
    let saltData = Data(repeating: 16, count: 32)
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: keyData), salt: saltData),
        scopeID: "sync-v1")
    let secure = SyncEnvelope.secureRecord(
        id: try #require(UUID(uuidString: id)),
        name: "Promoted", keyword: "promoted", plaintext: Data("private".utf8),
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        hlc: HLC(wallMs: 1_700_000_100_000, counter: 0, device: "01234567"),
        origin: "01234567")
    let records = String(
        decoding: try JSONEncoder().encode([WireCodec.seal(secure, using: sealer)]),
        as: UTF8.self)

    let response = reconcileLibrary(
        edited, base, records,
        keyData.base64EncodedString(), saltData.base64EncodedString(),
        "sync-v1", "89abcdef")
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == false)
    #expect(object["error"] as? String == "secure_record_conflict")
}

@Test func reconcileReportsAnExactMassDeletionWithoutApplyingAuthority() throws {
    var library = "[]"
    let ids = (1...6).map {
        String(format: "00000000-0000-4000-8000-%012d", $0)
    }
    for id in ids {
        library = try bridgeValue(upsertSnippet(
            library, id, "Snippet \(id.suffix(2))", "key", "body", "[]", true, false))
    }
    let key = Data(repeating: 4, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 8, count: 32).base64EncodedString()

    // A complete empty remote against an established six-record ancestor asks the
    // merge to remove all six. The host must receive exact review facts before it
    // commits the returned library bytes.
    let response = reconcileLibrary(library, library, "[]", key, salt, "sync-v1", "01234567")
    let payload = try bridgeValue(response)
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    let review = try #require(object["deletionReview"] as? [String: Any])
    #expect(review["liveCount"] as? Int == 6)
    #expect(review["requestedDeletions"] as? Int == 6)
    let expectedIDs = Set(ids.compactMap(UUID.init(uuidString:)))
    #expect(review["batchFingerprint"] as? String
            == SyncDeletionSafety.fingerprint(ids: expectedIDs))
    let facts = try #require(object["deletionFacts"] as? [String: Any])
    #expect(facts["liveCount"] as? Int == review["liveCount"] as? Int)
    #expect(facts["requestedDeletions"] as? Int == review["requestedDeletions"] as? Int)
    #expect(facts["batchFingerprint"] as? String == review["batchFingerprint"] as? String)
}

@Test func reconcileReportsBelowThresholdDeletionFactsWithoutOrdinaryReview() throws {
    var library = "[]"
    let ids = (1...6).map {
        String(format: "10000000-0000-4000-8000-%012d", $0)
    }
    for id in ids {
        library = try bridgeValue(upsertSnippet(
            library, id, "Snippet \(id.suffix(2))", "key", "body", "[]", true, false))
    }
    let key = Data(repeating: 6, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 7, count: 32).base64EncodedString()
    let initialPayload = try bridgeValue(reconcileLibrary(
        library, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let initialObject = try #require(
        JSONSerialization.jsonObject(with: Data(initialPayload.utf8)) as? [String: Any])
    let allRecords = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(initialObject["records"] as? String).utf8))
    let remoteWithoutOne = String(
        decoding: try JSONEncoder().encode(Array(allRecords.dropFirst())),
        as: UTF8.self)

    let payload = try bridgeValue(reconcileLibrary(
        library, library, remoteWithoutOne, key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])

    #expect(object["deletionReview"] == nil)
    let facts = try #require(object["deletionFacts"] as? [String: Any])
    #expect(facts["liveCount"] as? Int == 6)
    #expect(facts["requestedDeletions"] as? Int == 1)
}

@Test func recoveredSubsetWithEmptyAncestorRestoresMissingCloudRowsWithoutTombstones() throws {
    let firstID = "20000000-0000-4000-8000-000000000001"
    let secondID = "20000000-0000-4000-8000-000000000002"
    var complete = try bridgeValue(upsertSnippet(
        "[]", firstID, "First", "first", "one", "[]", true, false))
    complete = try bridgeValue(upsertSnippet(
        complete, secondID, "Second", "second", "two", "[]", true, false))
    let recoveredSubset = try bridgeValue(deleteSnippet(complete, secondID))
    let key = Data(repeating: 2, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 4, count: 32).base64EncodedString()

    let remoteSeed = try bridgeValue(reconcileLibrary(
        complete, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let remoteObject = try #require(
        JSONSerialization.jsonObject(with: Data(remoteSeed.utf8)) as? [String: Any])
    let remoteRecords = try #require(remoteObject["records"] as? String)

    // Primary-library recovery clears the old ancestor before this full snapshot.
    // Absence from the recovered export is therefore unknown, not deletion intent.
    let result = try bridgeValue(reconcileLibrary(
        recoveredSubset, "[]", remoteRecords, key, salt, "sync-v1", "89abcdef"))
    let resultObject = try #require(
        JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    let library = try #require(resultObject["library"] as? String)
    let snippets = try SnippetLibraryCodec.decode(Data(library.utf8))

    #expect(Set(snippets.map { $0.id.uuidString.lowercased() }) == Set([firstID, secondID]))
    #expect(resultObject["offers"] as? String == "[]")
    #expect(resultObject["deletionFacts"] == nil)
}

@Test func reviewedRecoveryBaselinePreservesPostRepairDeletesAndLocalOnlyRows() throws {
    let keptID = "30000000-0000-4000-8000-000000000001"
    let deletedID = "30000000-0000-4000-8000-000000000002"
    let localOnlyID = "30000000-0000-4000-8000-000000000003"
    var remoteLibrary = try bridgeValue(upsertSnippet(
        "[]", keptID, "Kept", "kept", "one", "[]", true, false))
    remoteLibrary = try bridgeValue(upsertSnippet(
        remoteLibrary, deletedID, "Delete after Repair", "delete", "two",
        "[]", true, false))
    let reviewedSnapshot = try bridgeValue(upsertSnippet(
        remoteLibrary, localOnlyID, "Never uploaded", "local", "three",
        "[]", true, false))
    let current = try bridgeValue(deleteSnippet(reviewedSnapshot, deletedID))
    let key = Data(repeating: 3, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 6, count: 32).base64EncodedString()
    let remoteSeed = try bridgeValue(reconcileLibrary(
        remoteLibrary, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let remoteObject = try #require(
        JSONSerialization.jsonObject(with: Data(remoteSeed.utf8)) as? [String: Any])
    let remoteRecords = try #require(remoteObject["records"] as? String)

    let result = try bridgeValue(reconcileLibraryAfterRecovery(
        current, "[]", remoteRecords, reviewedSnapshot,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    let snippets = try SnippetLibraryCodec.decode(Data(library.utf8))
    #expect(Set(snippets.map { $0.id.uuidString.lowercased() }) ==
        Set([keptID, localOnlyID]))

    let offers = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(object["offers"] as? String).utf8))
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 3, count: 32)),
            salt: Data(repeating: 6, count: 32)),
        scopeID: "sync-v1")
    let openedOffers = try offers.map { try WireCodec.open($0, using: sealer) }
    #expect(openedOffers.contains {
        $0.id.uuidString.lowercased() == deletedID && $0.deleted
    })
    #expect(openedOffers.contains {
        $0.id.uuidString.lowercased() == localOnlyID && !$0.deleted
    }, "an unchanged local-only recovery row must survive remote absence and upload")
}

@Test func checkpointRepairKeepsOldBaseSeparateFromReviewedPrimary() throws {
    let id = "31000000-0000-4000-8000-000000000001"
    let base = try bridgeValue(upsertSnippet(
        "[]", id, "Original", "repair-two-facts", "original body",
        "[]", true, false))
    let reviewedPrimary = try bridgeValue(upsertSnippet(
        base, id, "Local rename before Repair", "repair-two-facts",
        "original body", "[]", true, false))
    let remoteChanged = try bridgeValue(upsertSnippet(
        base, id, "Original", "repair-two-facts", "remote body edit",
        "[]", true, false))
    let key = Data(repeating: 7, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 8, count: 32).base64EncodedString()
    let remoteSeed = try bridgeValue(reconcileLibrary(
        remoteChanged, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let remoteObject = try #require(
        JSONSerialization.jsonObject(with: Data(remoteSeed.utf8)) as? [String: Any])
    let remoteRecords = try #require(remoteObject["records"] as? String)

    let result = try bridgeValue(reconcileLibraryAfterRecovery(
        reviewedPrimary, base, remoteRecords, reviewedPrimary,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    let merged = try #require(SnippetLibraryCodec.decode(Data(library.utf8)).first)
    #expect(merged.name == "Local rename before Repair")
    #expect(merged.content == "remote body edit")
}

@Test func checkpointRepairDeleteAfterReviewedLocalEditUsesOldConfirmedAncestor() throws {
    let id = "32000000-0000-4000-8000-000000000001"
    let base = try bridgeValue(upsertSnippet(
        "[]", id, "Original", "repair-delete", "server body",
        "[]", true, false))
    let reviewedPrimary = try bridgeValue(upsertSnippet(
        base, id, "Local edit before Repair", "repair-delete", "local body",
        "[]", true, false))
    let current = try bridgeValue(deleteSnippet(reviewedPrimary, id))
    let keyData = Data(repeating: 9, count: SnippetCrypto.keyByteCount)
    let saltData = Data(repeating: 10, count: 32)
    let key = keyData.base64EncodedString()
    let salt = saltData.base64EncodedString()
    let remoteSeed = try bridgeValue(reconcileLibrary(
        base, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let remoteObject = try #require(
        JSONSerialization.jsonObject(with: Data(remoteSeed.utf8)) as? [String: Any])
    let remoteRecords = try #require(remoteObject["records"] as? String)

    let result = try bridgeValue(reconcileLibraryAfterRecovery(
        current, base, remoteRecords, reviewedPrimary,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty,
            "an unchanged remote base must not resurrect a post-Repair deletion")

    let offers = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(object["offers"] as? String).utf8))
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: keyData), salt: saltData),
        scopeID: "sync-v1")
    let openedOffers = try offers.map { try WireCodec.open($0, using: sealer) }
    #expect(openedOffers.contains {
        $0.id.uuidString.lowercased() == id && $0.deleted
    })
}

@Test func lostCreateAcknowledgementThenLocalDeleteUsesDurableOfferAsAncestor() throws {
    let id = "33000000-0000-4000-8000-000000000001"
    let created = try bridgeValue(upsertSnippet(
        "[]", id, "Created", "lost-create", "body", "[]", true, false))
    let key = Data(repeating: 11, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 12, count: 32).base64EncodedString()
    let first = try bridgeValue(reconcileLibrary(
        created, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let firstObject = try #require(
        JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    let ambiguousOffer = try #require(firstObject["offers"] as? String)

    // The server accepted the create, but the client lost the response. Primary then
    // durably recorded the user's deletion before process restart.
    let recovered = try bridgeValue(reconcileLibraryWithPendingOffers(
        "[]", "[]", ambiguousOffer, "", false, false, ambiguousOffer,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(recovered.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)
    let offers = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(object["offers"] as? String).utf8))
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 11, count: 32)),
            salt: Data(repeating: 12, count: 32)),
        scopeID: "sync-v1")
    #expect(try offers.map { try WireCodec.open($0, using: sealer) }.contains {
        $0.id.uuidString.lowercased() == id && $0.deleted
    })
}

@Test func lostUpdateAcknowledgementThenLocalDeleteUsesDurableOfferAsAncestor() throws {
    let id = "34000000-0000-4000-8000-000000000001"
    let original = try bridgeValue(upsertSnippet(
        "[]", id, "Original", "lost-update", "old", "[]", true, false))
    let edited = try bridgeValue(upsertSnippet(
        original, id, "Edited", "lost-update", "new", "[]", true, false))
    let key = Data(repeating: 13, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 14, count: 32).base64EncodedString()
    let seed = try bridgeValue(reconcileLibrary(
        original, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let seedObject = try #require(
        JSONSerialization.jsonObject(with: Data(seed.utf8)) as? [String: Any])
    let remoteOriginal = try #require(seedObject["records"] as? String)
    let update = try bridgeValue(reconcileLibrary(
        edited, original, remoteOriginal,
        key, salt, "sync-v1", "01234567"))
    let updateObject = try #require(
        JSONSerialization.jsonObject(with: Data(update.utf8)) as? [String: Any])
    let ambiguousOffer = try #require(updateObject["offers"] as? String)

    let recovered = try bridgeValue(reconcileLibraryWithPendingOffers(
        "[]", original, ambiguousOffer, "", false, false, ambiguousOffer,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(recovered.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)
    let offers = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(object["offers"] as? String).utf8))
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 13, count: 32)),
            salt: Data(repeating: 14, count: 32)),
        scopeID: "sync-v1")
    #expect(try offers.map { try WireCodec.open($0, using: sealer) }.contains {
        $0.id.uuidString.lowercased() == id && $0.deleted
    })
}

@Test func recoveryKindControlsWhetherReviewedAbsenceCanConsumeAnOldOffer() throws {
    let id = "35000000-0000-4000-8000-000000000001"
    let created = try bridgeValue(upsertSnippet(
        "[]", id, "Ambiguous", "recovery-offer", "body", "[]", true, false))
    let key = Data(repeating: 15, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 16, count: 32).base64EncodedString()
    let first = try bridgeValue(reconcileLibrary(
        created, "[]", "[]", key, salt, "sync-v1", "01234567"))
    let firstObject = try #require(
        JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    let ambiguousOffer = try #require(firstObject["offers"] as? String)

    let primaryRecovery = try bridgeValue(reconcileLibraryWithPendingOffers(
        "[]", "[]", ambiguousOffer, "[]", false, false, ambiguousOffer,
        key, salt, "sync-v1", "89abcdef"))
    let primaryObject = try #require(
        JSONSerialization.jsonObject(with: Data(primaryRecovery.utf8)) as? [String: Any])
    let primaryLibrary = try #require(primaryObject["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(primaryLibrary.utf8)).count == 1,
            "absence from a possibly partial library backup must remain unknown")

    let checkpointRepair = try bridgeValue(reconcileLibraryWithPendingOffers(
        "[]", "[]", ambiguousOffer, "[]", true, false, ambiguousOffer,
        key, salt, "sync-v1", "89abcdef"))
    let checkpointObject = try #require(
        JSONSerialization.jsonObject(with: Data(checkpointRepair.utf8)) as? [String: Any])
    let checkpointLibrary = try #require(checkpointObject["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(checkpointLibrary.utf8)).isEmpty,
            "Repair reviewed the intact primary, so its absence is authoritative")
}

@Test func postReviewOfferProvenancePreservesADeletedPostReviewCreate() throws {
    let id = "36000000-0000-4000-8000-000000000001"
    let createdAfterReview = try bridgeValue(upsertSnippet(
        "[]", id, "After review", "post-review", "body", "[]", true, false))
    let key = Data(repeating: 17, count: SnippetCrypto.keyByteCount).base64EncodedString()
    let salt = Data(repeating: 18, count: 32).base64EncodedString()
    let first = try bridgeValue(reconcileLibraryAfterRecovery(
        createdAfterReview, "[]", "[]", "[]",
        key, salt, "sync-v1", "01234567"))
    let firstObject = try #require(
        JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
    let ambiguousOffer = try #require(firstObject["offers"] as? String)

    // This offer was durably captured while the same recovery review was active. If
    // the server accepted it but the response was lost, its exact echo is valid
    // ancestry even though the reviewed primary did not yet contain this new id.
    let recovered = try bridgeValue(reconcileLibraryWithPendingOffers(
        "[]", "[]", ambiguousOffer, "[]", false, true, ambiguousOffer,
        key, salt, "sync-v1", "89abcdef"))
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(recovered.utf8)) as? [String: Any])
    let library = try #require(object["library"] as? String)
    #expect(try SnippetLibraryCodec.decode(Data(library.utf8)).isEmpty)

    let offers = try JSONDecoder().decode(
        [WireRecord].self,
        from: Data(try #require(object["offers"] as? String).utf8))
    let sealer = SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(
            libraryKey: SymmetricKey(data: Data(repeating: 17, count: 32)),
            salt: Data(repeating: 18, count: 32)),
        scopeID: "sync-v1")
    #expect(try offers.map { try WireCodec.open($0, using: sealer) }.contains {
        $0.id.uuidString.lowercased() == id && $0.deleted
    })
}

private func bridgeValue(_ response: String) throws -> String {
    let object = try #require(
        JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    #expect(object["ok"] as? Bool == true)
    return try #require(object["value"] as? String)
}
