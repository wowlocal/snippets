import UIKit

final class SettingsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case sync
        case security

        var title: String {
            switch self {
            case .sync: "iCloud Sync"
            case .security: "Secure Snippets"
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
    }

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        environment.syncCoordinator.onStateChange = { [weak self] _ in
            self?.tableView.reloadData()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultChanged),
            name: .snippetsVaultStateChanged,
            object: nil
        )
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            environment.syncCoordinator.onStateChange = nil
        }
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
            cell.textLabel?.text = "Remove Secure Snippets from This iPad"
            cell.detailTextLabel?.text = environment.secureStore.usesSynchronizableVaultKey
                ? "The shared Keychain key remains available to your other devices."
                : "This also removes the device-only vault key."
            cell.textLabel?.textColor = .systemRed
            cell.imageView?.image = UIImage(systemName: "trash")
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
        default:
            break
        }
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .sync:
            var rows: [Row] = [.syncToggle, .syncStatus]
            if SyncCoordinator.isEnabled { rows.append(.syncNow) }
            if environment.syncCoordinator.state.isHalted { rows.append(.reviewHalt) }
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
        }
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
                _ = try await environment.vaultSession.unlock(reason: "Add a recovery key")
                var recoveryKey: String?
                _ = try environment.performLocalSecureChange {
                    try environment.secureStore.addRecoveryKeyIfNeeded { key in
                        recoveryKey = key
                        return true
                    }
                }
                guard let recoveryKey else { return }
                showRecoveryKey(recoveryKey)
                tableView.reloadData()
            } catch {
                showError(title: "Couldn’t Add Recovery Key", error: error)
            }
        }
    }

    private func showRecoveryKey(_ key: String) {
        let alert = UIAlertController(
            title: "Save Your Recovery Key",
            message: "Store this somewhere safe.\n\n\(key)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { _ in
            UIPasteboard.general.string = key
        })
        alert.addAction(UIAlertAction(title: "I’ve Saved It", style: .default))
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
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.accessibilityIdentifier = "recovery-key"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self, weak alert] _ in
            guard let self, let text = alert?.textFields?.first?.text else { return }
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
            : "This removes every secure snippet stored on this iPad. This action cannot be undone."
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
