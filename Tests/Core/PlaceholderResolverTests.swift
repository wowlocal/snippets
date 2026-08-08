import Foundation
import Testing

@testable import SnippetsCore

// The resolver is the last code that runs before snippet text lands in someone else's
// document, and the import path is the only place tokens are written by a machine
// rather than by a person. Every test here names the damage it prevents.

/// 2026-02-15 12:00:00 UTC. Expected values are made with the same ambient calendar,
/// time zone and formatter defaults as the resolver; the instant itself never moves.
private let epoch = Date(timeIntervalSince1970: 1_771_156_800)

private func expand(_ template: String, clipboard: String? = "CLIPBOARD") -> String {
    PlaceholderResolver.resolve(template: template, clipboard: { clipboard }, now: { epoch })
}

private func formatted(
    _ pattern: String,
    at date: Date = epoch,
    localeIdentifier: String? = nil
) -> String {
    let formatter = DateFormatter()
    if let localeIdentifier {
        formatter.locale = Locale(identifier: localeIdentifier)
    }
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}

private func styled(
    dateStyle: DateFormatter.Style,
    timeStyle: DateFormatter.Style,
    at date: Date = epoch,
    localeIdentifier: String? = nil
) -> String {
    let formatter = DateFormatter()
    if let localeIdentifier {
        formatter.locale = Locale(identifier: localeIdentifier)
    }
    formatter.dateStyle = dateStyle
    formatter.timeStyle = timeStyle
    return formatter.string(from: date)
}

private func shifted(
    _ date: Date = epoch,
    _ offsets: [(Calendar.Component, Int)],
    localeIdentifier: String? = nil
) -> Date {
    var calendar = Calendar.current
    if let localeIdentifier {
        calendar.locale = Locale(identifier: localeIdentifier)
    }
    return offsets.reduce(date) { partial, offset in
        calendar.date(byAdding: offset.0, value: offset.1, to: partial)!
    }
}

@Suite("Placeholder resolver")
struct PlaceholderResolverTests {

    // MARK: - Legacy and current Raycast round trips

    /// Legacy Raycast exports used `{date "…"}`. Canonicalize all three temporal kinds to
    /// Raycast's current explicit quoted grammar, then prove the resolver reads back every
    /// byte the importer wrote. A punctuation-rich format never enters the ambiguous
    /// compact `{date:…}` grammar.
    @Test func legacyRaycastFormatsCanonicalizeToResolvableCurrentTokens() {
        let cases = [
            (
                legacy: #"{date "MMM d, yyyy"}"#,
                token: #"{date format="MMM d, yyyy"}"#,
                pattern: "MMM d, yyyy"
            ),
            (
                legacy: #"{time "HH:mm:ss.SSS"}"#,
                token: #"{time format="HH:mm:ss.SSS"}"#,
                pattern: "HH:mm:ss.SSS"
            ),
            (
                legacy: #"{datetime "yyyy-MM-dd'T'HH:mm:ssZ"}"#,
                token: #"{datetime format="yyyy-MM-dd'T'HH:mm:ssZ"}"#,
                pattern: "yyyy-MM-dd'T'HH:mm:ssZ"
            ),
            (
                legacy: #"{date "yyyy年MM月dd日"}"#,
                token: #"{date format="yyyy年MM月dd日"}"#,
                pattern: "yyyy年MM月dd日"
            ),
        ]

        for testCase in cases {
            let converted = RaycastPlaceholders.converted(testCase.legacy)
            #expect(converted == testCase.token)
            #expect(PlaceholderResolver.isResolvablePlaceholder(converted))
            #expect(expand(converted) == formatted(testCase.pattern))
            #expect(!expand(converted).contains("{"))
        }
    }

    /// These examples use the current syntax documented by Raycast. They need no
    /// import rewrite: preserving them byte for byte also means a future modifier is
    /// never accidentally stripped by the compatibility converter.
    @Test func currentRaycastFormatsPassThroughAndExpand() {
        let cases = [
            (#"{date format="EEEE, MMM d, yyyy"}"#, "EEEE, MMM d, yyyy"),
            (#"{date format="MM/dd/yyyy"}"#, "MM/dd/yyyy"),
            (#"{time format="HH:mm:ss.SSS"}"#, "HH:mm:ss.SSS"),
            (#"{datetime format="yyyy-MM-dd'T'HH:mm:ssZ"}"#, "yyyy-MM-dd'T'HH:mm:ssZ"),
            (#"{date format="h:mm 'on the eve of' MMMM d"}"#, "h:mm 'on the eve of' MMMM d"),
        ]

        for (source, pattern) in cases {
            #expect(RaycastPlaceholders.converted(source) == source)
            #expect(PlaceholderResolver.isResolvablePlaceholder(source))
            #expect(expand(source) == formatted(pattern))
        }
    }

    @Test func offsetsUseTheInjectedInstantAndCalendar() {
        let formattedSource = #"{date format="yyyy-MM-dd HH:mm" offset="+3M -5d +2h +30m"}"#
        let formattedDate = shifted(epoch, [(.month, 3), (.day, -5), (.hour, 2), (.minute, 30)])
        #expect(expand(formattedSource) == formatted("yyyy-MM-dd HH:mm", at: formattedDate))

        let unquotedSource = "{time offset=+1h}"
        let oneHourLater = shifted(epoch, [(.hour, 1)])
        #expect(
            expand(unquotedSource)
                == styled(dateStyle: .none, timeStyle: .medium, at: oneHourLater)
        )

        let attributesInEitherOrder = #"{date offset="+1d" format="yyyy-MM-dd"}"#
        #expect(
            expand(attributesInEitherOrder)
                == formatted("yyyy-MM-dd", at: shifted(epoch, [(.day, 1)]))
        )
    }

    @Test func localeUsesLocalizedDefaultStyleAndCombinesWithOffset() {
        let french = #"{date locale="fr-FR" offset="+1d"}"#
        let tomorrow = shifted(epoch, [(.day, 1)], localeIdentifier: "fr-FR")
        #expect(
            expand(french)
                == styled(
                    dateStyle: .medium,
                    timeStyle: .none,
                    at: tomorrow,
                    localeIdentifier: "fr-FR"
                )
        )

        let twentyFourHour = #"{time locale="en-US-u-hc-h23"}"#
        #expect(
            expand(twentyFourHour)
                == styled(
                    dateStyle: .none,
                    timeStyle: .medium,
                    localeIdentifier: "en-US-u-hc-h23"
                )
        )
    }

    @Test func severalLegacyRaycastTokensAreAllCanonicalized() {
        let source = #"On {date "MMM d, yyyy"} at {time "HH:mm"} ({datetime "yyyy/MM/dd HH:mm"})"#
        let converted = RaycastPlaceholders.converted(source)
        #expect(
            converted
                == #"On {date format="MMM d, yyyy"} at {time format="HH:mm"} ({datetime format="yyyy/MM/dd HH:mm"})"#
        )
        #expect(
            expand(converted)
                == "On \(formatted("MMM d, yyyy")) at \(formatted("HH:mm")) (\(formatted("yyyy/MM/dd HH:mm")))"
        )
    }

    /// A compatibility rewrite is allowed only when its entire output is live. Inputs
    /// that carry braces, an unterminated ICU literal, or a quote boundary stay in the
    /// visibly foreign legacy spelling instead of becoming dead native-looking tokens.
    @Test(arguments: [
        #"{date "{yyyy}"}"#,
        #"{date "x}{clipboard"}"#,
        #"{date "yyyy-MM-dd'T"}"#,
        #"{date "unterminated}"#,
    ])
    func importerNeverManufacturesAnInertToken(source: String) {
        #expect(RaycastPlaceholders.converted(source) == source)
        #expect(!PlaceholderResolver.isResolvablePlaceholder(source))
    }

    // MARK: - Negative controls: explicit syntax must not eat ordinary code

    /// This is the compatibility regression a widened date character class caused.
    /// Compact JS/object literals and path-like values were matched as DateFormatter
    /// patterns and replaced with arbitrary date text. Only an explicit quoted
    /// `format=` value may carry commas, spaces, slashes or periods now.
    @Test(arguments: [
        "{date:value,time:value}",
        "{date:value, time:value}",
        "const metadata={date:value,time:value}",
        "{date:path/to.file}",
        "{time:host/path.txt}",
        "{datetime:value,date:value}",
    ])
    func compactCodeAndPathsPassThroughByteForByte(source: String) {
        #expect(expand(source) == source)
        #expect(!PlaceholderResolver.containsResolvablePlaceholder(in: source))
        #expect(!PlaceholderResolver.isResolvablePlaceholder(source))
    }

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

    @Test(arguments: [
        #"{date format="yyyy-MM-dd" locale="fr-FR"}"#,
        "{date format=yyyy-MM-dd}",
        "{date locale=fr-FR}",
        #"{date locale="en_US"}"#,
        #"{date locale="zz-ZZ"}"#,
        #"{date offset="+ 2d"}"#,
        #"{date offset="+1w"}"#,
        #"{date offset="+100001d"}"#,
        #"{date offset="+1d" offset="+2d"}"#,
        #"{date format="yyyy-MM-dd" unknown="x"}"#,
        #"{date format="yyyy-MM-dd'T"}"#,
        #"{date format=""}"#,
    ])
    func invalidOrAmbiguousModifiersStayVisible(source: String) {
        #expect(expand(source) == source)
        #expect(!PlaceholderResolver.containsResolvablePlaceholder(in: source))
        #expect(!PlaceholderResolver.isResolvablePlaceholder(source))
    }

    @Test func anEmptyDateFormatIsStillNotResolvable() {
        #expect(!PlaceholderResolver.containsResolvablePlaceholder(in: "{date:}"))
        #expect(expand("{date:}") == "{date:}")
    }

    @Test func aTokenCannotSpanFromOneBracePairIntoTheNext() {
        let rendered = expand(#"a {date format="MMM d, yyyy"} b {clipboard} c"#)
        #expect(rendered == "a \(formatted("MMM d, yyyy")) b CLIPBOARD c")
        #expect(expand("{a} and {b}") == "{a} and {b}")
    }

    // MARK: - The unchanged native vocabulary

    @Test func bareAndCompactNativeTokensBehaveExactlyAsBefore() {
        #expect(expand("{clipboard}") == "CLIPBOARD")
        #expect(expand("{clipboard}", clipboard: nil) == "")
        #expect(expand("{date:yyyy-MM-dd}") == formatted("yyyy-MM-dd"))
        #expect(
            expand("TP-{date:yyyyMMdd}-{clipboard}")
                == "TP-\(formatted("yyyyMMdd"))-CLIPBOARD"
        )
        for bare in ["{date}", "{time}", "{datetime}"] {
            #expect(!expand(bare).contains("{"), "\(bare) is replaced")
        }
    }

    @Test func theCompletionMenuOnlyOffersTokensTheResolverReplaces() {
        #expect(PlaceholderResolver.completionTokensAllResolve())
        #expect(!PlaceholderResolver.completionTokens.isEmpty)
        for token in PlaceholderResolver.completionTokens {
            #expect(token.hasPrefix("{") && token.hasSuffix("}"))
            #expect(PlaceholderResolver.isResolvablePlaceholder(token))
        }
        #expect(
            PlaceholderResolver.completionTokens.filter { $0.hasPrefix("{da") }
                == ["{date}", "{datetime}", "{date:yyyy-MM-dd}"]
        )
    }

    // MARK: - Dependency injection and previews

    @Test func theClipboardIsOnlyReadWhenATemplateActuallyAsksForIt() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let read: () -> String? = { counter.reads += 1; return "CLIP" }

        _ = PlaceholderResolver.resolve(template: "{date}", clipboard: read, now: { epoch })
        #expect(counter.reads == 0)

        _ = PlaceholderResolver.resolve(template: "{clipboard}", clipboard: read, now: { epoch })
        #expect(counter.reads == 1)
    }

    /// Offset and formatting work from the single injected sample too; no modifier is
    /// allowed to call `Date()` independently and straddle a time boundary.
    @Test func oneResolutionSamplesTheClockExactlyOnce() {
        final class Counter: @unchecked Sendable { var reads = 0 }
        let counter = Counter()
        let rendered = PlaceholderResolver.resolve(
            template: #"{date format="HH:mm:ss"} {time offset=+1h} {date:yyyy-MM-dd}"#,
            clipboard: { nil },
            now: { counter.reads += 1; return epoch }
        )

        #expect(counter.reads == 1)
        #expect(
            rendered
                == "\(formatted("HH:mm:ss")) "
                + styled(
                    dateStyle: .none,
                    timeStyle: .medium,
                    at: shifted(epoch, [(.hour, 1)])
                )
                + " \(formatted("yyyy-MM-dd"))"
        )
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
