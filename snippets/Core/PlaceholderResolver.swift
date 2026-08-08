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

    private enum ResolutionMode {
        case expansion
        case preview
    }

    /// Two alternatives, not one widened character class.
    ///
    /// The second alternative is the original token spelling and still governs every
    /// bare token (`{clipboard}`, `{date}`) and everything unknown. The first widens
    /// the alphabet — space, comma, slash, period — but *only* after a literal
    /// `date:`/`time:`/`datetime:` prefix, because that is the only place a
    /// `DateFormatter` pattern can appear. Widening the single class instead would
    /// have made the resolver a candidate for arbitrary braced prose, and the import
    /// path is not the only thing that puts braces in a snippet: people keep JSON,
    /// CSS and Swift in here.
    ///
    /// The character after the prefix colon may not be a space, which is what keeps
    /// `{date: value}` and `{time: 300}` — object literals, not tokens — out. A real
    /// format never starts with a space, so nothing legitimate pays for that guard.
    ///
    /// Neither alternative admits `{` or `}`, so a token still cannot span from one
    /// brace pair into the next.
    private static let tokenRegex = try? NSRegularExpression(
        pattern: #"\{((?:date|time|datetime):[a-zA-Z0-9:_\-/.][a-zA-Z0-9:_\-/., ]*|[a-zA-Z0-9:_\-]+)\}"#
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
    /// Exposed for the standalone test rather than for the app.
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
        containsToken(in: template, where: isResolvableToken)
    }

    static func containsClipboardPlaceholder(in template: String) -> Bool {
        containsToken(in: template) { $0 == "clipboard" }
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
        guard let tokenRegex else { return false }

        let fullRange = NSRange(text.startIndex..., in: text)
        guard
            let match = tokenRegex.firstMatch(in: text, options: [], range: fullRange),
            match.range(at: 0).location == fullRange.location,
            match.range(at: 0).length == fullRange.length,
            match.numberOfRanges == 2,
            let tokenRange = Range(match.range(at: 1), in: text)
        else {
            return false
        }

        return isResolvableToken(String(text[tokenRange]))
    }

    private static func resolve(
        template: String,
        mode: ResolutionMode,
        clipboard: () -> String?,
        now: Date
    ) -> String {
        guard let tokenRegex else { return template }

        let fullRange = NSRange(template.startIndex..., in: template)
        var rendered = template

        let matches = tokenRegex.matches(in: template, options: [], range: fullRange).reversed()
        for match in matches {
            guard
                match.numberOfRanges == 2,
                let tokenRange = Range(match.range(at: 1), in: template),
                let fullTokenRange = Range(match.range(at: 0), in: template)
            else {
                continue
            }

            let token = String(template[tokenRange])
            guard let replacement = replacementValue(
                for: token, mode: mode, clipboard: clipboard, now: now
            ) else {
                continue
            }

            rendered.replaceSubrange(fullTokenRange, with: replacement)
        }

        return rendered
    }

    private static func replacementValue(
        for token: String,
        mode: ResolutionMode,
        clipboard: () -> String?,
        now: Date
    ) -> String? {
        if token == "clipboard" {
            let value = clipboard() ?? ""
            guard mode == .preview else { return value }
            return limitedPreview(
                value,
                characterLimit: PreviewLimit.clipboardCharacters,
                truncatedMarker: "[clipboard preview truncated]"
            )
        }

        if token == "date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: now)
        }

        if token == "time" {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return formatter.string(from: now)
        }

        if token == "datetime" {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: now)
        }

        if let format = formattedDatePattern(for: token) {
            let formatter = DateFormatter()
            formatter.dateFormat = format
            return formatter.string(from: now)
        }

        return nil
    }

    private static let formattedDatePrefixes = ["date:", "time:", "datetime:"]

    /// Explicit date format carried by a `date:`/`time:`/`datetime:` token.
    /// Returns nil for an empty format (e.g. `{date:}`) so the token is left
    /// untouched, consistent with how unknown tokens behave.
    private static func formattedDatePattern(for token: String) -> String? {
        guard let prefix = formattedDatePrefixes.first(where: token.hasPrefix) else { return nil }
        let format = String(token.dropFirst(prefix.count))
        return format.isEmpty ? nil : format
    }

    private static func containsToken(in template: String, where predicate: (String) -> Bool) -> Bool {
        guard let tokenRegex else { return false }

        let fullRange = NSRange(template.startIndex..., in: template)
        let matches = tokenRegex.matches(in: template, options: [], range: fullRange)
        for match in matches {
            guard
                match.numberOfRanges == 2,
                let tokenRange = Range(match.range(at: 1), in: template)
            else {
                continue
            }

            if predicate(String(template[tokenRange])) {
                return true
            }
        }

        return false
    }

    private static func isResolvableToken(_ token: String) -> Bool {
        token == "clipboard"
            || token == "date"
            || token == "time"
            || token == "datetime"
            || formattedDatePattern(for: token) != nil
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
