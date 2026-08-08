import AppKit

// Standalone executable, matching Tests/AXCoordinateSpaceTests.swift.
// Build and run:
//
//   swiftc -O snippets/TemporaryPasteboardLease.swift \
//          Tests/TemporaryPasteboardLeaseTests.swift -o /tmp/pasteboard-lease-tests \
//          && /tmp/pasteboard-lease-tests

private func assertEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
        fputs("FAIL: \(message) - expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

private func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

/// Models the parts of NSPasteboard the lease depends on: `clearContents` bumps the change count,
/// `writeObjects` does not.
@MainActor
private final class FakePasteboard: SnippetPasteboardAccess {
    var changeCount = 7
    var items: [NSPasteboardItem] = []
    var writeObjectsSucceeds = true

    var pasteboardItems: [NSPasteboardItem]? { items }

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        items = []
        lastContentsOptions = nil
        return changeCount
    }

    /// Recorded so a test can assert that a concealed write was scoped to this Mac.
    /// Universal Clipboard would otherwise carry the secret to devices where the
    /// `ConcealedType` marker means nothing.
    private(set) var lastContentsOptions: NSPasteboard.ContentsOptions?

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        changeCount += 1
        items = []
        lastContentsOptions = options
        return changeCount
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        guard writeObjectsSucceeds else { return false }
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

/// An item whose payload cannot be read back, like a promised or lazily-provided flavor.
private final class UnreadableItem: NSPasteboardItem {
    override func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
}

@MainActor
private func makeItem(_ values: [(NSPasteboard.PasteboardType, String)]) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    for (type, value) in values {
        item.setData(Data(value.utf8), forType: type)
    }
    return item
}

private let html = NSPasteboard.PasteboardType("public.html")
private let tiff = NSPasteboard.PasteboardType("public.tiff")

@main
private enum TemporaryPasteboardLeaseTests {
    static func main() {
        MainActor.assumeIsolated { run() }
    }

    @MainActor
    private static func run() {
        testInPlaceLeasePreservesShape()
        testInPlaceRestoreDoesNotBumpChangeCount()
        testSupersededByAnotherCopy()
        testRestoreIsIdempotent()
        testUnreadablePasteboardIsRefused()
        testFailedWriteRestoresOriginals()
        testConcealedLeaseMarksOnlyTemporaryItem()
        testEmptyPasteboardUsesRewrite()
        testImageFirstPasteboardUsesRewrite()
        testConcealedWritesAreScopedToThisHost()
        print("TemporaryPasteboardLease tests passed")
    }

    @MainActor
    private static func testInPlaceLeasePreservesShape() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [
            makeItem([(.string, "user text"), (html, "<b>user text</b>")]),
            makeItem([(tiff, "image bytes")])
        ]
        let before = pasteboard.changeCount

        guard let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard) else {
            fputs("FAIL: expected a lease over a plain-text pasteboard\n", stderr)
            exit(1)
        }

        assertEqual(pasteboard.changeCount, before + 1, "taking the lease costs exactly one change count")
        assertEqual(pasteboard.items.count, 2, "every item is preserved")
        assertEqual(pasteboard.items[0].string(forType: .string), "snippet", "only the first string is swapped")
        assertEqual(
            pasteboard.items[0].types,
            [.string, html],
            "type declaration order survives the swap"
        )
        assertEqual(
            pasteboard.items[0].data(forType: html).flatMap { String(data: $0, encoding: .utf8) },
            "<b>user text</b>",
            "richer flavors of the first item are untouched"
        )
        assertEqual(
            pasteboard.items[1].data(forType: tiff).flatMap { String(data: $0, encoding: .utf8) },
            "image bytes",
            "later items are untouched"
        )
        assertTrue(lease.isOwned, "the lease owns the pasteboard it just wrote")
    }

    @MainActor
    private static func testInPlaceRestoreDoesNotBumpChangeCount() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(.string, "user text"), (html, "<b>user text</b>")])]

        let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard)!
        let owned = pasteboard.changeCount

        assertEqual(lease.restoreIfOwned(), .restored(changeCount: owned), "restoring reports the owned count")
        // This is the whole point: a clipboard manager polling change counts sees one write, not two.
        assertEqual(pasteboard.changeCount, owned, "handing the clipboard back costs no change count")
        assertEqual(pasteboard.items[0].string(forType: .string), "user text", "the user's text is back")
        assertEqual(
            pasteboard.items[0].data(forType: html).flatMap { String(data: $0, encoding: .utf8) },
            "<b>user text</b>",
            "the other flavors were never disturbed"
        )
    }

    @MainActor
    private static func testSupersededByAnotherCopy() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(.string, "user text")])]

        let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard)!
        pasteboard.clearContents()
        pasteboard.items = [makeItem([(.string, "something the user just copied")])]

        assertTrue(!lease.isOwned, "a newer copy takes the pasteboard away from us")
        assertEqual(lease.restoreIfOwned(), .superseded, "we never overwrite a newer copy")
        assertEqual(
            pasteboard.items[0].string(forType: .string),
            "something the user just copied",
            "the newer copy survives untouched"
        )
    }

    @MainActor
    private static func testRestoreIsIdempotent() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(.string, "user text")])]

        let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard)!
        let owned = pasteboard.changeCount

        assertEqual(lease.restoreIfOwned(), .restored(changeCount: owned), "first restore succeeds")
        assertEqual(lease.restoreIfOwned(), .superseded, "a repeat restore is a no-op")
        assertEqual(pasteboard.items[0].string(forType: .string), "user text", "the repeat did not rewrite anything")
    }

    @MainActor
    private static func testUnreadablePasteboardIsRefused() {
        let pasteboard = FakePasteboard()
        let unreadable = UnreadableItem()
        unreadable.setData(Data("promised".utf8), forType: .string)
        pasteboard.items = [unreadable]
        let before = pasteboard.changeCount

        // Refusing here is what lets the caller abandon the expansion before it deletes anything.
        assertTrue(
            TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard) == nil,
            "a pasteboard we cannot snapshot is refused"
        )
        assertEqual(pasteboard.changeCount, before, "a refused lease leaves the pasteboard alone")
        assertEqual(pasteboard.items.count, 1, "the user's item is still there")
    }

    @MainActor
    private static func testFailedWriteRestoresOriginals() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(.string, "user text")])]
        pasteboard.writeObjectsSucceeds = false

        assertTrue(
            TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard) == nil,
            "a pasteboard that refuses our write yields no lease"
        )
        pasteboard.writeObjectsSucceeds = true
        assertTrue(pasteboard.items.isEmpty, "the failed write left the pasteboard cleared")
    }

    @MainActor
    private static func testConcealedLeaseMarksOnlyTemporaryItem() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(.string, "user text")])]
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

        guard let lease = TemporaryPasteboardLease.begin(
            text: "secret", pasteboard: pasteboard, isConcealed: true
        ) else {
            fputs("FAIL: a secure snippet should still get a pasteboard lease\n", stderr)
            exit(1)
        }

        assertTrue(pasteboard.items[0].types.contains(concealed), "secure content is marked concealed")
        assertTrue(pasteboard.items[0].types.contains(transient), "secure content is marked transient")
        assertTrue(lease.restoreIfOwned() != .failed, "the concealed lease restores")
        assertEqual(pasteboard.items[0].string(forType: .string), "user text", "the user's text returns")
        assertTrue(!pasteboard.items[0].types.contains(concealed), "concealment does not contaminate restored data")
        assertTrue(!pasteboard.items[0].types.contains(transient), "transience does not contaminate restored data")
    }

    @MainActor
    private static func testEmptyPasteboardUsesRewrite() {
        let pasteboard = FakePasteboard()
        pasteboard.items = []

        // An empty clipboard is ordinary — right after login, or after the user cleared it — so it
        // must still expand rather than refuse.
        guard let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard) else {
            fputs("FAIL: an empty pasteboard must still be leasable\n", stderr)
            exit(1)
        }
        assertEqual(pasteboard.items[0].string(forType: .string), "snippet", "the snippet is on the pasteboard")

        assertTrue(lease.restoreIfOwned() != .failed, "restoring an empty snapshot succeeds")
        assertTrue(pasteboard.items.isEmpty, "the clipboard goes back to being empty, not to holding our snippet")
    }

    @MainActor
    private static func testImageFirstPasteboardUsesRewrite() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [makeItem([(tiff, "image bytes")])]

        guard let lease = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard) else {
            fputs("FAIL: an image-first pasteboard must still be leasable\n", stderr)
            exit(1)
        }
        assertEqual(pasteboard.items[0].string(forType: .string), "snippet", "the snippet is on the pasteboard")

        assertTrue(lease.restoreIfOwned() != .failed, "restoring an image snapshot succeeds")
        assertEqual(
            pasteboard.items[0].data(forType: tiff).flatMap { String(data: $0, encoding: .utf8) },
            "image bytes",
            "the user's image comes back byte for byte"
        )
    }

// MARK: - Concealed writes stay on this Mac

/// A secret on the fallback pasteboard path must not reach Universal Clipboard.
/// `org.nspasteboard.ConcealedType` is a macOS clipboard-manager convention; an iPhone
/// receiving the same clipboard has never heard of it, so scoping the write is the only
/// part of the concealed path that is a control rather than a courtesy.
    @MainActor
    private static func testConcealedWritesAreScopedToThisHost() {
    let pasteboard = FakePasteboard()
    _ = pasteboard.clearContents()

    _ = TemporaryPasteboardLease.begin(text: "hunter2", pasteboard: pasteboard, isConcealed: true)
    assertEqual(
        pasteboard.lastContentsOptions, .currentHostOnly,
        "a concealed write must be scoped to the current host")

    // And the ordinary path must NOT be scoped — de-scoping the user's own clipboard
    // would silently break their Universal Clipboard for everything else.
    let plain = FakePasteboard()
    _ = plain.clearContents()
    _ = TemporaryPasteboardLease.begin(text: "ordinary", pasteboard: plain, isConcealed: false)
    assertEqual(plain.lastContentsOptions, nil, "an ordinary write must not be host-scoped")
    }

}

