import UIKit

final class SettingsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Int, CaseIterable {
        case sync
        case security
        case diagnostics

        var title: String {
            switch self {
            case .sync: "iCloud Sync"
            case .security: "Secure Snippets"
            case .diagnostics: "Diagnostics"
            }
        }
    }

    private enum Row: Hashable {
        case syncToggle
        case syncStatus
        case syncNow
        case reviewHalt
        case keychainStatus
        case lockVault
        case addRecovery
        case restoreRecovery
        case forgetVault
        case diagnosticsStatus
        case exportDiagnostics
        case deleteDiagnostics
    }

    private let environment: AppEnvironment
    private let showsDoneButton: Bool
    private var temporaryExportURL: URL?
    private var syncObservation: UUID?

    init(environment: AppEnvironment, showsDoneButton: Bool = true) {
        self.environment = environment
        self.showsDoneButton = showsDoneButton
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        if showsDoneButton {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                systemItem: .done,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        syncObservation = environment.syncCoordinator.addStateObserver { [weak self] _ in
            self?.tableView.reloadData()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultChanged),
            name: .snippetsVaultStateChanged,
            object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if traitCollection.userInterfaceIdiom == .phone {
            navigationController?.setToolbarHidden(true, animated: animated)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent
            || navigationController?.isBeingDismissed == true {
            removeSyncObservation()
        }
    }

    private func removeSyncObservation() {
        guard let syncObservation else { return }
        environment.syncCoordinator.removeStateObserver(syncObservation)
        self.syncObservation = nil
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: Section(rawValue: section)!).count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows(in: Section(rawValue: indexPath.section)!)[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.numberOfLines = 0
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.selectionStyle = .default
        cell.accessoryView = nil
        cell.accessoryType = .none

        switch row {
        case .syncToggle:
            cell.textLabel?.text = "Sync this library"
            cell.detailTextLabel?.text = "Encrypted before it is sent to the existing Snippets CloudKit container."
            let control = UISwitch()
            control.isOn = SyncCoordinator.isEnabled
            control.accessibilityIdentifier = "icloud-sync"
            control.addAction(UIAction { [weak self, weak control] _ in
                guard let self, let control else { return }
                self.environment.syncCoordinator.setEnabled(control.isOn)
                self.tableView.reloadData()
            }, for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .syncStatus:
            cell.textLabel?.text = "Status"
            cell.detailTextLabel?.text = environment.syncCoordinator.statusDescription
            cell.selectionStyle = .none
        case .syncNow:
            cell.textLabel?.text = "Sync Now"
            cell.imageView?.image = UIImage(systemName: "arrow.triangle.2.circlepath")
            cell.textLabel?.textColor = AppTheme.tint
        case .reviewHalt:
            cell.textLabel?.text = "Resume After Review"
            cell.detailTextLabel?.text = "Only resume after confirming the library and CloudKit account are correct."
            cell.imageView?.image = UIImage(systemName: "exclamationmark.shield")
            cell.textLabel?.textColor = AppTheme.warning
        case .keychainStatus:
            cell.textLabel?.text = "Key Storage"
            cell.detailTextLabel?.text = environment.vaultSession.keychainStatusDescription
            cell.selectionStyle = .none
        case .lockVault:
            cell.textLabel?.text = "Lock Now"
            cell.imageView?.image = UIImage(systemName: "lock")
            cell.textLabel?.textColor = AppTheme.tint
        case .addRecovery:
            cell.textLabel?.text = "Add Recovery Key"
            cell.detailTextLabel?.text = "Create the offline recovery key this vault does not have yet."
            cell.imageView?.image = UIImage(systemName: "key")
        case .restoreRecovery:
            cell.textLabel?.text = "Restore with Recovery Key"
            cell.imageView?.image = UIImage(systemName: "key.viewfinder")
        case .forgetVault:
            cell.textLabel?.text = "Remove Secure Snippets from This Device"
            cell.detailTextLabel?.text = environment.secureStore.usesSynchronizableVaultKey
                ? "The shared Keychain key remains available to your other devices."
                : "This also removes the device-only vault key."
            cell.textLabel?.textColor = .systemRed
            cell.imageView?.image = UIImage(systemName: "trash")
        case .diagnosticsStatus:
            let summary = environment.diagnostics.summary()
            cell.textLabel?.text = "Persistent Logs"
            let bytes = ByteCountFormatter.string(
                fromByteCount: Int64(min(summary.byteCount, UInt64(Int64.max))),
                countStyle: .file)
            var detail = summary.storageAvailable
                ? "\(summary.fileCount) file(s), \(bytes). Kept for up to \(DiagnosticsService.retentionDays) days."
                : "The diagnostics folder is unavailable."
            if summary.privacyCleanupNeeded {
                detail += " Legacy audit cleanup still needs attention."
                cell.detailTextLabel?.textColor = .systemRed
            }
            cell.detailTextLabel?.text = detail
            cell.selectionStyle = .none
        case .exportDiagnostics:
            cell.textLabel?.text = "Export Diagnostic Logs"
            cell.detailTextLabel?.text = "Plaintext JSON Lines. Secure-snippet keywords "
                + "may be included; bodies, names, tags, IDs, paths, keys and ciphertext "
                + "are excluded."
            cell.imageView?.image = UIImage(systemName: "square.and.arrow.up")
            cell.textLabel?.textColor = AppTheme.tint
        case .deleteDiagnostics:
            cell.textLabel?.text = "Delete Diagnostic Logs"
            cell.imageView?.image = UIImage(systemName: "trash")
            cell.textLabel?.textColor = .systemRed
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rows(in: Section(rawValue: indexPath.section)!)[indexPath.row]
        switch row {
        case .syncNow:
            environment.syncCoordinator.syncNow()
        case .reviewHalt:
            confirmResumeAfterReview()
        case .lockVault:
            environment.vaultSession.lock()
        case .addRecovery:
            addRecoveryKey()
        case .restoreRecovery:
            promptForRecoveryKey()
        case .forgetVault:
            confirmForgetVault()
        case .exportDiagnostics:
            exportDiagnostics()
        case .deleteDiagnostics:
            confirmDeleteDiagnostics()
        default:
            break
        }
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .sync:
            var rows: [Row] = [.syncToggle, .syncStatus]
            if SyncCoordinator.isEnabled { rows.append(.syncNow) }
            if case .halted(let reason, _) = environment.syncCoordinator.state,
               reason.isUserRecoverable {
                rows.append(.reviewHalt)
            }
            return rows
        case .security:
            var rows: [Row] = [.keychainStatus]
            if environment.secureStore.hasVault {
                rows.append(.lockVault)
                if !environment.secureStore.hasRecoveryKey { rows.append(.addRecovery) }
                rows.append(.restoreRecovery)
                rows.append(.forgetVault)
            }
            return rows
        case .diagnostics:
            return [.diagnosticsStatus, .exportDiagnostics, .deleteDiagnostics]
        }
    }

    private func exportDiagnostics() {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
            DiagnosticsService.suggestedExportFilename(),
            isDirectory: false)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await environment.diagnostics.export(to: destination)
                temporaryExportURL = result.url
                let picker = UIDocumentPickerViewController(
                    forExporting: [result.url],
                    asCopy: true)
                picker.delegate = self
                present(picker, animated: true)
            } catch {
                showError(title: "Couldn’t Export Diagnostics", error: error)
            }
            tableView.reloadData()
        }
    }

    private func confirmDeleteDiagnostics() {
        let alert = UIAlertController(
            title: "Delete Diagnostic Logs?",
            message: "This permanently removes retained diagnostics and any legacy reveal-audit file from this device.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete Logs", style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.environment.diagnostics.deleteStoredLogs()
                self.tableView.reloadData()
            }
        })
        present(alert, animated: true)
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        removeTemporaryExport()
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        removeTemporaryExport()
    }

    private func removeTemporaryExport() {
        if let temporaryExportURL {
            try? FileManager.default.removeItem(at: temporaryExportURL)
        }
        temporaryExportURL = nil
    }

    private func confirmResumeAfterReview() {
        let alert = UIAlertController(
            title: "Resume iCloud Sync?",
            message: "This clears the safety halt and immediately attempts another sync round.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Resume", style: .default) { [weak self] _ in
            self?.environment.syncCoordinator.clearHaltAfterUserReview()
        })
        present(alert, animated: true)
    }

    private func addRecoveryKey() {
        Task { @MainActor in
            do {
                let pending = try await environment.vaultSession.withOneUseAuthentication(
                    reason: "Create and display a recovery key"
                ) {
                    try environment.secureStore.prepareRecoveryKeyAddition()
                }
                guard let pending else { return }
                showRecoveryKey(pending)
            } catch {
                showError(title: "Couldn’t Add Recovery Key", error: error)
            }
        }
    }

    private func showRecoveryKey(_ pending: SecureSnippetStore.PendingRecoveryKeyAddition) {
        let key = pending.recoveryKeyText
        let alert = UIAlertController(
            title: "Save Your Recovery Key",
            message: "Store this somewhere safe.\n\n\(key)",
            preferredStyle: .alert
        )
        let commit = { [weak self] in
            guard let self else { return }
            do {
                _ = try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.commitRecoveryKeyAddition(pending)
                }
                self.tableView.reloadData()
            } catch {
                self.showError(title: "Couldn’t Add Recovery Key", error: error)
            }
        }
        alert.addAction(UIAlertAction(title: "Copy & Save", style: .default) { _ in
            RecoveryKeyPasteboard.copy(key)
            commit()
        })
        alert.addAction(UIAlertAction(title: "I’ve Saved It", style: .default) { _ in commit() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in pending.cancel() })
        present(alert, animated: true)
    }

    private func promptForRecoveryKey() {
        let alert = UIAlertController(
            title: "Restore Vault Key",
            message: "Enter the recovery key created when Secure Snippets was set up.",
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = "Recovery key"
            field.accessibilityIdentifier = "recovery-key"
            RecoveryKeyInputProtection.configure(field)
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self, weak alert] _ in
            guard let self, let field = alert?.textFields?.first,
                  let text = field.text else { return }
            field.text = nil
            do {
                try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.restoreKey(fromRecoveryKey: text)
                }
                self.tableView.reloadData()
            } catch {
                self.showError(title: "Couldn’t Restore Vault Key", error: error)
            }
        })
        present(alert, animated: true)
    }

    private func confirmForgetVault() {
        let syncWarning = SyncCoordinator.isEnabled
            ? "Turn off iCloud Sync first."
            : "This removes every secure snippet stored on this device. This action cannot be undone."
        let alert = UIAlertController(
            title: "Remove Secure Snippets?",
            message: syncWarning,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        guard !SyncCoordinator.isEnabled else {
            present(alert, animated: true)
            return
        }
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.forgetEverything(
                        syncIsQuiescent: self.environment.syncCoordinator.isQuiescent
                    )
                }
                self.tableView.reloadData()
            } catch {
                self.showError(title: "Couldn’t Remove Secure Snippets", error: error)
            }
        })
        present(alert, animated: true)
    }

    private func showError(title: String, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func vaultChanged() {
        tableView.reloadData()
    }
}
