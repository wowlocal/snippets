import UIKit
import UniformTypeIdentifiers

@MainActor
protocol SnippetPasteboard: AnyObject {
    var string: String? { get }
    func writeOrdinaryText(_ text: String)
    func writeSecureText(_ text: String, expiresAt: Date)
}

@MainActor
final class SystemSnippetPasteboard: SnippetPasteboard {
    var string: String? { UIPasteboard.general.string }

    func writeOrdinaryText(_ text: String) {
        UIPasteboard.general.string = text
    }

    func writeSecureText(_ text: String, expiresAt: Date) {
        UIPasteboard.general.setItems(
            [[UTType.utf8PlainText.identifier: text]],
            options: [
                .localOnly: true,
                .expirationDate: expiresAt,
            ]
        )
    }
}

@MainActor
final class SnippetActionService {
    typealias SecureContentLoader = (_ id: UUID, _ reason: String) async throws -> SecurePlaintextLease

    enum CopyResult: Equatable {
        case copied(name: String, secure: Bool)
        case empty(name: String)
    }

    enum Failure: LocalizedError {
        case missingSnippet
        case invalidSecureContent

        var errorDescription: String? {
            switch self {
            case .missingSnippet:
                "The snippet no longer exists."
            case .invalidSecureContent:
                "The secure snippet does not contain valid text."
            }
        }
    }

    static let secureClipboardLifetime: TimeInterval = 60

    private let store: SnippetStore
    private let vaultSession: VaultSession
    private let secureStore: SecureSnippetStore
    private let pasteboard: any SnippetPasteboard
    private let now: () -> Date
    private let secureContentLoader: SecureContentLoader?

    init(
        store: SnippetStore,
        vaultSession: VaultSession,
        secureStore: SecureSnippetStore,
        pasteboard: (any SnippetPasteboard)? = nil,
        now: @escaping () -> Date = Date.init,
        secureContentLoader: SecureContentLoader? = nil
    ) {
        self.store = store
        self.vaultSession = vaultSession
        self.secureStore = secureStore
        self.pasteboard = pasteboard ?? SystemSnippetPasteboard()
        self.now = now
        self.secureContentLoader = secureContentLoader
    }

    func copy(id: UUID) async throws -> CopyResult {
        guard let snippet = store.snippetForDisplay(id: id) else {
            throw Failure.missingSnippet
        }
        if store.isSecure(id) {
            return try await copySecure(snippet)
        }
        return copyOrdinary(snippet)
    }

    func copyOrdinary(_ snippet: Snippet) -> CopyResult {
        let text = PlaceholderResolver.resolve(
            template: snippet.content,
            clipboard: { [pasteboard] in pasteboard.string }
        )
        guard !text.isEmpty else { return .empty(name: snippet.displayName) }
        pasteboard.writeOrdinaryText(text)
        return .copied(name: snippet.displayName, secure: false)
    }

    private func copySecure(_ snippet: Snippet) async throws -> CopyResult {
        let reason = "Copy \(snippet.displayName)"
        let lease: SecurePlaintextLease
        if let secureContentLoader {
            lease = try await secureContentLoader(snippet.id, reason)
        } else {
            lease = try await vaultSession.withOneUseAuthentication(reason: reason) {
                var plaintext = try secureStore.contentData(for: snippet.id)
                return SecurePlaintextLease(consuming: &plaintext)
            }
        }
        defer { lease.wipe() }

        guard var template = lease.makeUTF8String() else {
            throw Failure.invalidSecureContent
        }
        defer { template.removeAll(keepingCapacity: false) }

        var resolved = PlaceholderResolver.resolve(
            template: template,
            clipboard: { [pasteboard] in pasteboard.string }
        )
        defer { resolved.removeAll(keepingCapacity: false) }
        guard !resolved.isEmpty else { return .empty(name: snippet.displayName) }

        pasteboard.writeSecureText(
            resolved,
            expiresAt: now().addingTimeInterval(Self.secureClipboardLifetime)
        )
        return .copied(name: snippet.displayName, secure: true)
    }
}
