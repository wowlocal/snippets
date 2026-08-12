import AppKit
import CoreVideo
import Testing

@testable import SnippetsSecureEditor

@Suite("Secure AppKit content editor")
@MainActor
struct SnippetContentTextViewTests {
    private struct RasterDifference {
        let firstRow: Int
        let lastRow: Int
        let changedPixelsByRow: [Int]
    }

    private func editor(_ text: String = "vault-sentinel") -> SnippetContentTextView {
        let view = SnippetContentTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isEditable = true
        view.isSelectable = true
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        return view
    }

    private func rasterDifference(
        plaintext: CVPixelBuffer,
        redaction: CVPixelBuffer
    ) -> RasterDifference? {
        guard CVPixelBufferGetWidth(plaintext) == CVPixelBufferGetWidth(redaction),
              CVPixelBufferGetHeight(plaintext) == CVPixelBufferGetHeight(redaction),
              CVPixelBufferLockBaseAddress(plaintext, .readOnly) == kCVReturnSuccess
        else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(plaintext, .readOnly) }

        guard CVPixelBufferLockBaseAddress(redaction, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(redaction, .readOnly) }

        guard let plaintextBase = CVPixelBufferGetBaseAddress(plaintext),
              let redactionBase = CVPixelBufferGetBaseAddress(redaction) else { return nil }

        let width = CVPixelBufferGetWidth(plaintext)
        let height = CVPixelBufferGetHeight(plaintext)
        let plaintextBytesPerRow = CVPixelBufferGetBytesPerRow(plaintext)
        let redactionBytesPerRow = CVPixelBufferGetBytesPerRow(redaction)
        var changedPixelsByRow = Array(repeating: 0, count: height)

        for row in 0 ..< height {
            let plaintextRow = plaintextBase
                .advanced(by: row * plaintextBytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            let redactionRow = redactionBase
                .advanced(by: row * redactionBytesPerRow)
                .assumingMemoryBound(to: UInt8.self)
            for column in 0 ..< width {
                let offset = column * 4
                let colorDelta = (0 ..< 3).reduce(0) { partial, channel in
                    partial + abs(Int(plaintextRow[offset + channel]) - Int(redactionRow[offset + channel]))
                }
                if colorDelta > 12 {
                    changedPixelsByRow[row] += 1
                }
            }
        }

        guard let firstRow = changedPixelsByRow.firstIndex(where: { $0 > 0 }),
              let lastRow = changedPixelsByRow.lastIndex(where: { $0 > 0 }) else { return nil }
        return RasterDifference(
            firstRow: firstRow,
            lastRow: lastRow,
            changedPixelsByRow: changedPixelsByRow
        )
    }

    @Test func protectedRasterUsesTopDownVideoOrientation() throws {
        _ = NSApplication.shared
        let view = SnippetContentTextView(
            frame: NSRect(x: 0, y: 0, width: 180, height: 400)
        )
        view.font = .monospacedSystemFont(ofSize: 72, weight: .black)
        view.textColor = .black
        view.appearance = NSAppearance(named: .aqua)
        view.drawsBackground = false
        view.isRichText = false
        view.textContainerInset = NSSize(width: 12, height: 112)
        view.textContainer?.lineFragmentPadding = 0
        view.string = "F"
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 180, height: 200))
        scrollView.documentView = view
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scrollView.reflectScrolledClipView(scrollView.contentView)

        let plaintext = try #require(view.secureCaptureFrameForInspection(plaintext: true))
        let redaction = try #require(view.secureCaptureFrameForInspection(plaintext: false))
        #expect(plaintext.geometry.viewport.origin.y == 100)
        let difference = try #require(rasterDifference(
            plaintext: plaintext.pixelBuffer,
            redaction: redaction.pixelBuffer
        ))

        // CVPixelBuffer video memory is top-down: row zero is the displayed top.
        // A glyph placed at the NSTextView's top inset must therefore occupy the
        // upper half of the protected raster, not its vertical mirror at the bottom.
        #expect(difference.firstRow < plaintext.geometry.pixelHeight / 4)
        #expect(difference.lastRow < plaintext.geometry.pixelHeight / 2)

        // F is vertically asymmetric. Its long top bar must contain more changed
        // pixels than the bottom stroke. This catches a glyph mirrored in place,
        // not merely a line translated to the correct half of the frame.
        let glyphHeight = difference.lastRow - difference.firstRow + 1
        let bandHeight = max(1, glyphHeight / 3)
        let upperBand = difference.changedPixelsByRow[
            difference.firstRow ..< difference.firstRow + bandHeight
        ].reduce(0, +)
        let lowerBand = difference.changedPixelsByRow[
            difference.lastRow - bandHeight + 1 ... difference.lastRow
        ].reduce(0, +)
        #expect(upperBand > lowerBand)
    }

    @Test func secureModeRefusesEveryPasteboardAndServicesWriteBoundary() throws {
        let sentinel = "vault-sentinel"
        let view = editor(sentinel)
        let ordinaryWritableType = try #require(view.writablePasteboardTypes.last)
        view.isSecureContentMode = true

        let board = NSPasteboard(name: NSPasteboard.Name("secure-editor-\(UUID().uuidString)"))
        board.clearContents()
        try #require(board.setString("unchanged", forType: .string))
        let beforeGeneralPasteboard = NSPasteboard.general.changeCount

        #expect(view.writablePasteboardTypes.isEmpty)
        #expect(!view.writeSelection(to: board, type: ordinaryWritableType))
        #expect(!view.writeSelection(to: board, types: [ordinaryWritableType, .rtf]))
        #expect(board.string(forType: .string) == "unchanged")

        view.copy(nil)
        #expect(NSPasteboard.general.changeCount == beforeGeneralPasteboard)
        view.cut(nil)
        #expect(NSPasteboard.general.changeCount == beforeGeneralPasteboard)
        #expect(view.string == sentinel)

        #expect(view.validRequestor(forSendType: .string, returnType: nil) == nil)
        #expect(view.validRequestor(forSendType: nil, returnType: .string) == nil)
        #expect(view.validRequestor(forSendType: nil, returnType: nil) == nil)

        let dragEvent = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1))
        #expect(!view.dragSelection(with: dragEvent, offset: .zero, slideBack: true))
        #expect(view.dragImageForSelection(with: dragEvent, origin: nil) == nil)
        #expect(view.quickLookPreviewableItems(inRanges: []).isEmpty)

        let contextEvent = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1))
        let contextActions = Set(
            (view.menu(for: contextEvent)?.items ?? [])
                .compactMap(\.action)
                .map(NSStringFromSelector))
        #expect(!contextActions.contains("copy:"))
        #expect(!contextActions.contains("cut:"))
        #expect(!contextActions.contains("orderFrontSharingServicePicker:"))
        #expect(!contextActions.contains("performFindPanelAction:"))
        #expect(!contextActions.contains("performTextFinderAction:"))
        #expect(!contextActions.contains("checkSpelling:"))
        #expect(!contextActions.contains("showWritingTools:"))
    }

    @Test func secureModeDisablesAmbientTextServicesAndRestoresOrdinarySettings() {
        let view = editor()
        view.isContinuousSpellCheckingEnabled = true
        view.isGrammarCheckingEnabled = true
        view.isAutomaticSpellingCorrectionEnabled = true
        view.isAutomaticLinkDetectionEnabled = true
        view.isAutomaticDataDetectionEnabled = true
        view.isAutomaticDashSubstitutionEnabled = true
        view.isAutomaticTextReplacementEnabled = true
        view.isAutomaticTextCompletionEnabled = true
        view.inlinePredictionType = .yes
        view.mathExpressionCompletionType = .yes
        view.writingToolsBehavior = .limited
        view.usesFindPanel = true
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.usesRolloverButtonForSelection = true

        let ordinaryContinuousSpelling = view.isContinuousSpellCheckingEnabled
        let ordinaryGrammar = view.isGrammarCheckingEnabled
        let ordinarySpellingCorrection = view.isAutomaticSpellingCorrectionEnabled
        let ordinaryLinkDetection = view.isAutomaticLinkDetectionEnabled
        let ordinaryDataDetection = view.isAutomaticDataDetectionEnabled
        let ordinaryDashSubstitution = view.isAutomaticDashSubstitutionEnabled
        let ordinaryReplacement = view.isAutomaticTextReplacementEnabled
        let ordinaryCompletion = view.isAutomaticTextCompletionEnabled
        let ordinaryInlinePrediction = view.inlinePredictionType
        let ordinaryMathCompletion = view.mathExpressionCompletionType
        let ordinaryWritingTools = view.writingToolsBehavior
        let ordinaryFindPanel = view.usesFindPanel
        let ordinaryFindBar = view.usesFindBar
        let ordinaryIncrementalSearch = view.isIncrementalSearchingEnabled
        let ordinaryRollover = view.usesRolloverButtonForSelection

        view.isSecureContentMode = true

        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(view.enabledTextCheckingTypes == 0)
        #expect(!view.isAutomaticLinkDetectionEnabled)
        #expect(!view.isAutomaticDataDetectionEnabled)
        #expect(!view.isAutomaticDashSubstitutionEnabled)
        #expect(!view.isAutomaticTextReplacementEnabled)
        #expect(!view.isAutomaticTextCompletionEnabled)
        #expect(view.inlinePredictionType == .no)
        #expect(view.mathExpressionCompletionType == .no)
        #expect(view.writingToolsBehavior == .none)
        #expect(!view.usesFindPanel)
        #expect(!view.usesFindBar)
        #expect(!view.isIncrementalSearchingEnabled)
        #expect(!view.usesRolloverButtonForSelection)

        // Direct actions cannot silently re-enable the disabled services.
        view.toggleContinuousSpellChecking(nil)
        view.toggleGrammarChecking(nil)
        view.toggleAutomaticSpellingCorrection(nil)
        view.toggleAutomaticTextCompletion(nil)
        #expect(!view.isContinuousSpellCheckingEnabled)
        #expect(!view.isGrammarCheckingEnabled)
        #expect(!view.isAutomaticSpellingCorrectionEnabled)
        #expect(!view.isAutomaticTextCompletionEnabled)

        view.isSecureContentMode = false

        #expect(view.isContinuousSpellCheckingEnabled == ordinaryContinuousSpelling)
        #expect(view.isGrammarCheckingEnabled == ordinaryGrammar)
        #expect(view.isAutomaticSpellingCorrectionEnabled == ordinarySpellingCorrection)
        #expect(view.isAutomaticLinkDetectionEnabled == ordinaryLinkDetection)
        #expect(view.isAutomaticDataDetectionEnabled == ordinaryDataDetection)
        #expect(view.isAutomaticDashSubstitutionEnabled == ordinaryDashSubstitution)
        #expect(view.isAutomaticTextReplacementEnabled == ordinaryReplacement)
        #expect(view.isAutomaticTextCompletionEnabled == ordinaryCompletion)
        #expect(view.inlinePredictionType == ordinaryInlinePrediction)
        #expect(view.mathExpressionCompletionType == ordinaryMathCompletion)
        #expect(view.writingToolsBehavior == ordinaryWritingTools)
        #expect(view.usesFindPanel == ordinaryFindPanel)
        #expect(view.usesFindBar == ordinaryFindBar)
        #expect(view.isIncrementalSearchingEnabled == ordinaryIncrementalSearch)
        #expect(view.usesRolloverButtonForSelection == ordinaryRollover)
    }

    @Test func secureModeKeepsLiteralEditingAndNavigationButNoCompletion() {
        let view = editor("abc")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.isSecureContentMode = true

        #expect(view.tryToPerform(#selector(NSResponder.moveLeft(_:)), with: nil))
        #expect(view.selectedRange().location == 1)

        view.setSelectedRange(NSRange(location: 3, length: 0))
        view.insertText("{", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.string == "abc{")
        #expect(view.rangeForUserCompletion.location == NSNotFound)
        var selectedCompletion = 0
        #expect(view.completions(
            forPartialWordRange: NSRange(location: 3, length: 1),
            indexOfSelectedItem: &selectedCompletion)?.isEmpty == true)
        #expect(selectedCompletion == -1)
    }

    @Test func ordinaryModeStillWritesItsSelection() throws {
        let sentinel = "ordinary-sentinel"
        let view = editor(sentinel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false)
        window.contentView = view
        #expect(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: 0, length: (sentinel as NSString).length))
        let writableType = try #require(view.writablePasteboardTypes.last)
        let board = NSPasteboard(name: NSPasteboard.Name("ordinary-editor-\(UUID().uuidString)"))
        board.declareTypes([writableType], owner: nil)

        try #require(view.writeSelection(to: board, type: writableType))
        #expect(board.string(forType: writableType) == sentinel)
        #expect(!view.writablePasteboardTypes.isEmpty)
    }

    @Test func hoverBoundaryStartsRedactedRejectsSyntheticEntryAndTearsDown() throws {
        _ = NSApplication.shared
        let view = editor("")
        #expect(!view.setSecurePresentationEnabled(true))
        #expect(view.secureCapturePolicy.phase == .ordinary)
        view.isSecureContentMode = true
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        scrollView.documentView = view
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = scrollView
        // Keep the fixture deliberately non-key and off screen. A forged enter
        // event must not be enough to reveal without a fresh real-cursor check.
        #expect(!window.isVisible)
        #expect(!window.isKeyWindow)

        try #require(view.setSecurePresentationEnabled(true))
        #expect(view.secureCapturePolicy.phase == .protectedRedaction)
        #expect(view.secureHoverTracksPointerForInspection)
        #expect(!view.secureHoverRevealsPixelsForInspection)
        let redactionGeneration = view.secureCaptureFrameGenerationForInspection

        view.string = "hover-boundary-sentinel"
        #expect(view.secureCaptureFrameGenerationForInspection == redactionGeneration)
        let syntheticEntry = try #require(NSEvent.enterExitEvent(
            with: .mouseEntered,
            location: NSPoint(x: 20, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 99,
            trackingNumber: 99,
            userData: nil
        ))
        view.mouseEntered(with: syntheticEntry)

        #expect(view.secureCapturePolicy.phase == .protectedRedaction)
        #expect(!view.secureHoverRevealsPixelsForInspection)
        #expect(view.string == "hover-boundary-sentinel")

        try #require(view.redactSecurePixelsBeforePlaintextClear())
        view.clearSecurePlaintextStorageForTeardown()
        #expect(view.string.isEmpty)
        #expect(
            view.secureCaptureFrameGenerationForInspection == redactionGeneration,
            "teardown clear must not enqueue a post-clear frame or failure callback"
        )
        try #require(view.setSecurePresentationEnabled(false))
        #expect(view.secureCapturePolicy.phase == .ordinary)
        #expect(!view.secureHoverTracksPointerForInspection)
        #expect(!view.secureHoverRevealsPixelsForInspection)

        view.isSecureContentMode = false
        view.string = "ordinary-after-secure"
        view.mouseExited(with: syntheticEntry)
        #expect(view.secureCapturePolicy.phase == .ordinary)
        #expect(view.string == "ordinary-after-secure")
    }
}
