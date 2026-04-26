import AppKit
import Foundation

enum PlaceholderResolver {
    private enum PreviewLimit {
        static let clipboardCharacters = 1_000
        static let renderedCharacters = 2_000
    }

    private enum ResolutionMode {
        case expansion
        case preview
    }

    private static let tokenRegex = try? NSRegularExpression(pattern: "\\{([a-zA-Z0-9:_\\-]+)\\}")

    static func resolve(template: String) -> String {
        resolve(template: template, mode: .expansion)
    }

    static func resolveForPreview(template: String) -> String {
        let rendered = resolve(template: template, mode: .preview)
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

    private static func resolve(template: String, mode: ResolutionMode) -> String {
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
            guard let replacement = replacementValue(for: token, mode: mode) else {
                continue
            }

            rendered.replaceSubrange(fullTokenRange, with: replacement)
        }

        return rendered
    }

    private static func replacementValue(for token: String, mode: ResolutionMode) -> String? {
        if token == "clipboard" {
            let value = NSPasteboard.general.string(forType: .string) ?? ""
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
            return formatter.string(from: Date())
        }

        if token == "time" {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .medium
            return formatter.string(from: Date())
        }

        if token == "datetime" {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            return formatter.string(from: Date())
        }

        if token.hasPrefix("date:") || token.hasPrefix("time:") || token.hasPrefix("datetime:") {
            guard let format = token.split(separator: ":", maxSplits: 1).last else { return nil }
            let formatter = DateFormatter()
            formatter.dateFormat = String(format)
            return formatter.string(from: Date())
        }

        return nil
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
            || token.hasPrefix("date:")
            || token.hasPrefix("time:")
            || token.hasPrefix("datetime:")
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
