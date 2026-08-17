import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// A deliberately narrow JNI boundary. Kotlin passes UTF-8 JSON and opaque key
/// material; the shared Swift model, merge, canonical wire format and crypto remain
/// the authority on both Apple platforms and Android.
public func snippetsCoreVersion() -> String {
    "sync-v1/android-bridge-1"
}

public func canonicalizeLibrary(_ libraryJSON: String) -> String {
    bridgeResult {
        let snippets = try decodeLibrary(libraryJSON)
        return try encodeLibrary(snippets)
    }
}

/// Validates the encrypted remote cache at the same Swift/Core boundary that consumes
/// it during reconciliation. Kotlin's `JSONArray` proves only surface JSON syntax; it
/// cannot prove UUIDs, revisions, ciphertext fields, or record-version shape.
public func validateWireRecords(_ remoteRecordsJSON: String) -> String {
    bridgeResult {
        _ = try JSONDecoder().decode(
            [WireRecord].self,
            from: Data(remoteRecordsJSON.utf8))
        return remoteRecordsJSON
    }
}

public func upsertSnippet(
    _ libraryJSON: String,
    _ id: String,
    _ name: String,
    _ keyword: String,
    _ content: String,
    _ tagsJSON: String,
    _ isEnabled: Bool,
    _ isPinned: Bool
) -> String {
    bridgeResult {
        var snippets = try decodeLibrary(libraryJSON)
        let tags = try JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))
        let now = Date()

        if let uuid = UUID(uuidString: id),
           let index = snippets.firstIndex(where: { $0.id == uuid }) {
            var snippet = snippets[index]
            snippet.name = name
            snippet.keyword = Snippet.sanitizedKeyword(keyword)
            snippet.content = content
            snippet.tags = SnippetTagging.normalizedTags(tags)
            snippet.isEnabled = isEnabled
            snippet.isPinned = isPinned
            snippet.updatedAt = now
            snippets[index] = snippet
        } else {
            let uuid = UUID(uuidString: id) ?? UUID()
            snippets.append(Snippet(
                id: uuid,
                name: name,
                keyword: Snippet.sanitizedKeyword(keyword),
                content: content,
                tags: SnippetTagging.normalizedTags(tags),
                isEnabled: isEnabled,
                isPinned: isPinned,
                createdAt: now,
                updatedAt: now))
        }

        return try encodeLibrary(SnippetDisplayOrder.sorted(snippets))
    }
}

public func deleteSnippet(_ libraryJSON: String, _ id: String) -> String {
    bridgeResult {
        guard let uuid = UUID(uuidString: id) else { throw AndroidBridgeFailure.invalidIdentifier }
        let snippets = try decodeLibrary(libraryJSON).filter { $0.id != uuid }
        return try encodeLibrary(snippets)
    }
}

public func searchLibrary(_ libraryJSON: String, _ query: String) -> String {
    bridgeResult {
        let snippets = try decodeLibrary(libraryJSON)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            return try encodeLibrary(SnippetDisplayOrder.sorted(snippets))
        }

        let matches = snippets.filter { snippet in
            [snippet.displayName, snippet.normalizedKeyword, snippet.content]
                .contains { FuzzyMatch.score(query: needle, target: $0).matched }
                || snippet.tags.contains { FuzzyMatch.score(query: needle, target: $0).matched }
        }
        return try encodeLibrary(SnippetDisplayOrder.sorted(matches))
    }
}

/// Reconciles a local library with a complete encrypted remote record set.
///
/// The result value is JSON with `library`, `records`, `offers`, and
/// `needsUserAttention`. `records` is the desired complete encrypted state and
/// `offers` contains only records whose application revision differs from the remote
/// value. Backend generation/CAS tokens from remote records are preserved on offers.
public func reconcileLibrary(
    _ localLibraryJSON: String,
    _ baseLibraryJSON: String,
    _ remoteRecordsJSON: String,
    _ keyMaterialBase64: String,
    _ saltBase64: String,
    _ scopeID: String,
    _ deviceID: String
) -> String {
    reconcileLibraryImpl(
        localLibraryJSON,
        baseLibraryJSON,
        remoteRecordsJSON,
        recoveryBaselineJSON: nil,
        pendingOffersJSON: nil,
        keyMaterialBase64,
        saltBase64,
        scopeID,
        deviceID)
}

/// Reconciles the first complete pull after a reviewed checkpoint/library recovery.
/// `baseLibraryJSON` remains the older readable merge ancestor, while
/// `recoveryBaselineJSON` is the exact primary snapshot accepted by Repair/Check Again.
/// A local change after that review uses the reviewed snapshot as its ancestor; an
/// unchanged row is still merged against the older base. Keeping those facts separate
/// preserves both lost-ACK/pre-review intent and later local edits/deletes. A record
/// absent from the complete remote set remains unknown rather than a cloud deletion.
public func reconcileLibraryAfterRecovery(
    _ localLibraryJSON: String,
    _ baseLibraryJSON: String,
    _ remoteRecordsJSON: String,
    _ recoveryBaselineJSON: String,
    _ keyMaterialBase64: String,
    _ saltBase64: String,
    _ scopeID: String,
    _ deviceID: String
) -> String {
    reconcileLibraryImpl(
        localLibraryJSON,
        baseLibraryJSON,
        remoteRecordsJSON,
        recoveryBaselineJSON: recoveryBaselineJSON,
        pendingOffersJSON: nil,
        keyMaterialBase64,
        saltBase64,
        scopeID,
        deviceID)
}

/// Reconciles with the exact outbound batch durably published before a prior HTTP
/// request. `recoveryBaselineJSONOrEmpty` is empty outside reviewed recovery. When the
/// backend now returns an exact offered echo, that offer is tentative ancestry: a newer
/// local edit or deletion must be compared with our own accepted value, not with the
/// older confirmed base. The host retains the journal until convergence is durable.
/// `pendingOffersCoverReviewedAbsences` is true only when the journal proves it was
/// captured after the currently active recovery review.
public func reconcileLibraryWithPendingOffers(
    _ localLibraryJSON: String,
    _ baseLibraryJSON: String,
    _ remoteRecordsJSON: String,
    _ recoveryBaselineJSONOrEmpty: String,
    _ reviewedAbsencesAreAuthoritative: Bool,
    _ pendingOffersCoverReviewedAbsences: Bool,
    _ pendingOffersJSON: String,
    _ keyMaterialBase64: String,
    _ saltBase64: String,
    _ scopeID: String,
    _ deviceID: String
) -> String {
    reconcileLibraryImpl(
        localLibraryJSON,
        baseLibraryJSON,
        remoteRecordsJSON,
        recoveryBaselineJSON: recoveryBaselineJSONOrEmpty.isEmpty
            ? nil : recoveryBaselineJSONOrEmpty,
        reviewedAbsencesAreAuthoritative: reviewedAbsencesAreAuthoritative,
        pendingOffersCoverReviewedAbsences: pendingOffersCoverReviewedAbsences,
        pendingOffersJSON: pendingOffersJSON,
        keyMaterialBase64,
        saltBase64,
        scopeID,
        deviceID)
}

private func reconcileLibraryImpl(
    _ localLibraryJSON: String,
    _ baseLibraryJSON: String,
    _ remoteRecordsJSON: String,
    recoveryBaselineJSON: String?,
    reviewedAbsencesAreAuthoritative: Bool = false,
    pendingOffersCoverReviewedAbsences: Bool = false,
    pendingOffersJSON: String?,
    _ keyMaterialBase64: String,
    _ saltBase64: String,
    _ scopeID: String,
    _ deviceID: String
) -> String {
    bridgeResult {
        let local = try decodeLibrary(localLibraryJSON)
        let base = try decodeLibrary(baseLibraryJSON)
        let recoveryBaseline = try recoveryBaselineJSON.map(decodeLibrary)
        let remoteRecords = try JSONDecoder().decode(
            [WireRecord].self,
            from: Data(remoteRecordsJSON.utf8))
        let pendingOffers = try pendingOffersJSON.map {
            try JSONDecoder().decode([WireRecord].self, from: Data($0.utf8))
        } ?? []
        let sealer = try makeSealer(
            keyMaterialBase64: keyMaterialBase64,
            saltBase64: saltBase64,
            scopeID: scopeID)

        var remoteEnvelopes: [UUID: SyncEnvelope] = [:]
        var remoteByID: [UUID: WireRecord] = [:]
        for record in remoteRecords {
            remoteEnvelopes[record.id] = try WireCodec.open(record, using: sealer)
            remoteByID[record.id] = record
        }
        var offeredEnvelopes: [UUID: SyncEnvelope] = [:]
        for record in pendingOffers {
            guard offeredEnvelopes[record.id] == nil else {
                throw AndroidBridgeFailure.invalidOutboundJournal
            }
            offeredEnvelopes[record.id] = try WireCodec.open(record, using: sealer)
        }

        // Keep the backend order deterministic while exposing only ordinary records
        // to the plain-library merge. Secure records are intentionally opaque on
        // Android until the vault UI exists; they still remain in the desired wire set
        // below and therefore survive an iCloud -> Snippets Cloud -> iCloud round trip.
        let remote = remoteRecords.compactMap { remoteEnvelopes[$0.id]?.plainSnippet }
        // Recovery has two independent ancestors. For each remote id, retain the older
        // merge base whenever it exists, including after a post-review edit/delete. An
        // unchanged remote value is then correctly recognized as unchanged instead of
        // resurrecting over that newer local intent. Use the reviewed primary only as
        // fallback ancestry for a reviewed-only id changed after the explicit review.
        // Remote absence is never a deletion, so no ancestor is supplied for an id that
        // is absent from the complete record set.
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let baseByID = Dictionary(uniqueKeysWithValues: base.map { ($0.id, $0) })
        let liveSecureIDs = Set(remoteEnvelopes.compactMap { id, envelope in
            envelope.secure && !envelope.deleted ? id : nil
        })
        // A promotion performed on a vault-capable device replaces the ordinary
        // representation. Never let Android's stale plain row reuse the secure
        // carrier's CAS token and overwrite it. An unchanged shadow can disappear
        // automatically; an independently edited/local-only shadow is ambiguous and
        // stops before either primary bytes or the backend are mutated.
        for id in liveSecureIDs {
            guard let localValue = localByID[id] else { continue }
            guard let ancestor = baseByID[id],
                  SyncMerge.payloadEquals(ancestor, localValue) else {
                throw AndroidBridgeFailure.secureRecordConflict
            }
        }
        let mergeLocal = local.filter { !liveSecureIDs.contains($0.id) }
        let mergeLocalByID = Dictionary(uniqueKeysWithValues: mergeLocal.map { ($0.id, $0) })
        let reviewedByID = recoveryBaseline.map {
            Dictionary(uniqueKeysWithValues: $0.map { ($0.id, $0) })
        }
        var effectiveBaseByID: [UUID: Snippet] = [:]
        if let reviewedByID {
            let ids = Set(baseByID.keys).union(reviewedByID.keys).union(mergeLocalByID.keys)
            for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard remoteByID[id] != nil else { continue }
                let reviewed = reviewedByID[id]
                let localValue = mergeLocalByID[id]
                let changedAfterReview: Bool = switch (reviewed, localValue) {
                case (nil, nil): false
                case (.some, nil), (nil, .some): true
                case (.some(let reviewed), .some(let localValue)):
                    !SyncMerge.payloadEquals(reviewed, localValue)
                }
                if let ancestor = baseByID[id]
                    ?? (changedAfterReview ? reviewed : nil) {
                    effectiveBaseByID[id] = ancestor
                }
            }
        } else {
            effectiveBaseByID = baseByID
        }
        // A matching remote echo resolves an ambiguous HTTP acknowledgement. Prefer
        // that exact offered value over both ordinary and recovery ancestry. A live
        // echo becomes the merge base; an echoed tombstone removes the old live base
        // so a subsequent local recreation is not mistaken for an edit racing a new
        // remote deletion.
        for (id, offered) in offeredEnvelopes {
            guard let remote = remoteEnvelopes[id],
                  sameEnvelopeVersion(offered, remote),
                  recoveryBaseline == nil
                    || reviewedAbsencesAreAuthoritative
                    || pendingOffersCoverReviewedAbsences
                    || reviewedByID?[id] != nil
            else { continue }
            effectiveBaseByID[id] = offered.plainSnippet
        }
        let effectiveBase = effectiveBaseByID.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let outcome = SyncMerge.mergeLocal(base: effectiveBase, local: mergeLocal, remote: remote)
        // Keep the secure-carrier exclusion at the final serialization boundary too.
        // That makes this invariant independent of SyncMerge's treatment of a base-only
        // row and prevents a future merge change from reintroducing a plain shadow.
        let mergedSnippets = outcome.snippets.filter { !liveSecureIDs.contains($0.id) }
        let mergedByID = Dictionary(uniqueKeysWithValues: mergedSnippets.map { ($0.id, $0) })
        let deletionGuardLocalIDs = Set(localByID.keys).subtracting(liveSecureIDs)
        let deletionReview = SyncDeletionSafety.review(
            liveIDs: deletionGuardLocalIDs,
            resultingLiveIDs: Set(mergedByID.keys))
        let deletionFacts = SyncDeletionSafety.facts(
            liveIDs: deletionGuardLocalIDs,
            resultingLiveIDs: Set(mergedByID.keys))
        let normalizedDevice = HLC.normalizedDevice(deviceID)
        let clock = HLCGenerator(device: normalizedDevice)

        var desired: [WireRecord] = []
        var offers: [WireRecord] = []

        for snippet in mergedSnippets {
            let remoteEnvelope = remoteEnvelopes[snippet.id]
            let remoteSnippet = remoteEnvelope?.plainSnippet
            let record: WireRecord
            if let remoteEnvelope, let remoteSnippet,
               SyncMerge.payloadEquals(remoteSnippet, snippet),
               remoteSnippet.createdAt == snippet.createdAt,
               remoteSnippet.updatedAt == snippet.updatedAt,
               let existing = remoteByID[snippet.id] {
                _ = remoteEnvelope
                record = existing
            } else {
                let floor = UInt64(max(0, snippet.updatedAt.timeIntervalSince1970 * 1_000))
                let envelope = SyncEnvelope.plain(
                    snippet,
                    hlc: clock.send(atLeast: floor),
                    origin: normalizedDevice)
                var sealed = try WireCodec.seal(envelope, using: sealer)
                sealed.recordVersion = remoteByID[snippet.id]?.recordVersion
                record = sealed
            }
            desired.append(record)
            if remoteByID[snippet.id]?.rev != record.rev {
                offers.append(record)
            }
        }

        let allIDs = Set(base.map(\.id)).union(localByID.keys).union(remoteByID.keys)
        for id in allIDs where mergedByID[id] == nil {
            if let remoteEnvelope = remoteEnvelopes[id], remoteEnvelope.secure,
               !remoteEnvelope.deleted, let existing = remoteByID[id] {
                desired.append(existing)
                continue
            }
            if let remoteEnvelope = remoteEnvelopes[id], remoteEnvelope.deleted,
               let existing = remoteByID[id] {
                desired.append(existing)
                continue
            }
            let wasSecure = remoteEnvelopes[id]?.secure ?? false
            let tombstone = SyncEnvelope.tombstone(
                id: id,
                secure: wasSecure,
                hlc: clock.send(),
                origin: normalizedDevice)
            var record = try WireCodec.seal(tombstone, using: sealer)
            record.recordVersion = remoteByID[id]?.recordVersion
            desired.append(record)
            offers.append(record)
        }

        desired.sort { $0.id.uuidString < $1.id.uuidString }
        offers.sort { $0.id.uuidString < $1.id.uuidString }
        let payload = ReconcilePayload(
            library: try encodeLibrary(mergedSnippets),
            records: try encodeRecords(desired),
            offers: try encodeRecords(offers),
            needsUserAttention: outcome.needsUserAttention,
            deletionReview: deletionReview,
            deletionFacts: deletionFacts)
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

private enum AndroidBridgeFailure: Error {
    case invalidIdentifier
    case invalidKeyMaterial
    case invalidOutboundJournal
    case secureRecordConflict
}

private struct BridgeResponse: Codable {
    let ok: Bool
    let value: String?
    let error: String?
}

private struct ReconcilePayload: Codable {
    let library: String
    let records: String
    let offers: String
    let needsUserAttention: Bool
    let deletionReview: SyncDeletionSafety.Review?
    let deletionFacts: SyncDeletionSafety.Review?
}

private func bridgeResult(_ operation: () throws -> String) -> String {
    let response: BridgeResponse
    do {
        response = BridgeResponse(ok: true, value: try operation(), error: nil)
    } catch AndroidBridgeFailure.invalidIdentifier {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_identifier")
    } catch AndroidBridgeFailure.invalidKeyMaterial {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_key_material")
    } catch AndroidBridgeFailure.invalidOutboundJournal {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_outbound_journal")
    } catch AndroidBridgeFailure.secureRecordConflict {
        response = BridgeResponse(ok: false, value: nil, error: "secure_record_conflict")
    } catch is SnippetLibraryCodec.Failure {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_library")
    } catch is DecodingError {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_json")
    } catch {
        response = BridgeResponse(ok: false, value: nil, error: "operation_failed")
    }
    let data = (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false,"error":"encoding_failed"}"#.utf8)
    return String(decoding: data, as: UTF8.self)
}

private func sameEnvelopeVersion(
    _ lhs: SyncEnvelope?,
    _ rhs: SyncEnvelope?
) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case (.some(let lhs), .some(let rhs)):
        if let left = try? lhs.envelopeHash(), let right = try? rhs.envelopeHash() {
            return left == right
        }
        return lhs == rhs
    case (.some, nil), (nil, .some): return false
    }
}

private func decodeLibrary(_ text: String) throws -> [Snippet] {
    try SnippetLibraryCodec.decode(Data(text.utf8))
}

private func encodeLibrary(_ snippets: [Snippet]) throws -> String {
    String(decoding: try SnippetLibraryCodec.encode(snippets), as: UTF8.self)
}

private func encodeRecords(_ records: [WireRecord]) throws -> String {
    String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
}

private func makeSealer(
    keyMaterialBase64: String,
    saltBase64: String,
    scopeID: String
) throws -> SnippetCryptoSealer {
    guard let key = Data(base64Encoded: keyMaterialBase64),
          key.count == SnippetCrypto.keyByteCount,
          let salt = Data(base64Encoded: saltBase64),
          !salt.isEmpty,
          !scopeID.isEmpty else {
        throw AndroidBridgeFailure.invalidKeyMaterial
    }
    return SnippetCryptoSealer(
        keyring: SnippetCrypto.Keyring(libraryKey: SymmetricKey(data: key), salt: salt),
        scopeID: scopeID)
}
