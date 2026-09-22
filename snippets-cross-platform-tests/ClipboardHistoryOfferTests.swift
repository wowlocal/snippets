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

        let enable = try button("clipboardHistoryOfferEnable", in: offer)
        let dismiss = try button("clipboardHistoryOfferDismiss", in: offer)
        XCTAssertEqual(dismiss.accessibilityLabel(), "Not Now")
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
            XCTAssertGreaterThan(offer.frame.height, 40)
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
            let enable = try button("clipboardHistoryOfferEnable", in: offer)
            let dismiss = try button("clipboardHistoryOfferDismiss", in: offer)
            XCTAssertLessThanOrEqual(offer.convert(enable.bounds, from: enable).maxX,
                offer.convert(dismiss.bounds, from: dismiss).minX,
                "The enable and dismiss actions must not overlap at narrow widths")
        }
    }

    func testMainWindowGivesSurplusHeightToLibraryAndReclaimsHiddenOfferSpace() throws {
        try withMainWindow { controller, window in
            let offer = controller.clipboardHistoryOfferView
            let split = controller.mainSplitViewController.view
            var previousSize: (root: CGFloat, split: CGFloat, offer: CGFloat)?

            for height: CGFloat in [720, 1000] {
                window.setContentSize(NSSize(width: 1000, height: height))
                offer.isHidden = false
                controller.view.layoutSubtreeIfNeeded()
                let rootHeight = controller.view.bounds.height
                let offerHeight = offer.frame.height
                let splitHeight = split.frame.height
                XCTAssertGreaterThan(offerHeight, 40)
                XCTAssertLessThanOrEqual(offerHeight, 100,
                    "A visible offer must stay a compact banner when the main window has surplus height")
                XCTAssertEqual(offerHeight, offer.fittingSize.height, accuracy: 1,
                    "The full root stack must not stretch the banner beyond its text's fitting height")
                XCTAssertEqual(splitHeight + offerHeight, rootHeight, accuracy: 2,
                    "The library and editor must receive the rest of the main window")
                if let previousSize {
                    XCTAssertEqual(offerHeight, previousSize.offer, accuracy: 1)
                    XCTAssertEqual(splitHeight - previousSize.split, rootHeight - previousSize.root, accuracy: 2,
                        "Growing the window should grow the library, not the offer")
                }
                previousSize = (rootHeight, splitHeight, offerHeight)

                offer.isHidden = true
                controller.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(split.frame.height, rootHeight, accuracy: 2,
                    "Dismissing the offer must leave no reserved banner height")
                XCTAssertEqual(split.frame.height - splitHeight, offerHeight, accuracy: 2)
            }
            controller.mainSidebarSplitItem?.isCollapsed = true
            window.setContentSize(NSSize(width: 260, height: 720))
            controller.view.layoutSubtreeIfNeeded()
            let minimumWidthWithHiddenOffer = controller.view.bounds.width
            let rootStack = try XCTUnwrap(offer.superview as? NSStackView)
            rootStack.removeArrangedSubview(offer)
            offer.removeFromSuperview()
            controller.view.layoutSubtreeIfNeeded()
            window.setContentSize(NSSize(width: 260, height: 720))
            controller.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(minimumWidthWithHiddenOffer, controller.view.bounds.width, accuracy: 1,
                "A hidden offer must not raise the editor-only window's minimum width")
        }
    }

    func testMainWindowOfferKeepsPrivacyCopyReadableAtMinimumWidth() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            try withMainWindow(appearance: appearance) { controller, window in
                let offer = controller.clipboardHistoryOfferView
                for width: CGFloat in [1000, 491, 400] {
                    controller.mainSidebarSplitItem?.isCollapsed = width < 680
                    window.setContentSize(NSSize(width: width, height: 720))
                    offer.isHidden = false
                    controller.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(offer.bounds.width, controller.view.bounds.width, accuracy: 1)
                    XCTAssertLessThanOrEqual(offer.frame.height, 120)
                    for control in descendants(of: offer) where control is NSTextField || control is NSButton {
                        let frame = offer.convert(control.bounds, from: control)
                        XCTAssertGreaterThanOrEqual(frame.minX, -1)
                        XCTAssertLessThanOrEqual(frame.maxX, offer.bounds.width + 1)
                        XCTAssertGreaterThanOrEqual(frame.minY, -1)
                        XCTAssertLessThanOrEqual(frame.maxY, offer.bounds.height + 1)
                        if let label = control as? NSTextField, let cell = label.cell {
                            let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0,
                                width: label.bounds.width, height: 1000))
                            XCTAssertGreaterThanOrEqual(label.bounds.height + 1, needed.height,
                                "Integrated layout must show the complete privacy and retention sentence")
                        }
                    }
                }
            }
        }
    }

    private func withMainWindow(appearance: NSAppearance.Name = .aqua,
        _ body: (ViewController, NSWindow) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SnippetsClipboardOfferLayout-\(UUID().uuidString)", isDirectory: true)
        let key = SnippetStorageLocations.rootOverrideEnvironmentKey
        let previousRoot = ProcessInfo.processInfo.environment[key]
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        setenv(key, root.path, 1)
        defer {
            NSApp.appearance = previousAppearance
            if let previousRoot { setenv(key, previousRoot, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: root)
        }

        try autoreleasepool {
            let store = SnippetStore(configuration: .iOS)
            let usage = SnippetUsageStore()
            let controller = ViewController()
            controller.store = store
            controller.usageStore = usage
            controller.engine = SnippetExpansionEngine(store: store, usage: usage)
            // Exercise the real main split, editor and enclosing stack without launching
            // a second store binding, global monitor or the first-run presentation flow.
            NSApp.appearance?.performAsCurrentDrawingAppearance { controller.buildUI() }
            controller.view.appearance = NSApp.appearance
            controller.hasRestoredSplitViewDivider = true
            controller.permissionBannerContainer.isHidden = true
            controller.permissionBannerDivider.isHidden = true
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSApp.appearance
            window.contentView = controller.view
            defer {
                window.contentView = nil
                window.close()
            }
            try body(controller, window)
        }
    }

    private func button(_ identifier: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityIdentifier() == identifier })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
#endif
