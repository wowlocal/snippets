import Foundation

/// The narrow view `SnippetStore` is allowed to have of the vault.
///
/// A protocol rather than a direct reference so the dependency points one way: the
/// plaintext store knows only that *some* records exist elsewhere and what their
/// metadata is. It cannot reach a key, a ciphertext, or a plaintext through this, which
/// is what keeps `SnippetStore` — the type that owns export, the undo stack, and the
/// write path — structurally unable to leak a secret.
@MainActor
protocol SecureSnippetProviding: AnyObject {
    /// Content-free shells: real ids, names, keywords and tags, with `content == ""`.
    func secureShellsForDisplay() -> [Snippet]
    func isSecure(_ id: UUID) -> Bool
}
