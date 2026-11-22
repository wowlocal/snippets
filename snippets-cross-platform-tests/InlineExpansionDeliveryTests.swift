#if os(macOS)
import XCTest
@testable import Snippets_Debug

@MainActor
final class InlineExpansionDeliveryTests: XCTestCase {
    func testReadableRendererDoesNotRequireASelectionSetter() throws {
        let proof = try XCTUnwrap(VerifiedTriggerSelection.make(deletion: .confirmed(.init(query: "ab", triggerLength: 3)),
            textBeforeCaret: "😀 \\ab", originalSelection: NSRange(location: 6, length: 2), selectedText: "🌻"))
        let plan = try XCTUnwrap(InlineSelectionPlan(proof: proof, editorHandlesSelection: true,
                                                   fieldLength: nil, canSetRange: false))
        XCTAssertEqual(plan.steps.first?.before, proof.originalSelection)
        XCTAssertEqual(plan.steps.map(\.range), [NSRange(location: 8, length: 0), NSRange(location: 6, length: 2),
            NSRange(location: 5, length: 3), NSRange(location: 4, length: 4), NSRange(location: 3, length: 5)])
        XCTAssertNil(InlineSelectionPlan(proof: proof, editorHandlesSelection: false, fieldLength: nil, canSetRange: false))
    }

    func testSelectionPlansPreserveUnicodeNeighborsAtTheLongSelectionBoundary() throws {
        let query = "fi"
        let trigger = "\\" + query
        let deletion = TriggerDeletion.confirmed(.init(query: query, triggerLength: trigger.count))
        let suffixes = ["", "e\u{301}", "👩🏽‍💻", "שלום", String(repeating: "🐝", count: 60),
                        String(repeating: "🐝", count: 60) + "x"]
        for prefix in ["", "אבג ", "👨‍👩‍👧‍👦 ", "one\ntwo "] {
            for suffix in suffixes {
                let before = prefix + trigger
                let selected = NSRange(location: before.utf16.count, length: suffix.utf16.count)
                let proof = try XCTUnwrap(VerifiedTriggerSelection.make(deletion: deletion, textBeforeCaret: before,
                                                                       originalSelection: selected, selectedText: suffix))
                for canSet in [true, false] {
                    for trailing in ["", " tail"] {
                        let full = (before + suffix + trailing) as NSString
                        let plan = try XCTUnwrap(InlineSelectionPlan(proof: proof, editorHandlesSelection: true,
                                                                    fieldLength: full.length, canSetRange: canSet))
                        var selection = selected
                        for step in plan.steps {
                            XCTAssertEqual(step.before, selection)
                            XCTAssertGreaterThanOrEqual(step.range.location, prefix.utf16.count)
                            XCTAssertLessThanOrEqual(NSMaxRange(step.range), NSMaxRange(selected))
                            selection = step.range
                        }
                        XCTAssertEqual(full.replacingCharacters(in: selection, with: "X"), prefix + "X" + trailing)
                        if suffix.utf16.count > 120, prefix.isEmpty, trailing.isEmpty {
                            XCTAssertEqual(plan.steps.map(\.command), [.selectAll])
                        } else if suffix.utf16.count > 120, canSet {
                            XCTAssertEqual(plan.steps.map(\.command), [.setRange])
                        } else {
                            XCTAssertEqual(plan.steps.last?.command, .extendLeft)
                        }
                    }
                }
            }
        }
    }

    func testReadbackRequiresTheFullRendererTextAndExactCaret() throws {
        let tail = String(repeating: "a", count: 40)
        let receipt = try XCTUnwrap(InlinePasteReadback(location: 3, text: "😀" + tail))
        let caret = CFRange(location: 45, length: 0)
        XCTAssertEqual(receipt.progress(caret: caret) { range in
            XCTAssertEqual(range.location, 3)
            XCTAssertEqual(range.length, 42)
            return "😀" + tail
        }, .pasteObserved)
        XCTAssertEqual(receipt.progress(caret: caret) { _ in "🫐" + tail }, .pendingEditObserved)
        XCTAssertEqual(receipt.progress(caret: caret) { _ in nil }, .unreadable)
        XCTAssertEqual(receipt.progress(caret: CFRange(location: 44, length: 0)) { _ in
            XCTFail("A different caret cannot acknowledge this paste")
            return nil
        }, .idle)
        XCTAssertNil(InlinePasteReadback(location: 0, text: "two\nlines"))
        XCTAssertNil(InlinePasteReadback(location: 3, text: String(repeating: "x", count: 10_001)))
    }
}
#endif
