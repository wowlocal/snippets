import CloudKit
import Foundation

// App target only — see the note at the top of `CloudKitRecordMapping.swift`.

/// Translates CloudKit's failures into the engine's two error taxonomies.
///
/// ## Why this is a total switch with an explicit default
///
/// `SyncEngine.sync()` ends with a blanket `catch { handle(.unreachable(...)) }`, so any
/// error that is *not* a `SyncTransportFailure` is reported to the user as a network
/// problem. That is a reasonable last resort and a terrible place to land by accident: a
/// misconfigured container, a missing entitlement, and a full iCloud account would all
/// present as "the sync backend could not be reached", and the user would go and check
/// their wifi. So every `CKError` code is named here, and the `default` exists only for
/// codes Apple adds after this was written.
///
/// The mapping is chosen by *policy*, not by severity, because that is what the engine
/// does with it: `conflict` re-merges immediately, `rateLimited` backs off by a stated
/// amount, `authenticationRequired` stops and asks the user, and `permanent`
/// quarantines the record and moves on with the batch.
nonisolated enum CloudKitErrorMapping {

    /// A per-record outcome inside a partially accepted batch.
    static func rejection(for error: any Error) -> SyncRejection {
        guard let ckError = error as? CKError else {
            return .permanent(detail: "the sync backend rejected this snippet")
        }

        switch ckError.code {

        // The one that matters most: another device wrote this record after the view
        // this batch was built from. Re-merge and retry, which is what the three-way
        // merge on the fetch leg is for. The transport enriches this with the validated
        // server record because it knows the expected id and zone; this policy-only
        // mapper cannot safely do that by itself.
        case .serverRecordChanged:
            return .conflict(remote: nil)

        // Time-based back-pressure. CloudKit states the delay; honour it rather than
        // guessing, or the retry contributes to the condition it is waiting out.
        case .requestRateLimited, .zoneBusy, .serviceUnavailable,
             .accountTemporarilyUnavailable:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // The user has to do something. Retrying on a timer cannot fix any of these and
        // repeatedly hitting a locked account is how it gets throttled.
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted:
            return .authenticationRequired(detail: authenticationDetail(for: ckError.code))

        // Configuration or code, not data. `missingEntitlement` in particular means the
        // build is not provisioned for CloudKit at all, which no retry reaches.
        case .missingEntitlement, .badContainer, .badDatabase, .invalidArguments,
             .incompatibleVersion, .constraintViolation, .referenceViolation,
             .serverRejectedRequest, .internalError:
            return .permanent(detail: permanentDetail(for: ckError.code))

        // Not time-based, so not `rateLimited`: the user must free space or upgrade.
        case .quotaExceeded:
            return .permanent(detail: "the iCloud account is out of space")

        // A record too large for one request. The transport splits batches on this, so
        // seeing it per-record means one single record is over the limit.
        case .limitExceeded:
            return .permanent(detail: "this snippet is too large for CloudKit to store")

        // Transient plumbing. `serverResponseLost` is explicitly retryable: the write may
        // even have landed, which is exactly why the engine is required to be idempotent.
        case .networkUnavailable, .networkFailure, .serverResponseLost:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // A sibling in the batch failed and CloudKit refused this one as collateral. The
        // transport submits with `atomically: false` to make this rare, but a zone is
        // atomic-capable and CloudKit may still group.
        case .batchRequestFailed:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // A missing record can race another writer and is retryable. Zone loss is
        // intentionally handled by the CKSyncEngine driver as a reviewed safety halt;
        // an established zone must never be recreated/reuploaded automatically.
        case .changeTokenExpired, .unknownItem:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        case .zoneNotFound, .userDeletedZone:
            return .permanent(detail: "the CloudKit record zone no longer exists")

        // Cancellation is not a failure of the record.
        case .operationCancelled:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // Sharing and assets. This transport creates neither, so these mean the schema
        // is not what this build thinks it is.
        case .alreadyShared, .tooManyParticipants, .participantMayNeedVerification,
             .participantAlreadyInvited,
             .assetFileNotFound, .assetFileModified, .assetNotAvailable:
            return .permanent(detail: permanentDetail(for: ckError.code))

        // These describe the envelope, not a permanent rejection of this record. A
        // partial failure normally carries the actual per-item CKError; callers with an
        // item identity unwrap it through `recordError(in:for:)`. Without that identity,
        // retry rather than turn an incomplete response into a sticky account-review halt.
        case .resultsTruncated, .partialFailure:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        @unknown default:
            // A code Apple added since this was written. Retryable on purpose: refusing
            // a record forever on the strength of an unrecognised number is the worse
            // mistake, because it is the one that loses data.
            return .rateLimited(retryAfter: retryAfter(from: ckError))
        }
    }

    /// A failure of the whole call rather than of one record.
    static func failure(for error: any Error) -> SyncTransportFailure {
        if let failure = error as? SyncTransportFailure { return failure }
        guard let ckError = error as? CKError else {
            return .unreachable(detail: "the CloudKit operation failed")
        }

        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serverResponseLost, .internalError,
             .resultsTruncated, .partialFailure:
            return .unreachable(detail: "CloudKit is temporarily unreachable")
        default:
            return .rejected(rejection(for: ckError))
        }
    }

    /// Whether this error means the change feed has to be restarted from nothing.
    ///
    /// The caller must then report `isFullResync: true`, which tells the engine to treat
    /// the page as a snapshot and — critically — not to infer deletions from absence.
    static func isCursorLost(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .changeTokenExpired, .zoneNotFound, .userDeletedZone:
            return true
        default:
            return false
        }
    }

    /// A missing/deleted custom zone is a reviewed safety event, unlike an expired
    /// per-zone change token that CKSyncEngine can refetch from a fresh watermark.
    static func isZoneInvalidated(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        switch ckError.code {
        case .zoneNotFound, .userDeletedZone:
            return true
        default:
            return false
        }
    }

    /// Finds zone loss inside CloudKit's batch-level partial-failure envelopes while
    /// ignoring failures explicitly attributed to another zone. `sendChanges()` can
    /// throw this envelope after its delegate callbacks have completed, so checking only
    /// the outer code would incorrectly turn a destructive reset into an ordinary retry.
    static func containsZoneInvalidation(
        _ error: any Error,
        for zoneID: CKRecordZone.ID
    ) -> Bool {
        containsZoneInvalidation(error, for: zoneID, remainingDepth: 4)
    }

    private static func containsZoneInvalidation(
        _ error: any Error,
        for zoneID: CKRecordZone.ID,
        remainingDepth: Int
    ) -> Bool {
        if isZoneInvalidated(error) { return true }
        guard remainingDepth > 0,
              let ckError = error as? CKError,
              ckError.code == .partialFailure,
              let partialErrors = ckError.partialErrorsByItemID else { return false }

        return partialErrors.contains { itemID, nestedError in
            let belongsToZone: Bool
            if let recordID = itemID as? CKRecord.ID {
                belongsToZone = recordID.zoneID == zoneID
            } else if let failedZoneID = itemID as? CKRecordZone.ID {
                belongsToZone = failedZoneID == zoneID
            } else {
                // Unknown item identities have no authority to reset this transport's
                // established zone. Known direct zone-loss errors are handled above.
                belongsToZone = false
            }
            return belongsToZone && containsZoneInvalidation(
                nestedError,
                for: zoneID,
                remainingDepth: remainingDepth - 1)
        }
    }

    /// Extracts the failure attributed to this transport's zone from a batch envelope.
    /// Fetch APIs do not have per-record acceptance semantics, so their caller should map
    /// this scoped error directly (authentication stays authentication, configuration
    /// stays permanent) instead of flattening every partial failure into a network retry.
    static func zoneError(
        in error: any Error,
        for zoneID: CKRecordZone.ID
    ) -> (any Error)? {
        scopedErrors(in: error, for: zoneID, remainingDepth: 4).max {
            policyPriority(of: $0) < policyPriority(of: $1)
        }
    }

    private static func scopedErrors(
        in error: any Error,
        for zoneID: CKRecordZone.ID,
        remainingDepth: Int
    ) -> [any Error] {
        guard let ckError = error as? CKError,
              ckError.code == .partialFailure else { return [error] }
        guard remainingDepth > 0,
              let partialErrors = ckError.partialErrorsByItemID else { return [] }

        return partialErrors.flatMap { itemID, nestedError -> [any Error] in
            let belongsToZone: Bool
            if let recordID = itemID as? CKRecord.ID {
                belongsToZone = recordID.zoneID == zoneID
            } else if let failedZoneID = itemID as? CKRecordZone.ID {
                belongsToZone = failedZoneID == zoneID
            } else {
                belongsToZone = false
            }
            guard belongsToZone else { return [] }
            return scopedErrors(
                in: nestedError,
                for: zoneID,
                remainingDepth: remainingDepth - 1)
        }
    }

    private static func policyPriority(of error: any Error) -> Int {
        if isZoneInvalidated(error) { return 4 }
        switch failure(for: error) {
        case .rejected(let rejection):
            switch rejection {
            case .authenticationRequired: return 3
            case .permanent: return 2
            case .conflict, .rateLimited: return 1
            }
        case .accountChanged, .checkpointUnreadable, .remoteDataReset:
            return 3
        case .unreachable, .pushUnsupported:
            return 1
        }
    }

    /// Whether a batch should be split and retried rather than reported.
    static func isBatchTooLarge(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .limitExceeded
    }

    /// CKSyncEngine reports a partially accepted send both through per-record delegate
    /// events and by throwing from `sendChanges()`. The delegate events are the
    /// authoritative item outcomes; the outer error only says that not every item won.
    static func isIncompleteOperationResult(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .partialFailure
    }

    // MARK: - userInfo

    /// CloudKit's own number when it gives one.
    ///
    /// The fallback is deliberately small. The engine applies its own exponential
    /// backoff on top (2s, 4s, 8s … capped at five minutes), so this value only has to
    /// be non-zero and honest; inventing a large one here would compound with the
    /// engine's and strand a user who just walked back into wifi.
    static func retryAfter(from error: CKError, fallback: TimeInterval = 5) -> TimeInterval {
        if let seconds = error.userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return max(1, seconds.doubleValue)
        }
        if let seconds = error.retryAfterSeconds {
            return max(1, seconds)
        }
        return fallback
    }

    /// Unwraps `partialFailure` into the per-item errors the engine can act on.
    static func partialErrors(in error: any Error) -> [CKRecord.ID: any Error]? {
        guard let ckError = error as? CKError, ckError.code == .partialFailure else {
            return nil
        }
        return ckError.partialErrorsByItemID as? [CKRecord.ID: any Error]
    }

    /// Extracts the actual rejection for one failed record from CloudKit's batch-level
    /// `.partialFailure` envelope. The SDK can surface that envelope on an individual
    /// `failedRecordSaves` entry; treating the envelope itself as permanent loses the
    /// embedded conflict/rate-limit policy and can strand account-review recovery.
    static func recordError(
        in error: any Error,
        for recordID: CKRecord.ID
    ) -> (any Error)? {
        var current: any Error = error
        for _ in 0..<4 {
            guard let ckError = current as? CKError,
                  ckError.code == .partialFailure else { return current }
            guard let nested = ckError.partialErrorsByItemID?[recordID] else {
                return nil
            }
            current = nested
        }
        return nil
    }

    // MARK: - Durable, privacy-safe details

    /// These strings may reach Sync/state.json and user-visible halt UI. Keep this a
    /// closed mapping: CKError descriptions and userInfo can contain record names and
    /// other private CloudKit coordinates.
    private static func authenticationDetail(for code: CKError.Code) -> String {
        switch code {
        case .notAuthenticated:
            return "sign in to iCloud to sync snippets"
        case .permissionFailure:
            return "iCloud denied access to the Snippets private database"
        case .managedAccountRestricted:
            return "this managed iCloud account does not permit Snippets sync"
        default:
            return "iCloud authentication is required"
        }
    }

    private static func permanentDetail(for code: CKError.Code) -> String {
        switch code {
        case .missingEntitlement:
            return "this build is not entitled to use the configured CloudKit container"
        case .badContainer, .badDatabase:
            return "the app's CloudKit container configuration is invalid"
        case .invalidArguments, .incompatibleVersion:
            return "this app version made an unsupported CloudKit request"
        case .constraintViolation, .referenceViolation, .serverRejectedRequest:
            return "CloudKit rejected this snippet record"
        case .internalError:
            return "CloudKit could not process this snippet record"
        case .alreadyShared, .tooManyParticipants, .participantMayNeedVerification,
             .participantAlreadyInvited:
            return "the CloudKit sharing state is unsupported"
        case .assetFileNotFound, .assetFileModified, .assetNotAvailable:
            return "the CloudKit asset state is invalid"
        default:
            return "CloudKit permanently rejected this snippet record"
        }
    }
}

// MARK: - Account status

nonisolated extension CKAccountStatus {

    /// What sync should do about this account state, expressed in the engine's terms.
    ///
    /// `nil` means "proceed". Everything else is a `SyncTransportFailure` because the
    /// engine already knows how to present each one: `authenticationRequired` asks the
    /// user to sign in, and `unreachable` backs off and retries on its own.
    var syncBlockingFailure: SyncTransportFailure? {
        switch self {
        case .available:
            return nil
        case .noAccount:
            return .rejected(.authenticationRequired(
                detail: "no iCloud account is signed in on this device"))
        case .restricted:
            return .rejected(.authenticationRequired(
                detail: "iCloud is restricted on this device by a profile or parental control"))
        case .couldNotDetermine:
            // Not an auth failure: the usual cause is being offline, and telling someone
            // to sign in when they are merely on a train is worse than backing off.
            return .unreachable(detail: "could not determine the iCloud account status")
        case .temporarilyUnavailable:
            // Apple's guidance is explicit: do not delete cached data, do not enqueue
            // operations, wait for CKAccountChanged.
            return .unreachable(detail: "the iCloud account is temporarily unavailable")
        @unknown default:
            return .unreachable(detail: "unrecognised iCloud account status (\(rawValue))")
        }
    }
}
