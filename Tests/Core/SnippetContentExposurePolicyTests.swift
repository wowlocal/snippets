import Testing

@testable import SnippetsCore

@Suite("Secure snippet content exposure policy")
struct SnippetContentExposurePolicyTests {
    @Test func everyAmbientOutputSurfaceIsDeniedForSecureContent() {
        for surface in SnippetContentExposureSurface.allCases {
            #expect(!SnippetContentExposurePolicy.permits(surface, whileSecure: true))
            #expect(SnippetContentExposurePolicy.permits(surface, whileSecure: false))
        }
    }

    @Test func responderChainDeniesExportsWithoutBreakingTextCommands() {
        let allowed = [
            "undo:", "redo:", "paste:", "pasteAsPlainText:", "pasteAsRichText:",
            "delete:", "deleteBackward:", "deleteForward:", "selectAll:",
            "insertNewline:", "insertText:", "moveLeft:", "moveRight:",
            "moveWordForward:", "deleteWordBackward:", "scrollPageDown:", "complete:",
        ]
        let disclosures = [
            "copy:", "cut:", "writeSelectionToPasteboard:type:",
            "writeSelectionToPasteboard:types:",
            "orderFrontSharingServicePicker:", "performFindPanelAction:",
            "performTextFinderAction:", "toggleQuickLookPreviewPanel:",
            "startSpeaking:", "checkSpelling:", "showGuessPanel:",
            "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
            "showWritingTools:",
        ]

        for action in allowed {
            #expect(SnippetContentExposurePolicy.permitsResponderAction(
                named: action, whileSecure: true))
        }
        for action in disclosures {
            #expect(!SnippetContentExposurePolicy.permitsResponderAction(
                named: action, whileSecure: true))
            #expect(SnippetContentExposurePolicy.permitsResponderAction(
                named: action, whileSecure: false))
        }
        #expect(SnippetContentExposurePolicy.permitsResponderAction(
            named: "futureUnknownAction:", whileSecure: true))
    }

    @Test func secureDerivedSurfacesReturnNoBodyAtAll() {
        let secret = "token={clipboard}"

        #expect(SnippetContentExposurePolicy.dynamicPreviewTemplate(
            secret, whileSecure: true) == nil)
        #expect(SnippetContentExposurePolicy.namePlaceholderSource(
            secret, whileSecure: true) == nil)
        #expect(SnippetContentExposurePolicy.dynamicPreviewTemplate(
            secret, whileSecure: false) == secret)
        #expect(SnippetContentExposurePolicy.namePlaceholderSource(
            secret, whileSecure: false) == secret)
    }
}
