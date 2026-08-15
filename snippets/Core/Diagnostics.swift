import Foundation

// This file is part of the Foundation-only core. CocoaLumberjack is deliberately
// hidden behind `DiagnosticsSink` in the app targets so the CLI and CorePackage do
// not acquire an app-only logging dependency or start writing diagnostics.

nonisolated enum DiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
    case fault
}

nonisolated enum DiagnosticCategory: String, Codable, Sendable {
    case app
    case persistence
    case sync
    case cloudKit = "cloudkit"
    case vault
    case integration
    case performance
    case metricKit = "metrickit"
    case diagnostics
}

nonisolated enum DiagnosticFailureFamily: String, Codable, Sendable {
    case cocoa
    case posix
    case url
    case security
    case mach
    case cloudKit = "cloudkit"
    case other
}

/// The only error representation allowed in persistent diagnostics.
///
/// `localizedDescription`, `userInfo`, reflected values, paths, record identifiers,
/// and the original error type are intentionally impossible to recover from this value.
nonisolated struct DiagnosticFailure: Codable, Equatable, Sendable {
    let family: DiagnosticFailureFamily
    let code: Int

    init(_ error: any Error) {
        let value = error as NSError
        family = switch value.domain {
        case NSCocoaErrorDomain: .cocoa
        case NSPOSIXErrorDomain: .posix
        case NSURLErrorDomain: .url
        case NSOSStatusErrorDomain: .security
        case NSMachErrorDomain: .mach
        case "CKErrorDomain": .cloudKit
        default: .other
        }
        code = value.code
    }

    init(family: DiagnosticFailureFamily, code: Int) {
        self.family = family
        self.code = code
    }
}

/// The secure-snippet keyword is product-approved diagnostic metadata. It remains
/// bounded so a malformed library cannot turn one event into an unbounded write.
nonisolated struct DiagnosticKeyword: Codable, Equatable, Sendable {
    static let maximumUTF8Length = 256

    let value: String
    let wasTruncated: Bool

    init(_ rawValue: String) {
        let normalized = Snippet.sanitizedKeyword(rawValue)
        var result = ""
        var byteCount = 0
        result.reserveCapacity(min(normalized.utf8.count, Self.maximumUTF8Length))

        for character in normalized {
            let candidate = String(character)
            let candidateByteCount = candidate.utf8.count
            guard byteCount + candidateByteCount <= Self.maximumUTF8Length else {
                break
            }
            result.append(character)
            byteCount += candidateByteCount
        }

        value = result
        wasTruncated = result != normalized
    }
}

nonisolated enum DiagnosticStorageArea: String, Codable, Sendable {
    case library
    case usage
    case syncState = "sync_state"
    case syncBase = "sync_base"
    case syncMetadata = "sync_metadata"
    case syncQuarantine = "sync_quarantine"
    case vault
    case vaultIdentity = "vault_identity"
    case syncKey = "sync_key"
    case controlSocket = "control_socket"
    case launchAtLogin = "launch_at_login"
    case globalHotkey = "global_hotkey"
}

nonisolated enum DiagnosticStorageOperation: String, Codable, Sendable {
    case read
    case write
    case lock
    case remove
    case publish
    case adopt
    case recover
    case start
    case register
}

nonisolated enum DiagnosticStorageState: String, Codable, Sendable {
    case versionTooNew = "version_too_new"
    case readOnly = "read_only"
    case recreated
    case degraded
    case recovered
    case removed
}

nonisolated enum DiagnosticLifecycle: String, Codable, Sendable {
    case started
    case becameActive = "became_active"
    case enteredBackground = "entered_background"
    case willSleep = "will_sleep"
    case willTerminate = "will_terminate"
    case memoryWarning = "memory_warning"
}

nonisolated enum DiagnosticCloudEnvironment: String, Codable, Sendable {
    case production
    case development
    case absent
    case unrecognized
}

nonisolated enum DiagnosticSyncTrigger: String, Codable, Sendable {
    case startup
    case manual
    case poll
    case becameActive = "became_active"
    case localLibraryChange = "local_library_change"
    case keyChanged = "key_changed"
    case retry
}

nonisolated enum DiagnosticSyncState: String, Codable, Sendable {
    case disabled
    case idle
    case syncing
    case synced
    case waiting
    case failed
    case halted
}

nonisolated enum DiagnosticSyncHaltReason: String, Codable, Sendable {
    case incompatibleState = "incompatible_state"
    case accountRequiresReview = "account_requires_review"
    case destructiveChange = "destructive_change"
    case missingLock = "missing_lock"
    case other
}

nonisolated enum DiagnosticCloudOperation: String, Codable, Sendable {
    case accountStatus = "account_status"
    case ensureZone = "ensure_zone"
    case fetchChanges = "fetch_changes"
    case fetchRecord = "fetch_record"
    case modifyRecords = "modify_records"
    case deleteZone = "delete_zone"
    case mapRecord = "map_record"
}

nonisolated enum DiagnosticVaultAction: String, Codable, Sendable {
    case loaded
    case locked
    case unlocked
    case readOnly = "read_only"
    case adoptedSharedIdentity = "adopted_shared_identity"
    case publishedSharedIdentity = "published_shared_identity"
    case removedSharedIdentity = "removed_shared_identity"
    case reconciledInterruptedMove = "reconciled_interrupted_move"
    case forgotLocalVault = "forgot_local_vault"
}

nonisolated enum DiagnosticSecureRevealOutcome: String, Codable, Sendable {
    case busy
    case rateLimited = "rate_limited"
    case denied
    case timedOut = "timed_out"
    case revealed
    case failed
    case other

    init(legacyValue: String) {
        self = switch legacyValue {
        case "busy": .busy
        case "rate-limited": .rateLimited
        case "denied": .denied
        case "timed-out": .timedOut
        case "revealed": .revealed
        case "failed": .failed
        default: .other
        }
    }
}

nonisolated enum DiagnosticCallerClass: String, Codable, Sendable {
    case trusted
    case untrusted
    case unknown
}

/// The iOS editor surface whose fail-closed reveal policy changed state.
nonisolated enum DiagnosticSecureEditorSurface: String, Codable, Sendable {
    case phone
    case tablet
}

/// Privacy-safe projection of `SecureSnippetRevealPolicy.State`.
nonisolated enum DiagnosticSecureEditorState: String, Codable, Sendable {
    case ordinary
    case locked
    case authenticating
    case authenticatedRedacted = "authenticated_redacted"
    case presentingPlaintext = "presenting_plaintext"
    case protectedPlaintext = "protected_plaintext"
    case failedClosed = "failed_closed"
}

/// Privacy-safe projection of `VaultSession.State` at an editor transition.
nonisolated enum DiagnosticVaultState: String, Codable, Sendable {
    case noKey = "no_key"
    case locked
    case unlocked
}

/// Closed causes for iOS secure-editor policy transitions. These deliberately carry
/// no record identity: ordering plus the editor surface is enough to diagnose why
/// visible plaintext was withdrawn without making snippets correlatable in exports.
nonisolated enum DiagnosticSecureEditorReason: String, Codable, Sendable {
    case editorBound = "editor_bound"
    case userRequested = "user_requested"
    case authenticationCompleted = "authentication_completed"
    case authenticationFailed = "authentication_failed"
    case authenticationCancelled = "authentication_cancelled"
    case appWillResignActive = "app_will_resign_active"
    case appDidBecomeActive = "app_did_become_active"
    case sceneWillDeactivate = "scene_will_deactivate"
    case sceneDidActivate = "scene_did_activate"
    case storeRefreshLocal = "store_refresh_local"
    case storeRefreshExternal = "store_refresh_external"
    case storeRefreshRemoteSync = "store_refresh_remote_sync"
    case vaultWillLock = "vault_will_lock"
    case vaultStateChanged = "vault_state_changed"
    case sceneCaptureChanged = "scene_capture_changed"
    case presentationConfirmed = "presentation_confirmed"
    case presentationRejected = "presentation_rejected"
    case presentationRevoked = "presentation_revoked"
    case rendererFailed = "renderer_failed"
    case rendererRecovered = "renderer_recovered"
    case environmentRejected = "environment_rejected"
    case snippetChanged = "snippet_changed"
    case snippetUnavailable = "snippet_unavailable"
    case modalPresentation = "modal_presentation"
    case selectionChanged = "selection_changed"
    case viewDisappeared = "view_disappeared"
}

nonisolated enum DiagnosticSuggestionAnchorSource: String, Codable, Sendable {
    case accessibility
    case caret
    case mouse
    case fallback
    case unknown
}

nonisolated enum DiagnosticSuggestionAnchorReason: String, Codable, Sendable {
    case success
    case unavailable
    case invalidGeometry = "invalid_geometry"
    case timedOut = "timed_out"
    case unknown
}

/// High-frequency expansion diagnostics are opt-in. Every value remains closed and
/// content-free so enabling verbose collection cannot persist what the user typed.
nonisolated enum DiagnosticExpansionAXOperation: String, Codable, Sendable {
    case activation
    case printableEdit = "printable_edit"
    case hostEdit = "host_edit"
    case acceptance
    case observerRegistration = "observer_registration"
    case observerNotification = "observer_notification"
    case secureRevalidation = "secure_revalidation"
}

nonisolated enum DiagnosticExpansionAXOutcome: String, Codable, Sendable {
    case confirmed
    case localTracking = "local_tracking"
    case missingTrigger = "missing_trigger"
    case unavailable
    case stale
    case unsafe
    case observing
}

nonisolated enum DiagnosticExpansionContextState: String, Codable, Sendable {
    case axConfirmed = "ax_confirmed"
    case localDisplayOnly = "local_display_only"
    case uncertainAfterHostEdit = "uncertain_after_host_edit"
}

nonisolated enum DiagnosticExpansionAXStage: String, Codable, Sendable {
    case application
    case focusedElement = "focused_element"
    case selectedRange = "selected_range"
    case rangeText = "range_text"
    case value
    case observerCreation = "observer_creation"
    case valueNotification = "value_notification"
    case selectionNotification = "selection_notification"
}

nonisolated enum DiagnosticExpansionAXFailure: String, Codable, Sendable {
    case noApplication = "no_application"
    case notTrusted = "not_trusted"
    case attributeUnsupported = "attribute_unsupported"
    case noValue = "no_value"
    case cannotComplete = "cannot_complete"
    case notImplemented = "not_implemented"
    case invalidElement = "invalid_element"
    case invalidType = "invalid_type"
    case invalidRange = "invalid_range"
    case notificationUnsupported = "notification_unsupported"
    case alreadyRegistered = "already_registered"
    case apiDisabled = "api_disabled"
    case other
}

nonisolated enum DiagnosticMetricKind: String, Codable, Sendable {
    case crash
    case hang
    case cpuException = "cpu_exception"
    case diskWriteException = "disk_write_exception"
}

nonisolated enum DiagnosticMaintenanceAction: String, Codable, Sendable {
    case exportStarted = "export_started"
    case exportCompleted = "export_completed"
    case exportFailed = "export_failed"
    case retentionPruned = "retention_pruned"
    case legacyAuditMigrated = "legacy_audit_migrated"
    case legacyAuditMigrationFailed = "legacy_audit_migration_failed"
}

/// JSON values are created only by the closed event mapping below and by the
/// allow-listing MetricKit sanitizer in the app backend.
nonisolated indirect enum DiagnosticJSONValue: Encodable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case unsigned(UInt64)
    case double(Double)
    case boolean(Bool)
    case array([DiagnosticJSONValue])
    case object([String: DiagnosticJSONValue])
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

nonisolated struct DiagnosticAppContext: Equatable, Sendable {
    let version: String
    let build: String
    let bundleIdentifier: String
    let platform: String
    let operatingSystem: String
    let architecture: String
    let cloudEnvironment: DiagnosticCloudEnvironment
    let syncEnabled: Bool
}

nonisolated struct DiagnosticSyncRound: Equatable, Sendable {
    var durationMilliseconds: Int64
    var downloaded: Int
    var uploaded: Int
    var merged: Int
    var deferred: Int
    var quarantined: Int
    var fullResync: Bool

    init(
        durationMilliseconds: Int64,
        downloaded: Int = 0,
        uploaded: Int = 0,
        merged: Int = 0,
        deferred: Int = 0,
        quarantined: Int = 0,
        fullResync: Bool = false
    ) {
        self.durationMilliseconds = durationMilliseconds
        self.downloaded = downloaded
        self.uploaded = uploaded
        self.merged = merged
        self.deferred = deferred
        self.quarantined = quarantined
        self.fullResync = fullResync
    }
}

nonisolated struct DiagnosticMetric: Equatable, Sendable {
    let kind: DiagnosticMetricKind
    let durationMilliseconds: Int64?
    let primaryValue: Double?
    let exceptionType: Int64?
    let exceptionCode: Int64?
    let signal: Int64?
    let callStack: DiagnosticJSONValue?
    let wasTruncated: Bool
}

nonisolated struct DiagnosticExportManifest: Equatable, Sendable {
    let app: DiagnosticAppContext
    let exportedAt: String
    let oldestEntryAt: String?
    let newestEntryAt: String?
    let fileCount: Int
    let byteCount: UInt64
    let skippedTrailingLines: Int
}

/// Closed vocabulary for every value that can reach persistent diagnostics.
nonisolated enum DiagnosticEvent: Equatable, Sendable {
    case appStarted(DiagnosticAppContext)
    case lifecycle(DiagnosticLifecycle)
    case storageFailure(
        area: DiagnosticStorageArea,
        operation: DiagnosticStorageOperation,
        failure: DiagnosticFailure,
        attempt: Int?
    )
    case storageState(area: DiagnosticStorageArea, state: DiagnosticStorageState, value: Int?)
    case libraryMerge(conflictCopies: Int, keywordCollisions: Int)
    case syncTriggered(DiagnosticSyncTrigger)
    case syncState(DiagnosticSyncState, haltReason: DiagnosticSyncHaltReason?)
    case syncRound(DiagnosticSyncRound)
    case cloudKitFailure(operation: DiagnosticCloudOperation, failure: DiagnosticFailure)
    case cloudKitBatchSplit(recordCount: Int)
    case cloudKitRecordsIgnored(count: Int)
    case vaultAction(DiagnosticVaultAction, count: Int?)
    case secureReveal(keyword: DiagnosticKeyword, outcome: DiagnosticSecureRevealOutcome, caller: DiagnosticCallerClass)
    case secureEditorTransition(
        surface: DiagnosticSecureEditorSurface,
        from: DiagnosticSecureEditorState,
        to: DiagnosticSecureEditorState,
        reason: DiagnosticSecureEditorReason,
        vaultState: DiagnosticVaultState
    )
    case suggestionAnchor(
        source: DiagnosticSuggestionAnchorSource,
        reason: DiagnosticSuggestionAnchorReason,
        durationMilliseconds: Int64
    )
    case expansionAccessibility(
        operation: DiagnosticExpansionAXOperation,
        outcome: DiagnosticExpansionAXOutcome,
        stateBefore: DiagnosticExpansionContextState,
        stateAfter: DiagnosticExpansionContextState,
        stage: DiagnosticExpansionAXStage?,
        failure: DiagnosticExpansionAXFailure?,
        axErrorCode: Int?,
        queryLength: Int
    )
    case metricKit(DiagnosticMetric)
    case diagnosticsMaintenance(DiagnosticMaintenanceAction, count: Int?)
    case diagnosticsManifest(DiagnosticExportManifest)

    var category: DiagnosticCategory {
        switch self {
        case .appStarted, .lifecycle: .app
        case .storageFailure, .storageState, .libraryMerge: .persistence
        case .syncTriggered, .syncState, .syncRound: .sync
        case .cloudKitFailure, .cloudKitBatchSplit, .cloudKitRecordsIgnored: .cloudKit
        case .vaultAction, .secureReveal, .secureEditorTransition: .vault
        case .suggestionAnchor: .performance
        case .expansionAccessibility: .integration
        case .metricKit: .metricKit
        case .diagnosticsMaintenance, .diagnosticsManifest: .diagnostics
        }
    }

    var name: String {
        switch self {
        case .appStarted: "app_started"
        case .lifecycle: "app_lifecycle"
        case .storageFailure: "storage_failure"
        case .storageState: "storage_state"
        case .libraryMerge: "library_merge"
        case .syncTriggered: "sync_triggered"
        case .syncState: "sync_state"
        case .syncRound: "sync_round"
        case .cloudKitFailure: "cloudkit_failure"
        case .cloudKitBatchSplit: "cloudkit_batch_split"
        case .cloudKitRecordsIgnored: "cloudkit_records_ignored"
        case .vaultAction: "vault_action"
        case .secureReveal: "secure_reveal"
        case .secureEditorTransition: "secure_editor_transition"
        case .suggestionAnchor: "suggestion_anchor"
        case .expansionAccessibility: "expansion_accessibility"
        case .metricKit: "metrickit_diagnostic"
        case .diagnosticsMaintenance: "diagnostics_maintenance"
        case .diagnosticsManifest: "diagnostics_manifest"
        }
    }

    var defaultLevel: DiagnosticLevel {
        switch self {
        case .storageFailure, .cloudKitFailure:
            .error
        case .expansionAccessibility:
            .debug
        case .syncState(.halted, _):
            .fault
        case .storageState(_, .versionTooNew, _),
             .storageState(_, .readOnly, _),
             .storageState(_, .degraded, _),
             .cloudKitRecordsIgnored,
             .diagnosticsMaintenance(.legacyAuditMigrationFailed, _):
            .warning
        default:
            .info
        }
    }

    var requiresSynchronousWrite: Bool {
        switch self {
        case .storageFailure,
             .cloudKitFailure,
             .syncState(.halted, _),
             .secureReveal,
             .metricKit:
            true
        case .secureEditorTransition(_, let from, let to, _, _):
            from == .presentingPlaintext
                || from == .protectedPlaintext
                || to == .protectedPlaintext
                || to == .failedClosed
        default:
            false
        }
    }

    var fields: [String: DiagnosticJSONValue] {
        switch self {
        case .appStarted(let app):
            return app.fields
        case .lifecycle(let state):
            return ["state": .string(state.rawValue)]
        case .storageFailure(let area, let operation, let failure, let attempt):
            var fields = failure.fields
            fields["area"] = .string(area.rawValue)
            fields["operation"] = .string(operation.rawValue)
            if let attempt { fields["attempt"] = .integer(Int64(attempt)) }
            return fields
        case .storageState(let area, let state, let value):
            var fields: [String: DiagnosticJSONValue] = [
                "area": .string(area.rawValue),
                "state": .string(state.rawValue),
            ]
            if let value { fields["value"] = .integer(Int64(value)) }
            return fields
        case .libraryMerge(let conflictCopies, let keywordCollisions):
            return [
                "conflict_copies": .integer(Int64(conflictCopies)),
                "keyword_collisions": .integer(Int64(keywordCollisions)),
            ]
        case .syncTriggered(let trigger):
            return ["trigger": .string(trigger.rawValue)]
        case .syncState(let state, let haltReason):
            var fields: [String: DiagnosticJSONValue] = ["state": .string(state.rawValue)]
            if let haltReason { fields["halt_reason"] = .string(haltReason.rawValue) }
            return fields
        case .syncRound(let round):
            return [
                "duration_ms": .integer(round.durationMilliseconds),
                "downloaded": .integer(Int64(round.downloaded)),
                "uploaded": .integer(Int64(round.uploaded)),
                "merged": .integer(Int64(round.merged)),
                "deferred": .integer(Int64(round.deferred)),
                "quarantined": .integer(Int64(round.quarantined)),
                "full_resync": .boolean(round.fullResync),
            ]
        case .cloudKitFailure(let operation, let failure):
            var fields = failure.fields
            fields["operation"] = .string(operation.rawValue)
            return fields
        case .cloudKitBatchSplit(let recordCount):
            return ["record_count": .integer(Int64(recordCount))]
        case .cloudKitRecordsIgnored(let count):
            return ["count": .integer(Int64(count))]
        case .vaultAction(let action, let count):
            var fields: [String: DiagnosticJSONValue] = ["action": .string(action.rawValue)]
            if let count { fields["count"] = .integer(Int64(count)) }
            return fields
        case .secureReveal(let keyword, let outcome, let caller):
            return [
                "keyword": .string(keyword.value),
                "keyword_truncated": .boolean(keyword.wasTruncated),
                "outcome": .string(outcome.rawValue),
                "caller": .string(caller.rawValue),
            ]
        case .secureEditorTransition(let surface, let from, let to, let reason, let vaultState):
            return [
                "surface": .string(surface.rawValue),
                "from_state": .string(from.rawValue),
                "to_state": .string(to.rawValue),
                "reason": .string(reason.rawValue),
                "vault_state": .string(vaultState.rawValue),
            ]
        case .suggestionAnchor(let source, let reason, let durationMilliseconds):
            return [
                "source": .string(source.rawValue),
                "reason": .string(reason.rawValue),
                "duration_ms": .integer(durationMilliseconds),
            ]
        case .expansionAccessibility(
            let operation,
            let outcome,
            let stateBefore,
            let stateAfter,
            let stage,
            let failure,
            let axErrorCode,
            let queryLength
        ):
            var fields: [String: DiagnosticJSONValue] = [
                "operation": .string(operation.rawValue),
                "outcome": .string(outcome.rawValue),
                "state_before": .string(stateBefore.rawValue),
                "state_after": .string(stateAfter.rawValue),
                "query_length": .integer(Int64(max(0, queryLength))),
            ]
            if let stage { fields["stage"] = .string(stage.rawValue) }
            if let failure { fields["failure"] = .string(failure.rawValue) }
            if let axErrorCode { fields["ax_error_code"] = .integer(Int64(axErrorCode)) }
            return fields
        case .metricKit(let metric):
            var fields: [String: DiagnosticJSONValue] = [
                "kind": .string(metric.kind.rawValue),
                "truncated": .boolean(metric.wasTruncated),
            ]
            if let value = metric.durationMilliseconds { fields["duration_ms"] = .integer(value) }
            if let value = metric.primaryValue, value.isFinite { fields["value"] = .double(value) }
            if let value = metric.exceptionType { fields["exception_type"] = .integer(value) }
            if let value = metric.exceptionCode { fields["exception_code"] = .integer(value) }
            if let value = metric.signal { fields["signal"] = .integer(value) }
            if let value = metric.callStack { fields["call_stack"] = value }
            return fields
        case .diagnosticsMaintenance(let action, let count):
            var fields: [String: DiagnosticJSONValue] = ["action": .string(action.rawValue)]
            if let count { fields["count"] = .integer(Int64(count)) }
            return fields
        case .diagnosticsManifest(let manifest):
            var fields = manifest.app.fields
            fields["exported_at"] = .string(manifest.exportedAt)
            fields["oldest_entry_at"] = manifest.oldestEntryAt.map(DiagnosticJSONValue.string) ?? .null
            fields["newest_entry_at"] = manifest.newestEntryAt.map(DiagnosticJSONValue.string) ?? .null
            fields["file_count"] = .integer(Int64(manifest.fileCount))
            fields["byte_count"] = .unsigned(manifest.byteCount)
            fields["skipped_trailing_lines"] = .integer(Int64(manifest.skippedTrailingLines))
            return fields
        }
    }
}

nonisolated private extension DiagnosticFailure {
    var fields: [String: DiagnosticJSONValue] {
        [
            "error_family": .string(family.rawValue),
            "error_code": .integer(Int64(code)),
        ]
    }
}

nonisolated private extension DiagnosticAppContext {
    var fields: [String: DiagnosticJSONValue] {
        [
            "app_version": .string(version),
            "app_build": .string(build),
            "bundle_id": .string(bundleIdentifier),
            "platform": .string(platform),
            "os": .string(operatingSystem),
            "architecture": .string(architecture),
            "cloud_environment": .string(cloudEnvironment.rawValue),
            "sync_enabled": .boolean(syncEnabled),
        ]
    }
}

nonisolated struct DiagnosticRecord: Encodable, Equatable, Sendable {
    static let schemaVersion = 1

    let schema: Int
    let timestamp: String
    let elapsedMilliseconds: Int64
    let sessionIdentifier: String
    let sequence: UInt64
    let level: DiagnosticLevel
    let category: DiagnosticCategory
    let event: String
    let fields: [String: DiagnosticJSONValue]

    init(
        event: DiagnosticEvent,
        timestamp: String,
        elapsedMilliseconds: Int64,
        sessionIdentifier: String,
        sequence: UInt64,
        level: DiagnosticLevel? = nil
    ) {
        schema = Self.schemaVersion
        self.timestamp = timestamp
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.sessionIdentifier = sessionIdentifier
        self.sequence = sequence
        self.level = level ?? event.defaultLevel
        category = event.category
        self.event = event.name
        fields = event.fields
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case timestamp
        case elapsedMilliseconds = "elapsed_ms"
        case sessionIdentifier = "session_id"
        case sequence
        case level
        case category
        case event
        case fields
    }

    func jsonLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }
}

nonisolated protocol DiagnosticsSink: AnyObject, Sendable {
    func emit(_ event: DiagnosticEvent, level: DiagnosticLevel, synchronous: Bool)
    func flush()
}

nonisolated private final class DiagnosticsRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (any DiagnosticsSink)?

    func install(_ newSink: (any DiagnosticsSink)?) {
        lock.lock()
        sink = newSink
        lock.unlock()
    }

    func emit(_ event: DiagnosticEvent, level: DiagnosticLevel, synchronous: Bool) {
        lock.lock()
        let current = sink
        lock.unlock()
        current?.emit(event, level: level, synchronous: synchronous)
    }

    func flush() {
        lock.lock()
        let current = sink
        lock.unlock()
        current?.flush()
    }
}

nonisolated enum Diagnostics {
    private static let registry = DiagnosticsRegistry()

    static func install(_ sink: (any DiagnosticsSink)?) {
        registry.install(sink)
    }

    static func record(_ event: DiagnosticEvent) {
        registry.emit(
            event,
            level: event.defaultLevel,
            synchronous: event.requiresSynchronousWrite)
    }

    static func flush() {
        registry.flush()
    }
}
