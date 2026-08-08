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
            return .permanent(detail: "\(error)")
        }

        switch ckError.code {

        // The one that matters most: another device wrote this record after the view
        // this batch was built from. Re-merge and retry, which is what the three-way
        // merge on the fetch leg is for.
        case .serverRecordChanged:
            return .conflict(remoteRev: remoteRev(from: ckError))

        // Time-based back-pressure. CloudKit states the delay; honour it rather than
        // guessing, or the retry contributes to the condition it is waiting out.
        case .requestRateLimited, .zoneBusy, .serviceUnavailable,
             .accountTemporarilyUnavailable:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // The user has to do something. Retrying on a timer cannot fix any of these and
        // repeatedly hitting a locked account is how it gets throttled.
        case .notAuthenticated, .permissionFailure, .managedAccountRestricted:
            return .authenticationRequired(detail: ckError.localizedDescription)

        // Configuration or code, not data. `missingEntitlement` in particular means the
        // build is not provisioned for CloudKit at all, which no retry reaches.
        case .missingEntitlement, .badContainer, .badDatabase, .invalidArguments,
             .incompatibleVersion, .constraintViolation, .referenceViolation,
             .serverRejectedRequest, .internalError:
            return .permanent(detail: ckError.localizedDescription)

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

        // The zone or its contents went away underneath us. Not a per-record condition;
        // the fetch path turns these into a full resync. If one arrives here, a retry
        // after the transport re-creates the zone is the right response.
        case .zoneNotFound, .userDeletedZone, .changeTokenExpired, .unknownItem:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // Cancellation is not a failure of the record.
        case .operationCancelled:
            return .rateLimited(retryAfter: retryAfter(from: ckError))

        // Sharing and assets. This transport creates neither, so these mean the schema
        // is not what this build thinks it is.
        case .alreadyShared, .tooManyParticipants, .participantMayNeedVerification,
             .assetFileNotFound, .assetFileModified, .assetNotAvailable,
             .resultsTruncated, .partialFailure:
            return .permanent(detail: ckError.localizedDescription)

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
            return .unreachable(detail: "\(error)")
        }

        switch ckError.code {
        case .networkUnavailable, .networkFailure, .serverResponseLost, .internalError:
            return .unreachable(detail: ckError.localizedDescription)
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

    /// Whether a batch should be split and retried rather than reported.
    static func isBatchTooLarge(_ error: any Error) -> Bool {
        guard let ckError = error as? CKError else { return false }
        return ckError.code == .limitExceeded
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

    /// The revision CloudKit holds, when it discloses it.
    ///
    /// Supplying it turns a fetch-merge-resubmit round trip into a single fetch, which is
    /// why `SyncRejection.conflict` carries it. Read from the *server* record, never the
    /// client one — the client record is the value we just tried and failed to write.
    static func remoteRev(from error: CKError) -> String? {
        guard let server = error.serverRecord else { return nil }
        return server[CloudKitSchema.Field.rev] as? String
    }

    /// Unwraps `partialFailure` into the per-item errors the engine can act on.
    static func partialErrors(in error: any Error) -> [CKRecord.ID: any Error]? {
        guard let ckError = error as? CKError, ckError.code == .partialFailure else {
            return nil
        }
        return ckError.partialErrorsByItemID as? [CKRecord.ID: any Error]
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
                detail: "no iCloud account is signed in on this Mac"))
        case .restricted:
            return .rejected(.authenticationRequired(
                detail: "iCloud is restricted on this Mac by a profile or parental control"))
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
