import Foundation
import XCTest
@testable import SnippetsCore

final class PreparedSubstringSearchTests: XCTestCase {
    func testBytePathAndUnicodeFallbackAgreeWithCanonicalSubstringSearch() {
        let texts = ["", "abc xyz", "aaaaab", "a\0b", "a\r\nb", "K", "`", "Café", "Cafe\u{301}",
                     "👩🏽‍💻 code", "👩", "東京", "Σςσ", "Ångström", "가", "\u{1100}\u{1161}"]
        let queries = ["", "a", "ab", "ba", "aaab", "aaaba", "zy", "\0", "\r", "\n", "\r\n", "K", "K", "`",
                       "é", "e\u{301}", "👩", "🏽", "💻", "東京", "σ", "Å", "A\u{30a}", "가", "\u{1100}\u{1161}"]
        for text in texts {
            let field = PreparedSubstringSearch.Field(text)
            for query in queries {
                XCTAssertEqual(field.contains(.init(query)), text.contains(query),
                               "text=\(text.debugDescription), query=\(query.debugDescription)")
            }
        }
    }
}
