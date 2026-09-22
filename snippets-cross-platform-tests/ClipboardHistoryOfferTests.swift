import XCTest

#if os(macOS)
import AppKit
@testable import Snippets_Debug

@MainActor
final class ClipboardHistoryOfferTests: XCTestCase {
    func testOfferRequiresAnExplicitChoiceWithoutADefaultButton() throws {
        let offer = ClipboardHistoryOfferView()
        var choices: [String] = []
        offer.onEnable = { choices.append("enable") }
        offer.onDismiss = { choices.append("dismiss") }
        XCTAssertTrue(offer.isHidden)
        XCTAssertTrue(choices.isEmpty)

        let buttons = descendants(of: offer).compactMap { $0 as? NSButton }
        XCTAssertEqual(buttons.count, 2)
        XCTAssertTrue(buttons.allSatisfy { $0.keyEquivalent.isEmpty },
            "Showing an offer must not turn Return or Escape into a remembered preference")
        offer.isHidden = false
        XCTAssertTrue(choices.isEmpty, "Making the card visible does not opt in")

        let enable = try XCTUnwrap(buttons.first { $0.title == "Enable History" })
        let dismiss = try XCTUnwrap(buttons.first { $0.title == "Not Now" })
        dismiss.performClick(nil)
        XCTAssertEqual(choices, ["dismiss"])
        enable.performClick(nil)
        XCTAssertEqual(choices, ["dismiss", "enable"])
    }

    func testOfferFitsAtTheMinimumMainWindowWidthAndAfterResizing() throws {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 200))
        let offer = ClipboardHistoryOfferView()
        offer.isHidden = false
        root.addSubview(offer)
        NSLayoutConstraint.activate([
            offer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            offer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            offer.topAnchor.constraint(equalTo: root.topAnchor),
        ])

        for width: CGFloat in [1000, 491, 680] {
            root.setFrameSize(NSSize(width: width, height: 200))
            root.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(offer.frame.height, 60)
            XCTAssertLessThan(offer.frame.height, 130)
            for control in descendants(of: offer) where control is NSTextField || control is NSButton {
                let frame = offer.convert(control.bounds, from: control)
                XCTAssertGreaterThanOrEqual(frame.minX, -1)
                XCTAssertLessThanOrEqual(frame.maxX, offer.bounds.width + 1)
                XCTAssertGreaterThanOrEqual(frame.minY, -1)
                XCTAssertLessThanOrEqual(frame.maxY, offer.bounds.height + 1)
                if let label = control as? NSTextField, let cell = label.cell {
                    let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: label.bounds.width, height: 1000))
                    XCTAssertGreaterThanOrEqual(label.bounds.height + 1, needed.height,
                        "All privacy and retention copy must remain readable when the window narrows")
                }
            }
            let enable = try XCTUnwrap(descendants(of: offer).compactMap { $0 as? NSButton }
                .first { $0.title == "Enable History" })
            XCTAssertEqual(offer.convert(enable.bounds, from: enable).maxX, width - 16, accuracy: 1,
                "Actions stay at the trailing edge even when the copy fits on one line")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
#endif
