import AppKit

// The AppKit half of `Core/PlaceholderResolver.swift`, and the only file that names a
// pasteboard. The resolver takes the clipboard as a closure so that it can be built and
// tested with no AppKit; this is where the shipping app says what that closure is. It
// stays in the app target on purpose — moved into `Core/`, the module would import
// AppKit again and the split would have bought nothing.
extension PlaceholderResolver {
    /// Read at resolve time rather than captured earlier: an expansion must see the
    /// clipboard as it stands at the instant it fires, not as it stood when some
    /// controller was built. `SnippetExpansionEngine` relies on this — it hands the
    /// pasteboard back to the user (`finishPendingPasteboardOwnership`) immediately
    /// before resolving, so that `{clipboard}` cannot read a snippet we are still
    /// holding.
    static func systemClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    static func resolve(template: String) -> String {
        resolve(template: template, clipboard: systemClipboard)
    }

    static func resolveForPreview(template: String) -> String {
        resolveForPreview(template: template, clipboard: systemClipboard)
    }
}
