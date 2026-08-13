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
    bridgeResult {
        let local = try decodeLibrary(localLibraryJSON)
        let base = try decodeLibrary(baseLibraryJSON)
        let remoteRecords = try JSONDecoder().decode(
            [WireRecord].self,
            from: Data(remoteRecordsJSON.utf8))
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

        // Keep the backend order deterministic while exposing only ordinary records
        // to the plain-library merge. Secure records are intentionally opaque on
        // Android until the vault UI exists; they still remain in the desired wire set
        // below and therefore survive an iCloud -> Snippets Cloud -> iCloud round trip.
        let remote = remoteRecords.compactMap { remoteEnvelopes[$0.id]?.plainSnippet }
        let outcome = SyncMerge.mergeLocal(base: base, local: local, remote: remote)
        let localByID = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        let mergedByID = Dictionary(uniqueKeysWithValues: outcome.snippets.map { ($0.id, $0) })
        let normalizedDevice = HLC.normalizedDevice(deviceID)
        let clock = HLCGenerator(device: normalizedDevice)

        var desired: [WireRecord] = []
        var offers: [WireRecord] = []

        for snippet in outcome.snippets {
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
            library: try encodeLibrary(outcome.snippets),
            records: try encodeRecords(desired),
            offers: try encodeRecords(offers),
            needsUserAttention: outcome.needsUserAttention)
        return String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
    }
}

private enum AndroidBridgeFailure: Error {
    case invalidIdentifier
    case invalidKeyMaterial
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
}

private func bridgeResult(_ operation: () throws -> String) -> String {
    let response: BridgeResponse
    do {
        response = BridgeResponse(ok: true, value: try operation(), error: nil)
    } catch AndroidBridgeFailure.invalidIdentifier {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_identifier")
    } catch AndroidBridgeFailure.invalidKeyMaterial {
        response = BridgeResponse(ok: false, value: nil, error: "invalid_key_material")
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
