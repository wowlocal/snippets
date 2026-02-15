import AppKit
import Foundation

enum PlaceholderResolver {
    private static let tokenRegex = try? NSRegularExpression(pattern: "\\{([a-zA-Z0-9:_\\-]+)\\}")

    static func resolve(template: String) -> String {
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
            guard let replacement = replacementValue(for: token) else {
                continue
            }

            rendered.replaceSubrange(fullTokenRange, with: replacement)
        }

        return rendered
    }

    private static func replacementValue(for token: String) -> String? {
        if token == "clipboard" {
            return NSPasteboard.general.string(forType: .string) ?? ""
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
}
