import Foundation

/// Coalesces repeated presentations of the same suggestion input. Browser AX value
/// and selection notifications still validate the host text, but do not need to run
/// fuzzy matching and AppKit layout again after the optimistic key-down update.
///
/// Keep both library projections, including bodies and secure membership: a remote
/// edit or a secure transition must invalidate the selected Snippet even when its
/// visible name and keyword did not change. The ranking snapshot is fixed for one
/// session; reset this updater whenever that snapshot or the panel session changes.
@MainActor
final class SuggestionResultsUpdater {
    private struct Input: Equatable {
        let query: String
        let ordinary: [Snippet]
        let secure: [Snippet]
        let localeIdentifier: String
    }

    private var lastInput: Input?

    func reset() {
        lastInput = nil
    }

    func updateIfNeeded(
        query: String,
        ordinary: [Snippet],
        secure: [Snippet],
        localeIdentifier: String = Locale.current.identifier,
        update: () -> Void
    ) {
        let input = Input(query: query, ordinary: ordinary, secure: secure,
                          localeIdentifier: localeIdentifier)
        guard input != lastInput else { return }
        lastInput = input
        update()
    }
}
