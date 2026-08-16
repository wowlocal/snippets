import CocoaLumberjack
import CoreFoundation
import Darwin
import Foundation
import MetricKit
#if os(macOS)
import Security
#endif

nonisolated struct DiagnosticsSummary: Sendable {
    let fileCount: Int
    let byteCount: UInt64
    let oldestDate: Date?
    let newestDate: Date?
    let storageAvailable: Bool
    let privacyCleanupNeeded: Bool
}

nonisolated struct DiagnosticsExportResult: Sendable {
    let url: URL
    let recordCount: Int
    let byteCount: UInt64
    let skippedTrailingLines: Int
}

nonisolated enum ExpansionVerboseLoggingMode: String, CaseIterable, Sendable {
    case off
    case session
    case always

    var title: String {
        switch self {
        case .off: "Off"
        case .session: "This Session"
        case .always: "Always"
        }
    }
}

/// Owns the opt-in for high-frequency Accessibility expansion diagnostics.
/// `.session` deliberately lives only in memory; `.always` is the sole mode
/// persisted across launches.
nonisolated final class ExpansionVerboseLoggingPreference: @unchecked Sendable {
    static let defaultsKey = "SnippetsExpansionVerboseDiagnosticsEnabled"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var storedMode: ExpansionVerboseLoggingMode

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedMode = defaults.bool(forKey: Self.defaultsKey) ? .always : .off
    }

    var mode: ExpansionVerboseLoggingMode {
        lock.lock()
        defer { lock.unlock() }
        return storedMode
    }

    var isEnabled: Bool { mode != .off }

    func setMode(_ mode: ExpansionVerboseLoggingMode) {
        lock.lock()
        defer { lock.unlock() }
        storedMode = mode

        if mode == .always {
            defaults.set(true, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

nonisolated enum DiagnosticsExportError: LocalizedError {
    case storageUnavailable
    case corruptLog
    case exportTooLarge
    case cannotWrite

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            "The diagnostics folder is unavailable."
        case .corruptLog:
            "A diagnostics file is malformed and could not be exported safely."
        case .exportTooLarge:
            "The diagnostics export exceeds the 25 MB safety limit."
        case .cannotWrite:
            "The diagnostics export could not be written."
        }
    }
}

/// A file manager with a deliberately narrow namespace. Files elsewhere in
/// `Diagnostics/` are never adopted into rotation by CocoaLumberjack.
nonisolated private final class DiagnosticsLogFileManager: DDLogFileManagerDefault, @unchecked Sendable {
    override var newLogFileName: String {
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1_000)
        return "snippets-\(milliseconds)-\(UUID().uuidString.lowercased()).jsonl"
    }

    override func isLogFile(withName fileName: String) -> Bool {
        (fileName.hasPrefix("snippets-") || fileName == "legacy-audit-v1.jsonl")
            && fileName.hasSuffix(".jsonl")
    }

    override func createNewLogFile() throws -> String {
        let path = try super.createNewLogFile()
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return path
    }
}

nonisolated private final class RawJSONLogFormatter: NSObject, DDLogFormatter, @unchecked Sendable {
    func format(message logMessage: DDLogMessage) -> String? {
        logMessage.message
    }
}

nonisolated private final class DiagnosticsTimestampFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

/// The app-only diagnostics backend. Core code sees only `DiagnosticsSink`, keeping
/// CocoaLumberjack, MetricKit, entitlements, and platform storage out of CorePackage
/// and the CLI target.
nonisolated final class DiagnosticsService: NSObject, DiagnosticsSink, @unchecked Sendable {
    /// The application-wide backend. CocoaLumberjack and MetricKit are process-wide,
    /// so production code must not create one logger graph per `AppEnvironment`.
    static let shared = DiagnosticsService(registerGlobally: true, mirrorToOSLog: true)

    static let retentionDays = 14
    static let maximumFileSize: UInt64 = 1 * 1_024 * 1_024
    static let maximumFileCount = 64
    static let diskQuota: UInt64 = 24 * 1_024 * 1_024
    static let maximumExportSize: UInt64 = 25 * 1_024 * 1_024
    private static let timestampFormatter = DiagnosticsTimestampFormatter()

    let expansionVerboseLogging: ExpansionVerboseLoggingPreference

    private let fileManager: FileManager
    private let log = DDLog()
    private let logFileManager: DiagnosticsLogFileManager
    private let fileLogger: DDFileLogger
    private let sessionIdentifier = UUID().uuidString.lowercased()
    private let startedAtUptime = ProcessInfo.processInfo.systemUptime
    private let stateLock = NSLock()
    private let appContextLock = NSLock()
    private var cachedAppContext: DiagnosticAppContext?
    private let maintenanceQueue = DispatchQueue(
        label: "com.khm.snippets.diagnostics.maintenance",
        qos: .utility)
    private var sequence: UInt64 = 0
    private var privacyCleanupNeeded = false
    private var maintenanceTimer: DispatchSourceTimer?
    private let storageWasCreated: Bool
    private let retentionDayCount: Int
    private let registersGlobally: Bool
    private let mirrorsToOSLog: Bool

    init(
        fileManager: FileManager = .default,
        retentionDays: Int = DiagnosticsService.retentionDays,
        maximumFileSize: UInt64 = DiagnosticsService.maximumFileSize,
        maximumFileCount: Int = DiagnosticsService.maximumFileCount,
        diskQuota: UInt64 = DiagnosticsService.diskQuota,
        registerGlobally: Bool,
        mirrorToOSLog: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        expansionVerboseLogging = ExpansionVerboseLoggingPreference(defaults: userDefaults)
        retentionDayCount = max(1, retentionDays)
        registersGlobally = registerGlobally
        mirrorsToOSLog = mirrorToOSLog
        let diagnosticsURL = SnippetStorageLocations.diagnosticsFolderURL
        let logsURL = SnippetStorageLocations.diagnosticsLogsFolderURL
        var created = true
        do {
            try fileManager.createDirectory(
                at: logsURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.createDirectory(
                at: SnippetStorageLocations.tmpFolderURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: diagnosticsURL.path)
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: logsURL.path)
            #if os(iOS)
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
            try fileManager.setAttributes(protection, ofItemAtPath: diagnosticsURL.path)
            try fileManager.setAttributes(protection, ofItemAtPath: logsURL.path)
            #endif
            Self.excludeFromBackup(diagnosticsURL)
        } catch {
            created = false
        }
        storageWasCreated = created

        #if os(iOS)
        logFileManager = DiagnosticsLogFileManager(
            logsDirectory: logsURL.path,
            defaultFileProtectionLevel: .completeUntilFirstUserAuthentication)
        #else
        logFileManager = DiagnosticsLogFileManager(logsDirectory: logsURL.path)
        #endif
        logFileManager.maximumNumberOfLogFiles = UInt(max(1, maximumFileCount))
        logFileManager.logFilesDiskQuota = max(maximumFileSize, diskQuota)

        fileLogger = DDFileLogger(logFileManager: logFileManager)
        fileLogger.maximumFileSize = max(1_024, maximumFileSize)
        fileLogger.rollingFrequency = 24 * 60 * 60
        fileLogger.doNotReuseLogFiles = true
        fileLogger.automaticallyAppendNewlineForCustomFormatters = true
        fileLogger.logFormatter = RawJSONLogFormatter()

        super.init()

        log.add(fileLogger)
        if mirrorToOSLog {
            log.add(DDOSLogger.sharedInstance)
        }
        if registerGlobally {
            Diagnostics.install(self)
        }
        startMaintenanceTimer()
        // Directory creation above is launch-critical: SnippetStore's macOS vnode
        // observer must see the final folder layout. Retention scans, legacy migration,
        // timestamp formatter warm-up, and a synchronous logger flush are not. Keep
        // their ordering, but run them on the existing serial maintenance queue so
        // neither AppKit nor UIKit waits for disk housekeeping before its first frame.
        if registerGlobally {
            maintenanceQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                MXMetricManager.shared.add(self)
                self.emit(.appStarted(self.appContext), level: .info, synchronous: true)
                self.removeStaleTemporaryExports()
                self.hardenAndPrune()
                self.migrateLegacyAuditIfNeeded()
            }
        } else {
            // Isolated services are test/support tools with synchronous construction
            // semantics: callers may inspect retention or migration immediately.
            emit(.appStarted(appContext), level: .info, synchronous: true)
            removeStaleTemporaryExports()
            hardenAndPrune()
            migrateLegacyAuditIfNeeded()
        }
    }

    private var appContext: DiagnosticAppContext {
        appContextLock.lock()
        defer { appContextLock.unlock() }
        if let cachedAppContext { return cachedAppContext }
        let context = Self.makeAppContext()
        cachedAppContext = context
        return context
    }

    deinit {
        maintenanceTimer?.cancel()
        if registersGlobally {
            MXMetricManager.shared.remove(self)
            Diagnostics.install(nil)
        }
        log.flushLog()
        log.remove(fileLogger)
        if mirrorsToOSLog {
            log.remove(DDOSLogger.sharedInstance)
        }
    }

    func emit(_ event: DiagnosticEvent, level: DiagnosticLevel, synchronous: Bool) {
        let now = Date()
        let record: DiagnosticRecord

        stateLock.lock()
        sequence &+= 1
        record = DiagnosticRecord(
            event: event,
            timestamp: Self.timestamp(now),
            elapsedMilliseconds: Int64(max(
                0,
                (ProcessInfo.processInfo.systemUptime - startedAtUptime) * 1_000)),
            sessionIdentifier: sessionIdentifier,
            sequence: sequence,
            level: level)
        stateLock.unlock()

        guard let line = try? record.jsonLine(),
              var text = String(data: line, encoding: .utf8)
        else { return }
        if text.hasSuffix("\n") { text.removeLast() }

        let message = DDLogMessage(
            format: "%@",
            formatted: text,
            level: .all,
            flag: Self.logFlag(for: level),
            context: 0,
            file: "Diagnostics",
            function: nil,
            line: 0,
            tag: event.category.rawValue,
            options: [.copyFile],
            timestamp: now)
        log.log(asynchronous: !synchronous, message: message)

        if synchronous {
            log.flushLog()
            hardenLogFiles()
        }
    }

    func flush() {
        log.flushLog()
        hardenLogFiles()
    }

    func summary() -> DiagnosticsSummary {
        flush()
        let snapshots = logSnapshots()
        stateLock.lock()
        let cleanupNeeded = privacyCleanupNeeded
        stateLock.unlock()
        return DiagnosticsSummary(
            fileCount: snapshots.count,
            byteCount: snapshots.reduce(0) { $0 &+ $1.size },
            oldestDate: snapshots.compactMap(\.date).min(),
            newestDate: snapshots.compactMap(\.date).max(),
            storageAvailable: storageWasCreated,
            privacyCleanupNeeded: cleanupNeeded)
    }

    func export(to destination: URL) async throws -> DiagnosticsExportResult {
        Diagnostics.record(.diagnosticsMaintenance(.exportStarted, count: nil))
        flush()
        await rollCurrentFile()
        flush()

        do {
            let result = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<DiagnosticsExportResult, any Error>) in
                maintenanceQueue.async { [self] in
                    do {
                        hardenAndPrune()
                        continuation.resume(returning: try makeExport(at: destination))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            Diagnostics.record(.diagnosticsMaintenance(
                .exportCompleted,
                count: result.recordCount))
            return result
        } catch {
            Diagnostics.record(.diagnosticsMaintenance(.exportFailed, count: nil))
            throw error
        }
    }

    func deleteStoredLogs() async {
        flush()
        await rollCurrentFile()
        flush()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            maintenanceQueue.async { [self] in
                for path in logFileManager.unsortedLogFilePaths {
                    try? fileManager.removeItem(atPath: path)
                }
                let legacyAudit = SnippetStorageLocations.vaultAuditFileURL
                var legacyCleanupSucceeded = true
                if fileManager.fileExists(atPath: legacyAudit.path) {
                    do {
                        try fileManager.removeItem(at: legacyAudit)
                    } catch {
                        legacyCleanupSucceeded = false
                    }
                }
                stateLock.lock()
                privacyCleanupNeeded = !legacyCleanupSucceeded
                stateLock.unlock()
                continuation.resume()
            }
        }
    }

    static func suggestedExportFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Snippets-Diagnostics-\(formatter.string(from: now)).jsonl"
    }

    // MARK: - Export

    private struct LogSnapshot {
        let url: URL
        let date: Date?
        let size: UInt64
    }

    private struct ExportLine {
        let timestamp: String
        let session: String
        let sequence: UInt64
        let data: Data
    }

    private struct ExportEventSchema: Sendable {
        let category: String
        let requiredFields: Set<String>
        let optionalFields: Set<String>

        init(category: String, required: Set<String>, optional: Set<String> = []) {
            self.category = category
            requiredFields = required
            optionalFields = optional
        }
    }

    private static let exportTopLevelFields: Set<String> = [
        "schema", "timestamp", "elapsed_ms", "session_id", "sequence",
        "level", "category", "event", "fields",
    ]
    private static let exportAppFields: Set<String> = [
        "app_version", "app_build", "bundle_id", "platform", "os",
        "architecture", "cloud_environment", "sync_enabled",
    ]
    private static let exportEventSchemas: [String: ExportEventSchema] = [
        "app_started": ExportEventSchema(category: "app", required: exportAppFields),
        "app_lifecycle": ExportEventSchema(category: "app", required: ["state"]),
        "storage_failure": ExportEventSchema(
            category: "persistence",
            required: ["area", "operation", "error_family", "error_code"],
            optional: ["attempt"]),
        "storage_state": ExportEventSchema(
            category: "persistence", required: ["area", "state"], optional: ["value"]),
        "library_merge": ExportEventSchema(
            category: "persistence", required: ["conflict_copies", "keyword_collisions"]),
        "sync_triggered": ExportEventSchema(category: "sync", required: ["trigger"]),
        "sync_state": ExportEventSchema(
            category: "sync", required: ["state"], optional: ["halt_reason"]),
        "sync_round": ExportEventSchema(
            category: "sync",
            required: [
                "duration_ms", "downloaded", "uploaded", "merged", "deferred",
                "quarantined", "full_resync",
            ]),
        "cloudkit_failure": ExportEventSchema(
            category: "cloudkit", required: ["operation", "error_family", "error_code"]),
        "cloudkit_batch_split": ExportEventSchema(
            category: "cloudkit", required: ["record_count"]),
        "cloudkit_records_ignored": ExportEventSchema(
            category: "cloudkit", required: ["count"]),
        "cloudkit_sync_event": ExportEventSchema(
            category: "cloudkit",
            required: [
                "kind", "record_count", "fetch_depth", "submit_active",
                "full_resync", "generation_sealed",
            ]),
        "cloudkit_scheduler_transition": ExportEventSchema(
            category: "cloudkit",
            required: [
                "action", "full_resync", "pending_generation_count",
                "unready_generation_count",
            ],
            optional: ["reason"]),
        "vault_action": ExportEventSchema(
            category: "vault", required: ["action"], optional: ["count"]),
        "secure_reveal": ExportEventSchema(
            category: "vault",
            required: ["keyword", "keyword_truncated", "outcome", "caller"]),
        "secure_editor_transition": ExportEventSchema(
            category: "vault",
            required: ["surface", "from_state", "to_state", "reason", "vault_state"]),
        "suggestion_anchor": ExportEventSchema(
            category: "performance", required: ["source", "reason", "duration_ms"]),
        "expansion_accessibility": ExportEventSchema(
            category: "integration",
            required: [
                "operation", "outcome", "state_before", "state_after", "query_length",
            ],
            optional: ["stage", "failure", "ax_error_code"]),
        "metrickit_diagnostic": ExportEventSchema(
            category: "metrickit",
            required: ["kind", "truncated"],
            optional: [
                "duration_ms", "value", "exception_type", "exception_code", "signal",
                "call_stack",
            ]),
        "diagnostics_maintenance": ExportEventSchema(
            category: "diagnostics", required: ["action"], optional: ["count"]),
        "diagnostics_manifest": ExportEventSchema(
            category: "diagnostics",
            required: exportAppFields.union([
                "exported_at", "oldest_entry_at", "newest_entry_at", "file_count",
                "byte_count", "skipped_trailing_lines",
            ])),
    ]

    private static let exportStringFields: Set<String> = [
        "app_version", "app_build", "bundle_id", "platform", "os", "architecture",
        "cloud_environment", "state", "area", "operation", "error_family", "trigger",
        "halt_reason", "action", "keyword", "outcome", "caller", "source", "reason",
        "kind", "surface", "from_state", "to_state", "vault_state",
        "state_before", "state_after", "stage", "failure", "exported_at",
        "oldest_entry_at", "newest_entry_at",
    ]
    private static let exportBooleanFields: Set<String> = [
        "sync_enabled", "full_resync", "keyword_truncated", "truncated",
        "submit_active", "generation_sealed",
    ]
    private static let exportNumericFields: Set<String> = [
        "error_code", "attempt", "value", "conflict_copies", "keyword_collisions",
        "duration_ms", "downloaded", "uploaded", "merged", "deferred", "quarantined",
        "record_count", "count", "exception_type", "exception_code", "signal",
        "file_count", "byte_count", "skipped_trailing_lines", "query_length",
        "ax_error_code", "fetch_depth", "pending_generation_count",
        "unready_generation_count",
    ]

    private func makeExport(at destination: URL) throws -> DiagnosticsExportResult {
        guard storageWasCreated else { throw DiagnosticsExportError.storageUnavailable }

        let currentPath = fileLogger.currentLogFileInfo?.filePath
        let snapshots = logSnapshots()
            .filter { $0.url.path != currentPath }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        var lines: [ExportLine] = []
        var skippedTrailingLines = 0
        var byteCount: UInt64 = 0
        var includedFileCount = 0

        for snapshot in snapshots {
            let data: Data
            do {
                // Copy the bytes: an active CocoaLumberjack file may otherwise
                // grow underneath a memory mapping while export validates it.
                data = try Data(contentsOf: snapshot.url)
            } catch let error as NSError
                where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError
            {
                // Rotation quota cleanup is asynchronous. A file can legitimately
                // disappear after the snapshot list is captured; it is no longer
                // part of the retained diagnostics set, so omit it from this export.
                continue
            } catch {
                throw DiagnosticsExportError.corruptLog
            }
            guard !data.isEmpty else { continue }
            includedFileCount += 1
            let endsInNewline = data.last == 0x0A
            let rawLines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            for (index, rawLine) in rawLines.enumerated() {
                let lineData = Data(rawLine)
                guard let line = Self.validatedExportLine(lineData) else {
                    if index == rawLines.count - 1, !endsInNewline {
                        skippedTrailingLines += 1
                        continue
                    }
                    throw DiagnosticsExportError.corruptLog
                }
                let lineSize = UInt64(lineData.count + 1)
                guard byteCount <= Self.maximumExportSize - min(lineSize, Self.maximumExportSize) else {
                    throw DiagnosticsExportError.exportTooLarge
                }
                byteCount += lineSize
                lines.append(line)
            }
        }

        lines.sort {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.session != $1.session { return $0.session < $1.session }
            return $0.sequence < $1.sequence
        }

        let manifest = DiagnosticExportManifest(
            app: appContext,
            exportedAt: Self.timestamp(Date()),
            oldestEntryAt: lines.first?.timestamp,
            newestEntryAt: lines.last?.timestamp,
            fileCount: includedFileCount,
            byteCount: byteCount,
            skippedTrailingLines: skippedTrailingLines)
        let manifestRecord = DiagnosticRecord(
            event: .diagnosticsManifest(manifest),
            timestamp: Self.timestamp(Date()),
            elapsedMilliseconds: 0,
            sessionIdentifier: "export",
            sequence: 0)
        guard let manifestLine = try? manifestRecord.jsonLine() else {
            throw DiagnosticsExportError.cannotWrite
        }

        var output = Data()
        output.reserveCapacity(manifestLine.count + Int(byteCount))
        output.append(manifestLine)
        for line in lines {
            output.append(line.data)
            output.append(0x0A)
        }
        guard UInt64(output.count) <= Self.maximumExportSize else {
            throw DiagnosticsExportError.exportTooLarge
        }

        do {
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try AtomicFileWriter.write(
                output,
                to: destination,
                temporaryDirectory: destination.deletingLastPathComponent(),
                permissions: 0o600)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path)
            #if os(iOS)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path)
            #endif
        } catch {
            throw DiagnosticsExportError.cannotWrite
        }

        return DiagnosticsExportResult(
            url: destination,
            recordCount: lines.count,
            byteCount: UInt64(output.count),
            skippedTrailingLines: skippedTrailingLines)
    }

    private static func validatedExportLine(_ data: Data) -> ExportLine? {
        guard let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(dictionary.keys) == exportTopLevelFields,
              let schema = dictionary["schema"] as? NSNumber,
              isNumber(schema), schema.intValue == DiagnosticRecord.schemaVersion,
              let timestamp = dictionary["timestamp"] as? String,
              timestamp.utf8.count <= 64,
              timestampFormatter.date(from: timestamp) != nil,
              let elapsed = dictionary["elapsed_ms"] as? NSNumber,
              isNumber(elapsed), elapsed.doubleValue >= 0,
              let session = dictionary["session_id"] as? String,
              session.utf8.count <= 64,
              UUID(uuidString: session) != nil || session == "legacy-audit" || session == "export",
              let sequence = dictionary["sequence"] as? NSNumber,
              isNumber(sequence), sequence.doubleValue >= 0,
              sequence.doubleValue.rounded(.towardZero) == sequence.doubleValue,
              let level = dictionary["level"] as? String,
              DiagnosticLevel(rawValue: level) != nil,
              let category = dictionary["category"] as? String,
              let event = dictionary["event"] as? String,
              let schemaForEvent = exportEventSchemas[event],
              category == schemaForEvent.category,
              let fields = dictionary["fields"] as? [String: Any]
        else { return nil }

        let fieldNames = Set(fields.keys)
        guard schemaForEvent.requiredFields.isSubset(of: fieldNames),
              fieldNames.isSubset(of: schemaForEvent.requiredFields.union(schemaForEvent.optionalFields)),
              fields.allSatisfy({ validateExportField(key: $0.key, value: $0.value) })
        else { return nil }

        return ExportLine(
            timestamp: timestamp,
            session: session,
            sequence: sequence.uint64Value,
            data: data)
    }

    private static func validateExportField(key: String, value: Any) -> Bool {
        if exportStringFields.contains(key) {
            if (key == "oldest_entry_at" || key == "newest_entry_at"), value is NSNull {
                return true
            }
            guard let string = value as? String else { return false }
            let limit = key == "keyword" ? DiagnosticKeyword.maximumUTF8Length : 1_024
            return string.utf8.count <= limit
        }
        if exportBooleanFields.contains(key) {
            return isBoolean(value)
        }
        if exportNumericFields.contains(key) {
            guard let number = value as? NSNumber, isNumber(number) else { return false }
            return number.doubleValue.isFinite
        }
        if key == "call_stack" {
            var remainingNodes = 2_048
            return validateMetricStack(value, key: nil, depth: 0, remainingNodes: &remainingNodes)
        }
        return false
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isNumber(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) != CFBooleanGetTypeID() && number.doubleValue.isFinite
    }

    private static func validateMetricStack(
        _ value: Any,
        key: String?,
        depth: Int,
        remainingNodes: inout Int
    ) -> Bool {
        guard depth <= 64, remainingNodes > 0 else { return false }
        remainingNodes -= 1

        if let dictionary = value as? [String: Any] {
            guard !dictionary.isEmpty else { return false }
            for (childKey, childValue) in dictionary {
                guard metricContainerKeys.contains(childKey)
                        || metricNumericKeys.contains(childKey)
                        || childKey == "binaryUUID"
                        || childKey == "threadAttributed",
                      validateMetricStack(
                        childValue,
                        key: childKey,
                        depth: depth + 1,
                        remainingNodes: &remainingNodes)
                else { return false }
            }
            return true
        }
        if let array = value as? [Any] {
            guard key.map(metricContainerKeys.contains) == true else { return false }
            for child in array {
                guard validateMetricStack(
                    child,
                    key: key,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes)
                else { return false }
            }
            return true
        }
        if key == "binaryUUID", let string = value as? String {
            return UUID(uuidString: string) != nil
        }
        if key == "threadAttributed" {
            return isBoolean(value)
        }
        if let key, metricNumericKeys.contains(key), let number = value as? NSNumber {
            return isNumber(number)
        }
        return false
    }

    private func rollCurrentFile() async {
        await withCheckedContinuation { continuation in
            fileLogger.rollLogFile {
                continuation.resume()
            }
        }
    }

    // MARK: - Retention and privacy

    private func startMaintenanceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: maintenanceQueue)
        timer.schedule(deadline: .now() + .seconds(6 * 60 * 60), repeating: 6 * 60 * 60)
        timer.setEventHandler { [weak self] in self?.hardenAndPrune() }
        maintenanceTimer = timer
        timer.resume()
    }

    private func hardenAndPrune() {
        hardenLogFiles()
        let cutoff = Date().addingTimeInterval(
            -TimeInterval(retentionDayCount * 24 * 60 * 60))
        let currentPath = fileLogger.currentLogFileInfo?.filePath
        var removed = 0
        for snapshot in logSnapshots() where snapshot.url.path != currentPath {
            guard let date = snapshot.date, date < cutoff else { continue }
            if (try? fileManager.removeItem(at: snapshot.url)) != nil { removed += 1 }
        }
        if removed > 0 {
            emit(
                .diagnosticsMaintenance(.retentionPruned, count: removed),
                level: .info,
                synchronous: false)
        }
    }

    private func hardenLogFiles() {
        for path in logFileManager.unsortedLogFilePaths {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: path)
            #if os(iOS)
            try? fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path)
            #endif
        }
    }

    private func logSnapshots() -> [LogSnapshot] {
        logFileManager.unsortedLogFilePaths.compactMap { path in
            let url = URL(filePath: path)
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                return nil
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue ?? 1 <= 1
            else { return nil }
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let date = (attributes[.modificationDate] as? Date)
                ?? (attributes[.creationDate] as? Date)
            return LogSnapshot(url: url, date: date, size: size)
        }
    }

    private func migrateLegacyAuditIfNeeded() {
        let source = SnippetStorageLocations.vaultAuditFileURL
        guard fileManager.fileExists(atPath: source.path) else { return }

        let destination = SnippetStorageLocations.diagnosticsLogsFolderURL
            .appendingPathComponent("legacy-audit-v1.jsonl", isDirectory: false)
        if fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.removeItem(at: source)
            } catch {
                markPrivacyCleanupNeeded()
            }
            return
        }

        struct LegacyEntry: Decodable {
            let at: Date
            let outcome: String
            let keyword: String
        }

        do {
            let data = try Data(contentsOf: source)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let cutoff = Date().addingTimeInterval(
                -TimeInterval(retentionDayCount * 24 * 60 * 60))
            let entries = try decoder.decode([LegacyEntry].self, from: data)
                .filter { $0.at >= cutoff }
                .sorted { $0.at < $1.at }

            var migrated = Data()
            for (index, entry) in entries.enumerated() {
                let event = DiagnosticEvent.secureReveal(
                    keyword: DiagnosticKeyword(entry.keyword),
                    outcome: DiagnosticSecureRevealOutcome(legacyValue: entry.outcome),
                    caller: .unknown)
                let record = DiagnosticRecord(
                    event: event,
                    timestamp: Self.timestamp(entry.at),
                    elapsedMilliseconds: 0,
                    sessionIdentifier: "legacy-audit",
                    sequence: UInt64(index + 1))
                migrated.append(try record.jsonLine())
            }
            if !migrated.isEmpty {
                try AtomicFileWriter.write(
                    migrated,
                    to: destination,
                    temporaryDirectory: SnippetStorageLocations.tmpFolderURL)
                var attributes: [FileAttributeKey: Any] = [
                    .posixPermissions: 0o600,
                    .modificationDate: entries.last?.at ?? Date(),
                ]
                #if os(iOS)
                attributes[.protectionKey] =
                    FileProtectionType.completeUntilFirstUserAuthentication
                #endif
                try fileManager.setAttributes(attributes, ofItemAtPath: destination.path)
            }
            try fileManager.removeItem(at: source)
            emit(
                .diagnosticsMaintenance(.legacyAuditMigrated, count: entries.count),
                level: .info,
                synchronous: true)
        } catch {
            markPrivacyCleanupNeeded()
            emit(
                .diagnosticsMaintenance(.legacyAuditMigrationFailed, count: nil),
                level: .warning,
                synchronous: true)
        }
    }

    private func markPrivacyCleanupNeeded() {
        stateLock.lock()
        privacyCleanupNeeded = true
        stateLock.unlock()
    }

    private func removeStaleTemporaryExports() {
        #if os(iOS)
        let temporaryDirectory = fileManager.temporaryDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        else { return }
        for file in files where file.lastPathComponent.hasPrefix("Snippets-Diagnostics-")
            && file.pathExtension == "jsonl"
        {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try? fileManager.removeItem(at: file)
        }
        #endif
    }

    private static func excludeFromBackup(_ url: URL) {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    // MARK: - Context

    private static func makeAppContext() -> DiagnosticAppContext {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticAppContext(
            version: info["CFBundleShortVersionString"] as? String ?? "unknown",
            build: info["CFBundleVersion"] as? String ?? "unknown",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
            platform: platformName,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: architectureName,
            cloudEnvironment: cloudEnvironment,
            syncEnabled: UserDefaults.standard.bool(forKey: "SnippetsICloudSyncEnabled"))
    }

    private static var platformName: String {
        #if os(macOS)
        "macos"
        #else
        let simulatorModel = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        if simulatorModel?.hasPrefix("iPad") == true { return "ipados" }
        if simulatorModel?.hasPrefix("iPhone") == true { return "ios" }

        var system = utsname()
        guard uname(&system) == 0 else { return "ios" }
        let machine = withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
        return machine.hasPrefix("iPad") ? "ipados" : "ios"
        #endif
    }

    private static var architectureName: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }

    private static var cloudEnvironment: DiagnosticCloudEnvironment {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return .absent }
        guard let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-environment" as CFString,
            nil) as? String
        else { return .absent }
        switch value.lowercased() {
        case "production": return .production
        case "development": return .development
        default: return .unrecognized
        }
        #else
        #if targetEnvironment(simulator)
        return .absent
        #else
        // SecTask's public header is not shipped in the iOS SDK. Never infer this from
        // the source entitlement: only the signed artifact is authoritative, and the
        // install workflow validates it before placing a build on a device.
        return .unrecognized
        #endif
        #endif
    }

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }

    private static func logFlag(for level: DiagnosticLevel) -> DDLogFlag {
        switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .warning
        case .error, .fault: .error
        }
    }
}

// MARK: - MetricKit

nonisolated extension DiagnosticsService: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for diagnostic in payload.crashDiagnostics ?? [] {
                let stack = Self.sanitizeCallStack(diagnostic.callStackTree)
                Diagnostics.record(.metricKit(DiagnosticMetric(
                    kind: .crash,
                    durationMilliseconds: nil,
                    primaryValue: nil,
                    exceptionType: diagnostic.exceptionType?.int64Value,
                    exceptionCode: diagnostic.exceptionCode?.int64Value,
                    signal: diagnostic.signal?.int64Value,
                    callStack: stack.value,
                    wasTruncated: stack.truncated)))
            }
            for diagnostic in payload.hangDiagnostics ?? [] {
                let stack = Self.sanitizeCallStack(diagnostic.callStackTree)
                Diagnostics.record(.metricKit(DiagnosticMetric(
                    kind: .hang,
                    durationMilliseconds: Int64(diagnostic.hangDuration
                        .converted(to: .milliseconds).value.rounded()),
                    primaryValue: nil,
                    exceptionType: nil,
                    exceptionCode: nil,
                    signal: nil,
                    callStack: stack.value,
                    wasTruncated: stack.truncated)))
            }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] {
                let stack = Self.sanitizeCallStack(diagnostic.callStackTree)
                Diagnostics.record(.metricKit(DiagnosticMetric(
                    kind: .cpuException,
                    durationMilliseconds: Int64(diagnostic.totalSampledTime
                        .converted(to: .milliseconds).value.rounded()),
                    primaryValue: diagnostic.totalCPUTime.converted(to: .milliseconds).value,
                    exceptionType: nil,
                    exceptionCode: nil,
                    signal: nil,
                    callStack: stack.value,
                    wasTruncated: stack.truncated)))
            }
            for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] {
                let stack = Self.sanitizeCallStack(diagnostic.callStackTree)
                Diagnostics.record(.metricKit(DiagnosticMetric(
                    kind: .diskWriteException,
                    durationMilliseconds: nil,
                    primaryValue: diagnostic.totalWritesCaused.converted(to: .bytes).value,
                    exceptionType: nil,
                    exceptionCode: nil,
                    signal: nil,
                    callStack: stack.value,
                    wasTruncated: stack.truncated)))
            }
        }
    }

    private struct SanitizedCallStack {
        let value: DiagnosticJSONValue?
        let truncated: Bool
    }

    private static func sanitizeCallStack(_ tree: MXCallStackTree) -> SanitizedCallStack {
        guard let raw = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()) else {
            return SanitizedCallStack(value: nil, truncated: true)
        }
        var remainingNodes = 2_048
        var truncated = false
        let value = sanitizeMetricValue(
            raw,
            key: nil,
            depth: 0,
            remainingNodes: &remainingNodes,
            truncated: &truncated)
        if let value,
           let encoded = try? JSONEncoder().encode(value),
           encoded.count > 256 * 1_024 {
            return SanitizedCallStack(value: nil, truncated: true)
        }
        return SanitizedCallStack(value: value, truncated: truncated)
    }

    private static let metricContainerKeys: Set<String> = [
        "callStacks", "callStackRootFrames", "subFrames",
    ]
    private static let metricNumericKeys: Set<String> = [
        "offsetIntoBinaryTextSegment", "address", "sampleCount",
    ]

    private static func sanitizeMetricValue(
        _ raw: Any,
        key: String?,
        depth: Int,
        remainingNodes: inout Int,
        truncated: inout Bool
    ) -> DiagnosticJSONValue? {
        guard depth <= 64, remainingNodes > 0 else {
            truncated = true
            return nil
        }
        remainingNodes -= 1

        if let dictionary = raw as? [String: Any] {
            var result: [String: DiagnosticJSONValue] = [:]
            for childKey in dictionary.keys.sorted() {
                guard metricContainerKeys.contains(childKey)
                        || metricNumericKeys.contains(childKey)
                        || childKey == "binaryUUID"
                        || childKey == "threadAttributed"
                else { continue }
                guard let rawChild = dictionary[childKey] else { continue }
                if let child = sanitizeMetricValue(
                    rawChild,
                    key: childKey,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    truncated: &truncated) {
                    result[childKey] = child
                }
            }
            return result.isEmpty ? nil : .object(result)
        }
        if let array = raw as? [Any], key.map(metricContainerKeys.contains) == true {
            var result: [DiagnosticJSONValue] = []
            for child in array {
                guard let value = sanitizeMetricValue(
                    child,
                    key: key,
                    depth: depth + 1,
                    remainingNodes: &remainingNodes,
                    truncated: &truncated) else { continue }
                result.append(value)
            }
            return .array(result)
        }
        if key == "binaryUUID", let string = raw as? String,
           UUID(uuidString: string) != nil {
            return .string(string.lowercased())
        }
        if key == "threadAttributed", let number = raw as? NSNumber {
            return .boolean(number.boolValue)
        }
        if let key, metricNumericKeys.contains(key), let number = raw as? NSNumber {
            return .integer(number.int64Value)
        }
        return nil
    }
}
