import Foundation

/// A fully decoded, immutable import that can safely cross back to the main actor.
/// Parsing happens before the store is touched, so a malformed or oversized document
/// cannot leave a partial library mutation behind.
nonisolated struct PreparedSnippetImport: Sendable {
    let snippets: [Snippet]
    let snippetsPreservingExclamationPrefix: [Snippet]
    let hasRaycastExclamationKeywords: Bool

    func snippets(preservingExclamationPrefix preserve: Bool) -> [Snippet] {
        preserve ? snippetsPreservingExclamationPrefix : snippets
    }
}

/// Foundation-only import decoding, intentionally independent of `SnippetStore` so iOS
/// can run JSON work away from the main actor before applying the prepared records.
nonisolated enum SnippetImportParser {
    enum Failure: Error, Equatable {
        case invalidFormat
    }

    private struct SnippetCollection: Decodable {
        let snippets: [Snippet]
    }

    private struct RaycastSnippet: Decodable {
        let name: String
        let text: String
        let keyword: String?
    }

    static func parse(_ data: Data) throws -> PreparedSnippetImport {
        let decoder = JSONDecoder()
        if let snippets = try? decoder.decode([Snippet].self, from: data) {
            return native(snippets)
        }
        if let collection = try? decoder.decode(SnippetCollection.self, from: data) {
            return native(collection.snippets)
        }
        guard let raycast = try? decoder.decode([RaycastSnippet].self, from: data),
              !raycast.isEmpty else {
            throw Failure.invalidFormat
        }

        let preserving = raycast.map { item in
            Snippet(
                name: item.name,
                keyword: normalizedRaycastKeyword(item.keyword, preserveExclamationPrefix: true),
                content: RaycastPlaceholders.converted(item.text)
            )
        }
        let normalized = raycast.map { item in
            Snippet(
                name: item.name,
                keyword: normalizedRaycastKeyword(item.keyword, preserveExclamationPrefix: false),
                content: RaycastPlaceholders.converted(item.text)
            )
        }
        return PreparedSnippetImport(
            snippets: normalized,
            snippetsPreservingExclamationPrefix: preserving,
            hasRaycastExclamationKeywords: preserving.contains {
                $0.normalizedKeyword.hasPrefix("!")
            }
        )
    }

    private static func native(_ snippets: [Snippet]) -> PreparedSnippetImport {
        PreparedSnippetImport(
            snippets: snippets,
            snippetsPreservingExclamationPrefix: snippets,
            hasRaycastExclamationKeywords: false
        )
    }

    private static func normalizedRaycastKeyword(
        _ rawKeyword: String?,
        preserveExclamationPrefix: Bool
    ) -> String {
        var keyword = Snippet.sanitizedKeyword(rawKeyword ?? "")
        if !preserveExclamationPrefix, keyword.hasPrefix("!") {
            keyword.removeFirst()
            keyword = Snippet.sanitizedKeyword(keyword)
        }
        return keyword
    }
}
