import Foundation
import Testing

@testable import SnippetsCore

@Suite("Clipboard history policy")
struct ClipboardHistoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func exactCopiesMoveToFrontAndKeepIdentity() {
        let original = ClipboardHistoryEntry(text: "  {clipboard}\n", copiedAt: now.addingTimeInterval(-20))
        let newer = ClipboardHistoryEntry(text: "other", copiedAt: now.addingTimeInterval(-10))
        let result = ClipboardHistory.recording(original.text, in: [newer, original], now: now)
        #expect(result.map(\.id) == [original.id, newer.id])
        #expect(result.first?.text == "  {clipboard}\n")
        #expect(result.first?.copiedAt == now)
    }

    @Test func UnicodeAndWhitespaceAreNotNormalized() {
        let first = ClipboardHistoryEntry(text: "é", copiedAt: now.addingTimeInterval(-1))
        let result = ClipboardHistory.recording("e\u{301}", in: [first], now: now)
        #expect(result.count == 2)
        #expect(Array(result[0].text.utf8) == [101, 204, 129])
        #expect(ClipboardHistory.recording("é ", in: result, now: now).count == 3)
    }

    @Test func retentionPrunesExpiredAndOversizeEntries() {
        let expired = ClipboardHistoryEntry(text: "expired", copiedAt: now.addingTimeInterval(-7 * 86_400))
        let valid = ClipboardHistoryEntry(text: "valid", copiedAt: now.addingTimeInterval(-7 * 86_400 + 1))
        let tooLarge = ClipboardHistoryEntry(text: String(repeating: "é", count: ClipboardHistory.maximumEntryBytes), copiedAt: now)
        #expect(ClipboardHistory.retaining([expired, valid, tooLarge], now: now) == [valid])
        #expect(!ClipboardHistory.accepts(""))
    }

    @Test func countAndByteCapsKeepNewestEntries() {
        let entries = (0..<1_005).map {
            ClipboardHistoryEntry(text: "copy \($0)", copiedAt: now.addingTimeInterval(-Double($0)))
        }
        let retained = ClipboardHistory.retaining(entries, now: now)
        #expect(retained.count == 1_000)
        #expect(retained.last?.id == entries[999].id)
        let largeEntries = (0..<140).map {
            ClipboardHistoryEntry(text: String(repeating: "x", count: ClipboardHistory.maximumEntryBytes - 8) + "\($0)", copiedAt: now.addingTimeInterval(-Double($0)))
        }
        let capped = ClipboardHistory.retaining(largeEntries, now: now)
        #expect(capped.reduce(0) { $0 + $1.text.utf8.count } <= ClipboardHistory.maximumTotalBytes)
        #expect(capped.count == 128)
    }

    @Test func fullTextSearchIsCaseAndDiacriticInsensitiveAndPreservesOrder() {
        let first = ClipboardHistoryEntry(text: "first line\nCafé TOKEN", copiedAt: now)
        let second = ClipboardHistoryEntry(text: "token", copiedAt: now)
        #expect(ClipboardHistory.search("cafe token", in: [first, second]) == [first])
        #expect(ClipboardHistory.search(" ", in: [first, second]) == [first, second])
    }

    @Test func sensitiveTransientFileAndExcludedCopiesAreRejected() {
        for marker in ClipboardHistoryCapturePolicy.ignoredTypes {
            #expect(!ClipboardHistoryCapturePolicy.permits(types: ["public.utf8-plain-text", marker], sourceBundleID: nil, excludedBundleIDs: []))
        }
        #expect(!ClipboardHistoryCapturePolicy.permits(types: ["public.utf8-plain-text"], sourceBundleID: "example.private", excludedBundleIDs: ["example.private"]))
        #expect(ClipboardHistoryCapturePolicy.permits(types: ["public.utf8-plain-text", "public.html"], sourceBundleID: "example.editor", excludedBundleIDs: []))
        #expect(!ClipboardHistoryCapturePolicy.permits(types: ["public.png"], sourceBundleID: nil, excludedBundleIDs: []))
        #expect(!ClipboardHistoryCapturePolicy.permits(types: ["public.utf8-plain-text", "com.apple.is-sensitive"], sourceBundleID: nil, excludedBundleIDs: []))
    }

    @Test func FutureClockDatesCannotRetainCopiesForever() {
        let future = ClipboardHistoryEntry(text: "copy", copiedAt: now.addingTimeInterval(30 * 86_400))
        let retained = ClipboardHistory.retaining([future], now: now)
        #expect(retained.first?.copiedAt == now)
        #expect(ClipboardHistory.retaining(retained, now: now.addingTimeInterval(7 * 86_400)).isEmpty)
    }
}
