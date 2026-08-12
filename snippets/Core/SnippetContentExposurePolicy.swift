import Foundation

/// The closed list of ambient system features that may receive text from the
/// content editor. A secure snippet has exactly one intentional disclosure path:
/// the authenticated, one-use expansion flow. None of these UI conveniences are
/// that path.
nonisolated enum SnippetContentExposureSurface: CaseIterable, Equatable, Sendable {
    case dynamicPreview
    case namePlaceholder
    case pasteboardWrite
    case dragSource
    case servicesSend
    case sharingService
    case findPasteboard
    case speech
    case definitionLookup
    case textChecking
    case writingTools
}

/// Pure policy shared by the AppKit boundary and its tests. AppKit's concrete
/// output methods fail closed; responder filtering adds defense in depth without
/// blocking the many undocumented selectors used for keyboard editing and IME.
nonisolated enum SnippetContentExposurePolicy {
    /// Secure plaintext never reaches an ambient output surface. Ordinary text
    /// retains NSTextView's normal behavior.
    static func permits(
        _ surface: SnippetContentExposureSurface,
        whileSecure: Bool
    ) -> Bool {
        _ = surface
        return !whileSecure
    }

    /// Known commands that export text are denied. Other selectors remain available
    /// because NSTextView's keyboard system dispatches navigation, insertion, IME,
    /// deletion, completion and scrolling as responder commands too. The actual
    /// output boundaries also guard their methods directly.
    static func permitsResponderAction(named actionName: String, whileSecure: Bool) -> Bool {
        guard whileSecure else { return true }
        switch actionName {
        case "copy:", "cut:",
             "writeSelectionToPasteboard:type:",
             "writeSelectionToPasteboard:types:",
             "orderFrontSharingServicePicker:",
             "performFindPanelAction:", "performTextFinderAction:",
             "startSpeaking:",
             "quickLookPreviewItems:", "toggleQuickLookPreviewPanel:",
             "checkSpelling:", "showGuessPanel:",
             "checkTextInSelection:", "checkTextInDocument:",
             "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
             "toggleAutomaticSpellingCorrection:",
             "toggleAutomaticQuoteSubstitution:",
             "toggleAutomaticLinkDetection:",
             "toggleAutomaticDataDetection:",
             "toggleAutomaticDashSubstitution:",
             "toggleAutomaticTextReplacement:",
             "toggleSmartInsertDelete:",
             "toggleAutomaticTextCompletion:",
             "orderFrontSubstitutionsPanel:",
             "showWritingTools:":
            return false
        default:
            return true
        }
    }

    /// `nil` means the caller must clear and hide the preview without invoking
    /// placeholder resolution. That distinction keeps secrets out of resolver
    /// inputs as well as out of the final NSTextField.
    static func dynamicPreviewTemplate(
        _ template: String,
        whileSecure: Bool
    ) -> String? {
        permits(.dynamicPreview, whileSecure: whileSecure) ? template : nil
    }

    /// A secure body must not become a second plaintext copy in the ordinary name
    /// field's placeholder. `nil` selects the neutral product fallback instead.
    static func namePlaceholderSource(
        _ body: String,
        whileSecure: Bool
    ) -> String? {
        permits(.namePlaceholder, whileSecure: whileSecure) ? body : nil
    }
}
