import UIKit
import UniformTypeIdentifiers

@MainActor
protocol SnippetListViewControllerDelegate: AnyObject {
    func snippetList(_ controller: SnippetListViewController, selected id: UUID)
    func snippetListRequestedNewSnippet(_ controller: SnippetListViewController)
    func snippetListRequestedClipboardSnippet(_ controller: SnippetListViewController)
    func snippetListRequestedImport(_ controller: SnippetListViewController)
    func snippetListRequestedExport(_ controller: SnippetListViewController)
    func snippetListRequestedSettings(_ controller: SnippetListViewController)
    func snippetListRequestedShortcuts(_ controller: SnippetListViewController)
    func snippetList(_ controller: SnippetListViewController, requestedDelete id: UUID)
    func snippetList(_ controller: SnippetListViewController, requestedDuplicate id: UUID)
}

@MainActor
protocol SnippetEditorViewControllerDelegate: AnyObject {
    func snippetEditorRequestedDelete(_ controller: SnippetEditorViewController, id: UUID)
    func snippetEditorRequestedDuplicate(_ controller: SnippetEditorViewController, id: UUID)
    func snippetEditorRequestedSettings(_ controller: SnippetEditorViewController)
    func snippetEditorRequestedShortcuts(_ controller: SnippetEditorViewController)
}

final class MainSplitViewController: UISplitViewController {
    private enum DocumentPickerPurpose {
        case importing
        case exporting
    }

    let environment: AppEnvironment

    private let listController: SnippetListViewController
    private let editorController: SnippetEditorViewController
    private let listNavigationController: UINavigationController
    private let editorNavigationController: UINavigationController
    private var selectedSnippetID: UUID?
    private var documentPickerPurpose: DocumentPickerPurpose?

    init(environment: AppEnvironment) {
        self.environment = environment
        listController = SnippetListViewController(environment: environment)
        editorController = SnippetEditorViewController(environment: environment)
        listNavigationController = UINavigationController(rootViewController: listController)
        editorNavigationController = UINavigationController(rootViewController: editorController)
        super.init(style: .doubleColumn)

        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        minimumPrimaryColumnWidth = 260
        maximumPrimaryColumnWidth = 520
        preferredPrimaryColumnWidthFraction = 0.32
        presentsWithGesture = true

        listController.delegate = self
        editorController.delegate = self
        setViewController(listNavigationController, for: .primary)
        setViewController(editorNavigationController, for: .secondary)

        environment.store.onChange = { [weak self] source in
            guard let self else { return }
            self.libraryChanged(source: source)
        }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if selectedSnippetID == nil {
            selectInitialSnippetIfNeeded()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "New Snippet", action: #selector(newSnippetCommand), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "New from Clipboard", action: #selector(newClipboardCommand), input: "n", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Import", action: #selector(importCommand), input: "i", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Export", action: #selector(exportCommand), input: "e", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Keyboard Shortcuts", action: #selector(shortcutsCommand), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Undo", action: #selector(undoCommand), input: "z", modifierFlags: .command),
            UIKeyCommand(title: "Redo", action: #selector(redoCommand), input: "z", modifierFlags: [.command, .shift]),
        ]
    }

    func open(_ url: URL) {
        guard SnippetDeepLink.canHandle(url) else { return }
        do {
            let incoming = try SnippetDeepLink.snippet(from: url)
            let result: Snippet
            if SnippetDeepLink.isCreationLink(url) {
                result = environment.store.addSnippet(
                    name: incoming.name,
                    content: incoming.content,
                    tags: incoming.tags
                )
                var updated = result
                updated.keyword = incoming.keyword
                environment.store.update(updated)
            } else {
                result = try environment.store.importSharedSnippet(incoming)
            }
            select(id: result.id, revealEditor: true)
        } catch {
            showError(title: "Couldn’t Open Link", error: error)
        }
    }

    private func libraryChanged(source: SnippetStore.ChangeSource) {
        listController.reload(keepingSelection: true)
        if let selectedSnippetID,
           environment.store.snippetForDisplay(id: selectedSnippetID) != nil {
            editorController.bind(to: selectedSnippetID, preserveFirstResponder: source == .local)
        } else {
            selectInitialSnippetIfNeeded()
        }
    }

    private func selectInitialSnippetIfNeeded() {
        guard let first = listController.firstVisibleSnippetID else {
            selectedSnippetID = nil
            editorController.bind(to: nil)
            return
        }
        select(id: first, revealEditor: true)
    }

    private func select(id: UUID, revealEditor: Bool) {
        selectedSnippetID = id
        listController.select(id: id)
        editorController.bind(to: id)
        if revealEditor || isCollapsed {
            show(.secondary)
        }
    }

    private func createSnippet(content: String = "") {
        if content.isEmpty, let draft = environment.store.blankDraftSnippet {
            select(id: draft.id, revealEditor: true)
            editorController.focusBody()
            return
        }
        let snippet = environment.store.addSnippet(content: content)
        select(id: snippet.id, revealEditor: true)
        editorController.focusBody()
    }

    private func createFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMessage(title: "Clipboard Is Empty", message: "Copy some text, then try again.")
            return
        }
        createSnippet(content: text)
    }

    private func delete(id: UUID) {
        guard let snippet = environment.store.snippetForDisplay(id: id) else { return }
        let alert = UIAlertController(
            title: "Delete “\(snippet.displayName)” ?",
            message: environment.store.isSecure(id)
                ? "This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices."
                : "You can undo deletion of an ordinary snippet until the app closes.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                if self.environment.store.isSecure(id) {
                    try self.environment.performLocalSecureChange {
                        try self.environment.secureStore.delete(id: id)
                    }
                } else {
                    self.environment.store.delete(snippetID: id)
                }
                self.selectedSnippetID = nil
                self.selectInitialSnippetIfNeeded()
            } catch {
                self.showError(title: "Couldn’t Delete Snippet", error: error)
            }
        })
        present(alert, animated: true)
    }

    private func duplicate(id: UUID) {
        guard !environment.store.isSecure(id) else {
            showMessage(title: "Secure Snippet", message: "Secure snippets cannot be duplicated because that would create another plaintext disclosure path.")
            return
        }
        guard let copy = environment.store.duplicate(snippetID: id) else { return }
        select(id: copy.id, revealEditor: true)
    }

    private func showImporter() {
        editorController.prepareForModalPresentation()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .data], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        documentPickerPurpose = .importing
        present(picker, animated: true)
    }

    private func showExporter() {
        editorController.prepareForModalPresentation()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snippets-Export.json", isDirectory: false)
        do {
            let count = try environment.store.exportSnippets(to: url)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            documentPickerPurpose = .exporting
            present(picker, animated: true)
            listController.showStatus("Exporting \(count) ordinary snippet\(count == 1 ? "" : "s")…")
        } catch {
            showError(title: "Couldn’t Export Snippets", error: error)
        }
    }

    private func importDocument(at url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        let finish = { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let runImport: (Bool) -> Void = { [weak self] preserveExclamation in
            guard let self else { finish(); return }
            defer { finish() }
            do {
                let count = try self.environment.store.importSnippets(
                    from: url,
                    options: .init(preserveExclamationPrefix: preserveExclamation)
                )
                self.listController.showStatus("Imported \(count) snippet\(count == 1 ? "" : "s").")
                self.selectInitialSnippetIfNeeded()
            } catch {
                self.showError(title: "Couldn’t Import Snippets", error: error)
            }
        }

        guard environment.store.detectsRaycastExclamationKeywords(in: url) else {
            runImport(false)
            return
        }

        let alert = UIAlertController(
            title: "Raycast Keywords",
            message: "Some imported keywords begin with !. Keep it as part of each keyword?",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Remove !", style: .default) { _ in runImport(false) })
        alert.addAction(UIAlertAction(title: "Keep !", style: .default) { _ in runImport(true) })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in finish() })
        present(alert, animated: true)
    }

    private func showSettings() {
        editorController.prepareForModalPresentation()
        let settings = SettingsViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showShortcuts() {
        let message = [
            "⌘N  New snippet",
            "⇧⌘N  New from Clipboard",
            "⌘F  Search",
            "⇧⌘I  Import",
            "⇧⌘E  Export",
            "⌘Z / ⇧⌘Z  Undo / Redo",
            "⌘K  This list",
            "⌘Return  Copy selected snippet",
        ].joined(separator: "\n")
        showMessage(title: "Keyboard Shortcuts", message: message)
    }

    func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    func showError(title: String, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        showMessage(title: title, message: message)
    }

    @objc private func newSnippetCommand() { createSnippet() }
    @objc private func newClipboardCommand() { createFromClipboard() }
    @objc private func importCommand() { showImporter() }
    @objc private func exportCommand() { showExporter() }
    @objc private func shortcutsCommand() { showShortcuts() }

    @objc private func undoCommand() {
        guard environment.store.undo() else { return }
        libraryChanged(source: .local)
    }

    @objc private func redoCommand() {
        guard environment.store.redo() else { return }
        libraryChanged(source: .local)
    }
}

extension MainSplitViewController: SnippetListViewControllerDelegate {
    func snippetList(_ controller: SnippetListViewController, selected id: UUID) {
        select(id: id, revealEditor: true)
    }

    func snippetListRequestedNewSnippet(_ controller: SnippetListViewController) { createSnippet() }
    func snippetListRequestedClipboardSnippet(_ controller: SnippetListViewController) { createFromClipboard() }
    func snippetListRequestedImport(_ controller: SnippetListViewController) { showImporter() }
    func snippetListRequestedExport(_ controller: SnippetListViewController) { showExporter() }
    func snippetListRequestedSettings(_ controller: SnippetListViewController) { showSettings() }
    func snippetListRequestedShortcuts(_ controller: SnippetListViewController) { showShortcuts() }
    func snippetList(_ controller: SnippetListViewController, requestedDelete id: UUID) { delete(id: id) }
    func snippetList(_ controller: SnippetListViewController, requestedDuplicate id: UUID) { duplicate(id: id) }
}

extension MainSplitViewController: SnippetEditorViewControllerDelegate {
    func snippetEditorRequestedDelete(_ controller: SnippetEditorViewController, id: UUID) { delete(id: id) }
    func snippetEditorRequestedDuplicate(_ controller: SnippetEditorViewController, id: UUID) { duplicate(id: id) }
    func snippetEditorRequestedSettings(_ controller: SnippetEditorViewController) { showSettings() }
    func snippetEditorRequestedShortcuts(_ controller: SnippetEditorViewController) { showShortcuts() }
}

extension MainSplitViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let purpose = documentPickerPurpose
        documentPickerPurpose = nil
        guard purpose == .importing, let url = urls.first else { return }
        importDocument(at: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        documentPickerPurpose = nil
    }
}
