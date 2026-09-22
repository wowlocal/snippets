#if os(macOS)
import AppKit
import XCTest
@testable import Snippets_Debug

@MainActor
final class ClipboardHistoryPasteTransactionTests: XCTestCase {
    func testLiteralHistoryRemainsCurrentAndCanBePastedAgainWithoutWaiting() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("Previous rich clipboard", forType: .html)
        let text = "  Literal {clipboard}\n🔑 end  "
        var dispatched: [String?] = []
        for value in [text, "Second entry"] {
            let result = ClipboardHistoryPasteTransaction.paste(value, to: pasteboard,
                validateTarget: { nil }, prepareClipboard: { true }, prepareShortcut: {
                    { dispatched.append(pasteboard.string(forType: .string)) }
                })
            XCTAssertEqual(result, .dispatched)
            XCTAssertNil(result.message)
            XCTAssertEqual(dispatched.last, value, "Dispatch finishes before returning to the picker")
            XCTAssertEqual(pasteboard.string(forType: .string), value)
            let types = Set(try XCTUnwrap(pasteboard.types))
            XCTAssertTrue(types.contains(.string))
            XCTAssertTrue(types.contains(ClipboardHistoryPasteTransaction.internalType))
            XCTAssertFalse(types.contains(.html), "The previous clipboard's rich flavors must not survive")
            XCTAssertFalse(types.contains(.init("org.nspasteboard.TransientType")))
            XCTAssertFalse(types.contains(.init("org.nspasteboard.ConcealedType")))
        }
        await Task.yield()
        XCTAssertEqual(dispatched, [text, "Second entry"])
        XCTAssertEqual(pasteboard.string(forType: .string), "Second entry")
        pasteboard.clearContents()
        pasteboard.setString("New external copy", forType: .string)
        await Task.yield()
        XCTAssertEqual(pasteboard.string(forType: .string), "New external copy")
    }

    func testPendingSnippetLeasePreventsOverwritingItsClipboard() {
        let pasteboard = HistoryWritePasteboard()
        let result = ClipboardHistoryPasteTransaction.paste("Entry", to: pasteboard,
            validateTarget: { nil }, prepareClipboard: { false },
            prepareShortcut: { { XCTFail("A live snippet loan must not be pasted over") } })
        XCTAssertEqual(result, .clipboardUnavailable)
        XCTAssertEqual(pasteboard.clearCount, 0)
        XCTAssertEqual(pasteboard.writeCount, 0)
    }

    func testUnavailableEventsLeaveClipboardUntouched() {
        let pasteboard = HistoryWritePasteboard()
        let result = ClipboardHistoryPasteTransaction.paste("Entry", to: pasteboard,
            validateTarget: { nil }, prepareClipboard: { XCTFail("Events must be prepared first"); return true },
            prepareShortcut: { nil })
        XCTAssertEqual(result, .eventCreationFailed)
        XCTAssertEqual(pasteboard.clearCount, 0)
    }

    func testChangedTargetBeforePublishingLeavesClipboardUntouched() {
        for failureAtCheck in [1, 2] {
            let pasteboard = HistoryWritePasteboard()
            var checks = 0
            let result = ClipboardHistoryPasteTransaction.paste("Entry", to: pasteboard,
                validateTarget: {
                    checks += 1
                    return checks == failureAtCheck ? .focusedElementChanged : nil
                }, prepareClipboard: { true },
                prepareShortcut: { { XCTFail("A changed destination must not receive paste") } })
            XCTAssertEqual(result, .interrupted)
            XCTAssertEqual(pasteboard.clearCount, 0)
            XCTAssertEqual(pasteboard.writeCount, 0)
        }
    }

    func testChangedTargetAfterPublishingDoesNotSendShortcutOrRestoreOldContent() {
        let pasteboard = HistoryWritePasteboard()
        var checks = 0
        let result = ClipboardHistoryPasteTransaction.paste("Selected entry", to: pasteboard,
            validateTarget: {
                checks += 1
                return checks == 3 ? .focusedElementChanged : nil
            }, prepareClipboard: { true },
            prepareShortcut: { { XCTFail("The final target check must precede dispatch") } })
        XCTAssertEqual(result, .interrupted)
        XCTAssertEqual(pasteboard.items.first?.string(forType: .string), "Selected entry")
        XCTAssertEqual(pasteboard.writeCount, 1)
    }

    func testNewerCopyWinsBeforeDispatch() {
        let pasteboard = HistoryWritePasteboard()
        var checks = 0
        let result = ClipboardHistoryPasteTransaction.paste("Selected entry", to: pasteboard,
            validateTarget: {
                checks += 1
                if checks == 3 {
                    pasteboard.externalCopy("New external copy")
                }
                return nil
            }, prepareClipboard: { true },
            prepareShortcut: { { XCTFail("A superseded entry must never dispatch") } })
        XCTAssertEqual(result, .pasteboardSuperseded)
        XCTAssertEqual(pasteboard.items.first?.string(forType: .string), "New external copy")
        XCTAssertEqual(pasteboard.writeCount, 1)
    }

    func testFailedClipboardWriteDoesNotDispatchOrReadOldContent() {
        let pasteboard = HistoryWritePasteboard()
        pasteboard.acceptsWrites = false
        let result = ClipboardHistoryPasteTransaction.paste("Entry", to: pasteboard,
            validateTarget: { nil }, prepareClipboard: { true },
            prepareShortcut: { { XCTFail("Failed publication must not send paste") } })
        XCTAssertEqual(result, .clipboardUnavailable)
        XCTAssertEqual(pasteboard.writeCount, 1)
        XCTAssertNotNil(result.message)
    }

    func testSecureInputAppearingBeforeDispatchStopsPaste() {
        let pasteboard = HistoryWritePasteboard()
        var checks = 0
        let result = ClipboardHistoryPasteTransaction.paste("Entry", to: pasteboard,
            validateTarget: {
                checks += 1
                return checks == 3 ? .secureInputEnabled : nil
            }, prepareClipboard: { true },
            prepareShortcut: { { XCTFail("Secure input must stop ordinary history paste") } })
        XCTAssertEqual(result, .interrupted)
    }
}

@MainActor
private final class HistoryWritePasteboard: SnippetPasteboardAccess {
    var changeCount = 0
    var items: [NSPasteboardItem] = []
    var acceptsWrites = true
    var clearCount = 0
    var writeCount = 0
    var pasteboardItems: [NSPasteboardItem]? {
        XCTFail("History must not snapshot clipboard contents or start a loan")
        return items
    }

    func clearContents() -> Int {
        clearCount += 1
        changeCount += 1
        items = []
        return changeCount
    }

    func prepareForNewContents(with options: NSPasteboard.ContentsOptions) -> Int {
        XCTFail("History does not create a concealed snippet loan")
        return changeCount
    }

    func writeObjects(_ objects: [any NSPasteboardWriting]) -> Bool {
        writeCount += 1
        guard acceptsWrites else { return false }
        items = objects.compactMap { $0 as? NSPasteboardItem }
        return true
    }

    func externalCopy(_ text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        changeCount += 1
        items = [item]
    }
}
#endif
