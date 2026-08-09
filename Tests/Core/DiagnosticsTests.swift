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
        Diagnostics.record(.cloudKitFailure(
            operation: .fetchChanges,
            failure: DiagnosticFailure(family: .cloudKit, code: 3)))

        let captured = sink.events.filter {
            switch $0.0 {
            case .secureReveal(let keyword, _, _): keyword.value == "allowed-keyword"
            case .cloudKitFailure(let operation, _): operation == .fetchChanges
            default: false
            }
        }
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.2 })
    }
}
