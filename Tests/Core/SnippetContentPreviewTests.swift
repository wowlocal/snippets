import Foundation
import Testing

@testable import SnippetsCore

@Suite("Snippet content preview")
struct SnippetContentPreviewTests {
    private func snippet(content: String) -> Snippet {
        Snippet(name: "", keyword: "", content: content)
    }

    @Test func skipsBlankLinesAndTrimsTheFirstContentLine() {
        let value = snippet(content: " \t\r\n\n  café 👩🏽‍💻  \nignored")

        #expect(value.contentFirstLineUntruncated == "café 👩🏽‍💻")
    }

    @Test func recognizesEveryFoundationNewlineScalar() {
        let separators = [
            "\n", "\r", "\r\n", "\u{000B}", "\u{000C}", "\u{0085}",
            "\u{2028}", "\u{2029}",
        ]

        for separator in separators {
            let value = snippet(
                content: " \t\(separator)\u{2003}Expected\u{00A0}\(separator)ignored"
            )
            #expect(value.contentFirstLineUntruncated == "Expected")
        }
    }

    @Test func returnsEmptyForEmptyOrWhitespaceOnlyContent() {
        #expect(snippet(content: "").contentFirstLineUntruncated == "")
        #expect(
            snippet(content: " \t\r\n\u{2003}\u{2029}\u{00A0}")
                .contentFirstLineUntruncated == ""
        )
    }

    @Test func stopsBeforeLargeTrailingContent() {
        let trailingContent = String(repeating: "x", count: 1_000_000)
        let value = snippet(content: "\n  Preview  \n\(trailingContent)")

        #expect(value.contentFirstLineUntruncated == "Preview")
    }
}
