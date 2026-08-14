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

        @Test func onlyASyncedOrLocallyTrackedRefreshCanExpand() {
            #expect(
                SuggestionContextRefreshResult.synced.canUseForExpansion == true,
                "synced refresh can select or auto-expand"
            )
            #expect(
                SuggestionContextRefreshResult.localFallback.canUseForExpansion == true,
                "tracked local fallback can select or auto-expand when AX is unavailable"
            )
            #expect(
                SuggestionContextRefreshResult.unavailable.canUseForExpansion == false,
                "unavailable refresh cannot use stale suggestion state"
            )
            #expect(
                SuggestionContextRefreshResult.missingTrigger.canUseForExpansion == false,
                "missing trigger cannot select or auto-expand"
            )
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

        @Test func aNormalizedInsertionOfTheSameLengthStillCounts() {
            // Hosts normalize what they store; the expected length delta still proves the edit landed.
            #expect(
                AccessibilityTextReplacement.writeLanded(
                    valueBefore: "hello \\email",
                    valueAfter: "hello WORLD",
                    plan: Self.plan,
                    replacement: "world"
                ),
                "a normalized insertion of the same length still counts"
            )
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

        @Test func anEmptyKeywordQueryShowsNoExistingReferences() {
            #expect(
                KeywordSuggestions.existingMatches(query: "  ", among: ["doc.frontend"]).isEmpty
            )
        }
    }
}
