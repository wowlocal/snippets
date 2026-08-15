import UIKit
import AuthenticationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import Vision
import VisionKit

final class SettingsViewController: UITableViewController, UIDocumentPickerDelegate {
    private enum Section: Int, CaseIterable {
        case sync
        case security
        case diagnostics

        var title: String {
            switch self {
            case .sync: "Sync"
            case .security: "Secure Snippets"
            case .diagnostics: "Diagnostics"
            }
        }
    }

    private enum Row: Hashable {
        case syncProvider
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
    private lazy var cloudBootstrap = SnippetsCloudAccountBootstrap(
        selection: environment.backendSelection)

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
        case .syncProvider:
            let selection = environment.backendSelection
            cell.textLabel?.text = "Cloud Provider"
            cell.detailTextLabel?.text = selection.provider.displayName
            cell.accessoryType = .disclosureIndicator
        case .syncToggle:
            cell.textLabel?.text = "Sync this library"
            cell.detailTextLabel?.text = "Encrypted before it is sent. Only one cloud provider is writable at a time."
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
            cell.detailTextLabel?.text = "Only resume after confirming the library and selected cloud account are correct."
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
        case .syncProvider:
            chooseSyncProvider()
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
            var rows: [Row] = [.syncProvider, .syncToggle, .syncStatus]
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

    private func chooseSyncProvider() {
        let selection = environment.backendSelection
        let alert = UIAlertController(
            title: "Cloud Provider",
            message: "Switch and Sync preserves the local library and the other cloud. iCloud continues using the existing CloudKit implementation.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "iCloud", style: .default) { [weak self] _ in
            guard let self else { return }
            selection.selectICloud()
            self.environment.syncCoordinator.reloadProviderSelection()
            self.tableView.reloadData()
        })
        alert.addAction(UIAlertAction(title: "Snippets Cloud…", style: .default) { [weak self] _ in
            self?.configureSnippetsCloud()
        })
        if selection.hasCloudSession {
            alert.addAction(UIAlertAction(
                title: "Sign Out of Snippets Cloud on This Device",
                style: .destructive
            ) { [weak self] _ in
                guard let self else { return }
                confirmCloudSignOut()
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func configureSnippetsCloud() {
        let selection = environment.backendSelection
        guard let bundled = SyncBackendSelectionStore.bundledServerURL,
              SyncBackendSelectionStore.bundledOAuthRedirectURL != nil else {
            let unavailable = UIAlertController(
                title: "Snippets Cloud Isn’t Configured",
                message: "This build has no verified cloud endpoint and HTTPS sign-in callback. A self-hosted build must pin both at build time.",
                preferredStyle: .alert)
            unavailable.addAction(UIAlertAction(title: "OK", style: .default))
            present(unavailable, animated: true)
            return
        }
        if selection.hasCloudSession {
            do {
                try presentCloudState(cloudBootstrap.state())
            } catch {
                showError(title: "Couldn’t Open Snippets Cloud", error: error)
            }
            return
        }
        signInToSnippetsCloud(bundled, selection: selection)
    }

    private func signInToSnippetsCloud(
        _ serverURL: URL,
        selection: SyncBackendSelectionStore
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let state = try await cloudBootstrap.signIn(
                    serverURL: serverURL,
                    presentationContext: self)
                try presentCloudState(state)
            } catch {
                showError(title: "Couldn’t Sign In to Snippets Cloud", error: error)
            }
        }
    }

    private func presentCloudState(_ state: SnippetsCloudAccountBootstrap.State) throws {
        switch state {
        case .signedOut:
            configureSnippetsCloud()
        case .ready:
            environment.syncCoordinator.reloadProviderSelection()
            environment.syncCoordinator.syncNow()
            tableView.reloadData()
            presentCloudReadyMenu()
        case .needsTrustedDeviceOrRecovery:
            presentCloudUnlockMenu()
        case .waitingForApproval(let payload, let code):
            presentPairingQR(payload: payload, confirmationCode: code)
        case .approvalReady(let code):
            confirmPairingApproval(code: code)
        case .strongAuthenticationRequired(let action):
            requestStrongAuthentication(for: action)
        case .recoveryKitAuthenticationRequired:
            authenticateRecoveryKitPresentation()
        case .recoveryKitReady(let payload, let code):
            presentRecoveryKit(payload: payload, longCode: code)
        }
    }

    private func authenticateRecoveryKitPresentation() {
        runCloudTask(title: "Couldn’t Reveal Recovery Kit") { [weak self] in
            guard let self else { return }
            try await requireDeviceOwnerAuthentication(
                reason: "Reveal your Snippets Cloud recovery kit")
            try presentCloudState(
                cloudBootstrap.revealRecoveryKitAfterLocalAuthentication())
        }
    }

    private func presentCloudUnlockMenu() {
        let alert = UIAlertController(
            title: "Unlock Your Encrypted Library",
            message: "Use a device that already has this library, or your offline recovery kit. Snippets Cloud cannot read or recover the library key.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Use Nearby Device", style: .default) {
            [weak self] _ in
            self?.runCloudTask(title: "Couldn’t Create Invitation") {
                guard let self else { return }
                try self.presentCloudState(try await self.cloudBootstrap.beginPairing())
            }
        })
        alert.addAction(UIAlertAction(title: "Scan Recovery QR", style: .default) {
            [weak self] _ in self?.presentCloudScanner(mode: .recovery)
        })
        alert.addAction(UIAlertAction(title: "Enter Recovery Code", style: .default) {
            [weak self] _ in self?.promptForCloudRecoveryCode()
        })
        alert.addAction(UIAlertAction(title: "I Have Neither", style: .destructive) {
            [weak self] _ in self?.showIrrecoverableCloudDataWarning()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        presentActionSheet(alert)
    }

    private func presentCloudReadyMenu() {
        let alert = UIAlertController(
            title: "Snippets Cloud Is Ready",
            message: "No Snippets password or required email. This device has its own login session and a device-only copy of the encrypted library key.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Add Another Device", style: .default) {
            [weak self] _ in self?.presentCloudScanner(mode: .pairing)
        })
        alert.addAction(UIAlertAction(title: "Replace Recovery Kit", style: .default) {
            [weak self] _ in
            self?.runCloudTask(title: "Couldn’t Replace Recovery Kit") {
                guard let self else { return }
                try self.presentCloudState(
                    try await self.cloudBootstrap.prepareRecoveryReplacement())
            }
        })
        alert.addAction(UIAlertAction(title: "Sign Out on This Device", style: .destructive) {
            [weak self] _ in self?.confirmCloudSignOut()
        })
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        presentActionSheet(alert)
    }

    private func presentPairingQR(payload: String, confirmationCode: String) {
        let controller = CloudQRViewController(
            title: "Add This Device",
            message: "Scan this one-time QR on a device that already has the library. Compare the code on both devices. Expires in about five minutes.",
            payload: payload,
            displayedCode: confirmationCode,
            warning: "The QR contains only a nonce and this device’s ephemeral public key — never the library key.",
            primaryTitle: "Check Approval",
            primary: { [weak self] in
                self?.runCloudTask(title: "Pairing Isn’t Ready") {
                    guard let self else { return }
                    try self.presentCloudState(try await self.cloudBootstrap.checkPairing())
                }
            },
            secondaryTitle: "Cancel Pairing",
            secondary: { [weak self] in
                self?.runCloudTask(title: "Couldn’t Cancel Pairing") {
                    try await self?.cloudBootstrap.cancelPairing()
                }
            })
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func presentRecoveryKit(payload: String, longCode: String) {
        let controller = CloudQRViewController(
            title: "Save Your Recovery Kit",
            message: "Keep this QR or long code offline. It is the only fallback if every approved device is lost.",
            payload: payload,
            displayedCode: longCode,
            warning: "If you lose this kit and every approved device, old encrypted snippets are permanently unrecoverable — including by Snippets Cloud.",
            primaryTitle: "I Saved It",
            primary: { [weak self] in
                guard let self else { return }
                do {
                    try cloudBootstrap.acknowledgeRecoveryKitSaved()
                    environment.syncCoordinator.reloadProviderSelection()
                    environment.syncCoordinator.syncNow()
                    tableView.reloadData()
                } catch {
                    showError(title: "Couldn’t Finish Setup", error: error)
                }
            },
            relocksWhenInactive: true)
        present(UINavigationController(rootViewController: controller), animated: true)
    }

    private func presentCloudScanner(mode: CloudQRScannerViewController.Mode) {
        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable else {
            let alert = UIAlertController(
                title: "Camera Scanning Is Unavailable",
                message: mode == .recovery
                    ? "Use Enter Recovery Code instead."
                    : "Open this screen on an iPhone or iPad with an available camera.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let scanner = CloudQRScannerViewController(mode: mode) { [weak self] payload in
            guard let self else { return }
            switch mode {
            case .pairing:
                runCloudTask(title: "Couldn’t Read Invitation") {
                    try self.presentCloudState(
                        try await self.cloudBootstrap.prepareApproval(qrPayload: payload))
                }
            case .recovery:
                restoreCloudLibrary(with: payload)
            }
        }
        present(UINavigationController(rootViewController: scanner), animated: true)
    }

    private func confirmPairingApproval(code: String) {
        let alert = UIAlertController(
            title: "Add This iPhone or Mac?",
            message: SnippetsCloudPairingApprovalCopy.message(
                code: code,
                localAuthentication: "Face ID or Touch ID"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
            try? self?.cloudBootstrap.cancelApproval()
        })
        alert.addAction(UIAlertAction(
            title: SnippetsCloudPairingApprovalCopy.approveButtonTitle(code: code),
            style: .default
        ) { [weak self] _ in
            self?.authenticateAndContinue(action: .approveDevice)
        })
        present(alert, animated: true)
    }

    private func requestStrongAuthentication(for action: SnippetsCloudAccountBootstrap.StrongAction) {
        if action == .createInitialRecovery {
            let alert = UIAlertController(
                title: "Protect Your Recovery Kit",
                message: "Finish with a fresh passkey check. Apple or Google may be used to identify the account, but they never become the key to your snippets.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Continue", style: .default) { [weak self] _ in
                self?.continueWithStrongCloudSignIn()
            })
            present(alert, animated: true)
        } else {
            authenticateAndContinue(action: action)
        }
    }

    private func authenticateAndContinue(action: SnippetsCloudAccountBootstrap.StrongAction) {
        runCloudTask(title: "Approval Failed") { [weak self] in
            guard let self else { return }
            try await requireDeviceOwnerAuthentication(reason: action == .approveDevice
                ? "Approve a new device for your encrypted Snippets library"
                : "Replace your Snippets Cloud recovery kit")
            continueWithStrongCloudSignIn()
        }
    }

    private func continueWithStrongCloudSignIn() {
        guard let server = environment.backendSelection.cloudCoordinates?.serverURL else {
            showError(title: "Couldn’t Continue", error: SnippetsCloudAccountBootstrap.Failure.invalidState)
            return
        }
        runCloudTask(title: "Secure Approval Failed") { [weak self] in
            guard let self else { return }
            let state = try await cloudBootstrap.signIn(
                serverURL: server,
                strong: true,
                presentationContext: self)
            try presentCloudState(state)
        }
    }

    private func promptForCloudRecoveryCode() {
        let alert = UIAlertController(
            title: "Recovery Code",
            message: "Enter the long code from your offline recovery kit.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.autocapitalizationType = .allCharacters
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.placeholder = "XXXX-XXXX-…"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Restore", style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text else { return }
            self?.restoreCloudLibrary(with: value)
        })
        present(alert, animated: true)
    }

    private func restoreCloudLibrary(with value: String) {
        runCloudTask(title: "Couldn’t Restore Library") { [weak self] in
            guard let self else { return }
            try presentCloudState(try await cloudBootstrap.restore(recoveryCodeOrQR: value))
        }
    }

    private func showIrrecoverableCloudDataWarning() {
        let alert = UIAlertController(
            title: "Old Data Cannot Be Recovered",
            message: "Your account can still be used, but without any approved device or the recovery kit, the old encrypted snippets are mathematically unrecoverable. Snippets Cloud has no decryption key.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "I Understand", style: .default))
        present(alert, animated: true)
    }

    private func confirmCloudSignOut() {
        let alert = UIAlertController(
            title: "Sign Out on This Device?",
            message: "This removes this device’s login credential and device-only library key. Cloud ciphertext is not deleted. You will need another approved device or the recovery kit to reconnect.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            self?.runCloudTask(title: "Couldn’t Sign Out") {
                guard let self else { return }
                try await self.cloudBootstrap.signOutThisDevice()
                self.environment.syncCoordinator.reloadProviderSelection()
                self.tableView.reloadData()
            }
        })
        present(alert, animated: true)
    }

    private func runCloudTask(
        title: String,
        operation: @escaping @MainActor () async throws -> Void
    ) {
        Task { @MainActor [weak self] in
            do { try await operation() }
            catch { self?.showError(title: title, error: error) }
        }
    }

    private func presentActionSheet(_ alert: UIAlertController) {
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
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
        let alert = SyncResumeConfirmation.makeAlert(
            statusDescription: environment.syncCoordinator.statusDescription
        ) { [weak self] in
            self?.environment.syncCoordinator.clearHaltAfterUserReview()
        }
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
            ? "Turn off cloud sync first."
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
                // `SecureSnippetStore` scrubbed the sidecar on disk before deleting the
                // vault. Drop the bridge's same-process cache as the matching publication
                // step; otherwise a later opt-in can still project forgotten secure IDs.
                self.environment.syncLibrary.forgetSecureProjectionMetadata()
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

extension SettingsViewController: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        return view.window!
    }
}

@MainActor
private func requireDeviceOwnerAuthentication(reason: String) async throws {
    let context = LAContext()
    context.touchIDAuthenticationAllowableReuseDuration = 0
    var error: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
        throw error ?? SnippetsCloudAccountBootstrap.Failure.invalidState
    }
    guard try await context.evaluatePolicy(
        .deviceOwnerAuthentication,
        localizedReason: reason) else {
        throw SnippetsCloudAccountBootstrap.Failure.invalidState
    }
}

@MainActor
private final class CloudQRViewController: UIViewController {
    private let message: String
    private let payload: String
    private let displayedCode: String
    private let warning: String
    private let primaryTitle: String
    private let primary: () -> Void
    private let secondaryTitle: String?
    private let secondary: (() -> Void)?
    private let relocksWhenInactive: Bool
    private var inactivityObserver: NSObjectProtocol?

    init(
        title: String,
        message: String,
        payload: String,
        displayedCode: String,
        warning: String,
        primaryTitle: String,
        primary: @escaping () -> Void,
        secondaryTitle: String? = nil,
        secondary: (() -> Void)? = nil,
        relocksWhenInactive: Bool = false
    ) {
        self.message = message
        self.payload = payload
        self.displayedCode = displayedCode
        self.warning = warning
        self.primaryTitle = primaryTitle
        self.primary = primary
        self.secondaryTitle = secondaryTitle
        self.secondary = secondary
        self.relocksWhenInactive = relocksWhenInactive
        super.init(nibName: nil, bundle: nil)
        self.title = title
        modalPresentationStyle = .formSheet
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        view.isHidden = false
        guard relocksWhenInactive, inactivityObserver == nil else { return }
        inactivityObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Hide synchronously before the system captures the app-switcher image.
                self.view.isHidden = true
                self.dismiss(animated: false)
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let inactivityObserver {
            NotificationCenter.default.removeObserver(inactivityObserver)
            self.inactivityObserver = nil
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        let explanation = UILabel()
        explanation.text = message
        explanation.numberOfLines = 0
        explanation.textAlignment = .center
        explanation.font = .preferredFont(forTextStyle: .body)

        let imageView = UIImageView(image: Self.qrImage(payload))
        imageView.contentMode = .scaleAspectFit
        imageView.setContentHuggingPriority(.required, for: .vertical)
        imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor).isActive = true

        let code = UILabel()
        code.text = displayedCode
        code.numberOfLines = 0
        code.textAlignment = .center
        code.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        code.adjustsFontSizeToFitWidth = true
        code.minimumScaleFactor = 0.65
        code.accessibilityLabel = "Verification or recovery code"

        let warningLabel = UILabel()
        warningLabel.text = warning
        warningLabel.numberOfLines = 0
        warningLabel.textAlignment = .center
        warningLabel.font = .preferredFont(forTextStyle: .footnote)
        warningLabel.textColor = .systemRed

        let primaryButton = UIButton(type: .system)
        var primaryConfiguration = UIButton.Configuration.filled()
        primaryConfiguration.title = primaryTitle
        primaryButton.configuration = primaryConfiguration
        primaryButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            dismiss(animated: true, completion: primary)
        }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            explanation, imageView, code, warningLabel, primaryButton,
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        if let secondaryTitle, let secondary {
            let button = UIButton(type: .system)
            button.setTitle(secondaryTitle, for: .normal)
            button.setTitleColor(.systemRed, for: .normal)
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                dismiss(animated: true, completion: secondary)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            imageView.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    private static func qrImage(_ value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let image = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

@MainActor
private final class CloudQRScannerViewController:
    UIViewController, DataScannerViewControllerDelegate
{
    enum Mode { case pairing, recovery }

    private let mode: Mode
    private let completion: (String) -> Void
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .accurate,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: true,
        isHighlightingEnabled: true)
    private var completed = false

    init(mode: Mode, completion: @escaping (String) -> Void) {
        self.mode = mode
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = mode == .pairing ? "Scan New Device" : "Scan Recovery Kit"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        scanner.delegate = self
        addChild(scanner)
        scanner.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scanner.view)
        NSLayoutConstraint.activate([
            scanner.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scanner.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scanner.view.topAnchor.constraint(equalTo: view.topAnchor),
            scanner.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        scanner.stopScanning()
        super.viewWillDisappear(animated)
    }

    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        _ = dataScanner
        _ = allItems
        guard !completed else { return }
        for item in addedItems {
            guard case .barcode(let barcode) = item,
                  let payload = barcode.payloadStringValue,
                  !payload.isEmpty,
                  payload.utf8.count <= 4_096 else { continue }
            completed = true
            scanner.stopScanning()
            dismiss(animated: true) { [completion] in completion(payload) }
            return
        }
    }
}
