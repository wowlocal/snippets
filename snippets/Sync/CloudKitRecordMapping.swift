import CloudKit
import CryptoKit
import Foundation
#if os(macOS)
import Security
#endif

// App target only. `snippets/Core/` is compiled three ways — app, `snippets-cli`, and
// the test package — and the CLI is a bare Mach-O that holds no iCloud entitlement, so
// nothing that imports CloudKit may live there.

/// The CloudKit schema, and the conversions across it.
///
/// ## Everything named here is frozen once a second device reads a Production record
///
/// The Development environment is resettable from the CloudKit Dashboard, schema and
/// data together, so nothing in this file is expensive to be wrong about until the
/// first *Production* write. After that the schema is additive-only: a field can be
/// added, never renamed, retyped, or removed. That is the same hazard `snippets.json`
/// and `SyncEnvelope` already answer by freezing a key set, and the answer here is the
/// same — the record type carries no version suffix and the field set does not grow.
///
/// Versioning already exists one layer in: `SyncEnvelope.currentSchemaVersion` lives
/// *inside* `blob`, where an old build meets it as a clean `tooNew` quarantine. A
/// versioned record *type* would instead make an old build query for `SnippetRecord`
/// and find nothing at all, which looks exactly like an empty library — the one failure
/// this whole design refuses to let happen.
nonisolated enum CloudKitSchema {

    /// The container the entitlement names. Not `CKContainer.default()`: the default is
    /// derived from the bundle identifier, and this app's Debug bundle id is
    /// `com.khm.snippets.debug` while the entitlement grants
    /// `iCloud.com.khm.snippets` — so the default would resolve to a container the app
    /// is not authorized for and fail at runtime rather than at build time.
    static let containerIdentifier = "iCloud.com.khm.snippets"

    /// One custom zone, and it is not optional.
    ///
    /// The default zone does not support `CKServerChangeToken` at all, so `SyncCursor`
    /// would have nothing to hold and every fetch would be a full resync of the whole
    /// library. A custom zone is what makes a delta feed exist.
    static let zoneName = "SnippetLibrary"

    static let recordType: CKRecord.RecordType = "SnippetRecord"

    /// Exactly the three fields of `WireRecord` that are not the id.
    ///
    /// There is deliberately no `id` field: the id *is* `CKRecord.ID.recordName`, so
    /// storing it twice creates two things that can disagree.
    enum Field {
        /// `WireRecord.rev`. Client-derived and echoed back verbatim — see the note on
        /// `CloudKitTransport.submit`.
        static let rev = "rev"

        /// `WireRecord.deleted`. In the clear so a backend can garbage-collect
        /// tombstones, which is the entire reason `WireRecord` exposes it. Mark it
        /// **Queryable** in the Dashboard; without that the GC this field exists for
        /// cannot be written.
        static let deleted = "deleted"

        /// The sealed envelope. `Data`, never `CKAsset`.
        ///
        /// An asset field would be a single bit visible to the operator that splits the
        /// library into "big" and "small" — a far coarser leak than the 256-byte
        /// padding quantum the envelope already accepts. The ceiling this costs is
        /// roughly 767 KiB of snippet body, which no snippet reaches; a record that
        /// does is refused with a message that says so rather than silently promoted to
        /// a different storage shape.
        static let blob = "blob"
    }

    /// CloudKit's own documented ceiling for a single record's fields before `CKAsset`
    /// is required. Enforced here so an oversized record produces a sentence a human can
    /// act on instead of an opaque `limitExceeded` after three batch splits.
    static let maxBlobBytes = 900_000
}

/// The server environment selected by the running app's signed entitlement.
///
/// Development and Production are separate CloudKit routing coordinates. Apple does
/// not promise that a user-record name differs between them, so that name alone can
/// never scope a change token or archived `CKRecord` generation safely.
nonisolated enum CloudKitContainerEnvironment: String, Sendable {
    case development
    case production
    case unrecognized
}

/// Turns CloudKit's stable user record name into the opaque Core checkpoint identity.
///
/// The raw name never crosses this helper. Every backend-routing coordinate is a
/// separately length-prefixed field: container, database, environment, and user. That
/// prevents either an accidental concatenation collision or a Development checkpoint
/// from looking compatible with Production.
nonisolated enum CloudKitAccountIdentity {
    static func derive(
        containerIdentifier: String,
        databaseScope: CKDatabase.Scope,
        environment: CloudKitContainerEnvironment,
        userRecordID: CKRecord.ID
    ) -> SyncAccountIdentity {
        let database: String
        switch databaseScope {
        case .public: database = "public"
        case .private: database = "private"
        case .shared: database = "shared"
        @unknown default: database = "unrecognized-\(databaseScope.rawValue)"
        }

        var material = Data()
        append(Data("snippets-cloudkit-account-v1".utf8), to: &material)
        append(Data(containerIdentifier.utf8), to: &material)
        append(Data(database.utf8), to: &material)
        append(Data(environment.rawValue.utf8), to: &material)
        append(Data(userRecordID.recordName.utf8), to: &material)
        return SyncAccountIdentity(Data(SHA256.hash(data: material)))
    }

    private static func append(_ field: Data, to material: inout Data) {
        var count = UInt64(field.count).bigEndian
        withUnsafeBytes(of: &count) { material.append(contentsOf: $0) }
        material.append(field)
    }
}

/// Reads the CloudKit environment from the running binary, not from the source plist.
///
/// The selected server is a code-signing fact. Reading a build setting would recreate
/// the exact false-success this binding prevents: an artifact can be configured as
/// Release while its actual signature still routes CloudKit to Development. macOS and
/// iOS expose no common public entitlement API, so the implementation reads the
/// executable's standard Mach-O code-signature entitlement blob directly. The parser is
/// deliberately small, bounds-checked, and fail-closed.
nonisolated enum CloudKitRuntimeEnvironment {
    private static let environmentKey =
        "com.apple.developer.icloud-container-environment"
    private static let containerIdentifiersKey =
        "com.apple.developer.icloud-container-identifiers"
    private static let servicesKey = "com.apple.developer.icloud-services"

    static func current(
        containerIdentifier: String,
        bundle: Bundle = .main
    ) -> CloudKitContainerEnvironment {
        #if targetEnvironment(simulator)
        // Apple routes Simulator CloudKit only to Development, irrespective of the
        // device entitlement used by the same target. Simulator code signing exposes
        // only host/simulated entitlements, so container authorization remains a
        // CloudKit preflight concern there rather than something this process can prove.
        return .development
        #elseif os(macOS)
        // Read the entitlement of the running task. Reading Bundle.executableURL would
        // be a TOCTOU bug during an in-place Sparkle update: the old process can keep
        // running after that path starts naming the new app binary.
        guard let task = SecTaskCreateFromSelf(nil),
              let values = SecTaskCopyValuesForEntitlements(
                task,
                [servicesKey, containerIdentifiersKey, environmentKey] as CFArray,
                nil) as? [String: Any] else {
            return .unrecognized
        }
        return environment(
            fromSignedEntitlements: values,
            containerIdentifier: containerIdentifier)
        #else
        guard let executableURL = bundle.executableURL,
              let executable = try? Data(contentsOf: executableURL, options: .mappedIfSafe),
              let entitlements = signedEntitlements(fromMachO: executable) else {
            return .unrecognized
        }
        return environment(
            fromSignedEntitlements: entitlements,
            containerIdentifier: containerIdentifier)
        #endif
    }

    static func environment(
        fromSignedEntitlements entitlements: [String: Any],
        containerIdentifier: String
    ) -> CloudKitContainerEnvironment {
        guard let services = entitlements[servicesKey] as? [String],
              services.contains("CloudKit"),
              let containers = entitlements[containerIdentifiersKey] as? [String],
              containers.contains(containerIdentifier) else {
            return .unrecognized
        }

        guard let raw = entitlements[environmentKey] else {
            // CloudKit's documented default when this entitlement is absent is the
            // Development server. This is the normal directly-run macOS Debug shape.
            return .development
        }
        guard let value = raw as? String else { return .unrecognized }
        switch value.lowercased() {
        case "development": return .development
        case "production": return .production
        default: return .unrecognized
        }
    }

    /// Extracts the XML entitlement dictionary from the current architecture's Mach-O
    /// code signature. DER-only or malformed signatures intentionally return nil.
    static func signedEntitlements(fromMachO data: Data) -> [String: Any]? {
        guard let slice = currentArchitectureSlice(in: data) else { return nil }
        return signedEntitlements(in: data, slice: slice)
    }

    private struct Slice {
        var offset: Int
        var size: Int
    }

    private enum ByteOrder {
        case little
        case big
    }

    private static var currentCPUType: UInt32 {
        #if arch(arm64)
        return 0x0100_000C
        #elseif arch(x86_64)
        return 0x0100_0007
        #else
        return 0
        #endif
    }

    private static func currentArchitectureSlice(in data: Data) -> Slice? {
        guard let magic = uint32(data, at: 0, order: .big) else { return nil }
        let order: ByteOrder
        let is64BitFat: Bool
        switch magic {
        case 0xCAFE_BABE:
            order = .big
            is64BitFat = false
        case 0xBEBA_FECA:
            order = .little
            is64BitFat = false
        case 0xCAFE_BABF:
            order = .big
            is64BitFat = true
        case 0xBFBA_FECA:
            order = .little
            is64BitFat = true
        default:
            return Slice(offset: 0, size: data.count)
        }

        guard let countValue = uint32(data, at: 4, order: order),
              countValue <= 64,
              currentCPUType != 0 else { return nil }
        let count = Int(countValue)
        let stride = is64BitFat ? 32 : 20
        var selected: Slice?
        for index in 0..<count {
            let entry = 8 + index * stride
            guard let cpu = uint32(data, at: entry, order: order) else { return nil }
            let offset: UInt64?
            let size: UInt64?
            if is64BitFat {
                offset = uint64(data, at: entry + 8, order: order)
                size = uint64(data, at: entry + 16, order: order)
            } else {
                offset = uint32(data, at: entry + 8, order: order).map(UInt64.init)
                size = uint32(data, at: entry + 12, order: order).map(UInt64.init)
            }
            guard let offset, let size,
                  offset <= UInt64(Int.max), size <= UInt64(Int.max) else { return nil }
            let slice = Slice(offset: Int(offset), size: Int(size))
            guard valid(rangeAt: slice.offset, length: slice.size, in: data.count) else {
                return nil
            }
            if cpu == currentCPUType {
                // CPU subtype is not available as a compile-time Swift condition, and
                // arm64/arm64e slices are signed independently. A duplicate cputype is
                // therefore ambiguous; selecting the first could inspect a signature
                // that does not belong to the running image.
                guard selected == nil else { return nil }
                selected = slice
            }
        }
        return selected
    }

    private static func signedEntitlements(
        in data: Data,
        slice: Slice
    ) -> [String: Any]? {
        guard let magic = uint32(data, at: slice.offset, order: .big) else { return nil }
        let order: ByteOrder
        let headerSize: Int
        switch magic {
        case 0xCFFA_EDFE:
            order = .little
            headerSize = 32
        case 0xFEED_FACF:
            order = .big
            headerSize = 32
        case 0xCEFA_EDFE:
            order = .little
            headerSize = 28
        case 0xFEED_FACE:
            order = .big
            headerSize = 28
        default:
            return nil
        }

        guard let commandCountValue = uint32(data, at: slice.offset + 16, order: order),
              let commandBytesValue = uint32(data, at: slice.offset + 20, order: order),
              commandCountValue <= 16_384 else { return nil }
        let commandCount = Int(commandCountValue)
        let commandsStart = slice.offset + headerSize
        let commandBytes = Int(commandBytesValue)
        guard valid(rangeAt: commandsStart, length: commandBytes, in: data.count),
              commandsStart + commandBytes <= slice.offset + slice.size else { return nil }

        var commandOffset = commandsStart
        for _ in 0..<commandCount {
            guard commandOffset + 8 <= commandsStart + commandBytes,
                  let command = uint32(data, at: commandOffset, order: order),
                  let sizeValue = uint32(data, at: commandOffset + 4, order: order) else {
                return nil
            }
            let commandSize = Int(sizeValue)
            guard commandSize >= 8,
                  commandOffset + commandSize <= commandsStart + commandBytes else { return nil }

            if command == 0x1D {
                guard commandSize >= 16,
                      let relativeOffset = uint32(
                        data, at: commandOffset + 8, order: order),
                      let signatureSize = uint32(
                        data, at: commandOffset + 12, order: order) else { return nil }
                let signatureOffset = slice.offset + Int(relativeOffset)
                guard signatureOffset >= slice.offset,
                      valid(
                        rangeAt: signatureOffset,
                        length: Int(signatureSize),
                        in: data.count),
                      signatureOffset + Int(signatureSize) <= slice.offset + slice.size else {
                    return nil
                }
                return entitlementDictionary(
                    in: data,
                    signatureOffset: signatureOffset,
                    signatureSize: Int(signatureSize))
            }
            commandOffset += commandSize
        }
        return nil
    }

    private static func entitlementDictionary(
        in data: Data,
        signatureOffset: Int,
        signatureSize: Int
    ) -> [String: Any]? {
        guard uint32(data, at: signatureOffset, order: .big) == 0xFADE_0CC0,
              let totalLengthValue = uint32(data, at: signatureOffset + 4, order: .big),
              let countValue = uint32(data, at: signatureOffset + 8, order: .big) else {
            return nil
        }
        let totalLength = Int(totalLengthValue)
        let count = Int(countValue)
        guard totalLength <= signatureSize, count <= 4_096,
              valid(rangeAt: signatureOffset, length: totalLength, in: data.count),
              valid(rangeAt: signatureOffset + 12, length: count * 8, in: data.count),
              signatureOffset + 12 + count * 8 <= signatureOffset + totalLength else {
            return nil
        }
        let blobsStart = signatureOffset + 12 + count * 8

        for index in 0..<count {
            let entry = signatureOffset + 12 + index * 8
            guard let slot = uint32(data, at: entry, order: .big),
                  let relativeOffset = uint32(data, at: entry + 4, order: .big) else {
                return nil
            }
            guard slot == 5 else { continue }
            let blobOffset = signatureOffset + Int(relativeOffset)
            guard blobOffset >= blobsStart,
                  blobOffset + 8 <= signatureOffset + totalLength,
                  uint32(data, at: blobOffset, order: .big) == 0xFADE_7171,
                  let blobLengthValue = uint32(data, at: blobOffset + 4, order: .big) else {
                return nil
            }
            let blobLength = Int(blobLengthValue)
            guard blobLength >= 8,
                  blobOffset + blobLength <= signatureOffset + totalLength else { return nil }
            var payload = data.subdata(in: (blobOffset + 8)..<(blobOffset + blobLength))
            while payload.last == 0 { payload.removeLast() }
            guard let value = try? PropertyListSerialization.propertyList(
                from: payload, options: [], format: nil),
                  let dictionary = value as? [String: Any] else { return nil }
            return dictionary
        }
        return nil
    }

    private static func uint32(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) -> UInt32? {
        guard valid(rangeAt: offset, length: 4, in: data.count) else { return nil }
        let bytes = (0..<4).map { UInt32(data[offset + $0]) }
        switch order {
        case .big:
            return (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]
        case .little:
            return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24)
        }
    }

    private static func uint64(
        _ data: Data,
        at offset: Int,
        order: ByteOrder
    ) -> UInt64? {
        guard valid(rangeAt: offset, length: 8, in: data.count) else { return nil }
        var value: UInt64 = 0
        switch order {
        case .big:
            for index in 0..<8 { value = (value << 8) | UInt64(data[offset + index]) }
        case .little:
            for index in (0..<8).reversed() {
                value = (value << 8) | UInt64(data[offset + index])
            }
        }
        return value
    }

    private static func valid(rangeAt offset: Int, length: Int, in count: Int) -> Bool {
        offset >= 0 && length >= 0 && offset <= count && length <= count - offset
    }
}

// MARK: - WireRecord <-> CKRecord

nonisolated enum CloudKitRecordMapping {

    enum Failure: Error, CustomStringConvertible {
        case unrecognisedRecordName(String)
        case unexpectedRecordType(String)
        case unexpectedRecordZone
        case missingField(String, recordName: String)
        case blobTooLarge(bytes: Int, recordName: String)

        var description: String {
            switch self {
            case .unrecognisedRecordName(let name):
                return "record name '\(name)' is not a uuid"
            case .unexpectedRecordType(let type):
                return "record type '\(type)' is not the snippets record type"
            case .unexpectedRecordZone:
                return "record belongs to a different CloudKit zone"
            case .missingField(let field, let name):
                return "record \(name) has no '\(field)' field"
            case .blobTooLarge(let bytes, let name):
                return """
                    snippet \(name) is \(bytes) bytes sealed, over CloudKit's \
                    \(CloudKitSchema.maxBlobBytes)-byte per-record limit
                    """
            }
        }
    }

    /// `recordName` is the lowercase uuid string, matching `SyncBase.key` exactly.
    ///
    /// Matching matters: the base file is keyed the same way, and two spellings of the
    /// same id would make a record that round-trips through CloudKit look like a
    /// different record than the one in the ancestor — which reads as "one added, one
    /// deleted" to a three-way merge.
    static func recordID(for id: UUID, in zoneID: CKRecordZone.ID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.uuidString.lowercased(), zoneID: zoneID)
    }

    static func makeRecord(from wire: WireRecord, in zoneID: CKRecordZone.ID) throws -> CKRecord {
        guard wire.blob.count <= CloudKitSchema.maxBlobBytes else {
            throw Failure.blobTooLarge(
                bytes: wire.blob.count, recordName: wire.id.uuidString.lowercased())
        }

        let expectedID = recordID(for: wire.id, in: zoneID)

        // Restore the exact server generation when it is usable. A damaged/mismatched
        // cached archive falls back to a fresh record rather than wedging sync. This is
        // safe only because submit uses `.ifServerRecordUnchanged`: if the id already
        // exists, CloudKit returns `serverRecordChanged` and supplies authoritative
        // system fields instead of overwriting it.
        let record: CKRecord
        if let version = wire.recordVersion,
           let restored = try? CloudKitRecordVersion.restore(
                version,
                expectedRecordID: expectedID,
                expectedRecordType: CloudKitSchema.recordType) {
            record = restored
        } else {
            record = CKRecord(
                recordType: CloudKitSchema.recordType,
                recordID: expectedID)
        }
        record[CloudKitSchema.Field.rev] = wire.rev as CKRecordValue
        record[CloudKitSchema.Field.deleted] = wire.deleted as CKRecordValue
        record[CloudKitSchema.Field.blob] = wire.blob as CKRecordValue
        return record
    }

    static func makeWireRecord(
        from record: CKRecord,
        expectedZoneID: CKRecordZone.ID? = nil
    ) throws -> WireRecord {
        let name = record.recordID.recordName
        guard let id = UUID(uuidString: name),
              id.uuidString.lowercased() == name else {
            throw Failure.unrecognisedRecordName(name)
        }
        guard record.recordType == CloudKitSchema.recordType else {
            throw Failure.unexpectedRecordType(record.recordType)
        }
        if let expectedZoneID, record.recordID.zoneID != expectedZoneID {
            throw Failure.unexpectedRecordZone
        }
        guard let rev = record[CloudKitSchema.Field.rev] as? String else {
            throw Failure.missingField(CloudKitSchema.Field.rev, recordName: name)
        }
        guard let blob = record[CloudKitSchema.Field.blob] as? Data else {
            throw Failure.missingField(CloudKitSchema.Field.blob, recordName: name)
        }
        // Absent reads as "not deleted". A missing flag must never be read as a
        // tombstone: that turns a schema hiccup into a deletion.
        let deleted = record[CloudKitSchema.Field.deleted] as? Bool ?? false
        return WireRecord(
            id: id,
            rev: rev,
            deleted: deleted,
            blob: blob,
            recordVersion: try CloudKitRecordVersion.archive(record))
    }
}

// MARK: - Per-record optimistic-concurrency state

/// Durable `CKRecord` system fields, wrapped in Core's backend-opaque token.
///
/// Apple documents `encodeSystemFields(with:)` / `CKRecord(coder:)` as the supported way
/// to preserve `recordChangeTag` across launches. Archiving the whole record with
/// `archivedData(withRootObject:)` would also persist user fields, duplicating ciphertext
/// in plaintext protocol state and making the sidecar larger than necessary.
nonisolated enum CloudKitRecordVersion {

    enum Failure: Error, CustomStringConvertible {
        case archiveFailed
        case archiveTooLarge
        case decodeFailed
        case identityMismatch
        case missingChangeTag

        var description: String {
            switch self {
            case .archiveFailed: return "CloudKit record system fields could not be archived"
            case .archiveTooLarge: return "CloudKit record system fields archive is too large"
            case .decodeFailed: return "CloudKit record system fields could not be decoded"
            case .identityMismatch: return "CloudKit record system fields identify a different record"
            case .missingChangeTag: return "CloudKit record has no server change tag"
            }
        }
    }

    static func archive(_ record: CKRecord) throws -> SyncRecordVersion {
        // A fresh local CKRecord also has encodable system fields (type, id, zone), but
        // no server generation. Treating that archive as a version would allow a test or
        // malformed adapter response to acknowledge an offer without any usable CAS
        // token. CloudKit sets recordChangeTag only on a server-returned record.
        guard record.recordChangeTag?.isEmpty == false else {
            throw Failure.missingChangeTag
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        let data = archiver.encodedData
        guard !data.isEmpty else { throw Failure.archiveFailed }
        guard data.count <= SyncRecordVersion.maximumDataBytes else {
            throw Failure.archiveTooLarge
        }
        return SyncRecordVersion(data)
    }

    static func restore(
        _ version: SyncRecordVersion,
        expectedRecordID: CKRecord.ID,
        expectedRecordType: CKRecord.RecordType = CloudKitSchema.recordType
    ) throws -> CKRecord {
        let unarchiver: NSKeyedUnarchiver
        do {
            unarchiver = try NSKeyedUnarchiver(forReadingFrom: version.data)
        } catch {
            throw Failure.decodeFailed
        }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        defer { unarchiver.finishDecoding() }

        guard let record = CKRecord(coder: unarchiver),
              unarchiver.error == nil else {
            throw Failure.decodeFailed
        }
        guard record.recordID == expectedRecordID,
              record.recordType == expectedRecordType else {
            throw Failure.identityMismatch
        }
        guard record.recordChangeTag?.isEmpty == false else {
            throw Failure.missingChangeTag
        }
        return record
    }
}

// MARK: - Cursor

/// `SyncCursor` is a `String` and `CKServerChangeToken` is an object, so one has to be
/// encoded into the other. Base64 of the secure-coded archive, which is the only
/// representation Apple documents as durable across launches.
nonisolated enum CloudKitCursor {

    static func encode(_ token: CKServerChangeToken) -> SyncCursor? {
        guard let data = try? NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true)
        else { return nil }
        return SyncCursor(data.base64EncodedString())
    }

    /// Returns `nil` — "start from the beginning" — rather than throwing, for anything
    /// it cannot decode.
    ///
    /// That is the safe direction, and the protocol says so: a cursor this transport did
    /// not mint, or one written by a build whose archive format differed, costs a full
    /// resync. Throwing instead would make a corrupt one byte of state wedge sync
    /// permanently, and a resync that arrives as `isFullResync` cannot be mistaken for
    /// deletions.
    static func decode(_ cursor: SyncCursor?) -> CKServerChangeToken? {
        guard let cursor,
              let data = Data(base64Encoded: cursor.rawValue)
        else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: CKServerChangeToken.self, from: data)
    }
}
