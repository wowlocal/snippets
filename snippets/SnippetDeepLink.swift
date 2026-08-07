import Foundation

enum SnippetDeepLinkError: LocalizedError {
    case unsupportedURL
    case missingPayload
    case invalidPayload
    case unsupportedVersion
    case cannotEncodePayload

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            return "This link is not a supported Snippets share link."
        case .missingPayload:
            return "This share link is missing snippet data."
        case .invalidPayload:
            return "This share link is malformed or corrupted."
        case .unsupportedVersion:
            return "This share link was created by a newer version of Snippets."
        case .cannotEncodePayload:
            return "Could not create a share link for this snippet."
        }
    }
}

enum SnippetDeepLink {
    static let scheme = "snippets"

    private static let host = "share"
    /// `snippets://new?content=…` — the hand-writable half of the scheme.
    private static let creationHost = "new"
    private static let payloadQueryItem = "data"
    private static let currentVersion = 1

    private struct Payload: Codable {
        let version: Int
        let name: String
        let keyword: String
        let content: String
        // Optional so links from older app versions still decode.
        let tags: [String]?
    }

    static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        return scheme == self.scheme && (host == self.host || host == creationHost)
    }

    static func url(for snippet: Snippet) throws -> URL {
        let payload = Payload(
            version: currentVersion,
            name: snippet.name,
            keyword: snippet.normalizedKeyword,
            content: snippet.content,
            tags: snippet.tags.isEmpty ? nil : snippet.tags
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encodedPayload: String
        do {
            encodedPayload = try encoder.encode(payload).base64URLEncodedString()
        } catch {
            throw SnippetDeepLinkError.cannotEncodePayload
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: payloadQueryItem, value: encodedPayload)]

        guard let url = components.url else {
            throw SnippetDeepLinkError.cannotEncodePayload
        }

        return url
    }

    static func snippet(from url: URL) throws -> Snippet {
        guard canHandle(url) else {
            throw SnippetDeepLinkError.unsupportedURL
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SnippetDeepLinkError.missingPayload
        }

        if url.host?.lowercased() == creationHost {
            return try creationSnippet(from: components)
        }

        guard let encodedPayload = components.queryItems?.first(where: { $0.name == payloadQueryItem })?.value
        else {
            throw SnippetDeepLinkError.missingPayload
        }

        guard let data = Data(base64URLEncoded: encodedPayload) else {
            throw SnippetDeepLinkError.invalidPayload
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw SnippetDeepLinkError.invalidPayload
        }

        guard payload.version == currentVersion else {
            throw SnippetDeepLinkError.unsupportedVersion
        }

        return Snippet(
            name: payload.name,
            keyword: normalizedSharedKeyword(payload.keyword),
            content: payload.content,
            tags: SnippetTagging.normalizedTags(payload.tags ?? [])
        )
    }

    /// Plain query items, no base64 envelope and no version to pin: the share
    /// link is machine-written and round-trips a whole record, but this one has
    /// to survive being typed by hand and assembled by Shortcuts or Alfred,
    /// where percent-encoding is the only step available.
    ///
    /// Every field is optional so `snippets://new?content=…` is a complete link,
    /// but an empty one is refused — a URL that carries nothing is a mistake, not
    /// a request for a blank snippet.
    private static func creationSnippet(from components: URLComponents) throws -> Snippet {
        let queryItems = components.queryItems ?? []
        func value(named name: String) -> String {
            queryItems.first { $0.name.lowercased() == name }?.value ?? ""
        }

        let name = value(named: "name")
        let keyword = value(named: "keyword")
        let content = value(named: "content")
        let tags = value(named: "tags").components(separatedBy: ",")

        guard !name.isEmpty || !keyword.isEmpty || !content.isEmpty else {
            throw SnippetDeepLinkError.missingPayload
        }

        return Snippet(
            name: name,
            keyword: normalizedSharedKeyword(keyword),
            content: content,
            tags: SnippetTagging.normalizedTags(tags)
        )
    }

    private static func normalizedSharedKeyword(_ rawKeyword: String) -> String {
        Snippet.sanitizedKeyword(rawKeyword)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let paddingRemainder = base64.count % 4
        if paddingRemainder != 0 {
            base64.append(String(repeating: "=", count: 4 - paddingRemainder))
        }

        self.init(base64Encoded: base64)
    }
}
