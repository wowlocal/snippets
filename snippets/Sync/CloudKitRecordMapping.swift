import CloudKit
import Foundation

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

// MARK: - WireRecord <-> CKRecord

nonisolated enum CloudKitRecordMapping {

    enum Failure: Error, CustomStringConvertible {
        case unrecognisedRecordName(String)
        case missingField(String, recordName: String)
        case blobTooLarge(bytes: Int, recordName: String)

        var description: String {
            switch self {
            case .unrecognisedRecordName(let name):
                return "record name '\(name)' is not a uuid"
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

        // A fresh CKRecord with no system fields, deliberately. Combined with
        // `savePolicy: .allKeys` this needs no cached `recordChangeTag`, which is what
        // lets the whole system-fields sidecar not exist — see `CloudKitTransport.submit`.
        let record = CKRecord(
            recordType: CloudKitSchema.recordType,
            recordID: recordID(for: wire.id, in: zoneID))
        record[CloudKitSchema.Field.rev] = wire.rev as CKRecordValue
        record[CloudKitSchema.Field.deleted] = wire.deleted as CKRecordValue
        record[CloudKitSchema.Field.blob] = wire.blob as CKRecordValue
        return record
    }

    static func makeWireRecord(from record: CKRecord) throws -> WireRecord {
        let name = record.recordID.recordName
        guard let id = UUID(uuidString: name) else {
            throw Failure.unrecognisedRecordName(name)
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
        return WireRecord(id: id, rev: rev, deleted: deleted, blob: blob)
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
