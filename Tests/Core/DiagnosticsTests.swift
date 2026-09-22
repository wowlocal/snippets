import Foundation
import Testing

@testable import SnippetsCore

private final class RecordingDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(DiagnosticEvent, DiagnosticLevel, Bool)] = []

    var events: [(DiagnosticEvent, DiagnosticLevel, Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func emit(_ event: DiagnosticEvent, level: DiagnosticLevel, synchronous: Bool) {
        lock.lock()
        storage.append((event, level, synchronous))
        lock.unlock()
    }

    func flush() {}
}

@Suite("Persistent diagnostics privacy contract", .serialized)
struct DiagnosticsTests {
    @Test func securePasteDiagnosticsAreClosedBoundedAndContentFree() throws {
        let secret = "PRIVATE-PASSWORD PRIVATE-NAME /private/path caller=123"
        let failure = DiagnosticFailure(NSError(domain: NSCocoaErrorDomain, code: 42,
            userInfo: [NSLocalizedDescriptionKey: secret]))
        for stage in DiagnosticSecurePasteStage.allCases {
            for reason in DiagnosticSecurePasteReason.allCases {
                let event = DiagnosticEvent.securePaste(stage: stage, outcome: .failed,
                    target: .explicit, transport: .secureValue, reason: reason,
                    attempts: .max, durationMilliseconds: .max, axErrorCode: -25202, failure: failure)
                let record = DiagnosticRecord(event: event, timestamp: "2026-09-20T10:00:00.000Z",
                    elapsedMilliseconds: 1, sessionIdentifier: "test-session", sequence: 1)
                let data = try record.jsonLine()
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let fields = try #require(object["fields"] as? [String: Any])
                #expect(object["event"] as? String == "secure_paste")
                #expect(object["category"] as? String == "integration")
                #expect(Set(fields.keys) == ["stage", "outcome", "target", "transport", "reason",
                    "attempts", "duration_ms", "ax_error_code", "error_family", "error_code"])
                #expect(fields["reason"] as? String == reason.rawValue)
                #expect(fields["attempts"] as? Int == 16)
                #expect(fields["duration_ms"] as? Int == 600_000)
                #expect(fields["ax_error_code"] as? Int == -25202)
                #expect(!String(decoding: data, as: UTF8.self).contains(secret))
                #expect(event.defaultLevel == .warning)
                #expect(!event.requiresSynchronousWrite)
            }
        }
        let bounded = DiagnosticEvent.securePaste(stage: .handoff, outcome: .succeeded,
            target: .focused, transport: .none, reason: .none, attempts: -1,
            durationMilliseconds: -1, axErrorCode: .max, failure: nil)
        #expect(bounded.fields["attempts"] == .integer(0))
        #expect(bounded.fields["duration_ms"] == .integer(0))
        #expect(bounded.fields["ax_error_code"] == .integer(Int64(Int32.max)))
        #expect(bounded.defaultLevel == .info)
        for transport in DiagnosticSecurePasteTransport.allCases {
            let event = DiagnosticEvent.securePaste(stage: .delivery, outcome: .ambiguous,
                target: .focused, transport: transport, reason: .axWriteUnconfirmed,
                attempts: 1, durationMilliseconds: 1, axErrorCode: 0, failure: nil)
            #expect(event.fields["transport"] == .string(transport.rawValue))
            #expect(event.fields["reason"] == .string("ax_write_unconfirmed"))
            #expect(event.defaultLevel == .warning)
        }
    }

    @Test func cloudSignInRecordsAreBoundedAndExcludeAuthenticationErrorPayloads() throws {
        let secret = "email@example.test code=SECRET-CODE token=SECRET-TOKEN https://secret.example/callback"
        let failure = DiagnosticFailure(NSError(domain: NSURLErrorDomain, code: -1001,
            userInfo: [NSLocalizedDescriptionKey: secret, NSURLErrorFailingURLStringErrorKey: secret]))
        let events: [DiagnosticEvent] = [
            .cloudSignIn(stage: .providerDiscovery, outcome: .failed,
                durationMilliseconds: -8, storedSessionPresent: false,
                reason: .identityProviderUnavailable, failure: failure),
            .cloudSignInRequest(endpoint: .providerDiscovery, outcome: .failed,
                durationMilliseconds: .max, httpStatus: 503, reason: .httpStatus, failure: failure),
            .cloudSignInPresentationAnchor(available: false),
        ]
        let expectedFields: [Set<String>] = [
            ["stage", "outcome", "duration_ms", "stored_session_present", "reason", "error_family", "error_code"],
            ["endpoint", "outcome", "duration_ms", "http_status", "reason", "error_family", "error_code"],
            ["available"],
        ]
        for (index, event) in events.enumerated() {
            let record = DiagnosticRecord(event: event, timestamp: "2026-09-06T10:00:00.000Z",
                elapsedMilliseconds: 1, sessionIdentifier: "test-session", sequence: UInt64(index))
            let data = try record.jsonLine()
            let text = try #require(String(data: data, encoding: .utf8))
            let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let fields = try #require(object["fields"] as? [String: Any])
            #expect(Set(fields.keys) == expectedFields[index])
            #expect(object["category"] as? String == "sync")
            #expect(!text.contains("SECRET"))
            #expect(!text.contains("email@example"))
            #expect(!text.contains("secret.example"))
        }
        #expect(events[0].fields["duration_ms"] == .integer(0))
        #expect(events[1].fields["duration_ms"] == .integer(86_400_000))
        #expect(events[1].fields["http_status"] == .integer(503))
        let invalidStatus = DiagnosticEvent.cloudSignInRequest(endpoint: .token,
            outcome: .failed, durationMilliseconds: 1, httpStatus: 100_000, reason: nil, failure: nil)
        #expect(invalidStatus.fields["http_status"] == nil)
    }

    @Test func nativeEmailSignInUsesClosedPrivacySafeVocabulary() throws {
        for (stage, endpoint) in [(DiagnosticCloudSignInStage.emailCodeSend, DiagnosticCloudSignInEndpoint.emailCodeSend),
                                  (.emailCodeVerify, .emailCodeVerify)] {
            for reason in [DiagnosticCloudSignInReason.invalidEmail, .invalidCode, .codeExpired, .tooManyAttempts, .rateLimited] {
                let events: [DiagnosticEvent] = [
                    .cloudSignIn(stage: stage, outcome: .failed, durationMilliseconds: 1,
                                 storedSessionPresent: nil, reason: reason, failure: nil),
                    .cloudSignInRequest(endpoint: endpoint, outcome: .failed, durationMilliseconds: 1,
                                        httpStatus: 429, reason: reason, failure: nil)
                ]
                for event in events {
                    let data = try DiagnosticRecord(event: event, timestamp: "2026-09-06T12:00:00.000Z", elapsedMilliseconds: 1, sessionIdentifier: "test-session", sequence: 1).jsonLine()
                    let text = String(decoding: data, as: UTF8.self)
                    #expect(text.contains(reason.rawValue))
                    #expect(!text.contains("challengeId"))
                    #expect(!text.contains("refreshToken"))
                }
            }
        }
    }

    @Test func cloudSignInOnlyCriticalBoundariesWriteSynchronously() {
        func event(_ stage: DiagnosticCloudSignInStage, _ outcome: DiagnosticCloudSignInOutcome) -> DiagnosticEvent {
            .cloudSignIn(stage: stage, outcome: outcome, durationMilliseconds: 1,
                storedSessionPresent: nil, reason: nil, failure: nil)
        }
        #expect(event(.browserStart, .entered).requiresSynchronousWrite)
        #expect(event(.storedSession, .failed).requiresSynchronousWrite)
        #expect(event(.storedSession, .failed).defaultLevel == .error)
        #expect(!event(.browserWaiting, .entered).requiresSynchronousWrite)
        #expect(!event(.librarySetup, .succeeded).requiresSynchronousWrite)
        #expect(!event(.browserWaiting, .cancelled).requiresSynchronousWrite)
        #expect(event(.browserWaiting, .cancelled).defaultLevel == .info)
        #expect(DiagnosticEvent.cloudSignInPresentationAnchor(available: false).requiresSynchronousWrite)
        #expect(!DiagnosticEvent.cloudSignInPresentationAnchor(available: true).requiresSynchronousWrite)
    }

    @Test func secureKeywordIsNormalizedBoundedAndUnicodeSafe() {
        let raw = "\\  launch   " + String(repeating: "ключслово ", count: 80)
        let keyword = DiagnosticKeyword(raw)

        #expect(keyword.value.hasPrefix("launch-"))
        #expect(keyword.value.utf8.count <= DiagnosticKeyword.maximumUTF8Length)
        #expect(keyword.wasTruncated)
        #expect(String(data: Data(keyword.value.utf8), encoding: .utf8) == keyword.value)
    }

    @Test func arbitraryErrorTextAndUserInfoCannotReachARecord() throws {
        let secretBody = "PRIVATE-BODY-SENTINEL"
        let error = NSError(
            domain: "ThirdParty.SecretError",
            code: 731,
            userInfo: [
                NSLocalizedDescriptionKey: secretBody,
                NSFilePathErrorKey: "/Users/person/private-library.json",
            ])
        let record = DiagnosticRecord(
            event: .storageFailure(
                area: .library,
                operation: .read,
                failure: DiagnosticFailure(error),
                attempt: 2),
            timestamp: "2026-08-09T10:00:00.000Z",
            elapsedMilliseconds: 19,
            sessionIdentifier: "test-session",
            sequence: 1)

        let text = try #require(String(data: record.jsonLine(), encoding: .utf8))
        #expect(text.contains("\"error_family\":\"other\""))
        #expect(text.contains("\"error_code\":731"))
        #expect(!text.contains(secretBody))
        #expect(!text.contains("private-library"))
        #expect(!text.contains("ThirdParty.SecretError"))
    }

    @Test func secureRevealPersistsOnlyApprovedMetadata() throws {
        let record = DiagnosticRecord(
            event: .secureReveal(
                keyword: DiagnosticKeyword("deploy prod"),
                outcome: .revealed,
                caller: .trusted),
            timestamp: "2026-08-09T10:00:00.000Z",
            elapsedMilliseconds: 4,
            sessionIdentifier: "test-session",
            sequence: 9)

        let object = try #require(
            JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
        let fields = try #require(object["fields"] as? [String: Any])

        #expect(object["event"] as? String == "secure_reveal")
        #expect(fields["keyword"] as? String == "deploy-prod")
        #expect(fields["outcome"] as? String == "revealed")
        #expect(fields["caller"] as? String == "trusted")
        #expect(Set(fields.keys) == ["keyword", "keyword_truncated", "outcome", "caller"])
    }

    @Test func secureEditorTransitionPersistsOnlyClosedStateAndCause() throws {
        let record = DiagnosticRecord(
            event: .secureEditorTransition(
                surface: .phone,
                from: .protectedPlaintext,
                to: .locked,
                reason: .storeRefreshRemoteSync,
                vaultState: .unlocked),
            timestamp: "2026-08-12T19:14:02.123Z",
            elapsedMilliseconds: 545_614,
            sessionIdentifier: "test-session",
            sequence: 10)

        let object = try #require(
            JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
        let fields = try #require(object["fields"] as? [String: Any])

        #expect(object["event"] as? String == "secure_editor_transition")
        #expect(fields["surface"] as? String == "phone")
        #expect(fields["from_state"] as? String == "protected_plaintext")
        #expect(fields["to_state"] as? String == "locked")
        #expect(fields["reason"] as? String == "store_refresh_remote_sync")
        #expect(fields["vault_state"] as? String == "unlocked")
        #expect(Set(fields.keys) == [
            "surface", "from_state", "to_state", "reason", "vault_state",
        ])
    }

    @Test func terminalAccessibilityReplacementRecordsOnlyClosedOutcomeAndBoundedTiming() throws {
        for outcome in DiagnosticPasteAccessibilityOutcome.allCases {
            let event = DiagnosticEvent.accessibilityReplacement(outcome: outcome, durationMilliseconds: .max)
            let record = DiagnosticRecord(event: event, timestamp: "2026-09-22T10:00:00.000Z",
                elapsedMilliseconds: 1, sessionIdentifier: "00000000-0000-4000-8000-000000000001", sequence: 1)
            let object = try #require(JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
            let fields = try #require(object["fields"] as? [String: Any])
            #expect(object["event"] as? String == "accessibility_replacement")
            #expect(object["category"] as? String == "integration")
            #expect(Set(fields.keys) == ["outcome", "duration_ms"])
            #expect(fields["outcome"] as? String == outcome.rawValue)
            #expect(fields["duration_ms"] as? Int == 600_000)
            #expect(event.defaultLevel == (outcome == .delivered ? .info : .warning))
            #expect(!event.requiresSynchronousWrite)
        }
        #expect(DiagnosticEvent.accessibilityReplacement(outcome: .ambiguous,
            durationMilliseconds: .min).fields["duration_ms"] == .integer(0))
    }

    @Test func accessibilityReplacementProgressContainsOnlyWriteAttemptAndClosedRestoration() throws {
        for textWriteAttempted in [false, true] {
            for restoration in DiagnosticPasteSelectionRestoration.allCases {
                let event = DiagnosticEvent.accessibilityReplacement(
                    outcome: .ambiguous, durationMilliseconds: 42,
                    progress: .init(textWriteAttempted: textWriteAttempted,
                        selectionRestoration: restoration))
                let record = DiagnosticRecord(event: event, timestamp: "2026-09-22T10:00:00.000Z",
                    elapsedMilliseconds: 1,
                    sessionIdentifier: "00000000-0000-4000-8000-000000000001", sequence: 1)
                let object = try #require(JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
                let fields = try #require(object["fields"] as? [String: Any])
                #expect(Set(fields.keys) == [
                    "outcome", "duration_ms", "text_write_attempted", "selection_restoration",
                ])
                #expect(fields["text_write_attempted"] as? Bool == textWriteAttempted)
                #expect(fields["selection_restoration"] as? String == restoration.rawValue)
                #expect(!event.requiresSynchronousWrite)
            }
        }
        let legacy = DiagnosticEvent.accessibilityReplacement(outcome: .rejected,
            durationMilliseconds: 0)
        #expect(legacy.fields["text_write_attempted"] == nil)
        #expect(legacy.fields["selection_restoration"] == nil)
    }

    @Test func pasteDiagnosticsContainOnlyClosedOutcomesAndBoundedTiming() throws {
        for outcome in DiagnosticPasteOutcome.allCases {
            for restoration in DiagnosticPasteboardRestoration.allCases {
                let event = DiagnosticEvent.pasteDelivery(
                    outcome: outcome, restoration: restoration,
                    durationMilliseconds: .max, hadFingerprint: false)
                let record = DiagnosticRecord(
                    event: event, timestamp: "2026-09-15T10:00:00.000Z",
                    elapsedMilliseconds: 1, sessionIdentifier: "test-session", sequence: 1)
                let object = try #require(
                    JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
                let fields = try #require(object["fields"] as? [String: Any])
                #expect(object["event"] as? String == "paste_delivery")
                #expect(object["category"] as? String == "integration")
                #expect(Set(fields.keys) == ["outcome", "restoration", "duration_ms", "had_fingerprint"])
                #expect(fields["outcome"] as? String == outcome.rawValue)
                #expect(fields["restoration"] as? String == restoration.rawValue)
                #expect(fields["duration_ms"] as? Int == 600_000)
                #expect(fields["had_fingerprint"] as? Bool == false)
                #expect(event.requiresSynchronousWrite == (restoration == .pending))
            }
        }
        let timeout = DiagnosticEvent.pasteDelivery(
            outcome: .timedOut, restoration: .restored,
            durationMilliseconds: -10, hadFingerprint: true)
        #expect(timeout.fields["duration_ms"] == .integer(0))
        #expect(timeout.defaultLevel == .warning)
        for restoration in DiagnosticPasteboardRestoration.allCases {
            let recovery = DiagnosticEvent.pasteboardRecovery(outcome: restoration)
            #expect(recovery.fields == ["outcome": .string(restoration.rawValue)])
            #expect(recovery.requiresSynchronousWrite == (restoration == .pending))
        }
    }

    @Test func pasteProgressContainsOnlyClosedReasonsAndBoundedDispatchCounts() throws {
        for stage in DiagnosticPasteStage.allCases {
            for reason in DiagnosticPasteReason.allCases {
                let event = DiagnosticEvent.pasteDelivery(
                    outcome: .interrupted, restoration: .superseded,
                    durationMilliseconds: 30, hadFingerprint: false,
                    progress: .init(stage: stage, reason: reason, plannedDeletes: .max,
                                    deleteAttempts: .min, pastePosted: false))
                let record = DiagnosticRecord(event: event, timestamp: "2026-09-22T10:00:00.000Z",
                    elapsedMilliseconds: 1, sessionIdentifier: "test-session", sequence: 1)
                let object = try #require(JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
                let fields = try #require(object["fields"] as? [String: Any])
                #expect(Set(fields.keys) == ["outcome", "restoration", "duration_ms", "had_fingerprint",
                    "stage", "reason", "planned_deletes", "delete_attempts", "paste_posted"])
                #expect(fields["stage"] as? String == stage.rawValue)
                #expect(fields["reason"] as? String == reason.rawValue)
                #expect(fields["planned_deletes"] as? Int == 10_000)
                #expect(fields["delete_attempts"] as? Int == 0)
                #expect(fields["paste_posted"] as? Bool == false)
                #expect(!event.requiresSynchronousWrite)
                #expect(event.defaultLevel == .warning)
            }
        }
        let delivered = DiagnosticEvent.pasteDelivery(outcome: .textObserved, restoration: .restored,
            durationMilliseconds: 177, hadFingerprint: true,
            progress: .init(stage: .confirmation, plannedDeletes: 7, deleteAttempts: 7, pastePosted: true))
        #expect(delivered.fields["paste_posted"] == .boolean(true))
        #expect(delivered.fields["delete_attempts"] == .integer(7))
        #expect(delivered.fields["reason"] == .string("none"))
    }

    @Test func pasteSelectionProgressContainsOnlyClosedContentFreeFacts() throws {
        for transport in DiagnosticPasteTransport.allCases {
            for selection in DiagnosticPasteSelection.allCases {
                for restoration in DiagnosticPasteSelectionRestoration.allCases {
                    for origin in DiagnosticPasteInterruptionOrigin.allCases {
                        let event = DiagnosticEvent.pasteDelivery(
                            outcome: .interrupted, restoration: .superseded,
                            durationMilliseconds: 30, hadFingerprint: true,
                            progress: .init(stage: .selectionValidation, reason: .selectionChanged,
                                transport: transport, selection: selection,
                                selectionRestoration: restoration, interruptionOrigin: origin))
                        let record = DiagnosticRecord(event: event, timestamp: "2026-09-22T10:00:00.000Z",
                            elapsedMilliseconds: 1,
                            sessionIdentifier: "00000000-0000-4000-8000-000000000001", sequence: 1)
                        let object = try #require(
                            JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
                        let fields = try #require(object["fields"] as? [String: Any])
                        #expect(Set(fields.keys) == ["outcome", "restoration", "duration_ms", "had_fingerprint",
                            "stage", "reason", "planned_deletes", "delete_attempts", "paste_posted",
                            "transport", "selection", "selection_restoration", "interruption_origin"])
                        #expect(fields["transport"] as? String == transport.rawValue)
                        #expect(fields["selection"] as? String == selection.rawValue)
                        #expect(fields["selection_restoration"] as? String == restoration.rawValue)
                        #expect(fields["interruption_origin"] as? String == origin.rawValue)
                        #expect(!event.requiresSynchronousWrite)
                    }
                }
            }
        }
        let legacyProgress = DiagnosticEvent.pasteDelivery(
            outcome: .interrupted, restoration: .notBorrowed, durationMilliseconds: 0,
            hadFingerprint: false,
            progress: .init(selection: .rejected, selectionRestoration: .failed))
        #expect(legacyProgress.fields["transport"] == nil)
        #expect(legacyProgress.fields["selection"] == nil)
        #expect(legacyProgress.fields["selection_restoration"] == nil)
        #expect(legacyProgress.fields["interruption_origin"] == nil)
        #expect(legacyProgress.fields["ax_replacement_outcome"] == nil)
        for outcome in DiagnosticPasteAccessibilityOutcome.allCases {
            let event = DiagnosticEvent.pasteDelivery(
                outcome: .interrupted, restoration: .notBorrowed, durationMilliseconds: 0,
                hadFingerprint: false, progress: .init(accessibilityOutcome: outcome))
            #expect(event.fields["ax_replacement_outcome"] == .string(outcome.rawValue))
            #expect(Set(event.fields.keys) == ["outcome", "restoration", "duration_ms", "had_fingerprint",
                "stage", "reason", "planned_deletes", "delete_attempts", "paste_posted", "ax_replacement_outcome"])
        }
    }

    @Test func selectionConfirmationDiagnosticsAreClosedBoundedAndOptional() {
        for phase in SelectionPasteTransaction.Phase.allCases {
            for observation in TriggerSelectionObservation.allCases {
                let event = DiagnosticEvent.pasteDelivery(outcome: .interrupted, restoration: .restored,
                    durationMilliseconds: 0, hadFingerprint: false,
                    progress: .init(transport: .selectionPaste,
                        selectionConfirmation: .init(phase: phase, observation: observation,
                            writeAttempted: true, polls: .max, waitMilliseconds: .max)))
                #expect(Set(event.fields.keys) == ["outcome", "restoration", "duration_ms", "had_fingerprint",
                    "stage", "reason", "planned_deletes", "delete_attempts", "paste_posted",
                    "transport", "selection", "selection_restoration", "selection_phase",
                    "selection_observation", "selection_write_attempted", "selection_polls", "selection_wait_ms"])
                #expect(event.fields["selection_phase"] == .string(phase.rawValue))
                #expect(event.fields["selection_observation"] == .string(observation.rawValue))
                #expect(event.fields["selection_write_attempted"] == .boolean(true))
                #expect(event.fields["selection_polls"] == .integer(40))
                #expect(event.fields["selection_wait_ms"] == .integer(600_000))
                #expect(!event.requiresSynchronousWrite)
            }
        }
        let negative = DiagnosticEvent.pasteDelivery(outcome: .interrupted, restoration: .restored,
            durationMilliseconds: 0, hadFingerprint: false,
            progress: .init(transport: .selectionPaste,
                selectionConfirmation: .init(polls: .min, waitMilliseconds: .min)))
        #expect(negative.fields["selection_polls"] == .integer(0))
        #expect(negative.fields["selection_wait_ms"] == .integer(0))
        #expect(negative.fields["selection_write_attempted"] == .boolean(false))
        let unrelated = DiagnosticEvent.pasteDelivery(outcome: .interrupted, restoration: .restored,
            durationMilliseconds: 0, hadFingerprint: false,
            progress: .init(transport: .backspacePaste, selectionConfirmation: .init()))
        #expect(unrelated.fields["selection_phase"] == nil)
    }

    @Test func expansionAccessibilityPersistsOnlyClosedContentFreeFacts() throws {
        let record = DiagnosticRecord(
            event: .expansionAccessibility(
                operation: .observerNotification,
                outcome: .unavailable,
                stateBefore: .uncertainAfterHostEdit,
                stateAfter: .uncertainAfterHostEdit,
                stage: .selectedRange,
                failure: .attributeUnsupported,
                axErrorCode: -25_205,
                queryLength: 4),
            timestamp: "2026-08-14T09:12:00.000Z",
            elapsedMilliseconds: 12,
            sessionIdentifier: "test-session",
            sequence: 11)

        let object = try #require(
            JSONSerialization.jsonObject(with: record.jsonLine()) as? [String: Any])
        let fields = try #require(object["fields"] as? [String: Any])

        #expect(object["event"] as? String == "expansion_accessibility")
        #expect(fields["operation"] as? String == "observer_notification")
        #expect(fields["outcome"] as? String == "unavailable")
        #expect(fields["state_before"] as? String == "uncertain_after_host_edit")
        #expect(fields["state_after"] as? String == "uncertain_after_host_edit")
        #expect(fields["stage"] as? String == "selected_range")
        #expect(fields["failure"] as? String == "attribute_unsupported")
        #expect(fields["ax_error_code"] as? Int == -25_205)
        #expect(fields["query_length"] as? Int == 4)
        #expect(Set(fields.keys) == [
            "operation", "outcome", "state_before", "state_after", "stage",
            "failure", "ax_error_code", "query_length",
        ])
        #expect(DiagnosticExpansionAXOutcome.localTracking.rawValue == "local_tracking")
    }

    @Test func cloudKitTracePersistsOnlyOrderingCountsAndClosedState() throws {
        let eventRecord = DiagnosticRecord(
            event: .cloudKitSyncEvent(
                kind: .stateUpdate,
                recordCount: 3,
                fetchDepth: 2,
                submitActive: true,
                fullResync: false,
                generationSealed: true),
            timestamp: "2026-08-16T10:00:00.000Z",
            elapsedMilliseconds: 8,
            sessionIdentifier: "test-session",
            sequence: 12)
        let schedulerRecord = DiagnosticRecord(
            event: .cloudKitSchedulerTransition(
                action: .fullResyncStarted,
                reason: .checkpointRepair,
                fullResync: true,
                pendingGenerationCount: 1,
                unreadyGenerationCount: 1),
            timestamp: "2026-08-16T10:00:00.001Z",
            elapsedMilliseconds: 9,
            sessionIdentifier: "test-session",
            sequence: 13)

        let eventObject = try #require(
            JSONSerialization.jsonObject(with: eventRecord.jsonLine()) as? [String: Any])
        let eventFields = try #require(eventObject["fields"] as? [String: Any])
        #expect(eventObject["event"] as? String == "cloudkit_sync_event")
        #expect(Set(eventFields.keys) == [
            "kind", "record_count", "fetch_depth", "submit_active", "full_resync",
            "generation_sealed",
        ])
        #expect(eventFields["kind"] as? String == "state_update")
        #expect(eventFields["record_count"] as? Int == 3)

        let schedulerObject = try #require(
            JSONSerialization.jsonObject(with: schedulerRecord.jsonLine()) as? [String: Any])
        let schedulerFields = try #require(schedulerObject["fields"] as? [String: Any])
        #expect(schedulerObject["event"] as? String == "cloudkit_scheduler_transition")
        #expect(Set(schedulerFields.keys) == [
            "action", "reason", "full_resync", "pending_generation_count",
            "unready_generation_count",
        ])
        #expect(schedulerFields["reason"] as? String == "checkpoint_repair")
    }

    @Test func globalFacadeIsNoOpUntilInstalledAndIsThreadSafeAfterInstall() {
        Diagnostics.install(nil)
        Diagnostics.record(.lifecycle(.started))

        let sink = RecordingDiagnosticsSink()
        Diagnostics.install(sink)
        defer { Diagnostics.install(nil) }

        DispatchQueue.concurrentPerform(iterations: 1_000) { _ in
            Diagnostics.record(.syncTriggered(.manual))
        }

        let captured = sink.events.filter {
            if case .syncTriggered(.manual) = $0.0 { return true }
            return false
        }
        #expect(captured.count == 1_000)
        #expect(captured.allSatisfy { $0.1 == .info && !$0.2 })
    }

    @Test func highRiskEventsRequestSynchronousPersistence() {
        let sink = RecordingDiagnosticsSink()
        Diagnostics.install(sink)
        defer { Diagnostics.install(nil) }

        Diagnostics.record(.secureReveal(
            keyword: DiagnosticKeyword("allowed-keyword"),
            outcome: .failed,
            caller: .unknown))
        Diagnostics.record(.secureEditorTransition(
            surface: .tablet,
            from: .presentingPlaintext,
            to: .failedClosed,
            reason: .rendererFailed,
            vaultState: .unlocked))
        Diagnostics.record(.secureEditorTransition(
            surface: .phone,
            from: .locked,
            to: .authenticating,
            reason: .userRequested,
            vaultState: .locked))
        Diagnostics.record(.cloudKitFailure(
            operation: .fetchChanges,
            failure: DiagnosticFailure(family: .cloudKit, code: 3)))

        let captured = sink.events.filter {
            switch $0.0 {
            case .secureReveal(let keyword, _, _): keyword.value == "allowed-keyword"
            case .secureEditorTransition(_, _, _, .rendererFailed, _): true
            case .cloudKitFailure(let operation, _): operation == .fetchChanges
            default: false
            }
        }
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { $0.2 })

        let routineTransition = sink.events.first {
            if case .secureEditorTransition(_, _, _, .userRequested, _) = $0.0 {
                return true
            }
            return false
        }
        #expect(routineTransition?.2 == false)
    }
}
