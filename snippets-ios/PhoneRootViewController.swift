import UIKit
import UniformTypeIdentifiers

final class PhoneRootViewController: UINavigationController, SnippetsRootController {
    private enum DocumentPickerPurpose {
        case importing
        case exporting
    }

    private static let encryptedBackupType = UTType(
        exportedAs: EncryptedSnippetBackup.formatIdentifier,
        conformingTo: .data
    )

    let environment: AppEnvironment
    private let libraryController: PhoneLibraryViewController
    private let incomingLinkCoordinator: IncomingSnippetLinkCoordinator
    private var documentPickerPurpose: DocumentPickerPurpose?
    private var exportedTemporaryURL: URL?

    init(environment: AppEnvironment) {
        self.environment = environment
        let library = PhoneLibraryViewController(environment: environment)
        libraryController = library
        incomingLinkCoordinator = IncomingSnippetLinkCoordinator(store: environment.store)
        super.init(rootViewController: library)

        TemporaryExportFiles.removeStale()

        library.delegate = self
        AppTheme.configureNavigationBar(navigationBar)
        AppTheme.configureToolbar(toolbar)
        navigationBar.prefersLargeTitles = true
        toolbar.tintColor = AppTheme.tint

        environment.store.onChange = { [weak self] change in
            self?.libraryChanged(change)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func open(_ url: URL) {
        incomingLinkCoordinator.open(
            url,
            from: self,
            accepted: { [weak self] action in
                guard let self else { return }
                self.popToRootViewController(animated: false)
                self.libraryController.clearActiveQuery()
                self.showEditor(id: action.snippetID, focusBody: false)
            },
            failed: { [weak self] error in
                self?.showError(title: "Couldn’t Open Link", error: error)
            }
        )
    }

    private func libraryChanged(_ change: SnippetStore.Change) {
        let source = change.source
        // The phone library is completely covered by the editor and reloads from the
        // store in viewWillAppear. Rebuilding its search/filter sections here made
        // every editor keystroke pay for hidden UITableView work. The editor publishes
        // its own derived UI immediately after the store update returns.
        if source == .local, environment.isPerformingLocalEditorChange {
            return
        }

        libraryController.reload()
        if let editor = topViewController as? PhoneSnippetEditorViewController {
            editor.refreshFromStore(change: change)
        }
    }

    private func createSnippet(content: String = "") {
        let snippet: Snippet
        if content.isEmpty, let draft = environment.store.blankDraftSnippet {
            snippet = draft
        } else {
            snippet = environment.store.addSnippet(content: content)
        }
        showEditor(id: snippet.id, focusBody: true)
    }

    private func createFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showMessage(title: "Clipboard Is Empty", message: "Copy some text, then try again.")
            return
        }
        createSnippet(content: text)
    }

    private func showEditor(id: UUID, focusBody: Bool = false) {
        guard environment.store.snippetForDisplay(id: id) != nil else { return }
        if topViewController is PhoneSnippetEditorViewController {
            popViewController(animated: false)
        }
        let editor = PhoneSnippetEditorViewController(environment: environment, snippetID: id)
        editor.delegate = self
        pushViewController(editor, animated: true)
        if focusBody {
            DispatchQueue.main.async { [weak editor] in editor?.focusBody() }
        }
    }

    private func copy(id: UUID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await environment.snippetActions.copy(id: id)
                libraryController.showCopyResult(result)
            } catch {
                showError(title: "Couldn’t Copy Snippet", error: error)
            }
        }
    }

    private func togglePin(id: UUID) {
        guard let snippet = environment.store.snippetForDisplay(id: id) else { return }
        do {
            if environment.store.isSecure(id) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(id: id, isPinned: !snippet.isPinned)
                }
            } else {
                environment.store.togglePinned(snippetID: id)
            }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)
        } catch {
            showError(title: "Couldn’t Update Pin", error: error)
        }
    }

    private func requestDelete(id: UUID) {
        guard let snippet = environment.store.snippetForDisplay(id: id) else { return }
        if environment.store.isSecure(id) {
            confirmSecureDelete(snippet)
            return
        }
        deleteOrdinary(snippet)
    }

    private func deleteOrdinary(_ snippet: Snippet) {
        if topViewController is PhoneSnippetEditorViewController {
            popToRootViewController(animated: true)
        }
        guard let undoToken = environment.store.deleteForUndo(snippetID: snippet.id) else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        libraryController.showStatus("Deleted “\(snippet.displayName)”.", actionTitle: "Undo") { [weak self] in
            guard let self,
                  self.environment.store.restoreDeletedSnippet(using: undoToken) else { return }
        }
    }

    private func confirmSecureDelete(_ snippet: Snippet) {
        let alert = UIAlertController(
            title: "Delete “\(snippet.displayName)”?",
            message: "This permanently removes the encrypted snippet from this device and, when sync is on, from your other devices.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.delete(id: snippet.id)
                }
                if self.topViewController is PhoneSnippetEditorViewController {
                    self.popToRootViewController(animated: true)
                }
                self.libraryController.showStatus("Secure snippet deleted.")
            } catch {
                self.showError(title: "Couldn’t Delete Snippet", error: error)
            }
        })
        present(alert, animated: true)
    }

    private func duplicate(id: UUID) {
        guard !environment.store.isSecure(id) else { return }
        guard let duplicate = environment.store.duplicate(snippetID: id) else { return }
        showEditor(id: duplicate.id, focusBody: false)
    }

    private func connectICloud() {
        environment.syncCoordinator.setEnabled(true)
        libraryController.showStatus("Connecting to iCloud…")
        libraryController.reload()
    }

    private func syncNow() {
        guard SyncCoordinator.isEnabled else {
            connectICloud()
            return
        }
        libraryController.showStatus("Syncing…")
        environment.syncCoordinator.syncNow()
    }

    private func showSettings() {
        let settings = SettingsViewController(environment: environment, showsDoneButton: false)
        settings.navigationItem.largeTitleDisplayMode = .never
        pushViewController(settings, animated: true)
    }

    private func showImporter() {
        topViewController?.view.endEditing(true)
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.json, Self.encryptedBackupType],
            asCopy: false
        )
        picker.delegate = self
        picker.allowsMultipleSelection = false
        documentPickerPurpose = .importing
        present(picker, animated: true)
    }

    private func showExporter() {
        topViewController?.view.endEditing(true)
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
            libraryController.showStatus(
                "Exporting \(count) ordinary snippet\(count == 1 ? "" : "s"). Secure snippets are excluded."
            )
        } catch {
            if let temporaryURL { TemporaryExportFiles.remove(temporaryURL) }
            showError(title: "Couldn’t Export Snippets", error: error)
        }
    }

    private func showEncryptedBackupExporter() {
        topViewController?.view.endEditing(true)
        promptForNewBackupPassword { [weak self] passphrase in
            guard let self, let passphrase else { return }
            libraryController.showStatus("Preparing encrypted backup…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                var temporaryURL: URL?
                do {
                    let backup = try await environment.secureStore.makeEncryptedBackup(
                        store: environment.store,
                        passphrase: passphrase
                    )
                    removeTemporaryExport()
                    let url = try TemporaryExportFiles.makeURL(
                        filename: "Snippets-Backup.snippetsbackup"
                    )
                    temporaryURL = url
                    try AtomicFileWriter.write(
                        backup.data,
                        to: url,
                        temporaryDirectory: url.deletingLastPathComponent(),
                        permissions: 0o600
                    )
                    try TemporaryExportFiles.protect(url)
                    let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
                    picker.delegate = self
                    documentPickerPurpose = .exporting
                    exportedTemporaryURL = url
                    present(picker, animated: true)
                    libraryController.showStatus(
                        "Backup contains \(backup.ordinaryCount) ordinary and \(backup.secureCount) secure snippets."
                    )
                } catch {
                    if let temporaryURL { TemporaryExportFiles.remove(temporaryURL) }
                    showError(title: "Couldn’t Create Encrypted Backup", error: error)
                }
            }
        }
    }

    private func importDocument(at url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        libraryController.showStatus("Reading import…")
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
            do {
                let count = try self.environment.store.importSnippets(
                    prepared,
                    options: .init(preserveExclamationPrefix: preserveExclamation)
                )
                self.libraryController.showStatus(
                    "Imported \(count) snippet\(count == 1 ? "" : "s")."
                )
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
            libraryController.showStatus("Opening encrypted backup…")
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await environment.secureStore.importEncryptedBackup(
                        data,
                        passphrase: passphrase,
                        into: environment.store
                    )
                    libraryController.showStatus(
                        "Imported \(result.ordinaryCount) ordinary and \(result.secureCount) secure snippets."
                    )
                } catch {
                    showError(title: "Couldn’t Import Encrypted Backup", error: error)
                }
            }
        }
    }

    private func promptForNewBackupPassword(completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(
            title: "Protect Encrypted Backup",
            message: "Use a unique password of at least 12 characters and save it in a password manager. Snippets cannot recover it.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Backup password")
            field.textContentType = .newPassword
        }
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Confirm password")
            field.textContentType = .newPassword
        }
        guard let password = alert.textFields?.first,
              let confirmation = alert.textFields?.last else {
            completion(nil)
            return
        }
        let create = UIAlertAction(title: "Create Backup", style: .default) { _ in
            completion(password.text)
        }
        create.isEnabled = false
        let validate = UIAction { _ in
            let value = password.text ?? ""
            create.isEnabled = value.count >= 12
                && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && confirmation.text == value
        }
        password.addAction(validate, for: .editingChanged)
        confirmation.addAction(validate, for: .editingChanged)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion(nil) })
        alert.addAction(create)
        present(alert, animated: true)
    }

    private func promptForBackupPassword(completion: @escaping (String?) -> Void) {
        let alert = UIAlertController(
            title: "Open Encrypted Backup",
            message: "Enter the password used when this backup was created.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            Self.configureBackupPasswordField(field, placeholder: "Backup password")
            field.textContentType = .password
        }
        guard let password = alert.textFields?.first else {
            completion(nil)
            return
        }
        let open = UIAlertAction(title: "Open Backup", style: .default) { _ in
            completion(password.text)
        }
        open.isEnabled = false
        password.addAction(UIAction { _ in
            open.isEnabled = !(password.text ?? "").isEmpty
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

    private func showMessage(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func showError(title: String, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        showMessage(title: title, message: message)
    }
}

extension PhoneRootViewController: PhoneLibraryViewControllerDelegate {
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedCopy id: UUID) {
        copy(id: id)
    }

    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedEdit id: UUID) {
        showEditor(id: id)
    }

    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedPin id: UUID) {
        togglePin(id: id)
    }

    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedDelete id: UUID) {
        requestDelete(id: id)
    }

    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedDuplicate id: UUID) {
        duplicate(id: id)
    }

    func phoneLibraryRequestedNewSnippet(_ controller: PhoneLibraryViewController) {
        createSnippet()
    }

    func phoneLibraryRequestedClipboardSnippet(_ controller: PhoneLibraryViewController) {
        createFromClipboard()
    }

    func phoneLibraryRequestedImport(_ controller: PhoneLibraryViewController) {
        showImporter()
    }

    func phoneLibraryRequestedExport(_ controller: PhoneLibraryViewController) {
        showExporter()
    }

    func phoneLibraryRequestedEncryptedBackup(_ controller: PhoneLibraryViewController) {
        showEncryptedBackupExporter()
    }

    func phoneLibraryRequestedSync(_ controller: PhoneLibraryViewController) {
        syncNow()
    }

    func phoneLibraryRequestedSettings(_ controller: PhoneLibraryViewController) {
        showSettings()
    }

    func phoneLibraryRequestedConnectICloud(_ controller: PhoneLibraryViewController) {
        connectICloud()
    }
}

extension PhoneRootViewController: PhoneSnippetEditorViewControllerDelegate {
    func phoneSnippetEditor(
        _ controller: PhoneSnippetEditorViewController,
        requestedDelete id: UUID
    ) {
        requestDelete(id: id)
    }

    func phoneSnippetEditor(
        _ controller: PhoneSnippetEditorViewController,
        requestedDuplicate id: UUID
    ) {
        duplicate(id: id)
    }
}

extension PhoneRootViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        defer { documentPickerPurpose = nil }
        guard documentPickerPurpose == .importing, let url = urls.first else {
            removeTemporaryExport()
            return
        }
        importDocument(at: url)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        documentPickerPurpose = nil
        removeTemporaryExport()
    }
}
