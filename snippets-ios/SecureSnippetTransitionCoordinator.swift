import Foundation

/// Keeps the in-memory ordinary library and the vault projection aligned with the
/// two-file `LibraryTransaction`. iOS intentionally has no external-filesystem
/// observer, so every move must flush before the transaction and reload both stores
/// before returning to UI code.
@MainActor
enum SecureSnippetTransitionCoordinator {
    static func promote(
        snippetID: UUID,
        store: SnippetStore,
        secureStore: SecureSnippetStore
    ) throws {
        store.flushPendingWrites()
        // The transaction adopts the vault half first. Defer its callback until the
        // ordinary cache has also re-read the same transaction result, otherwise the UI
        // can observe a duplicate record (promotion) or no record at all (demotion).
        try secureStore.promote(snippetID: snippetID, notifyChange: false)
        reload(store: store, secureStore: secureStore)
    }

    static func demote(
        recordID: UUID,
        store: SnippetStore,
        secureStore: SecureSnippetStore
    ) throws {
        store.flushPendingWrites()
        try secureStore.demote(recordID: recordID, notifyChange: false)
        reload(store: store, secureStore: secureStore)
    }

    private static func reload(store: SnippetStore, secureStore: SecureSnippetStore) {
        // Both reads are silent. `coordinatedMoveDidFinish` then enters AppEnvironment's
        // normal secure-change path once, refreshing the merged UI and requesting sync
        // only after neither cache can expose an intermediate ownership state.
        store.reloadAfterExternalWrite(notifyChange: false)
        secureStore.reload(notifyChange: false)
        secureStore.coordinatedMoveDidFinish()
    }
}
