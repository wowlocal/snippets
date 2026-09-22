import Foundation
import Testing

@testable import SnippetsCore

// Everything the expansion path decides *before* a single key or Accessibility write
// goes out: where the trigger is, how many characters it occupies, what to replace,
// when to refuse, and what keyword to offer in the first place. All pure value-in /
// value-out — no disk, no clock, no pasteboard, no host process.

@Suite("Trigger context, AX replacement, and keyword derivation")
struct TextReplacementTests {

    // MARK: 1. Trigger context

    @Suite("Trigger context")
    struct TriggerContextTests {

        @Test func theQueryAfterTheTriggerIsExtracted() {
            #expect(
                SuggestionTriggerContext.context(inTextBeforeCaret: "hello \\email")
                    == SuggestionTriggerContext(query: "email", triggerLength: 6),
                "extracts query after trigger"
            )
        }

        @Test func anEmptyQueryAfterTheTriggerIsStillActive() {
            #expect(
                SuggestionTriggerContext.context(inTextBeforeCaret: "hello \\")
                    == SuggestionTriggerContext(query: "", triggerLength: 1),
                "empty query after trigger is active"
            )
        }

        @Test func theLastTriggerBeforeTheCaretWins() {
            #expect(
                SuggestionTriggerContext.context(inTextBeforeCaret: "\\first and \\sec")
                    == SuggestionTriggerContext(query: "sec", triggerLength: 4),
                "uses last trigger before caret"
            )
        }

        @Test func whitespaceAfterATriggerEndsTheKeywordQuery() {
            #expect(
                SuggestionTriggerContext.context(inTextBeforeCaret: "\\first and text") == nil,
                "whitespace after trigger ends keyword query"
            )
        }

        @Test func textWithoutATriggerIsNotActive() {
            #expect(
                SuggestionTriggerContext.context(inTextBeforeCaret: "plain text") == nil,
                "missing trigger is not active"
            )
        }

        @Test func onlyAXConfirmedContextCanAuthorizeExpansion() {
            #expect(
                SuggestionContextState.axConfirmed.canAuthorizeExpansion,
                "a fresh AX confirmation can authorize deletion"
            )
            #expect(
                !SuggestionContextState.localDisplayOnly.canAuthorizeExpansion,
                "optimistic display state cannot authorize deletion"
            )
            #expect(
                !SuggestionContextState.uncertainAfterHostEdit.canAuthorizeExpansion,
                "an ambiguous host edit cannot authorize deletion"
            )
        }

        @Test func localTypingAndHostEditsHaveExplicitSafetyTransitions() {
            #expect(
                SuggestionContextState.axConfirmed.afterLocalPrintableEdit == .localDisplayOnly,
                "typing updates display before AX confirms the new host value"
            )
            #expect(
                SuggestionContextState.uncertainAfterHostEdit.afterLocalPrintableEdit
                    == .uncertainAfterHostEdit,
                "more locally inferred typing cannot repair an ambiguous edit"
            )
            #expect(
                SuggestionContextState.localDisplayOnly.afterAmbiguousHostEdit
                    == .uncertainAfterHostEdit,
                "Backspace always makes host text uncertain until AX confirms it"
            )
        }

        @Test func anyUnconfirmedTextAreaCanUseAnUnchangedLocalSession() {
            #expect(!UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextArea",
                contextState: .localDisplayOnly,
                hasReadableAXContext: false,
                caretUnavailable: false,
                targetStillMatches: true), "an unconfirmed trigger alone does not prove a missing caret")
            #expect(UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextArea",
                contextState: .localDisplayOnly,
                hasReadableAXContext: false,
                caretUnavailable: true,
                targetStillMatches: true))

            #expect(!UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextField",
                contextState: .localDisplayOnly,
                hasReadableAXContext: false,
                caretUnavailable: true,
                targetStillMatches: true), "ordinary fields continue to require their readable caret")
            #expect(!UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextArea",
                contextState: .uncertainAfterHostEdit,
                hasReadableAXContext: false,
                caretUnavailable: true,
                targetStillMatches: true), "Backspace and other host edits revoke local authority")
            #expect(!UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextArea",
                contextState: .localDisplayOnly,
                hasReadableAXContext: true,
                caretUnavailable: true,
                targetStillMatches: true), "a host that once supplied AX context may not fall back")
            #expect(!UnconfirmedTextAreaSuggestionPolicy.canAuthorizeLocalTracking(
                focusedRole: "AXTextArea",
                contextState: .localDisplayOnly,
                hasReadableAXContext: false,
                caretUnavailable: true,
                targetStillMatches: false), "moving to another pane or tab revokes local authority")
        }

        @Test func secureLocalTrackingRequiresRepeatedPostAuthenticationEvidence() {
            let localDeletion = TriggerDeletion.localTracking(query: "token")

            #expect(SecureLocalTriggerRevalidationPolicy.canAuthorize(
                deletion: localDeletion,
                query: "token",
                consecutiveUnconfirmedReads: 2,
                secureEventInputEnabled: false,
                targetStillMatches: true))
            #expect(!SecureLocalTriggerRevalidationPolicy.canAuthorize(
                deletion: localDeletion,
                query: "token",
                consecutiveUnconfirmedReads: 1,
                secureEventInputEnabled: false,
                targetStillMatches: true), "one unreadable AX result may still be authentication handoff")
            #expect(!SecureLocalTriggerRevalidationPolicy.canAuthorize(
                deletion: localDeletion,
                query: "token",
                consecutiveUnconfirmedReads: 2,
                secureEventInputEnabled: true,
                targetStillMatches: true), "Local Authentication must release Secure Event Input")
            #expect(!SecureLocalTriggerRevalidationPolicy.canAuthorize(
                deletion: localDeletion,
                query: "token",
                consecutiveUnconfirmedReads: 2,
                secureEventInputEnabled: false,
                targetStillMatches: false), "the exact captured control must still own focus")
            #expect(!SecureLocalTriggerRevalidationPolicy.canAuthorize(
                deletion: .pendingLastCharacter(query: "token"),
                query: "token",
                consecutiveUnconfirmedReads: 2,
                secureEventInputEnabled: false,
                targetStillMatches: true), "secure expansion cannot reuse an automatic partial trigger")
        }
    }

    // MARK: 2. Trigger deletion

    @Suite("Trigger deletion")
    struct TriggerDeletionTests {

        @Test func aConfirmedDeletionCountsTheTriggerPlusTheQueryAndVouchesForIt() {
            let context = SuggestionTriggerContext(query: "email", triggerLength: 6)
            #expect(context.triggerText == "\\email", "trigger text is the backslash plus the query")
            #expect(TriggerDeletion.confirmed(context).isSelfConsistent, "confirmed deletion agrees with itself")
            #expect(TriggerDeletion.confirmed(context).characterCount == 6, "confirmed deletes trigger plus query")
            #expect(
                TriggerDeletion.confirmed(context).provenance == .accessibilityConfirmed,
                "a confirmed read is what allows failing closed"
            )
        }

        @Test func localTrackingCountsTheBackslashAndNeverFailsClosed() {
            let local = TriggerDeletion.localTracking(query: "email")
            #expect(local.characterCount == 6, "local tracking counts the backslash too")
            #expect(local.expectedText == "\\email", "local tracking reconstructs the trigger")
            #expect(local.provenance == .localTracking, "local tracking never fails closed")
            #expect(local.isSelfConsistent, "local deletion agrees with itself")
        }

        @Test func theSuppressedFinalKeyLeavesTheHostOneCharacterBehind() {
            // Auto-expansion suppresses the key that completed the keyword, so the host is one behind.
            let pending = TriggerDeletion.pendingLastCharacter(query: "email")
            #expect(pending.characterCount == 5, "the suppressed final key was never applied by the host")
            #expect(pending.expectedText == "\\emai", "the host holds the trigger minus that key")
            #expect(pending.isSelfConsistent, "pending deletion agrees with itself")
        }

        @Test func aBareTriggerIsJustTheBackslash() {
            let emptyQuery = SuggestionTriggerContext(query: "", triggerLength: 1)
            #expect(
                TriggerDeletion.confirmed(emptyQuery).expectedText == "\\",
                "a bare trigger is just the backslash"
            )
            #expect(TriggerDeletion.confirmed(emptyQuery).isSelfConsistent, "bare trigger agrees with itself")
        }

        @Test func graphemeCountingStaysConsistentForEmojiQueries() {
            let emoji = TriggerDeletion.localTracking(query: "🎉")
            #expect(emoji.isSelfConsistent, "grapheme counting stays consistent for emoji queries")
        }
    }

    // MARK: 3. Replacement arithmetic

    @Suite("Replacement arithmetic")
    struct PlanArithmeticTests {

        @Test func plainAsciiMapsOneCharacterToOneUtf16Unit() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "hello \\email",
                    caretRange: NSRange(location: 12, length: 0),
                    expectedTrigger: "\\email",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 20
                ) == .plan(.init(replacementRange: NSRange(location: 6, length: 6), caretLocation: 26)),
                "plain ASCII maps one character to one UTF-16 unit"
            )
        }

        @Test func anEmojiBeforeTheTriggerShiftsOffsetsButNotTheTriggerWidth() {
            // The caret offset is UTF-16 (7) while the read text is 6 characters: the trigger length must
            // come from the trigger's own UTF-16 width, not from the string's character count.
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "👋 \\em",
                    caretRange: NSRange(location: 7, length: 0),
                    expectedTrigger: "\\em",
                    triggerCharacterCount: 3,
                    replacementUTF16Length: 4
                ) == .plan(.init(replacementRange: NSRange(location: 4, length: 3), caretLocation: 8)),
                "an emoji before the trigger shifts UTF-16 offsets but not the trigger width"
            )
        }

        @Test func anEmojiInsideTheTriggerIsThreeUtf16UnitsNotTwo() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "hi \\🎉",
                    caretRange: NSRange(location: 6, length: 0),
                    expectedTrigger: "\\🎉",
                    triggerCharacterCount: 2,
                    replacementUTF16Length: 3
                ) == .plan(.init(replacementRange: NSRange(location: 3, length: 3), caretLocation: 6)),
                "an emoji inside the trigger is three UTF-16 units, not two"
            )
        }

        @Test func anActiveSelectionJoinsTheReplacedRangeAndDoesNotMoveTheCaret() {
            // An active selection is folded into the replaced range instead of costing an extra backspace.
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "hello \\em",
                    caretRange: NSRange(location: 9, length: 4),
                    expectedTrigger: "\\em",
                    triggerCharacterCount: 3,
                    replacementUTF16Length: 5
                ) == .plan(.init(replacementRange: NSRange(location: 6, length: 7), caretLocation: 11)),
                "the selection joins the replaced range and does not move the caret"
            )
        }

        @Test func newlinesBeforeTheCaretAreOrdinaryCharacters() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "line one\n\\em",
                    caretRange: NSRange(location: 12, length: 0),
                    expectedTrigger: "\\em",
                    triggerCharacterCount: 3,
                    replacementUTF16Length: 2
                ) == .plan(.init(replacementRange: NSRange(location: 9, length: 3), caretLocation: 11)),
                "newlines before the caret are ordinary characters"
            )
        }
    }

    // MARK: 4. Replacement rejection
    //
    // The rejected/unavailable distinction is the whole safety model: `rejected` means the
    // field moved under us, `unavailable` means we could not read it well enough to say.

    @Suite("Replacement rejection")
    struct PlanRejectionTests {

        @Test func differentTextBeforeTheCaretIsRejected() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "hello \\other",
                    caretRange: NSRange(location: 12, length: 0),
                    expectedTrigger: "\\email",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 3
                ) == .rejected,
                "different text before the caret is rejected, never guessed at"
            )
        }

        @Test func theComparisonIsExactIncludingCase() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\EMAIL",
                    caretRange: NSRange(location: 6, length: 0),
                    expectedTrigger: "\\email",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 3
                ) == .rejected,
                "the comparison is exact, including case"
            )
        }

        @Test func tooLittleTextBeforeTheCaretMeansTheFieldChanged() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\em",
                    caretRange: NSRange(location: 3, length: 0),
                    expectedTrigger: "\\email",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 3
                ) == .rejected,
                "too little text before the caret means the field changed"
            )
        }

        @Test func aCaretOffsetShorterThanTheTriggerIsUnavailableNotRejected() {
            // Offsets contradicting the text is a broken AX model, not proof the text moved — the event
            // path can still handle it.
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\email",
                    caretRange: NSRange(location: 3, length: 0),
                    expectedTrigger: "\\email",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 3
                ) == .unavailable,
                "a caret offset shorter than the trigger is unavailable, not rejected"
            )
        }

        @Test func aCallerWhoseOwnCountDisagreesWithItsTextIsRefused() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\email",
                    caretRange: NSRange(location: 6, length: 0),
                    expectedTrigger: "\\emai",
                    triggerCharacterCount: 6,
                    replacementUTF16Length: 3
                ) == .unavailable,
                "a caller whose own count disagrees with its text is refused"
            )
        }

        @Test func thereIsNothingToReplaceWithoutATrigger() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\email",
                    caretRange: NSRange(location: 6, length: 0),
                    expectedTrigger: "",
                    triggerCharacterCount: 0,
                    replacementUTF16Length: 3
                ) == .unavailable,
                "there is nothing to replace without a trigger"
            )
        }

        @Test func aCaretAtTheVeryStartCannotHoldTheTrigger() {
            #expect(
                AccessibilityTextReplacement.plan(
                    textBeforeCaret: "",
                    caretRange: NSRange(location: 0, length: 0),
                    expectedTrigger: "\\em",
                    triggerCharacterCount: 3,
                    replacementUTF16Length: 3
                ) == .rejected,
                "a caret at the very start cannot hold the trigger"
            )
        }

        @Test func invalidAndOverflowingOffsetsNeverProduceAReplacementPlan() {
            let inputs: [(NSRange, Int)] = [
                (NSRange(location: -1, length: 0), 3),
                (NSRange(location: 3, length: -1), 3),
                (NSRange(location: NSNotFound, length: 0), 3),
                (NSRange(location: Int.max - 2, length: 3), 3),
                (NSRange(location: 3, length: Int.max), 3),
                (NSRange(location: 3, length: 0), -1),
                (NSRange(location: 4, length: 0), Int.max)
            ]
            for (range, replacementLength) in inputs {
                #expect(AccessibilityTextReplacement.plan(
                    textBeforeCaret: "\\em",
                    caretRange: range,
                    expectedTrigger: "\\em",
                    triggerCharacterCount: 3,
                    replacementUTF16Length: replacementLength) == .unavailable)
            }
        }
    }

    // MARK: Verified trigger selection

    @Suite("Verified trigger selection")
    struct VerifiedTriggerSelectionTests {
        @Test func onePasteReplacesTheTriggerAndTheOriginalSelectedSuffix() throws {
            let selection = try #require(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "hello \\em",
                originalSelection: NSRange(location: 9, length: 4),
                selectedText: "tail"))

            #expect(selection.originalSelection == NSRange(location: 9, length: 4))
            #expect(selection.replacementRange == NSRange(location: 6, length: 7))
            #expect(selection.expectedText == "\\emtail")
            #expect(selection.matches(range: NSRange(location: 6, length: 7), text: "\\emtail"))
            #expect(!selection.matches(range: NSRange(location: 6, length: 7), text: "\\emfail"),
                    "a concurrent edit of equal length revokes paste and rollback authority")
            #expect(!selection.matches(range: NSRange(location: 7, length: 7), text: "\\emtail"),
                    "the same text at another position is not the captured selection")
            #expect(!selection.matches(range: NSRange(location: 6, length: 6), text: "\\emtail"))
        }

        @Test func graphemesAndSelectedEmojiUseTheirActualUTF16Widths() throws {
            let prefix = "👨‍👩‍👧‍👦 "
            let trigger = "\\e\u{301}🎉"
            let suffix = "🇨🇦"
            let original = NSRange(location: (prefix + trigger).utf16.count, length: suffix.utf16.count)
            let selection = try #require(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "e\u{301}🎉"),
                textBeforeCaret: prefix + trigger,
                originalSelection: original,
                selectedText: suffix))

            #expect(selection.replacementRange == NSRange(
                location: prefix.utf16.count, length: (trigger + suffix).utf16.count))
            #expect(selection.matches(range: selection.replacementRange, text: trigger + suffix))
        }

        @Test func canonicallyEquivalentTriggersStillRequireTheExactUTF16Rendition() {
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "é"),
                textBeforeCaret: "\\e\u{301}",
                originalSelection: NSRange(location: 3, length: 0),
                selectedText: "") == nil,
                "a normalized match does not authorize a different UTF-16 range")

            let query = "a\u{301}\u{327}"
            let reordered = "a\u{327}\u{301}"
            #expect(query == reordered, "Swift String equality intentionally normalizes this fixture")
            #expect(query.utf16.count == reordered.utf16.count)
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: query),
                textBeforeCaret: "\\" + reordered,
                originalSelection: NSRange(location: 4, length: 0),
                selectedText: "") == nil,
                "matching code-unit counts also cannot authorize a differently encoded trigger")
        }

        @Test func normalizedSelectedTextCannotAuthorizePasteOrRollback() throws {
            let selected = "a\u{301}\u{327}"
            let selection = try #require(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "\\em",
                originalSelection: NSRange(location: 3, length: selected.utf16.count),
                selectedText: selected))
            #expect(!selection.matches(
                range: selection.replacementRange, text: "\\ema\u{327}\u{301}"))
        }

        @Test func mismatchedTriggerOrOriginalSelectionCannotCreateASnapshot() {
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "\\ex",
                originalSelection: NSRange(location: 3, length: 0),
                selectedText: "") == nil)
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "\\em",
                originalSelection: NSRange(location: 3, length: 1),
                selectedText: "🎉") == nil,
                "the selected text's Character count cannot stand in for its UTF-16 length")
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "prefix \\em",
                originalSelection: NSRange(location: 3, length: 0),
                selectedText: "") == nil,
                "a prefix that extends before the field's start is contradictory AX evidence")
            #expect(VerifiedTriggerSelection.make(
                deletion: TriggerDeletion(characterCount: 4, expectedText: "\\em", provenance: .localTracking),
                textBeforeCaret: "\\em",
                originalSelection: NSRange(location: 3, length: 0),
                selectedText: "") == nil)
        }

        @Test func aKnownTriggerMismatchWinsOverAnUnreadableSelectedSuffix() {
            var suffixReads = 0
            let result = VerifiedTriggerSelection.prepare(
                deletion: .confirmed(.init(query: "em", triggerLength: 3)),
                textBeforeCaret: "\\ex",
                originalSelection: NSRange(location: 3, length: 4),
                readSelectedText: { suffixReads += 1; return nil })
            #expect(result == .rejected)
            #expect(suffixReads == 0, "a later read cannot downgrade positive mismatch evidence")
        }

        @Test func unreadableSuffixIsUnavailableOnlyAfterTheTriggerWasProved() {
            var suffixReads = 0
            let result = VerifiedTriggerSelection.prepare(
                deletion: .confirmed(.init(query: "em", triggerLength: 3)),
                textBeforeCaret: "\\em",
                originalSelection: NSRange(location: 3, length: 4),
                readSelectedText: { suffixReads += 1; return nil })
            #expect(result == .unavailable)
            #expect(suffixReads == 1)
        }

        @Test func readableButContradictorySelectedSuffixFailsClosed() {
            #expect(VerifiedTriggerSelection.prepare(
                deletion: .confirmed(.init(query: "em", triggerLength: 3)),
                textBeforeCaret: "\\em",
                originalSelection: NSRange(location: 3, length: 4),
                readSelectedText: { "xy" }) == .rejected)
        }

        @Test func negativeMissingAndOverflowingRangesAreRefusedWithoutArithmeticTraps() {
            let ranges = [
                NSRange(location: -1, length: 0),
                NSRange(location: 3, length: -1),
                NSRange(location: NSNotFound, length: 0),
                NSRange(location: Int.max - 1, length: 3),
                NSRange(location: 3, length: Int.max),
                NSRange(location: 2, length: 0)
            ]
            for range in ranges {
                #expect(VerifiedTriggerSelection.make(
                    deletion: .localTracking(query: "em"),
                    textBeforeCaret: "\\em",
                    originalSelection: range,
                    selectedText: "") == nil)
            }
        }

        @Test func combinedAXReadIsBoundedIncludingTheSelectedSuffix() {
            let before = String(repeating: "a", count: 9_994) + "\\em"
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: before,
                originalSelection: NSRange(location: 9_997, length: 3),
                selectedText: "xyz") != nil)
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: before,
                originalSelection: NSRange(location: 9_997, length: 4),
                selectedText: "wxyz") == nil)
            #expect(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "a" + before,
                originalSelection: NSRange(location: 9_998, length: 3),
                selectedText: "xyz") == nil)
        }

        @Test func aBoundedSuffixCanSelectATriggerLateInALargeDocument() throws {
            let selection = try #require(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "em"),
                textBeforeCaret: "near the caret \\em",
                originalSelection: NSRange(location: 1_000_000, length: 0),
                selectedText: ""))
            #expect(selection.replacementRange == NSRange(location: 999_997, length: 3))
        }

        @Test(arguments: ["x", "hello!", "a longer replacement"])
        func selectionPasteConfirmationStartsAtTheReplacementStart(replacement: String) throws {
            let prefix = "hello "
            let trigger = "\\email"
            let selection = try #require(VerifiedTriggerSelection.make(
                deletion: .localTracking(query: "email"),
                textBeforeCaret: prefix + trigger,
                originalSelection: NSRange(location: (prefix + trigger).utf16.count, length: 0),
                selectedText: ""))
            let before = PasteCaretFingerprint(
                caretLocation: selection.replacementRange.location,
                selectionLength: selection.replacementRange.length,
                textBeforeCaret: prefix)
            let after = PasteCaretFingerprint(
                caretLocation: (prefix + replacement).utf16.count,
                selectionLength: 0,
                textBeforeCaret: prefix + replacement)

            #expect(SnippetPasteConfirmationPolicy.progress(
                before: before, after: after, pastedText: replacement, tailLength: 32) == .pasteObserved,
                "shorter and equal-length replacements still move forward from the selection start")
            #expect(SnippetPasteConfirmationPolicy.progress(
                before: before, after: before, pastedText: replacement, tailLength: 32) == .idle,
                "preparing a selection alone never confirms a paste")
        }
    }

    // MARK: Native paste transaction

    @Suite("Selection paste transaction")
    struct SelectionPasteTransactionTests {
        private final class Host {
            var clipboardIsOwned = true
            var focusMatches = true
            var originalMatches = true
            var triggerIsSelected = false
            var setterSucceeds = true
            var setterApplies = true
            var posts = 0
            var selectionWrites = 0
            var proofReads = 0
            var baselineReads = 0
            var duringOriginalProof: (() -> Void)?
            var duringSelectedProof: ((Int) -> Void)?
            var duringSelectionWrite: (() -> Void)?
            var duringBaselineRead: (() -> Void)?

            func run() -> SelectionPasteTransaction.Result {
                SelectionPasteTransaction.run(
                    contextIsValid: { self.clipboardIsOwned && self.focusMatches },
                    originalSelectionMatches: {
                        self.duringOriginalProof?()
                        return self.originalMatches
                    },
                    selectTrigger: {
                        self.selectionWrites += 1
                        self.triggerIsSelected = self.setterApplies
                        self.duringSelectionWrite?()
                        return self.setterSucceeds
                    },
                    selectedTriggerMatches: {
                        self.proofReads += 1
                        // Simulate an AX reply that was true when requested, with another
                        // process changing context while that request is in flight.
                        let matchedAtRead = self.triggerIsSelected
                        self.duringSelectedProof?(self.proofReads)
                        return matchedAtRead
                    },
                    captureBaseline: {
                        self.baselineReads += 1
                        self.duringBaselineRead?()
                    },
                    postPaste: { self.posts += 1 })
            }
        }

        @Test func oneVerifiedSelectionProducesExactlyOnePaste() {
            let host = Host()
            #expect(host.run() == .posted)
            #expect(host.selectionWrites == 1)
            #expect(host.posts == 1)
            #expect(host.baselineReads == 1)
            #expect(host.proofReads == 2)
            // No text-delete callback exists: the host's native paste owns the one text mutation.
        }

        @Test func clipboardSupersessionBeforeSelectionCostsNoHostMutation() {
            let host = Host()
            host.duringOriginalProof = { host.clipboardIsOwned = false }
            #expect(host.run() == .contextChanged)
            #expect(host.selectionWrites == 0)
            #expect(host.posts == 0)
        }

        @Test func clipboardSupersessionAfterSelectionNeverDispatchesPaste() {
            let host = Host()
            host.duringSelectionWrite = { host.clipboardIsOwned = false }
            #expect(host.run() == .contextChanged)
            #expect(host.selectionWrites == 1)
            #expect(host.posts == 0)
        }

        @Test func focusMovementDuringTheLastAXReadCannotReceiveThePaste() {
            let host = Host()
            host.duringSelectedProof = { read in
                if read == 2 { host.focusMatches = false }
            }
            #expect(host.run() == .contextChanged)
            #expect(host.proofReads == 2)
            #expect(host.posts == 0)
        }

        @Test func clipboardSupersessionDuringTheLastAXReadCannotPasteNewClipboardContents() {
            let host = Host()
            host.duringSelectedProof = { read in
                if read == 2 { host.clipboardIsOwned = false }
            }
            #expect(host.run() == .contextChanged)
            #expect(host.posts == 0)
        }

        @Test func aBaselineReadThatChangesTheSelectionRevokesTheProof() {
            let host = Host()
            host.duringBaselineRead = { host.triggerIsSelected = false }
            #expect(host.run() == .selectionChanged)
            #expect(host.baselineReads == 1)
            #expect(host.posts == 0)
        }

        @Test func anIgnoredSelectionSetterDoesNotAuthorizePaste() {
            let host = Host()
            host.setterApplies = false
            #expect(host.run() == .selectionChanged)
            #expect(host.selectionWrites == 1)
            #expect(host.posts == 0)
            #expect(host.baselineReads == 0)
        }

        @Test func aFailedSetterNeverRetriesEvenIfItChangedTheHostSelection() {
            let host = Host()
            host.setterSucceeds = false
            #expect(host.run() == .selectionWriteFailed)
            #expect(host.triggerIsSelected,
                    "a failed reply is ambiguous; conservative restoration belongs to the caller")
            #expect(host.selectionWrites == 1)
            #expect(host.posts == 0)
            #expect(host.proofReads == 0)
        }

        @Test func anAlreadyChangedOriginalSelectionIsNeverOverwritten() {
            let host = Host()
            host.originalMatches = false
            #expect(host.run() == .originalSelectionChanged)
            #expect(host.selectionWrites == 0)
            #expect(host.posts == 0)
        }

        @Test func anAlreadyInvalidContextDoesNotTouchTheHost() {
            let host = Host()
            host.focusMatches = false
            #expect(host.run() == .contextChanged)
            #expect(host.selectionWrites == 0)
            #expect(host.proofReads == 0)
            #expect(host.posts == 0)
        }
    }

    @Suite("Accessibility selected-text transaction")
    struct AccessibilitySelectedTextTransactionTests {
        private final class Host {
            var contextMatches = true
            var originalMatches = true
            var selectedProofMatches = true
            var selected = false
            var selectSucceeds = true
            var selectionApplies = true
            var writeSucceeds = true
            var writeApplies = true
            var writeIsConfirmed = true
            var selectionWrites = 0
            var textWrites = 0
            var restorationChecks = 0
            var restorations = 0
            var caretWrites = 0
            var text = "\\em"
            var duringOriginalProof: (() -> Void)?
            var duringSelectedProof: (() -> Void)?
            var duringConfirmation: (() -> Void)?

            func run() -> AccessibilitySelectedTextTransaction.Result {
                AccessibilitySelectedTextTransaction.run(
                    contextIsValid: { self.contextMatches },
                    originalSelectionMatches: {
                        self.duringOriginalProof?()
                        return self.originalMatches
                    },
                    selectTrigger: {
                        self.selectionWrites += 1
                        self.selected = self.selectionApplies
                        return self.selectSucceeds
                    },
                    selectedTriggerMatches: {
                        self.duringSelectedProof?()
                        return self.selected && self.selectedProofMatches
                    },
                    writeText: {
                        self.textWrites += 1
                        if self.writeApplies { self.text = "world" }
                        return self.writeSucceeds
                    },
                    confirmText: {
                        self.duringConfirmation?()
                        return self.writeIsConfirmed && self.text == "world"
                    },
                    finishCaret: {
                        self.caretWrites += 1
                        self.selected = false
                    },
                    restoreSelection: {
                        self.restorationChecks += 1
                        // The production callback re-reads focus, exact range and exact text;
                        // a context change revokes permission even for a selection-only write.
                        if self.contextMatches && self.selected && self.text == "\\em" {
                            self.restorations += 1
                            self.selected = false
                        }
                    })
            }

            func type(_ character: String) {
                text = selected ? character : text + character
            }
        }

        @Test func successfulWriteIsConfirmedAndCollapsedExactlyOnce() {
            let host = Host()
            #expect(host.run() == .delivered)
            #expect(host.selectionWrites == 1)
            #expect(host.textWrites == 1)
            #expect(host.caretWrites == 1)
            #expect(host.restorationChecks == 0)
        }

        @Test func failedSelectionReplyRestoresBeforeTheNextTypedCharacter() {
            let host = Host()
            host.selectSucceeds = false
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.selectionWrites == 1)
            #expect(host.restorations == 1)
            #expect(host.textWrites == 0)
            host.type("x")
            #expect(host.text == "\\emx", "a selection-only failure must not eat the next keystroke")
        }

        @Test func failedSelectionProofRestoresWithoutAttemptingText() {
            let host = Host()
            host.selectedProofMatches = false
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.restorations == 1)
            #expect(host.textWrites == 0)
            #expect(host.caretWrites == 0)
        }

        @Test func anIgnoredSelectionSetterNeedsNoActualRestoration() {
            let host = Host()
            host.selectionApplies = false
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.restorationChecks == 1)
            #expect(host.restorations == 0)
            #expect(host.textWrites == 0)
        }

        @Test func failedOriginalProofNeverWritesOrRestoresSelection() {
            let host = Host()
            host.originalMatches = false
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.selectionWrites == 0)
            #expect(host.restorationChecks == 0)
            #expect(host.textWrites == 0)
        }

        @Test func contextChangedDuringOriginalProofNeverWritesOrRestoresSelection() {
            let host = Host()
            host.duringOriginalProof = { host.contextMatches = false }
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.selectionWrites == 0)
            #expect(host.restorationChecks == 0)
            #expect(host.textWrites == 0)
        }

        @Test func contextChangedDuringSelectedProofCannotWriteOrBlindlyRestore() {
            let host = Host()
            host.duringSelectedProof = { host.contextMatches = false }
            #expect(host.run() == .selectionUnconfirmed)
            #expect(host.textWrites == 0)
            #expect(host.restorationChecks == 1)
            #expect(host.restorations == 0)
        }

        @Test func aFailedTextSetterMayHaveWrittenAndNeverRestoresOrRetries() {
            let host = Host()
            host.writeSucceeds = false
            #expect(host.run() == .textUnconfirmed)
            #expect(host.text == "world")
            #expect(host.textWrites == 1)
            #expect(host.restorationChecks == 0)
            #expect(host.caretWrites == 0)
        }

        @Test func aSuccessfulNoOpTextSetterIsAmbiguousAndNeverRestoresOrRetries() {
            let host = Host()
            host.writeApplies = false
            #expect(host.run() == .textUnconfirmed)
            #expect(host.textWrites == 1)
            #expect(host.restorationChecks == 0)
            #expect(host.caretWrites == 0)
        }

        @Test func anUnverifiableWriteNeverRestoresSelectionEvenWhenItDidApply() {
            let host = Host()
            host.writeIsConfirmed = false
            #expect(host.run() == .textUnconfirmed)
            #expect(host.textWrites == 1)
            #expect(host.restorationChecks == 0)
            #expect(host.caretWrites == 0)
        }

        @Test func focusMovedDuringConfirmedWriteDoesNotReceiveACaretWrite() {
            let host = Host()
            host.duringConfirmation = { host.contextMatches = false }
            #expect(host.run() == .delivered)
            #expect(host.textWrites == 1)
            #expect(host.caretWrites == 0)
            #expect(host.restorationChecks == 0)
        }
    }

    // MARK: 5. Write verification

    @Suite("Write landed")
    struct WriteLandedTests {

        private static let plan = AccessibilityTextReplacement.Plan(
            replacementRange: NSRange(location: 6, length: 6),
            caretLocation: 11
        )

        @Test func theReplacementIsFoundWhereItWasWritten() {
            #expect(
                AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email",
                    valueAfter: "hello world",
                    plan: Self.plan,
                    replacement: "world"
                ),
                "the replacement is found where it was written"
            )
        }

        @Test func aSilentNoOpIsNotADelivery() {
            #expect(
                !AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email",
                    valueAfter: "hello \\email",
                    plan: Self.plan,
                    replacement: "world"
                ),
                "a silent no-op is not a delivery"
            )
        }

        @Test func anEqualLengthReplacementCannotTurnAnIgnoredWriteIntoSuccess() {
            #expect(!AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello \\email",
                plan: .init(replacementRange: NSRange(location: 6, length: 6), caretLocation: 12),
                replacement: "world!"),
                "an unchanged field with a zero length delta is still an ignored write")
        }

        @Test func anAlreadyMatchingReplacementIsAnIdempotentDelivery() {
            #expect(AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello \\email",
                plan: .init(replacementRange: NSRange(location: 6, length: 6), caretLocation: 12),
                replacement: "\\email"))
        }

        @Test func aSameLengthCaseChangeDoesNotProveOurReplacement() {
            #expect(!AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello WORLD!",
                plan: .init(replacementRange: NSRange(location: 6, length: 6), caretLocation: 12),
                replacement: "world!"))
        }

        @Test func malformedWritePlansFailWithoutOverflowingOrMatchingUnrelatedText() {
            for range in [
                NSRange(location: -1, length: 6),
                NSRange(location: 6, length: -1),
                NSRange(location: NSNotFound, length: 6),
                NSRange(location: Int.max - 2, length: 6),
                NSRange(location: 6, length: Int.max),
                NSRange(location: 6, length: 7)
            ] {
                #expect(!AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email", valueAfter: "hello world",
                    plan: .init(replacementRange: range, caretLocation: 11), replacement: "world"))
            }
        }

        @Test func anUnrelatedEditWithTheExpectedLengthDeltaIsNotOurReplacement() {
            #expect(
                !AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email",
                    valueAfter: "hello WORLD",
                    plan: Self.plan,
                    replacement: "world"
                ),
                "the expected length delta alone cannot prove our insertion"
            )
        }

        @Test func anUnchangedTriggerContainingTheShorterReplacementPrefixIsNotDelivered() {
            #expect(!AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email",
                valueAfter: "hello \\email",
                plan: Self.plan,
                replacement: "\\em"))
        }

        @Test func aMatchingReplacementDoesNotHideChangesOutsideItsRange() {
            let plan = AccessibilityTextReplacement.Plan(
                replacementRange: NSRange(location: 6, length: 6), caretLocation: 11)
            for after in ["HELLO world tail", "hello world FAIL", "hello world tail!"] {
                #expect(!AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email tail", valueAfter: after,
                    plan: plan, replacement: "world"))
            }
        }

        @Test func canonicalUnicodeCompositionIsTheSameCompletedEdit() {
            #expect(AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email tail",
                valueAfter: "hello café tail",
                plan: Self.plan,
                replacement: "cafe\u{301}"))
            #expect(AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email tail",
                valueAfter: "hello cafe\u{301} tail",
                plan: Self.plan,
                replacement: "café"))
        }

        @Test func normalizedReplacementCaretUsesTheActualHostUTF16Length() {
            #expect(AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: "hello \\email tail", valueAfter: "hello café tail",
                plan: Self.plan, replacement: "cafe\u{301}") == 10)
            #expect(AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: "hello \\email", valueAfter: "hello café",
                plan: Self.plan, replacement: "cafe\u{301}") == 10)
        }

        @Test func normalizedPrefixAndReplacementStillUseThePreservedSuffixAnchor() {
            #expect(AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: "e\u{301} \\em tail", valueAfter: "é café tail",
                plan: .init(replacementRange: NSRange(location: 3, length: 3), caretLocation: 8),
                replacement: "cafe\u{301}") == 6)
        }

        @Test func normalizedSuffixCannotSupplyAnExactCaretAnchor() {
            #expect(AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email e\u{301}", valueAfter: "hello world é",
                plan: Self.plan, replacement: "world"))
            #expect(AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: "hello \\email e\u{301}", valueAfter: "hello world é",
                plan: Self.plan, replacement: "world") == nil)
        }

        @Test func unconfirmedValueCannotAuthorizeAnyCaretPosition() {
            #expect(AccessibilityTextReplacement.confirmedCaretLocation(
                valueBefore: "hello \\email tail", valueAfter: "hello WRONG tail",
                plan: Self.plan, replacement: "world") == nil)
        }

        @Test func lineEndingChangesAreNotSilentlyTreatedAsOurExactWrite() {
            #expect(!AccessibilityTextReplacement.writeLanded(
                valueBefore: "hello \\email", valueAfter: "hello one\r\ntwo",
                plan: Self.plan, replacement: "one\ntwo"))
        }

        @Test func aRangeBisectingASurrogateCannotProveAWrite() {
            #expect(!AccessibilityTextReplacement.writeLanded(
                valueBefore: "🎉", valueAfter: "x",
                plan: .init(replacementRange: NSRange(location: 1, length: 1), caretLocation: 2),
                replacement: "x"))
        }

        @Test func anUnrelatedFieldValueIsNotADelivery() {
            #expect(
                !AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email",
                    valueAfter: "hi",
                    plan: Self.plan,
                    replacement: "world"
                ),
                "an unrelated field value is not a delivery"
            )
        }
    }

    // MARK: 6. Replacement policy

    @Suite("Replacement policy")
    struct PolicyTests {

        @Test func aDeliveredReplacementCommitsRegardlessOfProvenance() {
            #expect(
                AccessibilityReplacementPolicy.action(for: .delivered, provenance: .accessibilityConfirmed)
                    == .commit,
                "a delivered replacement commits"
            )
            #expect(
                AccessibilityReplacementPolicy.action(for: .delivered, provenance: .localTracking)
                    == .commit,
                "provenance does not matter once the write landed"
            )
        }

        @Test func anUnavailableFieldFallsBackToEventsForBothProvenances() {
            #expect(
                AccessibilityReplacementPolicy.action(for: .unavailable, provenance: .accessibilityConfirmed)
                    == .useEvents,
                "a field without writable attributes falls back to events"
            )
            #expect(
                AccessibilityReplacementPolicy.action(for: .unavailable, provenance: .localTracking)
                    == .useEvents,
                "the same fallback applies to locally tracked counts"
            )
        }

        @Test func aConfirmedCountThatNoLongerMatchesMustNotTypeBlindly() {
            // Failing closed only makes sense when Accessibility vouched for the count in the first place.
            #expect(
                AccessibilityReplacementPolicy.action(for: .rejected, provenance: .accessibilityConfirmed)
                    == .abort,
                "a confirmed count that no longer matches must not type blindly"
            )
        }

        @Test func laggingAccessibilityInChromiumKeepsTheWorkingEventPath() {
            #expect(
                AccessibilityReplacementPolicy.action(for: .rejected, provenance: .localTracking)
                    == .useEvents,
                "lagging Accessibility in Chromium keeps the working event path"
            )
        }

        @Test func anUnconfirmedWriteNeverFallsBackToASecondEdit() {
            #expect(AccessibilityReplacementPolicy.action(
                for: .attemptedUnconfirmed, provenance: .accessibilityConfirmed) == .abort)
            #expect(AccessibilityReplacementPolicy.action(
                for: .attemptedUnconfirmed, provenance: .localTracking) == .abort,
                "local tracking cannot prove that an attempted AX write changed nothing")
        }

        @Test func aCancelledSelectionTransactionNeverFallsBackForEitherProvenance() {
            #expect(AccessibilityReplacementPolicy.action(
                for: .cancelledBeforeText, provenance: .accessibilityConfirmed) == .abort)
            #expect(AccessibilityReplacementPolicy.action(
                for: .cancelledBeforeText, provenance: .localTracking) == .abort)
        }
    }

    // MARK: 7. Insertion policy

    @Suite("Insertion policy")
    struct InsertionPolicyTests {

        @Test func anOrdinaryHostGetsTheSurgicalWrite() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.apple.Safari",
                    globallyEnabled: nil,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: []
                ) == .selectedText,
                "an ordinary host gets the surgical write"
            )
        }

        @Test func aHostWithoutABundleIDIsNotEvidenceAgainstItself() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: nil,
                    globallyEnabled: nil,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: []
                ) == .selectedText,
                "a host without a bundle ID is not evidence against itself"
            )
        }

        @Test func aChromiumHostGetsTheWholeValueWrite() {
            // Chrome's omnibox hears a whole-value write and ignores a selected-text one, and no read
            // tells the ignored write apart from a real success.
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.google.Chrome",
                    globallyEnabled: nil,
                    hostIsChromiumFamily: true,
                    excludedBundleIDs: []
                ) == .wholeValue,
                "a Chromium host gets the whole-value write"
            )
        }

        @Test func theGlobalSwitchTurnsThePathOffEverywhere() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.apple.Safari",
                    globallyEnabled: false,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: []
                ) == AccessibilityInsertionPolicy.Strategy.none,
                "the global switch turns the path off everywhere"
            )
        }

        @Test func theSwitchSetToOnBehavesLikeTheDefault() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.apple.Safari",
                    globallyEnabled: true,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: []
                ) == .selectedText,
                "the switch set to on behaves like the default"
            )
        }

        @Test func aPerAppExclusionStillApplies() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.example.App",
                    globallyEnabled: nil,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: ["com.example.App"]
                ) == AccessibilityInsertionPolicy.Strategy.none,
                "a per-app exclusion still applies"
            )
        }

        @Test func anExcludedChromiumHostIsExcludedNotRerouted() {
            // The exclusion is the user saying "keep Accessibility out of this app"; a Chromium host
            // must not read that as permission to use the other strategy.
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.google.Chrome",
                    globallyEnabled: nil,
                    hostIsChromiumFamily: true,
                    excludedBundleIDs: ["com.google.Chrome"]
                ) == AccessibilityInsertionPolicy.Strategy.none,
                "an excluded Chromium host is excluded, not rerouted"
            )
        }

        @Test func somebodyElsesExclusionDoesNotSpillOver() {
            #expect(
                AccessibilityInsertionPolicy.strategy(
                    bundleID: "com.example.App",
                    globallyEnabled: nil,
                    hostIsChromiumFamily: false,
                    excludedBundleIDs: ["com.other.App"]
                ) == .selectedText,
                "somebody else's exclusion does not spill over"
            )
        }
    }

    // MARK: 8. Keyword suggestions

    @Suite("Keyword suggestions")
    struct KeywordSuggestionTests {

        @Test func aLongerCandidateAndTheIncumbentBlockEachOtherInBothDirections() {
            // The trap: a one-directional filter offers `email` beside an existing
            // `\em` and stops `\em` from expanding. Both ends have to be visible.
            #expect(
                KeywordRelation.between("email", "em") == .blocksShorter,
                "longer candidate kills the incumbent"
            )
            #expect(
                KeywordRelation.between("em", "email") == .blockedByLonger,
                "shorter candidate is swallowed"
            )
        }

        @Test func anExactMatchIsADuplicate() {
            #expect(KeywordRelation.between("sig", "sig") == .duplicate, "exact match")
        }

        @Test func appendADigitDisambiguationGetsTheSameCorrection() {
            // The same correction applied to append-a-digit disambiguation.
            #expect(KeywordRelation.between("sig2", "sig") == .blocksShorter, "sig2 beside sig kills sig")
        }

        @Test func keywordsWithNothingInCommonAreUnrelated() {
            #expect(KeywordRelation.between("sig", "tp") == .unrelated, "nothing in common")
        }

        @Test func aLabelAbbreviatesTwoWaysAndThenTheContentFollows() {
            // A label abbreviates two ways: the opening word and the initials.
            #expect(
                KeywordSuggestions.candidates(name: "Signature Block", contentFirstLine: "Best regards")
                    == ["sign", "sig", "sb", "best"],
                "name-first candidates, then content"
            )
        }

        @Test func aShortWordIsOfferedWhole() {
            // Short enough to type as it stands.
            #expect(
                KeywordSuggestions.candidates(name: "Email", contentFirstLine: "") == ["email"],
                "a short word is offered whole"
            )
        }

        @Test func diacriticsAreFoldedTheWayTheEngineFoldsThem() {
            // Diacritics fold the way the engine folds them, so the keyword stays typeable.
            #expect(
                KeywordSuggestions.candidates(name: "Café Order", contentFirstLine: "") == ["cafe", "co"],
                "folded, not truncated at the accent"
            )
        }

        @Test func aUrlSchemeIsSteppedOverButItsHostIsOffered() {
            // Content is a sentence: its initials spell nothing, so only its first real
            // word is offered — and the URL scheme is stepped over rather than offered.
            #expect(
                KeywordSuggestions.candidates(
                    name: "", contentFirstLine: "https://github.com/mike/snippets"
                ) == ["github"],
                "the scheme is not a keyword, the host might be"
            )
        }

        @Test func aContentSentenceYieldsNoInitials() {
            #expect(
                KeywordSuggestions.candidates(name: "", contentFirstLine: "Thanks so much for the update")
                    == ["thanks"],
                "no initials from content"
            )
        }

        @Test func anEmptySnippetOffersNothing() {
            // Nothing to derive from beats junk derived from nothing.
            #expect(
                KeywordSuggestions.candidates(name: "", contentFirstLine: "") == [],
                "empty snippet offers nothing"
            )
        }

        @Test func textWithNoTypeableWordOffersNothing() {
            #expect(
                KeywordSuggestions.candidates(name: "日本語", contentFirstLine: "こんにちは") == [],
                "no typeable word"
            )
        }

        @Test func oneCharacterIsNotAKeywordButItsInitialsSurvive() {
            #expect(
                KeywordSuggestions.candidates(name: "A", contentFirstLine: "") == [],
                "one character is not a keyword"
            )
            #expect(
                KeywordSuggestions.candidates(name: "A B", contentFirstLine: "") == ["ab"],
                "initials survive where the single-letter word does not"
            )
        }

        @Test func aNameAndContentThatAgreeProduceOnePairNotTwo() {
            // Duplicates collapse: the whole name and its own first word are one candidate.
            #expect(
                KeywordSuggestions.candidates(name: "Invoice", contentFirstLine: "Invoice for services")
                    == ["invo", "inv"],
                "name and content agreeing produce one pair, not two"
            )
        }

        @Test func existingKeywordsMatchADotComponentAnywhere() {
            #expect(
                KeywordSuggestions.existingMatches(
                    query: "doc",
                    among: ["frontend.doc", "doc.backend", "product"]
                ) == ["doc.backend", "frontend.doc"],
                "whole-keyword prefix leads, but a component in either position matches"
            )
        }

        @Test func existingKeywordPartsMatchWhenTypedInTheWrongOrder() {
            #expect(
                KeywordSuggestions.existingMatches(
                    query: "frontend.doc",
                    among: ["other", "doc.frontend", "doc.backend"]
                ) == ["doc.frontend"],
                "dot-separated naming components are order independent"
            )
        }

        @Test func partialReorderedKeywordPartsMatchWhileTyping() {
            #expect(
                KeywordSuggestions.existingMatches(
                    query: "front.do",
                    among: ["doc.frontend", "doc.backend", "frontend.design"]
                ) == ["doc.frontend"],
                "each partially typed component can find its existing counterpart"
            )
        }

        @Test func exactExistingKeywordLeadsAndFoldedDuplicatesCollapse() {
            #expect(
                KeywordSuggestions.existingMatches(
                    query: "\\CAFÉ.DOC",
                    among: ["cafe.doc.extra", "Café.Doc", "cafe.doc", "other.cafe.doc"]
                ) == ["Café.Doc", "cafe.doc.extra", "other.cafe.doc"],
                "matching follows keyword sanitizing, case and diacritic folding"
            )
        }

        @Test func tabCompletionAdvancesOnlyToTheNextKeywordPart() {
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "do",
                    among: ["doc.frontend", "doc.backend"]
                ) == "doc."
            )
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "doc.front",
                    among: ["doc.frontend.controls"]
                ) == "doc.frontend."
            )
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "my",
                    among: ["my-signature.work"]
                ) == "my-",
                "a sanitized space boundary is completed as a hyphen"
            )
        }

        @Test func tabCompletionOnlyAddsThePrefixSharedByEveryOption() {
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "doc.f",
                    among: ["doc.frontend", "doc.framework"]
                ) == "doc.fr"
            )
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "doc.",
                    among: ["doc.frontend", "doc.backend"]
                ) == nil,
                "Tab must not choose an arbitrary existing keyword"
            )
        }

        @Test func tabCompletionIsPrefixOnlyAndPreservesTheTypedPrefix() {
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "frontend",
                    among: ["doc.frontend"]
                ) == nil,
                "the broad reference matcher must not reorder completion text"
            )
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "CAF",
                    among: ["café.docs"]
                ) == "CAFé."
            )
            #expect(
                KeywordSuggestions.tabCompletion(
                    query: "doc.frontend",
                    among: ["doc.frontend"]
                ) == nil,
                "an exact keyword has no continuation"
            )
        }

        @Test func anEmptyKeywordQueryShowsNoExistingReferences() {
            #expect(
                KeywordSuggestions.existingMatches(query: "  ", among: ["doc.frontend"]).isEmpty
            )
        }
    }
}
