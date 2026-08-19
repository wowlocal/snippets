import UIKit
import UniformTypeIdentifiers

private extension UTType {
    static let snippetsEncryptedBackup = UTType(
        exportedAs: EncryptedSnippetBackup.formatIdentifier,
        conformingTo: .data)
}

@MainActor
protocol SnippetListViewControllerDelegate: AnyObject {
    func snippetList(_ controller: SnippetListViewController, selected id: UUID)
    func snippetListRequestedNewSnippet(_ controller: SnippetListViewController)
    func snippetListRequestedClipboardSnippet(_ controller: SnippetListViewController)
    func snippetListRequestedImport(_ controller: SnippetListViewController)
    func snippetListRequestedExport(_ controller: SnippetListViewController)
    func snippetListRequestedEncryptedBackup(_ controller: SnippetListViewController)
    func snippetListRequestedSettings(_ controller: SnippetListViewController)
    func snippetListRequestedShortcuts(_ controller: SnippetListViewController)
    func snippetList(_ controller: SnippetListViewController, requestedCopy id: UUID)
    func snippetList(_ controller: SnippetListViewController, requestedDelete id: UUID)
    func snippetList(_ controller: SnippetListViewController, requestedDuplicate id: UUID)
    func snippetList(_ controller: SnippetListViewController, requestedToggleSecurity id: UUID)
}

@MainActor
protocol SnippetEditorViewControllerDelegate: AnyObject {
    func snippetEditorRequestedCopy(_ controller: SnippetEditorViewController, id: UUID)
    func snippetEditorRequestedDelete(_ controller: SnippetEditorViewController, id: UUID)
    func snippetEditorRequestedDuplicate(_ controller: SnippetEditorViewController, id: UUID)
}

final class MainSplitViewController: UISplitViewController {
    private enum DocumentPickerPurpose {
        case importing
        case exporting
    }

    private enum KeyboardFocusContext {
        case modal
        case shortcutPanel
        case search
        case editor
        case list
        case none
    }

    private enum KeyboardCommandScope {
        case global
        case list
        case focusTraversal
        case escape
    }

    let environment: AppEnvironment
    private let incomingLinkCoordinator: IncomingSnippetLinkCoordinator

    private let listController: SnippetListViewController
    private let editorController: SnippetEditorViewController
    private let listNavigationController: UINavigationController
    private let editorNavigationController: UINavigationController
    private let shortcutPanel = ShortcutPanelView()
    private let toastPresenter = AppToastPresenter()
    private weak var shortcutPanelPreviousFirstResponder: UIView?
    private var selectedSnippetID: UUID?
    private var documentPickerPurpose: DocumentPickerPurpose?
    private var exportedTemporaryURL: URL?
    private var editorListReloadWorkItem: DispatchWorkItem?
    private let editorListReloadDelay: TimeInterval = 0.12

    init(environment: AppEnvironment) {
        self.environment = environment
        incomingLinkCoordinator = IncomingSnippetLinkCoordinator(store: environment.store)
        listController = SnippetListViewController(environment: environment)
        editorController = SnippetEditorViewController(environment: environment)
        listNavigationController = UINavigationController(rootViewController: listController)
        editorNavigationController = UINavigationController(rootViewController: editorController)
        super.init(style: .doubleColumn)

        preferredDisplayMode = .oneBesideSecondary
        preferredSplitBehavior = .tile
        primaryBackgroundStyle = .sidebar
        minimumPrimaryColumnWidth = 280
        maximumPrimaryColumnWidth = 500
        preferredPrimaryColumnWidthFraction = 0.28
        presentsWithGesture = true

        AppTheme.configureNavigationBar(listNavigationController.navigationBar)
        AppTheme.configureNavigationBar(editorNavigationController.navigationBar)
        listNavigationController.view.backgroundColor = .secondarySystemBackground
        editorNavigationController.view.backgroundColor = .systemBackground

        listController.delegate = self
        editorController.delegate = self
        listController.onFocusEntered = { [weak self] in
            self?.discardBlankDraftAfterLeaving(self?.selectedSnippetID)
        }
        setViewController(listNavigationController, for: .primary)
        setViewController(editorNavigationController, for: .secondary)

        environment.store.onChange = { [weak self] change in
            guard let self else { return }
            self.libraryChanged(change)
        }

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureShortcutPanel()
        toastPresenter.install(in: view)
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
        var commands = [
            Self.copySnippetKeyCommand(),
            Self.searchKeyCommand(),
            Self.toggleSidebarKeyCommand(),
            Self.editSnippetKeyCommand(),
            Self.deleteSnippetKeyCommand(),
            Self.nextFieldKeyCommand(),
            Self.previousFieldKeyCommand(),
            Self.nextSnippetKeyCommand(),
            Self.previousSnippetKeyCommand(),
            Self.nextSnippetArrowKeyCommand(),
            Self.previousSnippetArrowKeyCommand(),
            UIKeyCommand(title: "New Snippet", action: #selector(newSnippetCommand), input: "n", modifierFlags: .command),
            UIKeyCommand(title: "New from Clipboard", action: #selector(newClipboardCommand), input: "n", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Import", action: #selector(importCommand), input: "i", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Export for Sharing", action: #selector(exportCommand), input: "e", modifierFlags: [.command, .shift]),
            Self.shortcutsKeyCommand(),
            Self.undoKeyCommand(),
            Self.redoKeyCommand(),
        ]
        commands.append(Self.escapeKeyCommand())
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard let scope = keyboardCommandScope(for: action) else {
            return super.canPerformAction(action, withSender: sender)
        }

        let context = keyboardFocusContext
        if context == .modal { return false }
        if context == .shortcutPanel {
            return action == #selector(escapeCommand)
                || action == #selector(shortcutsCommand)
        }

        switch scope {
        case .global:
            return true
        case .list:
            guard context == .list else { return false }
            if isSnippetNavigationAction(action) {
                return listController.firstVisibleSnippetID != nil
            }
            if action == #selector(copySnippetCommand(_:))
                || action == #selector(editSnippetCommand)
                || action == #selector(deleteSnippetCommand) {
                return selectedSnippetID != nil
            }
            return true
        case .focusTraversal:
            return context == .editor || context == .list
        case .escape:
            return context == .search || context == .editor
        }
    }

    private var keyboardFocusContext: KeyboardFocusContext {
        if presentedViewController != nil { return .modal }
        if shortcutPanel.isPresented { return .shortcutPanel }
        if listController.isSearchFocused { return .search }
        if editorController.isEditorFocused { return .editor }
        if listController.isListFocused { return .list }
        return .none
    }

    private func keyboardCommandScope(for action: Selector) -> KeyboardCommandScope? {
        if action == #selector(copySnippetCommand(_:))
            || action == #selector(editSnippetCommand)
            || action == #selector(deleteSnippetCommand)
            || action == #selector(nextSnippetCommand)
            || action == #selector(previousSnippetCommand)
            || action == #selector(nextSnippetFromListCommand)
            || action == #selector(previousSnippetFromListCommand)
            || action == #selector(undoCommand)
            || action == #selector(redoCommand) {
            return .list
        }
        if action == #selector(nextFieldCommand)
            || action == #selector(previousFieldCommand) {
            return .focusTraversal
        }
        if action == #selector(escapeCommand) { return .escape }
        if action == #selector(newSnippetCommand)
            || action == #selector(newClipboardCommand)
            || action == #selector(importCommand)
            || action == #selector(exportCommand)
            || action == #selector(searchCommand)
            || action == #selector(toggleSidebarCommand)
            || action == #selector(shortcutsCommand) {
            return .global
        }
        return nil
    }

    private func isSnippetNavigationAction(_ action: Selector) -> Bool {
        action == #selector(nextSnippetCommand)
            || action == #selector(previousSnippetCommand)
            || action == #selector(nextSnippetFromListCommand)
            || action == #selector(previousSnippetFromListCommand)
    }

    static func copySnippetKeyCommand() -> UIKeyCommand {
        let command = UIKeyCommand(
            title: "Copy Snippet",
            action: #selector(copySnippetCommand(_:)),
            input: "\r",
            modifierFlags: []
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    static func searchKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Search",
            action: #selector(searchCommand),
            input: "f",
            modifierFlags: .command
        )
    }

    static func toggleSidebarKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Toggle Sidebar",
            action: #selector(toggleSidebarCommand),
            input: "b",
            modifierFlags: .command
        )
    }

    static func editSnippetKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Edit Snippet",
            action: #selector(editSnippetCommand),
            input: "e",
            modifierFlags: .command
        )
    }

    static func deleteSnippetKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Delete Snippet",
            action: #selector(deleteSnippetCommand),
            input: UIKeyCommand.inputDelete,
            modifierFlags: .command
        )
    }

    static func nextFieldKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Next Field",
            action: #selector(nextFieldCommand),
            input: "\t"
        )
    }

    static func previousFieldKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Previous Field",
            action: #selector(previousFieldCommand),
            input: "\t",
            modifierFlags: .shift
        )
    }

    static func shortcutsKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Toggle Shortcuts",
            action: #selector(shortcutsCommand),
            input: "k",
            modifierFlags: .command
        )
    }

    static func undoKeyCommand() -> UIKeyCommand {
        UIKeyCommand(
            title: "Undo Snippet Change",
            action: #selector(undoCommand),
            input: "z",
            modifierFlags: .command
        )
    }

    static func redoKeyCommand() -> UIKeyCommand {
        UIKeyCommand(
            title: "Redo Snippet Change",
            action: #selector(redoCommand),
            input: "z",
            modifierFlags: [.command, .shift]
        )
    }

    static func nextSnippetKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Next Snippet",
            action: #selector(nextSnippetCommand),
            input: "n",
            modifierFlags: .control
        )
    }

    static func previousSnippetKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Previous Snippet",
            action: #selector(previousSnippetCommand),
            input: "p",
            modifierFlags: .control
        )
    }

    static func nextSnippetArrowKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Next Snippet",
            action: #selector(nextSnippetFromListCommand),
            input: UIKeyCommand.inputDownArrow
        )
    }

    static func previousSnippetArrowKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Previous Snippet",
            action: #selector(previousSnippetFromListCommand),
            input: UIKeyCommand.inputUpArrow
        )
    }

    static func escapeKeyCommand() -> UIKeyCommand {
        priorityKeyCommand(
            title: "Return to Snippet List",
            action: #selector(escapeCommand),
            input: UIKeyCommand.inputEscape
        )
    }

    private static func priorityKeyCommand(
        title: String,
        action: Selector,
        input: String,
        modifierFlags: UIKeyModifierFlags = []
    ) -> UIKeyCommand {
        let command = UIKeyCommand(
            title: title,
            action: action,
            input: input,
            modifierFlags: modifierFlags
        )
        command.wantsPriorityOverSystemBehavior = true
        return command
    }

    var isSidebarVisible: Bool { displayMode != .secondaryOnly }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        updateShortcutPanelModifierState(event)
        super.pressesBegan(presses, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        updateShortcutPanelModifierState(event)
        super.pressesChanged(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesEnded(presses, with: event)
        updateShortcutPanelModifierState(event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        super.pressesCancelled(presses, with: event)
        if shortcutPanel.isPresented {
            shortcutPanel.setShowsAllShortcuts(false, animated: true)
        }
    }

    func open(_ url: URL) {
        incomingLinkCoordinator.open(
            url,
            from: self,
            accepted: { [weak self] action in
                self?.select(id: action.snippetID, revealEditor: true)
            },
            failed: { [weak self] error in
                self?.showError(title: "Couldn’t Open Link", error: error)
            }
        )
    }

    private func libraryChanged(_ change: SnippetStore.Change) {
        let source = change.source
        if source == .local, environment.isPerformingLocalEditorChange {
            scheduleEditorListReload()
            return
        }

        editorListReloadWorkItem?.cancel()
        editorListReloadWorkItem = nil
        listController.reload(keepingSelection: true)
        if let selectedSnippetID,
           environment.store.snippetForDisplay(id: selectedSnippetID) != nil {
            guard change.affects(selectedSnippetID) else { return }
            editorController.bind(
                to: selectedSnippetID,
                preserveFirstResponder: source == .local,
                diagnosticReason: .storeRefresh(source))
        } else {
            selectInitialSnippetIfNeeded()
        }
    }

    private func scheduleEditorListReload() {
        editorListReloadWorkItem?.cancel()
        listController.prepareForDeferredEditorReload()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.editorListReloadWorkItem = nil
            // The editor already refreshed its derived presentation from the exact
            // mutation that scheduled this work. Only the visible list needs the
            // coalesced update.
            self.listController.reloadAfterEditorChanges()
        }
        editorListReloadWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + editorListReloadDelay,
            execute: workItem
        )
    }

    private func selectInitialSnippetIfNeeded() {
        guard let first = listController.firstVisibleSnippetID else {
            selectedSnippetID = nil
            editorController.bind(to: nil)
            return
        }
        select(id: first, revealEditor: true)
    }

    private func select(id: UUID, revealEditor: Bool, ensureListVisible: Bool = false) {
        let outgoingSnippetID = selectedSnippetID
        if outgoingSnippetID != id {
            editorController.prepareForSelectionChange()
        }
        selectedSnippetID = id
        listController.select(id: id, ensureVisible: ensureListVisible)
        editorController.bind(to: id)
        if outgoingSnippetID != id {
            discardBlankDraftAfterLeaving(outgoingSnippetID)
        }
        if revealEditor || isCollapsed {
            show(.secondary)
        }
    }

    /// Mirrors the Mac editor's draft lifecycle: leaving a still-empty new row
    /// removes it on the next run-loop turn, after every UIKit editing-ended
    /// callback has had a chance to publish pending text or a trailing tag.
    private func discardBlankDraftAfterLeaving(_ snippetID: UUID?) {
        guard let snippetID,
              environment.store.blankDraftSnippet?.id == snippetID else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self,
                  environment.store.blankDraftSnippet?.id == snippetID else { return }
            environment.store.discardBlankDraft(id: snippetID)
        }
    }

    private func createSnippet(content: String = "") {
        if content.isEmpty, let draft = environment.store.blankDraftSnippet {
            select(id: draft.id, revealEditor: true)
            editorController.focusBody()
            return
        }
        let snippet: Snippet
        do {
            snippet = try environment.store.addSnippet(content: content)
        } catch {
            showMessage(
                title: "Library Recovery Required",
                message: error.localizedDescription)
            return
        }
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
                    self.environment.syncCoordinator.userDidDeleteSnippets(Set([id]))
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
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, .snippetsEncryptedBackup],
            asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        documentPickerPurpose = .importing
        present(picker, animated: true)
    }

    private func showExporter() {
        editorController.prepareForModalPresentation()
        removeTemporaryExport()
        var temporaryURL: URL?
        do {
            let url = try TemporaryExportFiles.makeURL(filename: "Snippets-Export.json")
            temporaryURL = url
            let count = try environment.store.exportSnippets(to: url)
            try TemporaryExportFiles.protect(url)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            documentPickerPurpose = .exporting
            exportedTemporaryURL = url
            present(picker, animated: true)
            listController.showStatus("Exporting \(count) ordinary snippet\(count == 1 ? "" : "s") for sharing… Secure snippets are not included.")
        } catch {
            if let temporaryURL { TemporaryExportFiles.remove(temporaryURL) }
            showError(title: "Couldn’t Export Snippets", error: error)
        }
    }

    private func showEncryptedBackupExporter() {
        editorController.prepareForModalPresentation()
        guard !environment.store.isLibraryQuarantined else {
            showError(
                title: "Library Recovery Required",
                error: SecureSnippetStore.EncryptedBackupFailure.libraryRecoveryRequired)
            return
        }
        promptForNewBackupPassword { [weak self] passphrase in
            guard let self, let passphrase else { return }
            listController.showStatus("Preparing encrypted backup…")

            Task { @MainActor [weak self] in
                guard let self else { return }
                var temporaryURL: URL?
                do {
                    let backup = try await environment.secureStore.makeEncryptedBackup(
                        store: environment.store,
                        passphrase: passphrase)
                    removeTemporaryExport()
                    let url = try TemporaryExportFiles.makeURL(
                        filename: "Snippets-Backup.snippetsbackup"
                    )
                    temporaryURL = url
                    try AtomicFileWriter.write(
                        backup.data,
                        to: url,
                        temporaryDirectory: url.deletingLastPathComponent(),
                        permissions: 0o600)
                    try TemporaryExportFiles.protect(url)

                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                    picker.delegate = self
                    documentPickerPurpose = .exporting
                    exportedTemporaryURL = url
                    present(picker, animated: true)
                    listController.showStatus(
                        "Encrypted backup contains \(backup.ordinaryCount) ordinary and \(backup.secureCount) secure snippet\(backup.totalCount == 1 ? "" : "s").")
                } catch {
                    if let temporaryURL { TemporaryExportFiles.remove(temporaryURL) }
                    showError(title: "Couldn’t Create Encrypted Backup", error: error)
                }
            }
        }
    }

    private func importDocument(at url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        listController.showStatus("Reading import…")
        Task { @MainActor [weak self] in
            guard let self else {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                return
            }
            do {
                let loaded = try await Task.detached(priority: .userInitiated) {
                    try IncomingDocumentLoader.load(url)
                }.value
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                switch loaded {
                case .encryptedBackup(let data):
                    self.importEncryptedBackup(data)
                case .snippets(let prepared):
                    self.reviewAndImport(prepared)
                }
            } catch {
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                self.showError(title: "Couldn’t Import Snippets", error: error)
            }
        }
    }

    private func reviewAndImport(_ prepared: PreparedSnippetImport) {
        let runImport: (Bool) -> Void = { [weak self] preserveExclamation in
            guard let self else { return }
            let options = SnippetStore.ImportOptions(
                preserveExclamationPrefix: preserveExclamation)
            do {
                if self.environment.store.isLibraryQuarantined {
                    let count = try self.environment.store
                        .quarantinedLibraryRecoveryCandidateCount(prepared, options: options)
                    let alert = UIAlertController(
                        title: "Replace the Quarantined Library?",
                        message: "The selected file contains \(count) ordinary snippet\(count == 1 ? "" : "s"). It will completely replace the unreadable ordinary-snippet library. Use only a complete Snippets JSON export—a partial or Raycast export can omit data. Secure snippets are unchanged, and the unreadable file is preserved. Sync stays paused until you review it and choose Check Again.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(
                        title: "Use Complete Export",
                        style: .destructive
                    ) { [weak self] _ in
                        guard let self else { return }
                        do {
                            let replaced = try self.environment.store
                                .replaceQuarantinedLibrary(with: prepared, options: options)
                            self.listController.showStatus(
                                "Installed \(replaced) snippet\(replaced == 1 ? "" : "s") as the recovery candidate. Review Sync and choose Check Again.")
                            self.selectInitialSnippetIfNeeded()
                        } catch {
                            self.showError(title: "Couldn’t Recover Library", error: error)
                        }
                    })
                    self.present(alert, animated: true)
                } else {
                    let count = try self.environment.store.importSnippets(
                        prepared,
                        options: options)
                    self.listController.showStatus(
                        "Imported \(count) snippet\(count == 1 ? "" : "s").")
                    self.selectInitialSnippetIfNeeded()
                }
            } catch {
                self.showError(title: "Couldn’t Import Snippets", error: error)
            }
        }

        guard prepared.hasRaycastExclamationKeywords else {
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
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func importEncryptedBackup(_ data: Data) {
        promptForBackupPassword { [weak self] passphrase in
            guard let self, let passphrase else { return }
            listController.showStatus("Opening encrypted backup…")

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let prepared = try await environment.secureStore
                        .prepareEncryptedBackupImport(data, passphrase: passphrase)
                    guard environment.store.isLibraryQuarantined else {
                        installEncryptedBackup(prepared, authoritativeRecovery: false)
                        return
                    }

                    let alert = UIAlertController(
                        title: "Restore the Quarantined Library from This Backup?",
                        message: "The authenticated backup contains \(prepared.ordinaryCount) ordinary and \(prepared.secureCount) secure snippet\(prepared.totalCount == 1 ? "" : "s"). Its ordinary library will completely replace the quarantined recovery candidate; compatible secure snippets will be restored in the same transaction. The unreadable original remains preserved, and Sync stays paused until you choose Check Again.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                    alert.addAction(UIAlertAction(
                        title: "Restore Encrypted Backup",
                        style: .destructive
                    ) { [weak self] _ in
                        self?.installEncryptedBackup(
                            prepared, authoritativeRecovery: true)
                    })
                    present(alert, animated: true)
                } catch {
                    showError(title: "Couldn’t Import Encrypted Backup", error: error)
                }
            }
        }
    }

    private func installEncryptedBackup(
        _ prepared: SecureSnippetStore.PreparedEncryptedBackupImport,
        authoritativeRecovery: Bool
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await environment.secureStore.importPreparedEncryptedBackup(
                    prepared,
                    into: environment.store,
                    authoritativeRecovery: authoritativeRecovery)
                listController.showStatus(authoritativeRecovery
                    ? "Installed encrypted recovery with \(result.ordinaryCount) ordinary and \(result.secureCount) secure snippet\(result.totalCount == 1 ? "" : "s"). Review Sync and choose Check Again."
                    : "Imported \(result.ordinaryCount) ordinary and \(result.secureCount) secure snippet\(result.totalCount == 1 ? "" : "s").")
                selectInitialSnippetIfNeeded()
            } catch {
                showError(title: "Couldn’t Import Encrypted Backup", error: error)
            }
        }
    }

    private func promptForNewBackupPassword(completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(
            title: "Protect Encrypted Backup",
            message: "This private backup includes secure snippets. Use a unique password of at least 12 characters and save it in a password manager; Snippets cannot recover it.",
            preferredStyle: .alert)
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Backup password")
            field.textContentType = .newPassword
        }
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Confirm password")
            field.textContentType = .newPassword
        }

        guard let passwordField = alert.textFields?.first,
              let confirmationField = alert.textFields?.last else {
            completion(nil)
            return
        }
        let create = UIAlertAction(title: "Create Backup", style: .default) { _ in
            completion(passwordField.text)
        }
        create.isEnabled = false
        let updateValidation = UIAction { _ in
            let password = passwordField.text ?? ""
            create.isEnabled = password.count >= 12
                && !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && confirmationField.text == password
        }
        passwordField.addAction(updateValidation, for: .editingChanged)
        confirmationField.addAction(updateValidation, for: .editingChanged)

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(create)
        present(alert, animated: true)
    }

    private func promptForBackupPassword(completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(
            title: "Open Encrypted Backup",
            message: "Enter the password used when this backup was created. The file is authenticated before anything is imported.",
            preferredStyle: .alert)
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Backup password")
            field.textContentType = .password
        }

        guard let passwordField = alert.textFields?.first else {
            completion(nil)
            return
        }
        let open = UIAlertAction(title: "Open Backup", style: .default) { _ in
            completion(passwordField.text)
        }
        open.isEnabled = false
        passwordField.addAction(UIAction { _ in
            open.isEnabled = !(passwordField.text ?? "").isEmpty
        }, for: .editingChanged)

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(open)
        present(alert, animated: true)
    }

    private static func configureBackupPasswordField(_ field: UITextField, placeholder: String) {
        field.placeholder = placeholder
        field.isSecureTextEntry = true
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
    }

    private func removeTemporaryExport() {
        guard let exportedTemporaryURL else { return }
        TemporaryExportFiles.remove(exportedTemporaryURL)
        self.exportedTemporaryURL = nil
    }

    private func showSettings() {
        editorController.prepareForModalPresentation()
        let settings = SettingsViewController(environment: environment)
        let navigation = UINavigationController(rootViewController: settings)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func showShortcuts() {
        presentShortcutPanel()
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
    @objc func searchCommand() {
        dismissShortcutPanel(animated: false, restoreFocus: false)
        show(.primary)
        listController.focusSearch()
        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.listController.focusSearch()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.listController.focusSearch()
            }
        }
    }

    @objc func toggleSidebarCommand() {
        dismissShortcutPanel(animated: false, restoreFocus: false)
        if isSidebarVisible {
            let shouldMoveFocus = listController.ownsFirstResponder
            hide(.primary)
            if shouldMoveFocus, !editorController.focusFirstEditorField() {
                becomeFirstResponder()
            }
        } else {
            show(.primary)
        }
    }

    @objc func editSnippetCommand() {
        dismissShortcutPanel(animated: false, restoreFocus: false)
        guard keyboardFocusContext == .list,
              selectedSnippetID != nil else { return }
        show(.secondary)
        editorController.focusBody()
    }

    @objc func nextFieldCommand() {
        guard keyboardFocusContext == .editor
                || keyboardFocusContext == .list else { return }
        if editorController.moveEditorFocus(forward: true) { return }
        show(.secondary)
        editorController.focusFirstEditorField()
    }

    @objc func previousFieldCommand() {
        guard keyboardFocusContext == .editor
                || keyboardFocusContext == .list else { return }
        if editorController.moveEditorFocus(forward: false) { return }
        show(.primary)
        listController.focusList()
    }

    @objc func nextSnippetCommand() {
        selectAdjacentSnippet(forward: true)
    }

    @objc func previousSnippetCommand() {
        selectAdjacentSnippet(forward: false)
    }

    @objc func nextSnippetFromListCommand() {
        selectAdjacentSnippet(forward: true)
    }

    @objc func previousSnippetFromListCommand() {
        selectAdjacentSnippet(forward: false)
    }

    @objc func shortcutsCommand() {
        if shortcutPanel.isPresented {
            dismissShortcutPanel(animated: true, restoreFocus: true)
        } else {
            presentShortcutPanel()
        }
    }

    @objc func escapeCommand() {
        _ = handleEscapeBeforeSystemBehavior()
    }

    func handleEscapeBeforeSystemBehavior() -> Bool {
        guard presentedViewController == nil else { return false }
        if shortcutPanel.isPresented {
            dismissShortcutPanel(animated: true, restoreFocus: true)
            return true
        }
        guard keyboardFocusContext == .search
                || keyboardFocusContext == .editor else { return false }

        show(.primary)
        listController.focusFilteredList()
        if let transitionCoordinator {
            transitionCoordinator.animate(alongsideTransition: nil) { [weak self] _ in
                self?.listController.focusFilteredList()
            }
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.listController.focusFilteredList()
            }
        }
        return true
    }

    func handleReturnBeforeSystemBehavior() -> Bool {
        guard !shortcutPanel.isPresented,
              listController.isListFocused,
              selectedSnippetID != nil else { return false }
        copySnippetCommand(Self.copySnippetKeyCommand())
        return true
    }

    @objc func copySnippetCommand(_ sender: UIKeyCommand) {
        guard keyboardFocusContext == .list, let selectedSnippetID else { return }
        copy(id: selectedSnippetID)
    }

    private func copy(id: UUID) {
        if environment.store.isSecure(id) {
            editorController.prepareForModalPresentation()
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch try await environment.snippetActions.copy(id: id) {
                case .copied(let name, let secure):
                    let detail = secure ? " Secure clipboard expires in 60 seconds." : ""
                    toastPresenter.show(message: "Copied “\(name)”.\(detail)")
                case .empty(let name):
                    toastPresenter.show(message: "“\(name)” has no content to copy.")
                }
            } catch {
                showError(title: "Couldn’t Copy Snippet", error: error)
            }
        }
    }

    @objc func deleteSnippetCommand() {
        guard keyboardFocusContext == .list,
              let selectedSnippetID else { return }
        delete(id: selectedSnippetID)
    }

    @objc private func undoCommand() {
        guard keyboardFocusContext == .list else { return }
        guard environment.store.undo() else { return }
        libraryChanged(.init(source: .local))
    }

    @objc private func redoCommand() {
        guard keyboardFocusContext == .list else { return }
        guard environment.store.redo() else { return }
        libraryChanged(.init(source: .local))
    }

    private func configureShortcutPanel() {
        shortcutPanel.onDismiss = { [weak self] in
            self?.dismissShortcutPanel(animated: true, restoreFocus: true)
        }
        view.addSubview(shortcutPanel)
        NSLayoutConstraint.activate([
            shortcutPanel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            shortcutPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            shortcutPanel.topAnchor.constraint(equalTo: view.topAnchor),
            shortcutPanel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func presentShortcutPanel() {
        loadViewIfNeeded()
        guard !shortcutPanel.isPresented else { return }
        shortcutPanelPreviousFirstResponder = view.activeFirstResponder()
        view.bringSubviewToFront(shortcutPanel)
        shortcutPanel.present(animated: view.window != nil)
        becomeFirstResponder()
    }

    private func dismissShortcutPanel(animated: Bool, restoreFocus: Bool) {
        guard shortcutPanel.isPresented else { return }
        let previousFirstResponder = restoreFocus ? shortcutPanelPreviousFirstResponder : nil
        shortcutPanelPreviousFirstResponder = nil
        let shouldAnimate = animated && UIView.areAnimationsEnabled && view.window != nil
        shortcutPanel.dismiss(animated: shouldAnimate) {
            if previousFirstResponder?.window != nil,
               previousFirstResponder?.becomeFirstResponder() == true {
                return
            }
            self.becomeFirstResponder()
        }
    }

    private func updateShortcutPanelModifierState(_ event: UIPressesEvent?) {
        guard shortcutPanel.isPresented else { return }
        shortcutPanel.setShowsAllShortcuts(
            event?.modifierFlags.contains(.alternate) == true,
            animated: true
        )
    }

    private func selectAdjacentSnippet(forward: Bool) {
        guard keyboardFocusContext == .list,
              let id = listController.adjacentSnippetID(forward: forward) else { return }
        select(id: id, revealEditor: false, ensureListVisible: true)
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
    func snippetListRequestedEncryptedBackup(_ controller: SnippetListViewController) {
        showEncryptedBackupExporter()
    }
    func snippetListRequestedSettings(_ controller: SnippetListViewController) { showSettings() }
    func snippetListRequestedShortcuts(_ controller: SnippetListViewController) { showShortcuts() }
    func snippetList(_ controller: SnippetListViewController, requestedCopy id: UUID) { copy(id: id) }
    func snippetList(_ controller: SnippetListViewController, requestedDelete id: UUID) { delete(id: id) }
    func snippetList(_ controller: SnippetListViewController, requestedDuplicate id: UUID) { duplicate(id: id) }
    func snippetList(_ controller: SnippetListViewController, requestedToggleSecurity id: UUID) {
        select(id: id, revealEditor: true)
        editorController.requestSecurityToggle(for: id)
    }
}

extension MainSplitViewController: SnippetEditorViewControllerDelegate {
    func snippetEditorRequestedCopy(_ controller: SnippetEditorViewController, id: UUID) { copy(id: id) }
    func snippetEditorRequestedDelete(_ controller: SnippetEditorViewController, id: UUID) { delete(id: id) }
    func snippetEditorRequestedDuplicate(_ controller: SnippetEditorViewController, id: UUID) { duplicate(id: id) }
}

extension MainSplitViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let purpose = documentPickerPurpose
        documentPickerPurpose = nil
        if purpose == .exporting {
            removeTemporaryExport()
            return
        }
        guard purpose == .importing, let url = urls.first else { return }
        importDocument(at: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        documentPickerPurpose = nil
        removeTemporaryExport()
    }
}

private extension UIView {
    func activeFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.activeFirstResponder() { return responder }
        }
        return nil
    }
}
