import Foundation
import XCTest
@testable import SnippetsCore

final class ClipboardHistorySearchTests: XCTestCase {
    func testPreparedSearchPreservesLiteralANDUnicodeAndOrder() {
        let entries = ["Café TOKEN", "Cafe\u{301} token", "Straße", "ﬃ file", "İIıi", "Σςσ",
                       "👩🏽‍💻 code", "東京", "{clipboard}\n  literal text", "a\r\nb", "e\u{301}x"]
            .map { ClipboardHistoryEntry(text: $0) }
        let queries = ["", " ", "cafe token", "TOKEN cafe", "é", "s", "ss", "strasse", "f", "ffi",
                       "i", "I", "ı", "σ", "👩🏽‍💻", "東京", "{clip", "text literal", "ab", "ex", "\u{301}", "missing"]
        for budget in [0, 1_000_000] {
            var index = ClipboardHistorySearchIndex(maximumBytes: budget)
            for query in queries {
                let actual = index.results(query, in: entries)
                XCTAssertEqual(actual, ClipboardHistory.search(query, in: entries), "query=\(query)")
                for match in actual {
                    let original = entries.first { $0.id == match.id }!
                    XCTAssertEqual(Array(match.text.utf8), Array(original.text.utf8))
                }
            }
            XCTAssertLessThanOrEqual(index.estimatedBytes, budget)
        }
    }

    func testTypingReusesPreparationAndEditsDeletionAndRecencyStayCurrent() {
        var index = ClipboardHistorySearchIndex()
        let first = ClipboardHistoryEntry(text: "First entry")
        var second = ClipboardHistoryEntry(text: "Second entry")
        _ = index.results("entry", in: [first, second])
        _ = index.results("second", in: [first, second])
        XCTAssertEqual(index.preparedEntryCount, 2)
        second.copiedAt = second.copiedAt.addingTimeInterval(10)
        XCTAssertEqual(index.results("entry", in: [second, first]), [second, first])
        XCTAssertEqual(index.preparedEntryCount, 2)
        let edited = ClipboardHistoryEntry(id: first.id, text: "Changed text")
        XCTAssertEqual(index.results("changed", in: [edited]), [edited])
        XCTAssertEqual(index.preparedEntryCount, 3)
        XCTAssertTrue(index.results("entry", in: [edited]).isEmpty)
        XCTAssertTrue(index.results("entry", in: []).isEmpty)
        XCTAssertEqual(index.estimatedBytes, 0)
    }

    func testWorkerCoalescesAndCancellationCannotPublishStaleEntries() {
        let worker = DispatchQueue(label: "ClipboardHistorySearchTests.worker")
        let gate = DispatchSemaphore(value: 0)
        worker.async { gate.wait() }
        let pipeline = ClipboardHistorySearchPipeline(queue: worker)
        let stale = expectation(description: "stale result")
        stale.isInverted = true
        let current = expectation(description: "current result")
        let entry = ClipboardHistoryEntry(text: "Current")
        pipeline.submit(query: "stale", entries: [.init(text: "Stale")]) { _ in stale.fulfill() }
        pipeline.cancel(clearCache: true)
        pipeline.submit(query: "current", entries: [entry]) { response in
            XCTAssertEqual(response.entries, [entry])
            XCTAssertTrue(pipeline.isCurrent(response.generation))
            current.fulfill()
        }
        gate.signal()
        wait(for: [current, stale], timeout: 0.3)
    }
}
