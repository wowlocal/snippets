import UIKit

/// Reviews all externally supplied snippet links before they can mutate the library.
///
/// A `snippets://share` URL contains plaintext controlled by whoever supplied the URL.
/// Importing it directly is especially dangerous because the store deliberately merges
/// shared snippets by keyword: a link could replace a trusted expansion and enable its
/// replacement without the user ever seeing the incoming text. This coordinator is the
/// single UIKit entry point for both phone and pad, and keeps the decoded snippet staged
/// until the user explicitly accepts the preview.
@MainActor
final class IncomingSnippetLinkCoordinator {
    enum ReviewError: LocalizedError, Equatable {
        case libraryChanged

        var errorDescription: String? {
            switch self {
            case .libraryChanged:
                return "Your library changed while this link was open. Review the link again before importing it."
            }
        }
    }

    enum AcceptedAction: Equatable {
        case created(UUID)
        case imported(UUID)

        var snippetID: UUID {
            switch self {
            case .created(let id), .imported(let id): id
            }
        }
    }

    /// Internal so the unit tests can prove that decoding is side-effect free and that
    /// the only mutation path installs an inactive trigger. It is not exposed outside
    /// the app module.
    struct Review {
        let incoming: Snippet
        let isCreation: Bool
        let replacedSnippet: Snippet?

        var title: String {
            if isCreation { return "Create Snippet From Link?" }
            return replacedSnippet == nil ? "Import Shared Snippet?" : "Replace Existing Snippet?"
        }

        var acceptTitle: String {
            if isCreation { return "Create Disabled" }
            if let replacedSnippet { return "Replace \(replacedSnippet.displayName)" }
            return "Import Disabled"
        }
    }

    private let store: SnippetStore

    init(store: SnippetStore) {
        self.store = store
    }

    /// Decodes and presents a review. Any currently presented transient UI is dismissed
    /// first so a link delivered while a picker or menu is open cannot leave its alert
    /// behind an unrelated modal.
    func open(
        _ url: URL,
        from presenter: UIViewController,
        accepted: @escaping (AcceptedAction) -> Void,
        failed: @escaping (Error) -> Void
    ) {
        let review: Review
        do {
            review = try makeReview(for: url)
        } catch {
            failed(error)
            return
        }

        let presentReview = { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            let alert = self.alert(for: review, accepted: accepted, failed: failed)
            presenter.present(alert, animated: true)
        }

        presenter.view.endEditing(true)
        if presenter.presentedViewController != nil {
            presenter.dismiss(animated: false, completion: presentReview)
        } else {
            presentReview()
        }
    }

    func makeReview(for url: URL) throws -> Review {
        guard SnippetDeepLink.canHandle(url) else {
            throw SnippetDeepLinkError.unsupportedURL
        }
        let incoming = try SnippetDeepLink.snippet(from: url)
        let isCreation = SnippetDeepLink.isCreationLink(url)
        return Review(
            incoming: incoming,
            isCreation: isCreation,
            replacedSnippet: isCreation ? nil : existingSnippetReplaced(by: incoming)
        )
    }

    private func alert(
        for review: Review,
        accepted: @escaping (AcceptedAction) -> Void,
        failed: @escaping (Error) -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: review.title,
            message: message(for: review),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(
            title: review.acceptTitle,
            style: review.replacedSnippet == nil ? .default : .destructive
        ) { [weak self] _ in
            guard let self else { return }
            do {
                accepted(try self.apply(review))
            } catch {
                failed(error)
            }
        })
        return alert
    }

    func apply(_ review: Review) throws -> AcceptedAction {
        if review.isCreation {
            // Creation links never merge by ID or keyword: `addSnippet` creates a
            // fresh identity. Library changes while their alert is open therefore
            // cannot change the impact the user approved.
            // `addSnippet` has no keyword parameter. Creating it with no keyword first
            // means there is no instant in which an untrusted URL is an active trigger;
            // the follow-up update installs both the keyword and disabled flag together.
            var created = store.addSnippet(
                name: review.incoming.name,
                content: review.incoming.content,
                tags: review.incoming.tags
            )
            created.keyword = review.incoming.normalizedKeyword
            created.isEnabled = false
            store.update(created)
            store.flushPendingWrites()
            return .created(created.id)
        }

        // A share import merges by ID first and normalized keyword second. Recompute
        // that exact target immediately before mutation and require the full reviewed
        // record snapshot to match. This catches both a target appearing after a
        // non-replacement review and any edit/replacement/removal of the record whose
        // destructive impact the user approved. There is no suspension point between
        // this side-effect-free validation and `importSharedSnippet` on MainActor.
        guard existingSnippetReplaced(by: review.incoming) == review.replacedSnippet else {
            throw ReviewError.libraryChanged
        }

        var staged = review.incoming
        staged.isEnabled = false
        let imported = try store.importSharedSnippet(staged)
        return .imported(imported.id)
    }

    private func existingSnippetReplaced(by incoming: Snippet) -> Snippet? {
        if let sameID = store.snippets.first(where: { $0.id == incoming.id }) {
            return sameID
        }

        let keyword = incoming.normalizedKeyword
        guard !keyword.isEmpty else { return nil }
        let key = SnippetTagging.filterKey(for: keyword)
        return store.snippets.first {
            !$0.normalizedKeyword.isEmpty
                && SnippetTagging.filterKey(for: $0.normalizedKeyword) == key
        }
    }

    private func message(for review: Review) -> String {
        var paragraphs: [String] = []
        if let replaced = review.replacedSnippet {
            paragraphs.append(
                "This will permanently replace “\(replaced.displayName)”. Review the incoming content before continuing."
            )
        }
        paragraphs.append(summary(of: review.incoming))
        paragraphs.append(
            review.isCreation
                ? "The snippet will be created disabled. Review it in the editor before enabling expansion."
                : "The imported snippet will stay disabled until you review and enable it."
        )
        return paragraphs.joined(separator: "\n\n")
    }

    private func summary(of snippet: Snippet) -> String {
        let keyword = snippet.normalizedKeyword.isEmpty
            ? "No keyword"
            : "\\\(snippet.normalizedKeyword)"
        let tags = snippet.tags.isEmpty ? "None" : snippet.tags.joined(separator: ", ")
        let trimmed = snippet.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = trimmed.isEmpty ? "(empty content)" : truncatedPreview(trimmed)
        return "Name: \(snippet.displayName)\nKeyword: \(keyword)\nTags: \(tags)\n\nPreview:\n\(preview)"
    }

    private func truncatedPreview(_ content: String) -> String {
        let limit = 280
        guard content.count > limit else { return content }
        let end = content.index(content.startIndex, offsetBy: limit)
        return String(content[..<end]) + "…"
    }
}
