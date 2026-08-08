import Foundation
import Testing

@testable import SnippetsCore

// The resolver is the last code that runs before snippet text lands in someone else's
// document, and the import path is the only place tokens are written by a machine
// rather than by a person. Every test here names the damage it prevents.

/// 2026-02-15 12:00:00 UTC. Midday on purpose: these tests format this instant in the
/// machine's own time zone, and midday is the only choice that stays on one calendar
/// day from UTC-11 through UTC+12.
private let epoch = Date(timeIntervalSince1970: 1_771_156_800)

private func expand(_ template: String, clipboard: String? = "CLIPBOARD") -> String {
    PlaceholderResolver.resolve(template: template, clipboard: { clipboard }, now: { epoch })
}

/// What a `DateFormatter` makes of `pattern` on this machine at `epoch`. Computed here
/// rather than hard-coded so the assertions say "a formatted date" without pinning the
/// suite to one locale or one time zone.
private func formatted(_ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = pattern
    return formatter.string(from: epoch)
}

@Suite("Placeholder resolver")
struct PlaceholderResolverTests {

    // MARK: - The Raycast round trip

    /// **The bug**, and it was silent data loss into the user's own documents.
    ///
    /// The importer rewrote `{date "…"}` into `{date:…}` accepting any characters
    /// between the quotes, while `tokenRegex` admitted only `[a-zA-Z0-9:_-]`. Every
    /// Raycast format containing a space, a comma, a slash or a period — `MMM d, yyyy`
    /// above all — arrived as a token the resolver did not recognise, and unrecognised
    /// tokens pass through *by design*. An imported library therefore typed the literal
    /// text `{date:MMM d, yyyy}` into whatever the user was writing, every time, with
    /// nothing anywhere saying so.
    ///
    /// Both halves are asserted: what the importer writes, and that the resolver reads
    /// exactly that back. Pinning only one end is how this shipped.
    @Test func everyRaycastDateFormatTheImporterRewritesAlsoExpands() {
        let cases = [
            (raycast: #"{date "MMM d, yyyy"}"#, token: "{date:MMM d, yyyy}", pattern: "MMM d, yyyy"),
            (raycast: #"{date "yyyy/MM/dd"}"#,  token: "{date:yyyy/MM/dd}",  pattern: "yyyy/MM/dd"),
            (raycast: #"{date "yyyy-MM-dd"}"#,  token: "{date:yyyy-MM-dd}",  pattern: "yyyy-MM-dd"),
            (raycast: #"{date "HH:mm"}"#,       token: "{date:HH:mm}",       pattern: "HH:mm"),
        ]

        for testCase in cases {
            #expect(RaycastPlaceholders.converted(testCase.raycast) == testCase.token,
                    "the importer rewrites \(testCase.raycast)")
            #expect(PlaceholderResolver.isResolvablePlaceholder(testCase.token),
                    "the resolver reads back what the importer wrote for \(testCase.raycast)")
            #expect(expand(testCase.token) == formatted(testCase.pattern),
                    "\(testCase.token) expands to a formatted date")
            #expect(!expand(testCase.token).contains("{"),
                    "no brace from \(testCase.raycast) may reach the document")
        }
    }

    /// The invariant that outlives the four cases above: whatever the importer emits,
    /// the resolver reads. A format the grammar does not admit must come out in the
    /// Raycast spelling, unconverted — never as a native-looking token that is dead.
    @Test func theImporterNeverWritesATokenTheResolverCannotReadBack() {
        let exotic = [
            #"{date "MMM d, yyyy"}"#,
            #"{date "MMMM d, yyyy 'at' h:mm a"}"#,   // ICU quoted literal, not admitted
            #"{date "{yyyy}"}"#,                      // a format carrying its own braces
            #"{date "x}{clipboard"}"#,                // a format trying to smuggle a second token
            #"{date "yyyy年MM月dd日"}"#,
            #"{date "yyyy/MM/dd"} and {date "HH:mm"}"#,
        ]

        for source in exotic {
            let converted = RaycastPlaceholders.converted(source)
            let rendered = expand(converted)
            #expect(
                converted == source || !rendered.contains("{date:"),
                "\(source) was rewritten into a token the resolver leaves in the document"
            )
        }
    }

    @Test func aRaycastFormatTheGrammarRejectsIsLeftInTheRaycastSpelling() {
        let source = #"{date "MMMM d, yyyy 'at' h:mm a"}"#
        #expect(RaycastPlaceholders.converted(source) == source)
        #expect(expand(source) == source, "and passes through the resolver untouched")
    }

    @Test func severalRaycastTokensInOneSnippetAreAllConverted() {
        let source = #"Dear X, on {date "MMM d, yyyy"} at {date "HH:mm"} — regards"#
        #expect(RaycastPlaceholders.converted(source)
                == "Dear X, on {date:MMM d, yyyy} at {date:HH:mm} — regards")
    }

    // MARK: - Negative controls: the widened alphabet must not eat anything new

    /// The other half of the fix, and the reason `tokenRegex` is two alternatives
    /// rather than one widened character class. People keep JSON, CSS and Swift in
    /// snippets. `{date: value}` is an object literal, not a token, and the resolver
    /// has always left it alone — a naive widening that admitted a space anywhere would
    /// have started feeding it to `DateFormatter`, where `d`, `a`, `t` and `e` are all
    /// pattern letters. That is the same bug again, pointing the other way.
    @Test(arguments: [
        "{date: value}",
        "{date: 1}",
        "{time: 300}",
        "{ date }",
        "{style: {color: red}}",
        "let x = {date: 1, time: 2}",
        "{nonsense}",
        "{unknown token with spaces}",
        "{date:}",
        "no tokens at all",
        "",
    ])
    func unrelatedBracedTextStillPassesThroughByteForByte(source: String) {
        #expect(expand(source) == source)
        #expect(!PlaceholderResolver.containsResolvablePlaceholder(in: source))
        #expect(!PlaceholderResolver.isResolvablePlaceholder(source))
    }

    /// `{date:}` has its own line in the resolver — an empty format is left untouched,
    /// "consistent with how unknown tokens behave" — and the widened alternative must
    /// not have quietly started matching it.
    @Test func anEmptyDateFormatIsStillNotResolvable() {
        #expect(!PlaceholderResolver.containsResolvablePlaceholder(in: "{date:}"))
        #expect(expand("{date:}") == "{date:}")
    }

    /// A token still cannot span from one brace pair into the next: neither alternative
    /// admits a brace, which is what stops the newly legal space from swallowing the
    /// text between two unrelated tokens.
    @Test func aTokenCannotSpanFromOneBracePairIntoTheNext() {
        let rendered = expand("a {date:MMM d, yyyy} b {clipboard} c")
        #expect(rendered == "a \(formatted("MMM d, yyyy")) b CLIPBOARD c")
        #expect(expand("{a} and {b}") == "{a} and {b}")
    }

    // MARK: - The unchanged vocabulary

    @Test func theBareTokensBehaveExactlyAsBefore() {
        #expect(expand("{clipboard}") == "CLIPBOARD")
        #expect(expand("{clipboard}", clipboard: nil) == "")
        #expect(expand("{date:yyyy-MM-dd}") == formatted("yyyy-MM-dd"))
        #expect(expand("TP-{date:yyyyMMdd}-{clipboard}")
                == "TP-\(formatted("yyyyMMdd"))-CLIPBOARD")
        for bare in ["{date}", "{time}", "{datetime}"] {
            #expect(!expand(bare).contains("{"), "\(bare) is replaced")
        }
    }

    /// Migrated from the standalone `Tests/PlaceholderResolverTests.swift`. The content
    /// editor's `{` completion and the resolver read from the same place precisely so a
    /// menu can never offer a token the resolver would leave sitting in the text. If
    /// someone adds a token to the list without teaching the resolver about it, this is
    /// what says so.
    @Test func theCompletionMenuOnlyOffersTokensTheResolverReplaces() {
        #expect(PlaceholderResolver.completionTokensAllResolve())
        #expect(!PlaceholderResolver.completionTokens.isEmpty)
        for token in PlaceholderResolver.completionTokens {
            #expect(token.hasPrefix("{") && token.hasSuffix("}"),
                    "\(token) is a complete brace pair, because completion replaces the brace typed")
            #expect(PlaceholderResolver.isResolvablePlaceholder(token))
        }
        #expect(PlaceholderResolver.completionTokens.filter { $0.hasPrefix("{da") }
                == ["{date}", "{datetime}", "{date:yyyy-MM-dd}"])
    }

    // MARK: - Injection

    /// The point of the closure: nothing in `Core/` may touch `NSPasteboard`. A template
    /// with no `{clipboard}` in it must not even ask.
    @Test func theClipboardIsOnlyReadWhenATemplateActuallyAsksForIt() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let read: () -> String? = { counter.reads += 1; return "CLIP" }

        _ = PlaceholderResolver.resolve(template: "{date}", clipboard: read, now: { epoch })
        #expect(counter.reads == 0)

        _ = PlaceholderResolver.resolve(template: "{clipboard}", clipboard: read, now: { epoch })
        #expect(counter.reads == 1)
    }

    /// One resolve samples one instant. Four separate `Date()` calls used to mean a
    /// template naming both the date and the time could straddle midnight, or a second
    /// boundary, and print two moments that never coexisted.
    @Test func theSameInputsAlwaysProduceTheSameOutput() {
        let template = "{date:HH:mm:ss} {time:HH:mm:ss} {date:yyyy-MM-dd}"
        let once = expand(template)
        #expect(once == expand(template))
        #expect(once == "\(formatted("HH:mm:ss")) \(formatted("HH:mm:ss")) \(formatted("yyyy-MM-dd"))")
    }

    @Test func theClipboardPreviewIsStillTruncated() {
        let huge = String(repeating: "x", count: 3_000)
        let preview = PlaceholderResolver.resolveForPreview(
            template: "{clipboard}", clipboard: { huge }, now: { epoch }
        )
        #expect(preview.hasSuffix("[clipboard preview truncated]"))
        #expect(preview.count < huge.count)
    }
}
