import Darwin
import Foundation

/// Converts opaque secure conflict snapshots into ordinary vault records once the
/// caller already holds the vault key. The operation is pure: app code commits the
/// returned complete record array in the same `LibraryTransaction` that installs the
/// survivor, so neither a crash nor a representation change can strand ciphertext in
/// a best-effort sync sidecar.
nonisolated enum SyncSecureConflictMaterializer {

    enum Failure: Error, Equatable {
        case malformedVariant
        case incompatibleVault
        case identifierCollision
        case contentHashMismatch
    }

    struct Result: Equatable {
        var records: [VaultRecord]
        var materializedIDs: [UUID]
    }

    static let provenanceExtensionKey = "conflictCopy.v1"

    static func materialize(
        envelope: SyncEnvelope,
        keyring: SnippetCrypto.Keyring,
        vaultKID: String,
        existingSnippets: [Snippet],
        existingRecords: [VaultRecord]
    ) throws -> Result {
        let variants: [SyncMerge.SecureContentConflictVariant]
        do {
            try SyncMerge.validateContentConflictExtensions(in: envelope)
            variants = try SyncMerge.secureContentConflictVariants(in: envelope)
        } catch {
            throw Failure.malformedVariant
        }
        var records = existingRecords
        var materialized: [UUID] = []

        for variant in variants {
            guard variant.sourceExtensions[SyncEnvelope.vaultKeyIDExtensionKey]?.text
                    == vaultKID,
                  let sealed = String(data: variant.fields.content, encoding: .utf8),
                  let expectedHash = variant.sourceExtensions[
                    SyncEnvelope.vaultContentHashExtensionKey]?.text
            else { throw Failure.incompatibleVault }

            let provenance = JSONValue.object([
                "version": .integer(1),
                "sourceID": .string(variant.sourceID.uuidString.lowercased()),
                "fingerprint": .string(variant.fingerprint),
            ])

            if existingSnippets.contains(where: { $0.id == variant.copyID }) {
                throw Failure.identifierCollision
            }
            let existingCopies = records.filter { $0.id == variant.copyID }
            guard existingCopies.count <= 1 else {
                // A damaged vault may contain duplicate ids even though every normal
                // writer prevents them. Accepting the first matching record would leave
                // a later unrelated duplicate to win projection order after the
                // materializer reported success.
                throw Failure.identifierCollision
            }
            if let existing = existingCopies.first {
                guard existing.x[provenanceExtensionKey] == provenance else {
                    throw Failure.identifierCollision
                }
                try authenticate(
                    sealed: existing.sealed,
                    expectedHash: existing.contentHash,
                    recordID: existing.id,
                    vaultKID: vaultKID,
                    keyring: keyring)
                continue
            }

            var plaintext = try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: vaultKID, recordID: variant.sourceID),
                keyring: keyring)
            defer { wipe(&plaintext) }
            guard SnippetCrypto.contentHash(of: plaintext, keyring: keyring) == expectedHash else {
                throw Failure.contentHashMismatch
            }
            let resealed = try SnippetCrypto.seal(
                plaintext,
                for: SnippetCrypto.RecordContext(
                    scopeID: vaultKID, recordID: variant.copyID),
                keyring: keyring)

            let fields = variant.fields
            let copy = VaultRecord(
                id: variant.copyID,
                name: conflictName(name: fields.name, updatedAt: fields.updatedAt),
                keyword: "",
                tags: SnippetTagging.normalizedTags(fields.tags + ["conflict"]),
                isEnabled: false,
                isPinned: false,
                createdAt: fields.createdAt,
                updatedAt: fields.updatedAt,
                hlc: variant.sourceHLC,
                contentHash: expectedHash,
                sealed: resealed,
                x: [provenanceExtensionKey: provenance])
            records.append(copy)
            materialized.append(copy.id)
        }

        return Result(
            records: records,
            materializedIDs: materialized.sorted { $0.uuidString < $1.uuidString })
    }

    /// Matching provenance proves which deterministic conflict this id belongs to; it
    /// does not authenticate a secure body that arrived beside the source in the same
    /// batch. Validate that body before the bridge can replace the freshly materialized
    /// copy with it inside the transaction.
    static func validateIncomingSecureCopy(
        _ envelope: SyncEnvelope,
        keyring: SnippetCrypto.Keyring,
        vaultKID: String
    ) throws {
        guard !envelope.deleted,
              envelope.secure,
              envelope.x[SyncEnvelope.vaultKeyIDExtensionKey]?.text == vaultKID,
              let fields = envelope.fields,
              let sealed = String(data: fields.content, encoding: .utf8),
              let expectedHash = envelope.x[
                SyncEnvelope.vaultContentHashExtensionKey]?.text
        else { throw Failure.incompatibleVault }

        try authenticate(
            sealed: sealed,
            expectedHash: expectedHash,
            recordID: envelope.id,
            vaultKID: vaultKID,
            keyring: keyring)
    }

    private static func authenticate(
        sealed: String,
        expectedHash: String,
        recordID: UUID,
        vaultKID: String,
        keyring: SnippetCrypto.Keyring
    ) throws {
        var plaintext: Data
        do {
            plaintext = try SnippetCrypto.open(
                sealed,
                for: SnippetCrypto.RecordContext(
                    scopeID: vaultKID, recordID: recordID),
                keyring: keyring)
        } catch {
            throw Failure.malformedVariant
        }
        defer { wipe(&plaintext) }
        guard SnippetCrypto.contentHash(of: plaintext, keyring: keyring) == expectedHash else {
            throw Failure.contentHashMismatch
        }
    }

    private static func conflictName(name: String, updatedAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm 'UTC'"
        let displayName = name.isEmpty ? "Untitled" : name
        return "\(displayName) (conflict \(formatter.string(from: updatedAt)))"
    }

    private static func wipe(_ data: inout Data) {
        data.withUnsafeMutableBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            _ = memset_s(address, bytes.count, 0, bytes.count)
        }
        data.removeAll(keepingCapacity: false)
    }
}
