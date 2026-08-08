import Foundation

// Compiled into the app and the test package — see `Snippet.swift`. Lives in `Core/`
// because it is the last thing that runs before snippet text is typed into someone
// else's document, so it needs to be reachable by `swift test`. The clipboard arrives
// as a closure rather than as `NSPasteboard.general` precisely so that this file can
// be built with no AppKit, no window server, and no pasteboard; the shipping default
// lives in `PlaceholderResolver+Pasteboard.swift` in the app target.

nonisolated enum PlaceholderResolver {
    private enum PreviewLimit {
        static let clipboardCharacters = 1_000
        static let renderedCharacters = 2_000
    }

    private enum ParserLimit {
        static let attributeTextCharacters = 1_024
        static let formatCharacters = 512
        static let localeCharacters = 64
        static let offsetTerms = 8
        static let offsetMagnitude = 100_000
    }

    private enum ResolutionMode {
        case expansion
        case preview
    }

    private enum TemporalKind: String, CaseIterable {
        case date
        case time
        case datetime
    }

    private struct TemporalOffset {
        enum Unit: Character {
            case minute = "m"
            case hour = "h"
            case day = "d"
            case month = "M"
            case year = "y"

            var calendarComponent: Calendar.Component {
                switch self {
                case .minute: .minute
                case .hour: .hour
                case .day: .day
                case .month: .month
                case .year: .year
                }
            }
        }

        let value: Int
        let unit: Unit
    }

    private struct TemporalPlaceholder {
        let kind: TemporalKind
        let format: String?
        let localeIdentifier: String?
        let offsets: [TemporalOffset]
    }

    private enum ParsedPlaceholder {
        case clipboard
        case temporal(TemporalPlaceholder)
    }

    private struct Attribute {
        let value: String
        let wasQuoted: Bool
    }

    /// This deliberately finds candidates rather than defining the placeholder grammar.
    /// `parsePlaceholder` below makes the decision. Keeping those jobs separate lets us
    /// accept Raycast's explicit `format="..."` syntax without widening the compact native
    /// `{date:yyyy-MM-dd}` spelling into arbitrary braced code such as
    /// `{date:value,time:value}` or `{date:path/to.file}`.
    private static let candidateRegex = try? NSRegularExpression(
        pattern: #"\{([^{}\r\n]*)\}"#
    )

    /// The compact spelling is the app's original grammar. Punctuation-rich patterns use
    /// the explicit quoted `format="..."` form instead, where their intent is unambiguous.
    private static let compactFormatRegex = try? NSRegularExpression(
        pattern: #"^[a-zA-Z0-9:_\-]+$"#
    )

    private static let localeSyntaxRegex = try? NSRegularExpression(
        pattern: #"^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{1,8})*$"#
    )

    private static let availableLocaleCores: Set<String> = Set(
        Locale.availableIdentifiers.map(localeCore)
    )

    /// What typing `{` in the content editor offers. Deliberately next door to
    /// `isResolvableToken` below, which is the rule that decides whether any of
    /// them actually resolve: kept apart, a menu could offer a token the
    /// resolver would then ignore. `assertCompletionTokensResolve` is the check.
    static let completionTokens = [
        "{clipboard}",
        "{date}",
        "{time}",
        "{datetime}",
        "{date:yyyy-MM-dd}"
    ]

    /// True when every offered token is one the resolver will actually replace.
    /// Exposed for the `SnippetsCore` regression suite rather than for the app.
    static func completionTokensAllResolve() -> Bool {
        completionTokens.allSatisfy { token in
            containsResolvablePlaceholder(in: token)
        }
    }

    static func resolve(
        template: String,
        clipboard: () -> String?,
        now: () -> Date = { Date() }
    ) -> String {
        resolve(template: template, mode: .expansion, clipboard: clipboard, now: now())
    }

    static func resolveForPreview(
        template: String,
        clipboard: () -> String?,
        now: () -> Date = { Date() }
    ) -> String {
        let rendered = resolve(template: template, mode: .preview, clipboard: clipboard, now: now())
        return limitedPreview(
            rendered,
            characterLimit: PreviewLimit.renderedCharacters,
            truncatedMarker: "[preview truncated]"
        )
    }

    static func containsResolvablePlaceholder(in template: String) -> Bool {
        containsPlaceholder(in: template) { _ in true }
    }

    static func containsClipboardPlaceholder(in template: String) -> Bool {
        containsPlaceholder(in: template) {
            if case .clipboard = $0 { return true }
            return false
        }
    }

    /// True when `text` is *exactly* one `{…}` token this resolver replaces — nothing
    /// around it, nothing smuggled alongside it.
    ///
    /// `containsResolvablePlaceholder` asks "is there a live token somewhere in here",
    /// which is the right question for a snippet body and the wrong one for an importer
    /// that has just synthesised a token and wants to know whether it will read back:
    /// a Raycast format carrying its own braces (`{date "x}{clipboard"}`) would
    /// otherwise be judged by whatever the tail of it happened to look like.
    static func isResolvablePlaceholder(_ text: String) -> Bool {
        guard let candidateRegex else { return false }

        let fullRange = NSRange(text.startIndex..., in: text)
        guard
            let match = candidateRegex.firstMatch(in: text, options: [], range: fullRange),
            match.range(at: 0).location == fullRange.location,
            match.range(at: 0).length == fullRange.length,
            match.numberOfRanges == 2,
            let tokenRange = Range(match.range(at: 1), in: text)
        else {
            return false
        }

        return parsePlaceholder(String(text[tokenRange])) != nil
    }

    private static func resolve(
        template: String,
        mode: ResolutionMode,
        clipboard: () -> String?,
        now: Date
    ) -> String {
        guard let candidateRegex else { return template }

        let fullRange = NSRange(template.startIndex..., in: template)
        var rendered = template

        let matches = candidateRegex.matches(in: template, options: [], range: fullRange).reversed()
        for match in matches {
            guard
                match.numberOfRanges == 2,
                let tokenRange = Range(match.range(at: 1), in: template),
                let fullTokenRange = Range(match.range(at: 0), in: template)
            else {
                continue
            }

            guard let placeholder = parsePlaceholder(String(template[tokenRange])) else {
                continue
            }
            guard let replacement = replacementValue(
                for: placeholder, mode: mode, clipboard: clipboard, now: now
            ) else {
                continue
            }

            rendered.replaceSubrange(fullTokenRange, with: replacement)
        }

        return rendered
    }

    private static func replacementValue(
        for placeholder: ParsedPlaceholder,
        mode: ResolutionMode,
        clipboard: () -> String?,
        now: Date
    ) -> String? {
        switch placeholder {
        case .clipboard:
            let value = clipboard() ?? ""
            guard mode == .preview else { return value }
            return limitedPreview(
                value,
                characterLimit: PreviewLimit.clipboardCharacters,
                truncatedMarker: "[clipboard preview truncated]"
            )

        case .temporal(let temporal):
            guard let adjustedDate = adjustedDate(now, for: temporal) else { return nil }
            let formatter = DateFormatter()
            if let localeIdentifier = temporal.localeIdentifier {
                formatter.locale = Locale(identifier: localeIdentifier)
            }
            if let format = temporal.format {
                formatter.dateFormat = format
            } else {
                switch temporal.kind {
                case .date:
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .none
                case .time:
                    formatter.dateStyle = .none
                    formatter.timeStyle = .medium
                case .datetime:
                    formatter.dateStyle = .medium
                    formatter.timeStyle = .medium
                }
            }

            return formatter.string(from: adjustedDate)
        }
    }

    private static func adjustedDate(
        _ date: Date,
        for placeholder: TemporalPlaceholder
    ) -> Date? {
        var calendar = Calendar.current
        if let localeIdentifier = placeholder.localeIdentifier {
            calendar.locale = Locale(identifier: localeIdentifier)
        }

        var adjusted = date
        for offset in placeholder.offsets {
            guard let next = calendar.date(
                byAdding: offset.unit.calendarComponent,
                value: offset.value,
                to: adjusted
            ) else {
                return nil
            }
            adjusted = next
        }
        return adjusted
    }

    private static func containsPlaceholder(
        in template: String,
        where predicate: (ParsedPlaceholder) -> Bool
    ) -> Bool {
        guard let candidateRegex else { return false }

        let fullRange = NSRange(template.startIndex..., in: template)
        let matches = candidateRegex.matches(in: template, options: [], range: fullRange)
        for match in matches {
            guard
                match.numberOfRanges == 2,
                let tokenRange = Range(match.range(at: 1), in: template)
            else {
                continue
            }

            if let placeholder = parsePlaceholder(String(template[tokenRange])),
               predicate(placeholder) {
                return true
            }
        }

        return false
    }

    private static func parsePlaceholder(_ body: String) -> ParsedPlaceholder? {
        if body == "clipboard" { return .clipboard }

        for kind in TemporalKind.allCases {
            if body == kind.rawValue {
                return .temporal(
                    TemporalPlaceholder(kind: kind, format: nil, localeIdentifier: nil, offsets: [])
                )
            }

            let compactPrefix = kind.rawValue + ":"
            if body.hasPrefix(compactPrefix) {
                let format = String(body.dropFirst(compactPrefix.count))
                guard isCompactFormat(format) else { return nil }
                return .temporal(
                    TemporalPlaceholder(kind: kind, format: format, localeIdentifier: nil, offsets: [])
                )
            }

            // Legacy Raycast exports used `{date "…"}`. Accept it directly as well as through
            // `RaycastPlaceholders.converted`, because an older import may already be on disk.
            let legacyPrefix = kind.rawValue + " \""
            if body.hasPrefix(legacyPrefix), body.hasSuffix("\"") {
                let start = body.index(body.startIndex, offsetBy: legacyPrefix.count)
                let end = body.index(before: body.endIndex)
                let format = String(body[start..<end])
                guard isExplicitFormat(format) else { return nil }
                return .temporal(
                    TemporalPlaceholder(kind: kind, format: format, localeIdentifier: nil, offsets: [])
                )
            }

            let attributePrefix = kind.rawValue + " "
            if body.hasPrefix(attributePrefix) {
                let attributeText = String(body.dropFirst(attributePrefix.count))
                return parseTemporalAttributes(attributeText, kind: kind).map(ParsedPlaceholder.temporal)
            }
        }

        return nil
    }

    private static func parseTemporalAttributes(
        _ text: String,
        kind: TemporalKind
    ) -> TemporalPlaceholder? {
        guard text.count <= ParserLimit.attributeTextCharacters,
              let attributes = parseAttributes(text),
              !attributes.isEmpty,
              attributes.count <= 3
        else {
            return nil
        }

        var format: String?
        var localeIdentifier: String?
        var offsets: [TemporalOffset] = []
        var seen = Set<String>()

        for (key, attribute) in attributes {
            guard seen.insert(key).inserted else { return nil }
            switch key {
            case "format":
                guard attribute.wasQuoted, isExplicitFormat(attribute.value) else { return nil }
                format = attribute.value

            case "locale":
                guard attribute.wasQuoted,
                      let locale = validatedLocaleIdentifier(attribute.value)
                else {
                    return nil
                }
                localeIdentifier = locale

            case "offset":
                guard let parsedOffsets = parseOffsets(attribute.value) else { return nil }
                offsets = parsedOffsets

            default:
                return nil
            }
        }

        // Raycast treats these as mutually exclusive: a custom pattern fully specifies
        // formatting, while `locale` selects the localized default style.
        guard format == nil || localeIdentifier == nil else { return nil }
        return TemporalPlaceholder(
            kind: kind,
            format: format,
            localeIdentifier: localeIdentifier,
            offsets: offsets
        )
    }

    private static func parseAttributes(_ text: String) -> [(String, Attribute)]? {
        var attributes: [(String, Attribute)] = []
        var index = text.startIndex

        while index < text.endIndex {
            while index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }

            let keyStart = index
            while index < text.endIndex, text[index] != "=", text[index] != " " {
                index = text.index(after: index)
            }
            guard index < text.endIndex, text[index] == "=", keyStart < index else { return nil }
            let key = String(text[keyStart..<index])
            index = text.index(after: index)
            guard index < text.endIndex else { return nil }

            let value: String
            let wasQuoted: Bool
            if text[index] == "\"" {
                wasQuoted = true
                index = text.index(after: index)
                let valueStart = index
                while index < text.endIndex, text[index] != "\"" {
                    index = text.index(after: index)
                }
                guard index < text.endIndex else { return nil }
                value = String(text[valueStart..<index])
                index = text.index(after: index)
            } else {
                wasQuoted = false
                let valueStart = index
                while index < text.endIndex, text[index] != " " {
                    index = text.index(after: index)
                }
                guard valueStart < index else { return nil }
                value = String(text[valueStart..<index])
            }

            if index < text.endIndex, text[index] != " " { return nil }
            attributes.append((key, Attribute(value: value, wasQuoted: wasQuoted)))
        }

        return attributes
    }

    private static func parseOffsets(_ value: String) -> [TemporalOffset]? {
        let terms = value.split(separator: " ", omittingEmptySubsequences: true)
        guard !terms.isEmpty, terms.count <= ParserLimit.offsetTerms else { return nil }

        var offsets: [TemporalOffset] = []
        offsets.reserveCapacity(terms.count)
        for term in terms {
            guard term.count >= 3,
                  let sign = term.first, sign == "+" || sign == "-",
                  let unitCharacter = term.last,
                  let unit = TemporalOffset.Unit(rawValue: unitCharacter)
            else {
                return nil
            }

            let digits = term.dropFirst().dropLast()
            guard !digits.isEmpty,
                  digits.unicodeScalars.allSatisfy({ (48...57).contains(Int($0.value)) }),
                  let magnitude = Int(digits),
                  magnitude <= ParserLimit.offsetMagnitude
            else {
                return nil
            }

            offsets.append(
                TemporalOffset(value: sign == "-" ? -magnitude : magnitude, unit: unit)
            )
        }
        return offsets
    }

    private static func isCompactFormat(_ format: String) -> Bool {
        guard !format.isEmpty, let compactFormatRegex else { return false }
        let range = NSRange(format.startIndex..., in: format)
        guard let match = compactFormatRegex.firstMatch(in: format, options: [], range: range) else {
            return false
        }
        return match.range.location == range.location && match.range.length == range.length
    }

    private static func isExplicitFormat(_ format: String) -> Bool {
        guard !format.isEmpty,
              format.count <= ParserLimit.formatCharacters,
              !format.contains("\"") && !format.contains("{") && !format.contains("}"),
              !format.contains("\n") && !format.contains("\r")
        else {
            return false
        }

        // ICU quotes literal prose with apostrophes; doubled apostrophes are a literal
        // apostrophe and do not enter or leave quote mode.
        var index = format.startIndex
        var isInsideLiteral = false
        while index < format.endIndex {
            guard format[index] == "'" else {
                index = format.index(after: index)
                continue
            }
            let next = format.index(after: index)
            if next < format.endIndex, format[next] == "'" {
                index = format.index(after: next)
            } else {
                isInsideLiteral.toggle()
                index = next
            }
        }
        return !isInsideLiteral
    }

    private static func validatedLocaleIdentifier(_ identifier: String) -> String? {
        guard !identifier.isEmpty,
              identifier.count <= ParserLimit.localeCharacters,
              !identifier.contains("_"),
              let localeSyntaxRegex
        else {
            return nil
        }

        let range = NSRange(identifier.startIndex..., in: identifier)
        guard let match = localeSyntaxRegex.firstMatch(in: identifier, options: [], range: range),
              match.range.location == range.location,
              match.range.length == range.length
        else {
            return nil
        }

        let core = localeCore(identifier)
        guard availableLocaleCores.contains(core)
                || availableLocaleCores.contains(where: { $0.hasPrefix(core + "-") })
        else {
            return nil
        }
        return identifier
    }

    private static func localeCore(_ identifier: String) -> String {
        var normalized = identifier
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()
        if let legacyOptions = normalized.firstIndex(of: "@") {
            normalized = String(normalized[..<legacyOptions])
        }
        if let unicodeExtension = normalized.range(of: "-u-") {
            normalized = String(normalized[..<unicodeExtension.lowerBound])
        }
        return normalized
    }

    private static func limitedPreview(
        _ value: String,
        characterLimit: Int,
        truncatedMarker: String
    ) -> String {
        guard
            characterLimit > 0,
            let cutoffIndex = value.index(
                value.startIndex,
                offsetBy: characterLimit,
                limitedBy: value.endIndex
            ),
            cutoffIndex < value.endIndex
        else {
            return value
        }

        return String(value[..<cutoffIndex]) + "\n... " + truncatedMarker
    }
}
