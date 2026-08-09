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
    private let shortcutPanel = ShortcutPanelView()
    private weak var shortcutPanelPreviousFirstResponder: UIView?
    private var selectedSnippetID: UUID?
    private var documentPickerPurpose: DocumentPickerPurpose?
    private var exportedTemporaryURL: URL?

    init(environment: AppEnvironment) {
        self.environment = environment
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

    override func viewDidLoad() {
        super.viewDidLoad()
        configureShortcutPanel()
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
            UIKeyCommand(title: "Undo", action: #selector(undoCommand), input: "z", modifierFlags: .command),
            UIKeyCommand(title: "Redo", action: #selector(redoCommand), input: "z", modifierFlags: [.command, .shift]),
        ]
        commands.append(Self.escapeKeyCommand())
        return commands
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(escapeCommand) {
            return shortcutPanel.isPresented
        }
        if action == #selector(nextSnippetCommand)
            || action == #selector(previousSnippetCommand) {
            return !shortcutPanel.isPresented
                && !listController.isSearchFocused
                && listController.firstVisibleSnippetID != nil
        }
        if action == #selector(nextSnippetFromListCommand)
            || action == #selector(previousSnippetFromListCommand) {
            return !shortcutPanel.isPresented
                && listController.isListFocused
                && listController.firstVisibleSnippetID != nil
        }
        return super.canPerformAction(action, withSender: sender)
    }

    static func copySnippetKeyCommand() -> UIKeyCommand {
        let command = UIKeyCommand(
            title: "Copy Snippet",
            action: #selector(copySnippetCommand(_:)),
            input: "\r",
            modifierFlags: .command
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

    private func select(id: UUID, revealEditor: Bool, ensureListVisible: Bool = false) {
        selectedSnippetID = id
        listController.select(id: id, ensureVisible: ensureListVisible)
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Snippets-Export.json", isDirectory: false)
        do {
            let count = try environment.store.exportSnippets(to: url)
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            documentPickerPurpose = .exporting
            exportedTemporaryURL = url
            present(picker, animated: true)
            listController.showStatus("Exporting \(count) ordinary snippet\(count == 1 ? "" : "s") for sharing… Secure snippets are not included.")
        } catch {
            showError(title: "Couldn’t Export Snippets", error: error)
        }
    }

    private func showEncryptedBackupExporter() {
        editorController.prepareForModalPresentation()
        promptForNewBackupPassword { [weak self] passphrase in
            guard let self, let passphrase else { return }
            listController.showStatus("Preparing encrypted backup…")

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let backup = try await environment.secureStore.makeEncryptedBackup(
                        store: environment.store,
                        passphrase: passphrase)
                    removeTemporaryExport()
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent("Snippets-Backup.snippetsbackup", isDirectory: false)
                    try AtomicFileWriter.write(
                        backup.data,
                        to: url,
                        temporaryDirectory: FileManager.default.temporaryDirectory,
                        permissions: 0o600)
                    try FileManager.default.setAttributes(
                        [.protectionKey: FileProtectionType.complete],
                        ofItemAtPath: url.path)

                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                    picker.delegate = self
                    documentPickerPurpose = .exporting
                    exportedTemporaryURL = url
                    present(picker, animated: true)
                    listController.showStatus(
                        "Encrypted backup contains \(backup.ordinaryCount) ordinary and \(backup.secureCount) secure snippet\(backup.totalCount == 1 ? "" : "s").")
                } catch {
                    showError(title: "Couldn’t Create Encrypted Backup", error: error)
                }
            }
        }
    }

    private func importDocument(at url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        let finish = { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        let encryptedData = try? Data(contentsOf: url)
        let isEncryptedBackup = url.pathExtension.caseInsensitiveCompare(
            EncryptedSnippetBackup.preferredFilenameExtension) == .orderedSame
            || encryptedData.map(EncryptedSnippetBackup.isEncryptedBackup) == true
        if isEncryptedBackup {
            finish()
            guard let encryptedData else {
                showMessage(
                    title: "Couldn’t Read Encrypted Backup",
                    message: "The selected backup file could not be read.")
                return
            }
            importEncryptedBackup(encryptedData)
            return
        }

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

    private func importEncryptedBackup(_ data: Data) {
        promptForBackupPassword { [weak self] passphrase in
            guard let self, let passphrase else { return }
            listController.showStatus("Opening encrypted backup…")

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await environment.secureStore.importEncryptedBackup(
                        data,
                        passphrase: passphrase,
                        into: environment.store)
                    listController.showStatus(
                        "Imported \(result.ordinaryCount) ordinary and \(result.secureCount) secure snippet\(result.totalCount == 1 ? "" : "s").")
                    selectInitialSnippetIfNeeded()
                } catch {
                    showError(title: "Couldn’t Import Encrypted Backup", error: error)
                }
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
        try? FileManager.default.removeItem(at: exportedTemporaryURL)
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
        guard selectedSnippetID != nil else { return }
        show(.secondary)
        editorController.focusBody()
    }

    @objc func nextFieldCommand() {
        guard !shortcutPanel.isPresented else { return }
        if editorController.moveEditorFocus(forward: true) { return }
        show(.secondary)
        editorController.focusFirstEditorField()
    }

    @objc func previousFieldCommand() {
        guard !shortcutPanel.isPresented else { return }
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
        dismissShortcutPanel(animated: true, restoreFocus: true)
    }

    func handleEscapeBeforeSystemSearch() -> Bool {
        guard listController.isSearchFocused else { return false }
        listController.focusFilteredList()
        return true
    }

    @objc func copySnippetCommand(_ sender: UIKeyCommand) {
        guard let name = editorController.copySelectedSnippet() else { return }
        listController.showStatus("Copied “\(name)”.")
    }

    @objc private func undoCommand() {
        guard environment.store.undo() else { return }
        libraryChanged(source: .local)
    }

    @objc private func redoCommand() {
        guard environment.store.redo() else { return }
        libraryChanged(source: .local)
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
        guard !shortcutPanel.isPresented,
              !listController.isSearchFocused,
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
