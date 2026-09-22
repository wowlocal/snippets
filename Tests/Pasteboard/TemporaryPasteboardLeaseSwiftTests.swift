import AppKit
import Testing
@testable import SnippetsPasteboard

@MainActor
private final class FakePasteboard: SnippetPasteboardAccess {
    var changeCount = 7
    var items: [NSPasteboardItem] = []
    var itemListIsReadable = true
    var writeFailuresRemaining = 0
    var writesAlwaysFail = false
    private(set) var writeCallCount = 0
    private(set) var lastContentsOptions: NSPasteboard.ContentsOptions?
    var onWrite: ((FakePasteboard) -> Void)?

    var pasteboardItems: [NSPasteboardItem]? { itemListIsReadable ? items : nil }

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        items = []
        lastContentsOptions = nil
        return changeCount
    }

    @discardableResult
    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        let count = clearContents()
        lastContentsOptions = options
        return count
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeCallCount += 1
        onWrite?(self)
        if writeFailuresRemaining > 0 {
            writeFailuresRemaining -= 1
            return false
        }
        guard !writesAlwaysFail else { return false }
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }
}

private final class UnreadableItem: NSPasteboardItem {
    override func data(forType type: NSPasteboard.PasteboardType) -> Data? { nil }
}

@MainActor
private func item(_ values: [(NSPasteboard.PasteboardType, String)]) -> NSPasteboardItem {
    let result = NSPasteboardItem()
    for (type, value) in values {
        result.setData(Data(value.utf8), forType: type)
    }
    return result
}

private let tiff = NSPasteboard.PasteboardType("public.tiff")
private let html = NSPasteboard.PasteboardType("public.html")

@MainActor
private func acquiredLease(
    text: String,
    pasteboard: FakePasteboard,
    isConcealed: Bool = false
) -> TemporaryPasteboardLease? {
    TemporaryPasteboardLease.begin(
        text: text,
        pasteboard: pasteboard,
        isConcealed: isConcealed
    ).acquiredLease
}

@Suite("Temporary pasteboard lease")
@MainActor
struct TemporaryPasteboardLeaseSwiftTests {
    @Test("history acknowledges only a successfully restored generation")
    func historyRestoreCallbackPreservesNewUserCopies() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "original")])]
        var restored: [Int] = []
        let lease = try #require(TemporaryPasteboardLease.begin(text: "{clipboard}",
            pasteboard: pasteboard, onRestore: { restored.append($0) }).acquiredLease)
        #expect(restored.isEmpty)
        #expect(pasteboard.items.first?.string(forType: .string) == "{clipboard}")
        #expect(lease.restoreWithRetries())
        #expect(restored == [pasteboard.changeCount])
        _ = lease.restoreIfOwned()
        #expect(restored.count == 1)

        let second = try #require(TemporaryPasteboardLease.begin(text: "temporary",
            pasteboard: pasteboard, onRestore: { restored.append($0) }).acquiredLease)
        pasteboard.clearContents()
        pasteboard.items = [item([(.string, "new copy")])]
        #expect(second.restoreIfOwned() == .superseded)
        #expect(restored.count == 1)
        #expect(pasteboard.items.first?.string(forType: .string) == "new copy")
    }

    @Test("failed acquisition rollback is acknowledged without hiding a foreign copy")
    func historyObservesAcquisitionRollback() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "original")])]
        pasteboard.writeFailuresRemaining = 1
        var restored: [Int] = []
        let result = TemporaryPasteboardLease.begin(text: "temporary", pasteboard: pasteboard,
            onRestore: { restored.append($0) })
        #expect(result.isRefused)
        #expect(restored == [pasteboard.changeCount])
        #expect(pasteboard.items.first?.string(forType: .string) == "original")
    }

    @Test("a rich multi-item clipboard lends only replacement text")
    func temporaryLeaseExcludesEveryOriginalRepresentation() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [
            item([(.string, "user text"), (html, "<b>user text</b>"), (.rtf, "old rtf")]),
            item([(tiff, "image bytes")]),
        ]
        let before = pasteboard.changeCount

        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))

        #expect(pasteboard.changeCount == before + 1)
        #expect(pasteboard.items.count == 1)
        #expect(Set(pasteboard.items[0].types) == [
            .string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        ])
        #expect(pasteboard.items[0].string(forType: .string) == "snippet")
        // This fake retains un-published NSPasteboardItems. AppKit's availableType lookup
        // requires a published item on some macOS versions; the real named-board test below
        // exercises that lookup. Here prove the actual representation contract directly.
        #expect(pasteboard.items[0].data(forType: .html) == nil)
        #expect(pasteboard.items[0].data(forType: .rtf) == nil)
        #expect(lease.isOwned)
    }

    @Test("restoration publishes the complete original as a new generation")
    func restorePublishesOriginalSnapshot() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text"), (html, "<b>user text</b>")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        let owned = pasteboard.changeCount

        #expect(lease.restoreIfOwned() == .restored(changeCount: owned + 1))
        #expect(pasteboard.changeCount == owned + 1)
        #expect(pasteboard.items[0].string(forType: .string) == "user text")
        #expect(pasteboard.items[0].data(forType: html).flatMap { String(data: $0, encoding: .utf8) }
            == "<b>user text</b>")
    }

    @Test("a newer owner supersedes the lease and survives untouched")
    func newerCopySupersedesLease() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))

        pasteboard.clearContents()
        pasteboard.items = [item([(.string, "new user copy")])]

        #expect(!lease.isOwned)
        #expect(lease.restoreIfOwned() == .superseded)
        #expect(pasteboard.items[0].string(forType: .string) == "new user copy")
    }

    @Test("restore is idempotent")
    func restoreIsIdempotent() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        let owned = pasteboard.changeCount

        #expect(lease.restoreIfOwned() == .restored(changeCount: owned + 1))
        #expect(lease.restoreIfOwned() == .superseded)
        #expect(pasteboard.items[0].string(forType: .string) == "user text")
    }

    @Test("a nil item list is an unavailable snapshot, not an empty clipboard")
    func unavailableItemListIsRefusedWithoutClearing() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        pasteboard.itemListIsReadable = false
        let before = pasteboard.changeCount

        #expect(TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard).isRefused)
        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.items[0].string(forType: .string) == "user text")
    }

    @Test("one unreadable flavor refuses the entire snapshot")
    func unreadableFlavorIsRefusedWithoutClearing() {
        let pasteboard = FakePasteboard()
        let unreadable = UnreadableItem()
        unreadable.setData(Data("promised".utf8), forType: .string)
        pasteboard.items = [unreadable]
        let before = pasteboard.changeCount

        #expect(TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard).isRefused)
        #expect(pasteboard.changeCount == before)
        #expect(pasteboard.items.count == 1)
    }

    @Test("failed acquisition retries rollback with fresh item objects")
    func transientAcquisitionFailureRestoresOriginalSnapshot() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        // Temporary write plus two rollback writes fail; the third rollback lands.
        pasteboard.writeFailuresRemaining = 3

        #expect(TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard).isRefused)
        #expect(pasteboard.writeCallCount == 4)
        #expect(pasteboard.items.first?.string(forType: .string) == "user text")
    }

    @Test("exhausted acquisition rollback retains a lease for later recovery")
    func exhaustedAcquisitionRollbackRetainsSnapshot() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        // The temporary write and all three immediate rollback writes fail.
        pasteboard.writeFailuresRemaining = 4

        let result = TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard)
        let pending: TemporaryPasteboardLease
        switch result {
        case .recoveryPending(let lease):
            pending = lease
        case .acquired, .refused:
            Issue.record("exhausted rollback must retain the captured snapshot")
            return
        }
        #expect(pending.isOwned)
        #expect(pasteboard.items.isEmpty)

        // The pasteboard server recovers later; the retained production lease can still repay
        // the debt instead of having discarded the only copy of the user's bytes.
        #expect(pending.restoreWithRetries())
        #expect(pasteboard.items.first?.string(forType: .string) == "user text")
    }

    @Test("a user copy made inside a failed acquisition prevents rollback")
    func userCopyDuringFailedAcquisitionWins() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "old user text")])]
        pasteboard.writeFailuresRemaining = 1
        pasteboard.onWrite = { board in
            guard board.writeCallCount == 1 else { return }
            board.onWrite = nil
            board.clearContents()
            board.items = [item([(.string, "new user copy")])]
        }

        #expect(TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard).isRefused)
        #expect(pasteboard.writeCallCount == 1)
        #expect(pasteboard.items.first?.string(forType: .string) == "new user copy")
    }

    @Test("one failed temporary write immediately rolls back the original")
    func failedTemporaryWriteRestoresOriginal() {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        pasteboard.writeFailuresRemaining = 1

        #expect(TemporaryPasteboardLease.begin(text: "snippet", pasteboard: pasteboard).isRefused)
        #expect(pasteboard.items.first?.string(forType: .string) == "user text")
    }

    @Test("concealed markers exist only while secret text is borrowed")
    func concealedLeaseMarksOnlyTemporaryItem() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(.string, "user text")])]
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        let lease = try #require(acquiredLease(
            text: "secret", pasteboard: pasteboard, isConcealed: true))

        #expect(pasteboard.items[0].types.contains(concealed))
        #expect(pasteboard.items[0].types.contains(transient))
        let restore = lease.restoreIfOwned()
        #expect(restore == .restored(changeCount: pasteboard.changeCount))
        #expect(pasteboard.items[0].string(forType: .string) == "user text")
        #expect(!pasteboard.items[0].types.contains(concealed))
        #expect(!pasteboard.items[0].types.contains(transient))
    }

    @Test("concealed writes stay on this Mac while ordinary writes remain universal")
    func concealedWritesAreCurrentHostOnly() {
        let concealed = FakePasteboard()
        _ = acquiredLease(text: "secret", pasteboard: concealed, isConcealed: true)
        #expect(concealed.lastContentsOptions == .currentHostOnly)

        let ordinary = FakePasteboard()
        _ = acquiredLease(text: "ordinary", pasteboard: ordinary)
        #expect(ordinary.lastContentsOptions == nil)
    }

    @Test("an empty clipboard can be borrowed and restored to empty")
    func emptyPasteboardUsesRewrite() throws {
        let pasteboard = FakePasteboard()
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))

        #expect(pasteboard.items[0].string(forType: .string) == "snippet")
        let restore = lease.restoreIfOwned()
        #expect(restore == .restored(changeCount: pasteboard.changeCount))
        #expect(pasteboard.items.isEmpty)
    }

    @Test("an image-first clipboard is restored byte for byte")
    func imageFirstPasteboardUsesRewrite() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(tiff, "image bytes")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))

        #expect(pasteboard.items[0].string(forType: .string) == "snippet")
        let restore = lease.restoreIfOwned()
        #expect(restore == .restored(changeCount: pasteboard.changeCount))
        let restored = pasteboard.items[0].data(forType: tiff)
            .flatMap { String(data: $0, encoding: .utf8) }
        #expect(restored == "image bytes")
    }

    @Test("one failed restore write recovers with fresh objects")
    func failedRestoreWriteRecoversImmediately() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(tiff, "image bytes")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        pasteboard.writeFailuresRemaining = 1

        #expect(lease.restoreIfOwned() == .restored(changeCount: pasteboard.changeCount))
        let restored = pasteboard.items[0].data(forType: tiff)
            .flatMap { String(data: $0, encoding: .utf8) }
        #expect(restored == "image bytes")
        #expect(!lease.isOwned)
    }

    @Test("a user copy made inside a failed restore is never overwritten")
    func userCopyDuringFailedRestoreWins() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(tiff, "image bytes")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        let acquisitionWrites = pasteboard.writeCallCount
        pasteboard.writeFailuresRemaining = 1
        pasteboard.onWrite = { board in
            guard board.writeCallCount == acquisitionWrites + 1 else { return }
            board.onWrite = nil
            board.clearContents()
            board.items = [item([(.string, "new user copy")])]
        }

        #expect(lease.restoreIfOwned() == .superseded)
        #expect(pasteboard.writeCallCount == acquisitionWrites + 1)
        #expect(pasteboard.items.first?.string(forType: .string) == "new user copy")
    }

    @Test("the production retry policy restores after transient failures")
    func productionRetryPolicyIsExercised() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(tiff, "image bytes")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        // Two writes per failed attempt. The third attempt succeeds.
        pasteboard.writeFailuresRemaining = 4

        #expect(lease.restoreWithRetries())
        #expect(!lease.isOwned)
        let restored = pasteboard.items.first?.data(forType: tiff)
            .flatMap { String(data: $0, encoding: .utf8) }
        #expect(restored == "image bytes")
    }

    @Test("permanent write failure remains an explicit debt")
    func permanentRestoreFailureRemainsOwned() throws {
        let pasteboard = FakePasteboard()
        pasteboard.items = [item([(tiff, "image bytes")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: pasteboard))
        pasteboard.writesAlwaysFail = true

        #expect(!lease.restoreWithRetries())
        #expect(lease.isOwned)
        #expect(lease.lastRestoreResult == .failed)
        pasteboard.writesAlwaysFail = false
        #expect(lease.restoreWithRetries())
        #expect(lease.lastRestoreResult == .restored(changeCount: pasteboard.changeCount))
        #expect(pasteboard.items.first?.data(forType: tiff) == Data("image bytes".utf8))
    }

    @Test("real pasteboard isolates formats and restores every item byte for byte")
    func realPasteboardRoundTrip() throws {
        // Never use .general: tests must not borrow the user's clipboard.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("com.example.editor-fragment")
        let original = [
            item([(.html, "<b>original</b>"), (.rtf, "{\\rtf1 original}"),
                  (.string, "original"), (custom, "opaque editor payload")]),
            item([(.string, "second item"), (tiff, "image bytes")]),
        ]
        #expect(board.writeObjects(original))
        let snapshot = PasteboardSnapshot(reading: board)
        let lease = try #require(TemporaryPasteboardLease.begin(
            text: "replacement\nsecond line 🎉", pasteboard: board).acquiredLease)
        let temporary = try #require(board.pasteboardItems?.first)
        #expect(board.pasteboardItems?.count == 1)
        #expect(Set(temporary.types) == [
            .string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        ])
        #expect(temporary.availableType(from: [.html, .rtf, custom, .string]) == .string)
        #expect(temporary.string(forType: .string) == "replacement\nsecond line 🎉")
        let editor = NSTextView()
        editor.isRichText = true
        #expect(editor.readSelection(from: board))
        #expect(editor.string == "replacement\nsecond line 🎉")
        let borrowedCount = board.changeCount
        #expect(lease.restoreWithRetries())
        #expect(board.changeCount != borrowedCount)
        let restored = try #require(board.pasteboardItems)
        let savedItems = try #require(snapshot.items)
        #expect(restored.count == savedItems.count)
        for (actual, saved) in zip(restored, savedItems) {
            #expect(actual.types == saved.values.map(\.type))
            for value in saved.values { #expect(actual.data(forType: value.type) == value.data) }
        }
    }

    @Test("rich text recovery retains all formats after exhausting immediate retries")
    func richTextRecoverySurvivesExhaustedRetries() throws {
        let board = FakePasteboard()
        board.items = [item([(.string, "original"), (.html, "<b>original</b>")])]
        let lease = try #require(acquiredLease(text: "snippet", pasteboard: board))
        board.writeFailuresRemaining = 6
        #expect(!lease.restoreWithRetries())
        #expect(lease.isOwned)
        #expect(lease.lastRestoreResult == .failed)
        #expect(board.items.isEmpty)
        #expect(lease.restoreWithRetries())
        #expect(board.items.first?.string(forType: .string) == "original")
        #expect(board.items.first?.data(forType: .html) == Data("<b>original</b>".utf8))
        #expect(lease.lastRestoreResult == .restored(changeCount: board.changeCount))
    }
}
