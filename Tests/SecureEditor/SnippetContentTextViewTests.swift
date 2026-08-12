import AppKit
import Testing

@testable import SnippetsSecureEditor

@Suite("Secure AppKit content editor")
@MainActor
struct SnippetContentTextViewTests {
    private func editor(_ text: String = "vault-sentinel") -> SnippetContentTextView {
        let view = SnippetContentTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.isEditable = true
        view.isSelectable = true
        view.string = text
        view.setSelectedRange(NSRange(location: 0, length: (text as NSString).length))
        return view
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
}
