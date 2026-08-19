import UIKit
import AuthenticationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import Vision
import VisionKit

struct SettingsBackupActions {
    let importLibrary: () -> Void
    let exportForSharing: () -> Void
    let exportEncryptedBackup: () -> Void
}

final class SettingsViewController: UIViewController {
    private let environment: AppEnvironment
    private let backupActions: SettingsBackupActions
    private var phoneNavigationController: UINavigationController?
    private var splitController: UISplitViewController?

    init(environment: AppEnvironment, backupActions: SettingsBackupActions) {
        self.environment = environment
        self.backupActions = backupActions
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        preferredContentSize = CGSize(width: 900, height: 700)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        view.accessibilityIdentifier = "settings-root"

        let sidebar = SettingsSidebarViewController()
        sidebar.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )

        if traitCollection.userInterfaceIdiom == .phone {
            let navigation = UINavigationController(rootViewController: sidebar)
            AppTheme.configureNavigationBar(navigation.navigationBar)
            phoneNavigationController = navigation
            sidebar.onSelection = { [weak self, weak navigation] destination, rowID in
                guard let self else { return }
                navigation?.pushViewController(
                    self.makePane(destination: destination, highlightedRow: rowID),
                    animated: true
                )
            }
            embed(navigation)
        } else {
            let split = UISplitViewController(style: .doubleColumn)
            split.preferredDisplayMode = .oneBesideSecondary
            split.preferredSplitBehavior = .tile
            split.minimumPrimaryColumnWidth = 250
            split.maximumPrimaryColumnWidth = 340

            let primary = UINavigationController(rootViewController: sidebar)
            let initial = makePane(destination: .sync, highlightedRow: nil)
            let secondary = UINavigationController(rootViewController: initial)
            AppTheme.configureNavigationBar(primary.navigationBar)
            AppTheme.configureNavigationBar(secondary.navigationBar)
            split.setViewController(primary, for: .primary)
            split.setViewController(secondary, for: .secondary)
            splitController = split

            sidebar.onSelection = { [weak self, weak split] destination, rowID in
                guard let self else { return }
                let pane = self.makePane(destination: destination, highlightedRow: rowID)
                let navigation = UINavigationController(rootViewController: pane)
                AppTheme.configureNavigationBar(navigation.navigationBar)
                split?.setViewController(navigation, for: .secondary)
                split?.show(.secondary)
            }
            embed(split)
            sidebar.select(destination: .sync)
        }
    }

    private func embed(_ child: UIViewController) {
        addChild(child)
        child.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(child.view)
        NSLayoutConstraint.activate([
            child.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            child.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            child.view.topAnchor.constraint(equalTo: view.topAnchor),
            child.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        child.didMove(toParent: self)
    }

    private func makePane(
        destination: SettingsDestination,
        highlightedRow: SettingsRowID?
    ) -> UIViewController {
        switch destination {
        case .sync, .secureSnippets, .diagnostics:
            return SettingsPaneViewController(
                environment: environment,
                destination: destination,
                highlightedRow: highlightedRow
            )
        case .backup:
            return BackupSettingsViewController(actions: backupActions, highlightedRow: highlightedRow)
        case .about:
            return AboutSettingsViewController(highlightedRow: highlightedRow)
        case .general, .expansion, .integrations:
            preconditionFailure("macOS-only Settings destination used on iOS")
        }
    }
}

private final class SettingsSidebarViewController: UITableViewController, UISearchResultsUpdating {
    var onSelection: ((SettingsDestination, SettingsRowID?) -> Void)?

    private let navigationSections = SettingsCatalog.navigationSections(for: .iOS)
    private var searchResults: [SettingsSearchEntry] = []
    private var isSearching = false

    init() {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "destination")

        let search = UISearchController(searchResultsController: nil)
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Search Settings"
        search.searchBar.searchTextField.accessibilityIdentifier = "settings-search"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    func select(destination: SettingsDestination) {
        for (sectionIndex, section) in navigationSections.enumerated() {
            guard let row = section.destinations.firstIndex(of: destination) else { continue }
            tableView.selectRow(
                at: IndexPath(row: row, section: sectionIndex),
                animated: false,
                scrollPosition: .none
            )
            return
        }
    }

    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text ?? ""
        isSearching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        searchResults = isSearching ? SettingsCatalog.search(query, platform: .iOS) : []
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        isSearching ? 1 : navigationSections.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        isSearching ? "Search Results" : navigationSections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        isSearching ? searchResults.count : navigationSections[section].destinations.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: isSearching ? .subtitle : .default, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        if isSearching {
            let entry = searchResults[indexPath.row]
            cell.textLabel?.text = entry.title
            cell.detailTextLabel?.text = entry.destination.title
            cell.detailTextLabel?.textColor = .secondaryLabel
            cell.imageView?.image = UIImage(systemName: entry.destination.systemImageName)
            cell.accessibilityIdentifier = "settings-search-\(entry.rowID.rawValue)"
        } else {
            let destination = navigationSections[indexPath.section].destinations[indexPath.row]
            cell.textLabel?.text = destination.title
            cell.imageView?.image = UIImage(systemName: destination.systemImageName)
            cell.accessibilityIdentifier = "settings-destination-\(destination.rawValue)"
        }
        cell.imageView?.tintColor = AppTheme.tint
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        if isSearching {
            let result = searchResults[indexPath.row]
            onSelection?(result.destination, result.rowID)
        } else {
            let destination = navigationSections[indexPath.section].destinations[indexPath.row]
            onSelection?(destination, nil)
        }
    }
}

private final class BackupSettingsViewController: UITableViewController {
    private enum Row: Int, CaseIterable {
        case importLibrary
        case exportForSharing
        case exportEncryptedBackup
    }

    private let actions: SettingsBackupActions
    private let highlightedRow: SettingsRowID?

    init(actions: SettingsBackupActions, highlightedRow: SettingsRowID?) {
        self.actions = actions
        self.highlightedRow = highlightedRow
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SettingsDestination.backup.title
        navigationItem.largeTitleDisplayMode = .never
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let highlightedRow,
              let row = row(for: highlightedRow) else { return }
        let indexPath = IndexPath(row: row.rawValue, section: 0)
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { Row.allCases.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Exports for sharing are readable JSON. Use an encrypted backup for safekeeping."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row)!
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        switch row {
        case .importLibrary:
            cell.textLabel?.text = "Import Library"
            cell.detailTextLabel?.text = "Add snippets from a JSON library or restore an encrypted archive."
            cell.imageView?.image = UIImage(systemName: "square.and.arrow.down")
        case .exportForSharing:
            cell.textLabel?.text = "Export for Sharing"
            cell.detailTextLabel?.text = "Create a readable JSON copy of the library."
            cell.imageView?.image = UIImage(systemName: "square.and.arrow.up")
        case .exportEncryptedBackup:
            cell.textLabel?.text = "Export Encrypted Backup"
            cell.detailTextLabel?.text = "Create a password-protected archive."
            cell.imageView?.image = UIImage(systemName: "lock.doc")
        }
        cell.accessibilityIdentifier = "settings-backup-\(row)"
        cell.detailTextLabel?.numberOfLines = 0
        cell.imageView?.tintColor = AppTheme.tint
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .importLibrary: actions.importLibrary()
        case .exportForSharing: actions.exportForSharing()
        case .exportEncryptedBackup: actions.exportEncryptedBackup()
        }
    }

    private func row(for rowID: SettingsRowID) -> Row? {
        switch rowID {
        case .importLibrary: .importLibrary
        case .exportSharing: .exportForSharing
        case .encryptedBackup: .exportEncryptedBackup
        default: nil
        }
    }
}

private final class AboutSettingsViewController: UITableViewController {
    private let highlightedRow: SettingsRowID?

    init(highlightedRow: SettingsRowID?) {
        self.highlightedRow = highlightedRow
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = SettingsDestination.about.title
        navigationItem.largeTitleDisplayMode = .never
        tableView.tableHeaderView = makeHeader()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.tintColor = AppTheme.tint
        if indexPath.row == 0 {
            cell.textLabel?.text = "View on GitHub"
            cell.detailTextLabel?.text = "Source code, releases, and issue tracker"
            cell.imageView?.image = UIImage(systemName: "safari")
        } else {
            cell.textLabel?.text = "MIT License"
            cell.detailTextLabel?.text = "Open-source license"
            cell.imageView?.image = UIImage(systemName: "doc.text")
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let urlString = indexPath.row == 0
            ? "https://github.com/wowlocal/snippets"
            : "https://github.com/wowlocal/snippets/blob/main/LICENSE"
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if highlightedRow == .version, let header = tableView.tableHeaderView {
            header.alpha = 0.35
            UIView.animate(withDuration: 0.55) { header.alpha = 1 }
            return
        }
        guard highlightedRow == .projectLink else { return }
        let indexPath = IndexPath(row: 0, section: 0)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .middle)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 180))
        let icon = UIImageView(
            image: UIImage(named: "AppIcon") ?? UIImage(systemName: "text.quote")
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.layer.cornerRadius = 18
        icon.clipsToBounds = true
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Snippets"
        title.font = .preferredFont(forTextStyle: .title1)
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        let versionLabel = UILabel()
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        versionLabel.text = "Version \(version) (\(build))"
        versionLabel.textColor = .secondaryLabel
        versionLabel.font = .preferredFont(forTextStyle: .subheadline)
        let labels = UIStackView(arrangedSubviews: [title, versionLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 4
        header.addSubview(icon)
        header.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 92),
            icon.heightAnchor.constraint(equalToConstant: 92),
            icon.leadingAnchor.constraint(equalTo: header.layoutMarginsGuide.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 20),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: header.layoutMarginsGuide.trailingAnchor),
            labels.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
        ])
        return header
    }
}

final class SettingsPaneViewController: UITableViewController, UIDocumentPickerDelegate {
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
        case syncRecovery
        case vaultStatus
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
    private let destination: SettingsDestination
    private let highlightedRow: SettingsRowID?
    private var didRevealHighlightedRow = false
    private var temporaryExportURL: URL?
    private var syncObservation: UUID?
    private lazy var cloudBootstrap = SnippetsCloudAccountBootstrap(
        selection: environment.backendSelection)

    private var visibleSections: [Section] {
        switch destination {
        case .sync: [.sync]
        case .secureSnippets: [.security]
        case .diagnostics: [.diagnostics]
        case .general, .expansion, .backup, .integrations, .about: []
        }
    }

    init(
        environment: AppEnvironment,
        destination: SettingsDestination,
        highlightedRow: SettingsRowID?
    ) {
        self.environment = environment
        self.destination = destination
        self.highlightedRow = highlightedRow
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = destination.title
        navigationItem.largeTitleDisplayMode = .never
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
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        revealHighlightedRowIfNeeded()
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

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        visibleSections[section].title
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows(in: visibleSections[section]).count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows(in: visibleSections[indexPath.section])[indexPath.row]
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
            cell.detailTextLabel?.text = environment.backendSelection.snippetsCloudEnabled
                ? "Encrypted before it is sent. Only one cloud provider is writable at a time."
                : "Encrypted before it is sent to iCloud."
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
        case .syncRecovery:
            if let action = environment.syncCoordinator.recoveryAction {
                cell.textLabel?.text = action.buttonTitle
                cell.detailTextLabel?.text = action.explanation
            }
            cell.imageView?.image = UIImage(systemName: "exclamationmark.shield")
            cell.textLabel?.textColor = AppTheme.warning
        case .vaultStatus:
            cell.textLabel?.text = "Secure Snippets Status"
            if !environment.secureStore.hasVault {
                cell.detailTextLabel?.text = "Not set up. Make any snippet secure to create your encrypted vault."
            } else if environment.vaultSession.state.isUnlocked {
                cell.detailTextLabel?.text = "Unlocked for this session. Secure snippets still authenticate before reveal or insertion."
            } else {
                cell.detailTextLabel?.text = "Locked. Secure snippets stay encrypted until you authenticate."
            }
            cell.imageView?.image = UIImage(
                systemName: environment.vaultSession.state.isUnlocked ? "lock.open" : "lock"
            )
            cell.selectionStyle = .none
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
            cell.detailTextLabel?.text = "Plaintext JSON Lines. Operation counts, CloudKit "
                + "callback and scheduler states, and secure-snippet keywords may be included; "
                + "bodies, names, tags, IDs, paths, keys and ciphertext are excluded."
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
        let row = rows(in: visibleSections[indexPath.section])[indexPath.row]
        switch row {
        case .syncProvider:
            chooseSyncProvider()
        case .syncNow:
            environment.syncCoordinator.syncNow()
        case .syncRecovery:
            performSyncRecovery()
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
            var rows: [Row] = environment.backendSelection.snippetsCloudEnabled
                ? [.syncProvider, .syncToggle, .syncStatus]
                : [.syncToggle, .syncStatus]
            if environment.syncCoordinator.recoveryAction != nil {
                rows.append(.syncRecovery)
            } else if environment.syncCoordinator.canRequestManualSync {
                rows.append(.syncNow)
            }
            return rows
        case .security:
            var rows: [Row] = [.vaultStatus, .keychainStatus]
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

    private func revealHighlightedRowIfNeeded() {
        guard !didRevealHighlightedRow, let highlightedRow else { return }
        didRevealHighlightedRow = true

        let candidateIDs: Set<SettingsRowID> = switch highlightedRow {
        case .cloudAccount: [.cloudProvider, .syncEnabled]
        case .vaultSetup: [.vaultStatus]
        case .recoveryKey, .restoreRecovery, .forgetVault: [highlightedRow, .vaultStatus]
        default: [highlightedRow]
        }

        for (sectionIndex, section) in visibleSections.enumerated() {
            let sectionRows = rows(in: section)
            guard let rowIndex = sectionRows.firstIndex(where: {
                candidateIDs.contains(settingsRowID(for: $0))
            }) else { continue }
            reveal(indexPath: IndexPath(row: rowIndex, section: sectionIndex))
            return
        }

        if let firstSection = visibleSections.first, !rows(in: firstSection).isEmpty {
            reveal(indexPath: IndexPath(row: 0, section: 0))
        }
    }

    private func reveal(indexPath: IndexPath) {
        tableView.scrollToRow(at: indexPath, at: .middle, animated: true)
        tableView.selectRow(at: indexPath, animated: true, scrollPosition: .none)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            self?.tableView.deselectRow(at: indexPath, animated: true)
        }
    }

    private func settingsRowID(for row: Row) -> SettingsRowID {
        switch row {
        case .syncProvider: .cloudProvider
        case .syncToggle: .syncEnabled
        case .syncStatus: .syncStatus
        case .syncNow: .syncNow
        case .syncRecovery: .syncRecovery
        case .vaultStatus: .vaultStatus
        case .keychainStatus: .keyStorage
        case .lockVault: .lockVault
        case .addRecovery: .recoveryKey
        case .restoreRecovery: .restoreRecovery
        case .forgetVault: .forgetVault
        case .diagnosticsStatus: .persistentLogs
        case .exportDiagnostics: .exportLogs
        case .deleteDiagnostics: .deleteLogs
        }
    }

    private func chooseSyncProvider() {
        let selection = environment.backendSelection
        guard selection.snippetsCloudEnabled else { return }
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
        if selection.cloudCredentialResetRequired {
            alert.addAction(UIAlertAction(
                title: "Reset Unreadable Cloud Sign-In",
                style: .destructive
            ) { [weak self] _ in
                self?.confirmUnreadableCloudCredentialReset()
            })
        } else if selection.hasPendingRemoteRevocation || selection.hasPendingLocalErase {
            alert.addAction(UIAlertAction(
                title: "Retry Sign Out",
                style: .destructive
            ) { [weak self] _ in
                self?.retryInterruptedCloudSignOut()
            })
        } else if selection.hasCloudSession {
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
        guard selection.snippetsCloudEnabled else { return }
        if selection.cloudCredentialResetRequired {
            confirmUnreadableCloudCredentialReset()
            return
        }
        if selection.hasPendingRemoteRevocation || selection.hasPendingLocalErase {
            retryInterruptedCloudSignOut()
            return
        }
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

    private func confirmUnreadableCloudCredentialReset() {
        let alert = UIAlertController(
            title: "Reset Unreadable Cloud Sign-In?",
            message: "Snippets cannot verify the saved sign-in history or prove that every older token was revoked. First revoke Snippets in your identity provider’s connected-app settings. Reset removes this device’s cloud login and device-only library key; local snippets and cloud ciphertext are not deleted.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset This Device", style: .destructive) {
            [weak self] _ in
            guard let self else { return }
            runCloudTask(title: "Couldn’t Reset Cloud Sign-In") {
                try await self.environment.syncCoordinator.withQuiescedCloudTransport {
                    try self.cloudBootstrap.resetUnreadableCredentialsOnThisDevice()
                }
                self.tableView.reloadData()
            }
        })
        present(alert, animated: true)
    }

    private func retryInterruptedCloudSignOut() {
        runCloudTask(title: "Couldn’t Finish Signing Out") { [weak self] in
            guard let self else { return }
            try await environment.syncCoordinator.withQuiescedCloudTransport {
                try await self.cloudBootstrap.signOutThisDevice()
            }
            tableView.reloadData()
        }
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
                try await self.environment.syncCoordinator.withQuiescedCloudTransport {
                    try await self.cloudBootstrap.signOutThisDevice()
                }
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

    private func performSyncRecovery() {
        // Startup prerequisites such as a temporarily unreadable sync key use
        // `needsAttention` with Check Again rather than a sticky halt. The coordinator
        // owns exact action validation for both state shapes.
        guard let action = environment.syncCoordinator.recoveryAction else { return }

        guard action.confirmationTitle != nil else {
            environment.syncCoordinator.performRecovery(action)
            tableView.reloadData()
            return
        }
        let alert = SyncRecoveryConfirmation.makeAlert(
            action: action,
            statusDescription: environment.syncCoordinator.statusDescription
        ) { [weak self] in
            self?.environment.syncCoordinator.performRecovery(action)
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

extension SettingsPaneViewController: ASWebAuthenticationPresentationContextProviding {
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
