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
    private static let payloadQueryItem = "data"
    private static let currentVersion = 1

    private struct Payload: Codable {
        let version: Int
        let name: String
        let keyword: String
        let content: String
    }

    static func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else {
            return false
        }

        return scheme == self.scheme && host == self.host
    }

    static func url(for snippet: Snippet) throws -> URL {
        let payload = Payload(
            version: currentVersion,
            name: snippet.name,
            keyword: snippet.normalizedKeyword,
            content: snippet.content
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

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encodedPayload = components.queryItems?.first(where: { $0.name == payloadQueryItem })?.value
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
            content: payload.content
        )
    }

    private static func normalizedSharedKeyword(_ rawKeyword: String) -> String {
        var keyword = rawKeyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.hasPrefix("\\") {
            keyword.removeFirst()
        }
        return keyword
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
