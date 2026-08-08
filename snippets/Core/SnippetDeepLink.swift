import Foundation

// Compiled into the app and the test package — see `Snippet.swift`. Lives in `Core/`
// because it is one of the few paths by which snippet content leaves the machine, so it
// needs to be reachable by `swift test`.

nonisolated enum SnippetDeepLinkError: LocalizedError {
    case unsupportedURL
    case missingPayload
    case invalidPayload
    case unsupportedVersion
    case cannotEncodePayload
    case secureSnippetNotShareable

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
        case .secureSnippetNotShareable:
            return "Secure snippets cannot be shared. A share link carries the snippet's text in plain sight."
        }
    }
}

nonisolated enum SnippetDeepLink {
    static let scheme = "snippets"

    private static let host = "share"
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

        return scheme == self.scheme && host == self.host
    }

    /// Builds a share link.
    ///
    /// - Parameter isSecure: whether this snippet lives in the vault. **Required, with
    ///   no default.** A share link is a plaintext payload in a URL that ends up on the
    ///   pasteboard, in a chat window, and in shell history — the single worst place a
    ///   secret could go. Making the caller state this turns "someone forgot the check"
    ///   into a compile error. Belt and braces: a secure snippet reaching here carries
    ///   `content == ""` anyway, because the vault only ever hands out shells.
    static func url(for snippet: Snippet, isSecure: Bool) throws -> URL {
        guard !isSecure else { throw SnippetDeepLinkError.secureSnippetNotShareable }
        return try unsafeURL(for: snippet)
    }

    private static func unsafeURL(for snippet: Snippet) throws -> URL {
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
            content: payload.content,
            tags: SnippetTagging.normalizedTags(payload.tags ?? [])
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
