import UIKit

@MainActor
protocol PhoneLibraryViewControllerDelegate: AnyObject {
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedCopy id: UUID)
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedEdit id: UUID)
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedPin id: UUID)
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedDelete id: UUID)
    func phoneLibrary(_ controller: PhoneLibraryViewController, requestedDuplicate id: UUID)
    func phoneLibraryRequestedNewSnippet(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedClipboardSnippet(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedImport(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedExport(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedEncryptedBackup(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedSync(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedSettings(_ controller: PhoneLibraryViewController)
    func phoneLibraryRequestedConnectICloud(_ controller: PhoneLibraryViewController)
}

final class PhoneLibraryViewController: UIViewController {
    private struct Section {
        let title: String
        let snippets: [Snippet]
    }

    private enum DefaultsKey {
        static let showedGestureCoaching = "SnippetsPhoneGestureCoachingShown"
    }

    weak var delegate: PhoneLibraryViewControllerDelegate?

    private let environment: AppEnvironment
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let emptyView = PhoneEmptyLibraryView()
    private let syncStatusBanner = PhoneSyncStatusBanner()
    private let contentStack = UIStackView()
    private let filterButton = UIButton(type: .system)
    private let toastPresenter = PhoneToastPresenter()
    private var filterItem: UIBarButtonItem?
    private var activeTagKeys = Set<String>()
    private var sections: [Section] = []
    private var syncObservation: UUID?
    private var pendingCoachingWorkItem: DispatchWorkItem?
    private var hasCompletedSync: Bool

    init(environment: AppEnvironment) {
        self.environment = environment
        hasCompletedSync = FileManager.default.fileExists(
            atPath: SnippetStorageLocations.syncBaseFileURL.path
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true

        configureSearch()
        configureNavigationMenu()
        configureTable()
        configureEmptyView()
        configureToolbar()

        syncObservation = environment.syncCoordinator.addStateObserver { [weak self] state in
            guard let self else { return }
            if case .idle(let lastSync) = state, lastSync != nil {
                self.hasCompletedSync = true
            }
            self.configureNavigationMenu()
            self.updateSyncPresentation()
            self.updateEmptyState()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true, let syncObservation {
            environment.syncCoordinator.removeStateObserver(syncObservation)
            self.syncObservation = nil
        }
    }

    func reload() {
        let existingTags = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTags)

        let results = SnippetLibraryQuery.results(
            in: environment.store.snippetsSortedForDisplay(),
            searchText: searchController.searchBar.text ?? "",
            activeTagKeys: activeTagKeys
        )
        sections = []
        if !results.pinned.isEmpty {
            sections.append(Section(title: "Pinned", snippets: results.pinned))
        }
        if !results.snippets.isEmpty {
            sections.append(Section(title: "Snippets", snippets: results.snippets))
        }

        tableView.reloadData()
        updateFilterItem()
        configureNavigationMenu()
        updateSyncPresentation()
        updateEmptyState()
    }

    /// Restores a neutral Library before routing to content from outside the current
    /// search/filter flow (for example, after the user accepts an incoming share link).
    func clearActiveQuery() {
        searchController.searchBar.text = nil
        searchController.isActive = false
        activeTagKeys.removeAll()
        reload()
    }

    func showCopyResult(_ result: SnippetActionService.CopyResult) {
        switch result {
        case .copied(let name, let secure):
            let detail = secure ? " Secure clipboard expires in 60 seconds." : ""
            toastPresenter.show(message: "Copied “\(name)”.\(detail)")
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            scheduleGestureCoachingIfNeeded()
        case .empty(let name):
            toastPresenter.show(message: "“\(name)” has no content to copy.")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }

    func showStatus(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        toastPresenter.show(message: message, actionTitle: actionTitle, action: action)
    }

    func selectSearch() {
        searchController.isActive = true
        searchController.searchBar.searchTextField.becomeFirstResponder()
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search snippets"
        searchController.searchBar.accessibilityIdentifier = "phone-snippet-search"
        searchController.searchBar.searchTextField.accessibilityIdentifier = "phone-snippet-search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .integrated
        definesPresentationContext = true
    }

    private func configureNavigationMenu() {
        let syncTitle = SyncCoordinator.isEnabled ? "Sync Now" : "Connect iCloud"
        let syncImage = SyncCoordinator.isEnabled ? "arrow.triangle.2.circlepath" : "icloud"
        let menu = UIMenu(children: [
            UIAction(title: "New from Clipboard", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibraryRequestedClipboardSnippet(self)
            },
            UIMenu(title: "Transfer", image: UIImage(systemName: "arrow.left.arrow.right"), children: [
                UIAction(title: "Import", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.phoneLibraryRequestedImport(self)
                },
                UIAction(title: "Export for Sharing", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.phoneLibraryRequestedExport(self)
                },
                UIAction(title: "Encrypted Backup", image: UIImage(systemName: "lock.doc")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.phoneLibraryRequestedEncryptedBackup(self)
                },
            ]),
            UIAction(title: syncTitle, image: UIImage(systemName: syncImage)) { [weak self] _ in
                guard let self else { return }
                if SyncCoordinator.isEnabled {
                    self.delegate?.phoneLibraryRequestedSync(self)
                } else {
                    self.delegate?.phoneLibraryRequestedConnectICloud(self)
                }
            },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibraryRequestedSettings(self)
            },
        ])
        let item = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: menu)
        item.accessibilityLabel = "More"
        navigationItem.rightBarButtonItem = item
    }

    private func configureToolbar() {
        var filterConfiguration = UIButton.Configuration.plain()
        filterConfiguration.image = UIImage(systemName: "line.3.horizontal.decrease.circle")
        filterConfiguration.imagePadding = 4
        filterConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 6,
            leading: 8,
            bottom: 6,
            trailing: 8
        )
        filterButton.configuration = filterConfiguration
        filterButton.accessibilityIdentifier = "phone-tag-filter"
        filterButton.accessibilityLabel = "Filter by tags"
        filterButton.accessibilityHint = "Shows the available tag filters"
        filterButton.addAction(
            UIAction { [weak self] _ in self?.showFilters() },
            for: .touchUpInside
        )
        NSLayoutConstraint.activate([
            filterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            filterButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        let filter = UIBarButtonItem(customView: filterButton)
        filterItem = filter

        let add = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibraryRequestedNewSnippet(self)
            }
        )
        add.accessibilityIdentifier = "phone-new-snippet"

        toolbarItems = [
            filter,
            UIBarButtonItem(systemItem: .flexibleSpace),
            navigationItem.searchBarPlacementBarButtonItem,
            UIBarButtonItem(systemItem: .flexibleSpace),
            add,
        ]
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.backgroundColor = .clear
        tableView.keyboardDismissMode = .onDrag
        tableView.sectionHeaderTopPadding = 8
        tableView.estimatedRowHeight = 82
        tableView.rowHeight = UITableView.automaticDimension
        tableView.register(PhoneSnippetCell.self, forCellReuseIdentifier: PhoneSnippetCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "phone-snippet-list"

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            self?.requestedRefresh()
        }, for: .valueChanged)
        tableView.refreshControl = refresh

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.addArrangedSubview(syncStatusBanner)
        contentStack.addArrangedSubview(tableView)
        view.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // The table background is a real interactive onboarding surface. Unlike
            // table rows, UIKit does not automatically inset that background around a
            // translucent navigation bar and toolbar, so constrain the whole library
            // surface to the safe area to prevent large text/actions from sitting under
            // either bar.
            contentStack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
        toastPresenter.install(in: view)
    }

    private func configureEmptyView() {
        emptyView.onConnect = { [weak self] in
            guard let self else { return }
            self.delegate?.phoneLibraryRequestedConnectICloud(self)
        }
        emptyView.onSync = { [weak self] in
            guard let self else { return }
            self.delegate?.phoneLibraryRequestedSync(self)
        }
        emptyView.onCreate = { [weak self] in
            guard let self else { return }
            self.delegate?.phoneLibraryRequestedNewSnippet(self)
        }
        emptyView.onImport = { [weak self] in
            guard let self else { return }
            self.delegate?.phoneLibraryRequestedImport(self)
        }
        emptyView.onClearFilters = { [weak self] in
            guard let self else { return }
            self.activeTagKeys.removeAll()
            self.reload()
            UIAccessibility.post(notification: .announcement, argument: "Tag filters cleared")
        }
    }

    private func updateFilterItem() {
        let count = activeTagKeys.count
        var configuration = filterButton.configuration ?? .plain()
        configuration.image = UIImage(
            systemName: count == 0
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill"
        )
        // The count is intentionally visible rather than encoded only by the filled
        // symbol. That makes a narrowed library apparent without opening the sheet.
        configuration.title = count == 0 ? nil : "\(count)"
        filterButton.configuration = configuration
        filterButton.accessibilityValue = count == 0
            ? "No active filters"
            : "\(count) active filter\(count == 1 ? "" : "s")"
        filterItem?.accessibilityValue = filterButton.accessibilityValue
    }

    private func updateEmptyState() {
        guard sections.isEmpty else {
            tableView.backgroundView = nil
            return
        }

        let libraryIsEmpty = environment.store.snippetsSortedForDisplay().isEmpty
        let hasQuery = !(searchController.searchBar.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if libraryIsEmpty {
            if isAwaitingFirstFetch {
                emptyView.configureFirstFetch(
                    syncStatus: firstFetchStatus,
                    canRetry: !environment.syncCoordinator.state.isSyncing
                )
            } else {
                emptyView.configureEmptyLibrary(
                    offersICloud: !SyncCoordinator.isEnabled,
                    syncStatus: environment.syncCoordinator.statusDescription
                )
            }
        } else if hasQuery {
            emptyView.configureNoResults(
                title: "No Results",
                message: activeTagKeys.isEmpty
                    ? "Try a different search."
                    : "Try changing the search or clearing a tag filter.",
                offersClearFilters: !activeTagKeys.isEmpty
            )
        } else {
            emptyView.configureNoResults(
                title: "No Snippets Match",
                message: "Clear a tag filter to see more snippets.",
                offersClearFilters: true
            )
        }
        tableView.backgroundView = emptyView
    }

    private var isAwaitingFirstFetch: Bool {
        SyncCoordinator.isEnabled && !hasCompletedSync
    }

    private var firstFetchStatus: String {
        switch environment.syncCoordinator.state {
        case .disabled, .idle(lastSync: nil):
            return "Preparing the first iCloud fetch. Your local library will stay empty until it finishes."
        case .syncing:
            return "Checking iCloud for the library from your other devices."
        case .offline, .needsAuthentication, .waitingForVault, .halted:
            return "The first fetch has not finished. \(environment.syncCoordinator.statusDescription)"
        case .idle(lastSync: _):
            return environment.syncCoordinator.statusDescription
        }
    }

    private func updateSyncPresentation() {
        guard SyncCoordinator.isEnabled else {
            syncStatusBanner.isHidden = true
            return
        }

        syncStatusBanner.isHidden = false
        syncStatusBanner.configure(
            state: environment.syncCoordinator.state,
            status: environment.syncCoordinator.statusDescription,
            isFirstFetch: !hasCompletedSync
        )
    }

    private func requestedRefresh() {
        guard SyncCoordinator.isEnabled else {
            finishRefresh()
            confirmSyncEnablementForRefresh()
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRefresh() }
            // The request completes after the requested round (including a coalesced
            // replay). Halt/backoff no-ops complete with their final state, while an
            // unavailable start returns immediately as not-started. The spinner follows
            // the real lifecycle rather than a timer in every case.
            _ = await self.environment.syncCoordinator.requestSync(trigger: .manual)
        }
    }

    private func finishRefresh() {
        tableView.refreshControl?.endRefreshing()
    }

    private func confirmSyncEnablementForRefresh() {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Turn On iCloud Sync?",
            message: "Pull to refresh uses iCloud. Snippets encrypts records before uploading them, and you can turn sync off later in Settings.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        alert.addAction(UIAlertAction(title: "Turn On", style: .default) { [weak self] _ in
            guard let self else { return }
            self.delegate?.phoneLibraryRequestedConnectICloud(self)
        })
        present(alert, animated: true)
    }

    private func showFilters() {
        let controller = PhoneTagFilterViewController(
            tags: environment.store.tagUsage(),
            activeKeys: activeTagKeys
        )
        controller.onChange = { [weak self] keys in
            self?.activeTagKeys = keys
            self?.reload()
        }
        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    private func snippet(at indexPath: IndexPath) -> Snippet {
        sections[indexPath.section].snippets[indexPath.row]
    }

    private func scheduleGestureCoachingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.showedGestureCoaching) else { return }
        UserDefaults.standard.set(true, forKey: DefaultsKey.showedGestureCoaching)
        pendingCoachingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.toastPresenter.show(
                message: "Tip: swipe right to pin. Swipe left to edit or delete.",
                duration: 5
            )
        }
        pendingCoachingWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4, execute: workItem)
    }

    private func contextMenu(for snippet: Snippet) -> UIMenu {
        let isSecure = environment.store.isSecure(snippet.id)
        var actions: [UIMenuElement] = [
            UIAction(title: "Copy", image: UIImage(systemName: isSecure ? "faceid" : "doc.on.doc")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibrary(self, requestedCopy: snippet.id)
            },
            UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibrary(self, requestedEdit: snippet.id)
            },
            UIAction(
                title: snippet.isPinned ? "Unpin" : "Pin",
                image: UIImage(systemName: snippet.isPinned ? "pin.slash" : "pin")
            ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibrary(self, requestedPin: snippet.id)
            },
        ]
        if !isSecure {
            actions.append(UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.phoneLibrary(self, requestedDuplicate: snippet.id)
            })
        }
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            self.delegate?.phoneLibrary(self, requestedDelete: snippet.id)
        })
        return UIMenu(children: actions)
    }
}

extension PhoneLibraryViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        reload()
    }
}

extension PhoneLibraryViewController: UITableViewDataSource, UITableViewDelegate {
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].snippets.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PhoneSnippetCell.reuseIdentifier,
            for: indexPath
        ) as! PhoneSnippetCell
        let snippet = snippet(at: indexPath)
        cell.configure(snippet: snippet, isSecure: environment.store.isSecure(snippet.id))
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Copy") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.phoneLibrary(self, requestedCopy: snippet.id)
                return true
            },
            UIAccessibilityCustomAction(name: "Edit") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.phoneLibrary(self, requestedEdit: snippet.id)
                return true
            },
            UIAccessibilityCustomAction(name: snippet.isPinned ? "Unpin" : "Pin") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.phoneLibrary(self, requestedPin: snippet.id)
                return true
            },
            UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in
                guard let self else { return false }
                self.delegate?.phoneLibrary(self, requestedDelete: snippet.id)
                return true
            },
        ]
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        delegate?.phoneLibrary(self, requestedCopy: snippet(at: indexPath).id)
    }

    func tableView(
        _ tableView: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        let snippet = snippet(at: indexPath)
        return UIContextMenuConfiguration(identifier: snippet.id as NSUUID, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: snippet)
        }
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let snippet = snippet(at: indexPath)
        let pin = UIContextualAction(
            style: .normal,
            title: snippet.isPinned ? "Unpin" : "Pin"
        ) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.delegate?.phoneLibrary(self, requestedPin: snippet.id)
            completion(true)
        }
        pin.image = UIImage(systemName: snippet.isPinned ? "pin.slash" : "pin")
        pin.backgroundColor = AppTheme.tint
        let configuration = UISwipeActionsConfiguration(actions: [pin])
        configuration.performsFirstActionWithFullSwipe = true
        return configuration
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let snippet = snippet(at: indexPath)
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.delegate?.phoneLibrary(self, requestedDelete: snippet.id)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.delegate?.phoneLibrary(self, requestedEdit: snippet.id)
            completion(true)
        }
        edit.image = UIImage(systemName: "pencil")
        edit.backgroundColor = AppTheme.tint
        let configuration = UISwipeActionsConfiguration(actions: [delete, edit])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private final class PhoneSnippetCell: UITableViewCell {
    static let reuseIdentifier = "PhoneSnippetCell"

    private let secureSymbolView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let pinnedSymbolView = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let disabledSymbolView = UIImageView(image: UIImage(systemName: "pause.circle.fill"))
    private let statusSymbols = UIStackView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let tagsStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .secondarySystemGroupedBackground

        secureSymbolView.tintColor = AppTheme.warning
        pinnedSymbolView.tintColor = AppTheme.tint
        disabledSymbolView.tintColor = .secondaryLabel
        [secureSymbolView, pinnedSymbolView, disabledSymbolView].forEach { symbol in
            symbol.contentMode = .scaleAspectFit
            symbol.setContentHuggingPriority(.required, for: .horizontal)
            symbol.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                symbol.widthAnchor.constraint(equalToConstant: 16),
                symbol.heightAnchor.constraint(equalToConstant: 16),
            ])
        }
        statusSymbols.axis = .horizontal
        statusSymbols.spacing = 5
        statusSymbols.alignment = .center
        [secureSymbolView, pinnedSymbolView, disabledSymbolView]
            .forEach(statusSymbols.addArrangedSubview)

        nameLabel.font = AppTheme.scaledFont(size: 16, weight: .semibold, textStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 0

        detailLabel.font = AppTheme.scaledFont(size: 13, textStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2

        tagsStack.axis = .horizontal
        tagsStack.spacing = 5
        tagsStack.alignment = .center

        let titleRow = UIStackView(arrangedSubviews: [statusSymbols, nameLabel])
        titleRow.axis = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .center
        let stack = UIStackView(arrangedSubviews: [titleRow, detailLabel, tagsStack])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 4
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: PhoneSnippetCell, _: UITraitCollection) in
            cell.updateTagLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snippet: Snippet, isSecure: Bool) {
        nameLabel.text = snippet.displayName
        secureSymbolView.isHidden = !isSecure
        pinnedSymbolView.isHidden = !snippet.isPinned
        disabledSymbolView.isHidden = snippet.isEnabled
        statusSymbols.isHidden = !isSecure && !snippet.isPinned && snippet.isEnabled

        let keyword = snippet.normalizedKeyword.isEmpty ? nil : "\\\(snippet.normalizedKeyword)"
        let firstLine = snippet.contentFirstLine
        let statePrefix = snippet.isEnabled ? "" : "Disabled · "
        if isSecure {
            detailLabel.text = statePrefix + (keyword.map { "Secure · \($0)" } ?? "Secure snippet")
        } else if let keyword, !firstLine.isEmpty {
            detailLabel.text = "\(statePrefix)\(keyword) · \(firstLine)"
        } else {
            detailLabel.text = statePrefix + (keyword ?? (firstLine.isEmpty ? "No content" : firstLine))
        }
        contentView.alpha = 1
        nameLabel.textColor = snippet.isEnabled ? .label : .secondaryLabel
        detailLabel.textColor = snippet.isEnabled ? .secondaryLabel : .tertiaryLabel

        tagsStack.arrangedSubviews.forEach { view in
            tagsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for tag in snippet.tags.prefix(3) {
            let label = PhoneTagPillLabel()
            label.configure(tag: tag)
            tagsStack.addArrangedSubview(label)
        }
        if snippet.tags.count > 3 {
            let more = UILabel()
            more.font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
            more.textColor = .secondaryLabel
            more.text = "+\(snippet.tags.count - 3)"
            tagsStack.addArrangedSubview(more)
        }
        tagsStack.isHidden = snippet.tags.isEmpty
        updateTagLayout()

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = snippet.displayName
        accessibilityValue = [
            isSecure ? "Secure" : "Standard",
            snippet.isPinned ? "Pinned" : nil,
            snippet.isEnabled ? "Enabled" : "Disabled",
            keyword.map { "Keyword \($0)" },
            snippet.tags.isEmpty ? nil : "Tags: \(snippet.tags.joined(separator: ", "))",
        ].compactMap { $0 }.joined(separator: ", ")
        accessibilityHint = isSecure
            ? "Double tap to authenticate and copy"
            : "Double tap to copy"
    }

    private func updateTagLayout() {
        let usesVerticalTags = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        tagsStack.axis = usesVerticalTags ? .vertical : .horizontal
        tagsStack.alignment = usesVerticalTags ? .leading : .center
    }
}

private final class PhoneTagPillLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        numberOfLines = 1
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + insets.left + insets.right,
            height: size.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    func configure(tag: String) {
        text = tag
        textColor = AppTheme.tagColor(for: tag)
        backgroundColor = AppTheme.tagFillColor(for: tag)
    }
}

private final class PhoneEmptyLibraryView: UIView {
    var onConnect: (() -> Void)?
    var onSync: (() -> Void)?
    var onCreate: (() -> Void)?
    var onImport: (() -> Void)?
    var onClearFilters: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let connectButton = UIButton(type: .system)
    private let createButton = UIButton(type: .system)
    private let importButton = UIButton(type: .system)
    private let clearFiltersButton = UIButton(type: .system)
    private let actions = UIStackView()
    private let stack = UIStackView()
    private var primaryButtonStartsSync = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        contentView.translatesAutoresizingMaskIntoConstraints = false

        imageView.image = UIImage(systemName: "text.page")
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 36, weight: .regular)
        imageView.tintColor = AppTheme.tint
        imageView.contentMode = .scaleAspectFit
        imageView.setContentHuggingPriority(.required, for: .vertical)

        titleLabel.font = AppTheme.scaledFont(size: 20, weight: .bold, textStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "phone-empty-title"

        messageLabel.font = AppTheme.scaledFont(size: 15, textStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "phone-empty-message"

        configureButton(connectButton, title: "Connect iCloud", symbol: "icloud", prominent: true) { [weak self] in
            guard let self else { return }
            if self.primaryButtonStartsSync {
                self.onSync?()
            } else {
                self.onConnect?()
            }
        }
        connectButton.accessibilityIdentifier = "phone-connect-icloud"
        configureButton(createButton, title: "Create Snippet", symbol: "plus", prominent: false) { [weak self] in
            self?.onCreate?()
        }
        createButton.accessibilityIdentifier = "phone-empty-create"
        configureButton(importButton, title: "Import", symbol: "square.and.arrow.down", prominent: false) { [weak self] in
            self?.onImport?()
        }
        configureButton(
            clearFiltersButton,
            title: "Clear Filters",
            symbol: "line.3.horizontal.decrease.circle",
            prominent: true
        ) { [weak self] in
            self?.onClearFilters?()
        }
        clearFiltersButton.accessibilityIdentifier = "phone-clear-filters"

        actions.axis = .vertical
        actions.spacing = 10
        actions.alignment = .fill
        [connectButton, createButton, importButton, clearFiltersButton]
            .forEach(actions.addArrangedSubview)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        [imageView, titleLabel, messageLabel, actions].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(18, after: messageLabel)

        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            contentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -24),
            actions.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            actions.centerXAnchor.constraint(equalTo: stack.centerXAnchor),
        ])
        let centered = stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor, constant: -20)
        centered.priority = .defaultHigh
        centered.isActive = true

        updateForContentSizeCategory()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: PhoneEmptyLibraryView, _: UITraitCollection) in
            view.updateForContentSizeCategory()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureEmptyLibrary(offersICloud: Bool, syncStatus: String) {
        primaryButtonStartsSync = false
        imageView.image = UIImage(systemName: offersICloud ? "icloud.and.arrow.down" : "text.page")
        titleLabel.text = offersICloud ? "Bring Your Library to iPhone" : "Your Library Is Empty"
        messageLabel.text = offersICloud
            ? "Connect iCloud to fetch the library you already use on Mac and iPad."
            : "\(syncStatus) You can also create a snippet on this device."
        connectButton.isHidden = !offersICloud
        connectButton.configuration?.title = "Connect iCloud"
        connectButton.configuration?.image = UIImage(systemName: "icloud")
        connectButton.accessibilityIdentifier = "phone-connect-icloud"
        createButton.isHidden = false
        importButton.isHidden = false
        clearFiltersButton.isHidden = true
        actions.isHidden = false
    }

    func configureFirstFetch(syncStatus: String, canRetry: Bool) {
        primaryButtonStartsSync = true
        imageView.image = UIImage(systemName: "icloud.and.arrow.down")
        titleLabel.text = canRetry ? "Library Hasn’t Been Fetched" : "Fetching Your Library"
        messageLabel.text = syncStatus
        connectButton.configuration?.title = "Try Again"
        connectButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        connectButton.accessibilityIdentifier = "phone-sync-now"
        connectButton.isHidden = !canRetry
        createButton.isHidden = true
        importButton.isHidden = true
        clearFiltersButton.isHidden = true
        actions.isHidden = !canRetry
    }

    func configureNoResults(
        title: String,
        message: String,
        offersClearFilters: Bool
    ) {
        primaryButtonStartsSync = false
        imageView.image = UIImage(systemName: "magnifyingglass")
        titleLabel.text = title
        messageLabel.text = message
        connectButton.isHidden = true
        createButton.isHidden = true
        importButton.isHidden = true
        clearFiltersButton.isHidden = !offersClearFilters
        actions.isHidden = !offersClearFilters
    }

    private func updateForContentSizeCategory() {
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        imageView.isHidden = isAccessibilitySize
        stack.spacing = isAccessibilitySize ? 10 : 14
        scrollView.alwaysBounceVertical = isAccessibilitySize
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        symbol: String,
        prominent: Bool,
        action: @escaping () -> Void
    ) {
        var configuration = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = AppTheme.tint
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 11,
            leading: 18,
            bottom: 11,
            trailing: 18
        )
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
    }
}

private final class PhoneTagFilterViewController: UITableViewController {
    private let tags: [(tag: String, count: Int)]
    private var activeKeys: Set<String>
    var onChange: ((Set<String>) -> Void)?

    init(tags: [(tag: String, count: Int)], activeKeys: Set<String>) {
        self.tags = tags
        self.activeKeys = activeKeys
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateTitleAndClearButton()
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Clear",
            primaryAction: UIAction { [weak self] _ in
                guard let self else { return }
                self.activeKeys.removeAll()
                self.tableView.reloadData()
                self.updateTitleAndClearButton()
                self.onChange?(self.activeKeys)
            }
        )
        navigationItem.leftBarButtonItem?.accessibilityHint = "Removes every active tag filter"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        updateTitleAndClearButton()

        if tags.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "tag")
            configuration.text = "No Tags Yet"
            configuration.secondaryText = "Add tags to a snippet, then return here to filter your library."
            contentUnavailableConfiguration = configuration
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "A snippet must match every selected tag."
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        tags.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = tags[indexPath.row]
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        cell.textLabel?.text = item.tag
        cell.detailTextLabel?.text = "\(item.count)"
        cell.imageView?.image = UIImage(systemName: "tag.fill")
        cell.imageView?.tintColor = AppTheme.tagColor(for: item.tag)
        let isActive = activeKeys.contains(SnippetTagging.filterKey(for: item.tag))
        cell.accessoryType = isActive ? .checkmark : .none
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.accessibilityLabel = item.tag
        cell.accessibilityValue = "\(item.count) snippet\(item.count == 1 ? "" : "s"), \(isActive ? "selected" : "not selected")"
        cell.accessibilityHint = "Double tap to \(isActive ? "remove" : "apply") this filter"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let key = SnippetTagging.filterKey(for: tags[indexPath.row].tag)
        if !activeKeys.insert(key).inserted {
            activeKeys.remove(key)
        }
        tableView.reloadRows(at: [indexPath], with: .automatic)
        updateTitleAndClearButton()
        onChange?(activeKeys)
    }

    private func updateTitleAndClearButton() {
        let count = activeKeys.count
        title = count == 0 ? "Filter by Tags" : "Filter by Tags (\(count))"
        navigationItem.leftBarButtonItem?.isEnabled = count > 0
        navigationItem.leftBarButtonItem?.accessibilityValue = count == 0
            ? "No active filters"
            : "\(count) active filter\(count == 1 ? "" : "s")"
    }
}

private final class PhoneSyncStatusBanner: UIView {
    private let symbolView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .secondarySystemGroupedBackground
        accessibilityIdentifier = "phone-sync-status"
        isAccessibilityElement = true

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.tintColor = AppTheme.tint
        symbolView.contentMode = .scaleAspectFit
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = AppTheme.tint

        statusLabel.font = AppTheme.scaledFont(size: 12, weight: .medium, textStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 0

        let leadingStatus = UIView()
        leadingStatus.translatesAutoresizingMaskIntoConstraints = false
        leadingStatus.addSubview(symbolView)
        leadingStatus.addSubview(activityIndicator)
        let row = UIStackView(arrangedSubviews: [leadingStatus, statusLabel])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 9
        addSubview(row)

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = .separator
        addSubview(separator)

        NSLayoutConstraint.activate([
            leadingStatus.widthAnchor.constraint(equalToConstant: 20),
            leadingStatus.heightAnchor.constraint(equalToConstant: 20),
            symbolView.centerXAnchor.constraint(equalTo: leadingStatus.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: leadingStatus.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),
            activityIndicator.centerXAnchor.constraint(equalTo: leadingStatus.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: leadingStatus.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(
                equalToConstant: 1 / max(traitCollection.displayScale, 1)
            ),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(state: SyncEngine.State, status: String, isFirstFetch: Bool) {
        let text: String
        let symbolName: String
        switch state {
        case .disabled:
            text = isFirstFetch ? "Preparing the first iCloud fetch…" : "Preparing iCloud Sync…"
            symbolName = "icloud"
        case .syncing:
            text = isFirstFetch ? "Fetching your iCloud library…" : "Syncing changes…"
            symbolName = "arrow.triangle.2.circlepath"
        case .idle(let lastSync):
            if isFirstFetch && lastSync == nil {
                text = "Waiting to fetch your iCloud library…"
                symbolName = "icloud.and.arrow.down"
            } else {
                text = status
                symbolName = "checkmark.icloud"
            }
        case .offline:
            text = isFirstFetch ? "First fetch paused. \(status)" : status
            symbolName = "icloud.slash"
        case .needsAuthentication:
            text = status
            symbolName = "person.crop.circle.badge.exclamationmark"
        case .waitingForVault:
            text = status
            symbolName = "lock.icloud"
        case .halted:
            text = status
            symbolName = "exclamationmark.icloud"
        }

        statusLabel.text = text
        accessibilityLabel = "iCloud Sync"
        accessibilityValue = text
        accessibilityHint = state.requiresSyncAttention
            ? "Open Settings for details and recovery actions"
            : nil

        let isSyncing = state.isSyncing
        symbolView.isHidden = isSyncing
        activityIndicator.isHidden = !isSyncing
        if isSyncing {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
            symbolView.image = UIImage(systemName: symbolName)
        }
    }
}

private final class PhoneToastPresenter {
    private static let actionIdentifier = UIAction.Identifier("PhoneToastAction")

    private let container = AppTheme.glassView(tintColor: AppTheme.tint.withAlphaComponent(0.06))
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let stack = UIStackView()
    private var hideWorkItem: DispatchWorkItem?
    private var pendingAction: (() -> Void)?

    func install(in view: UIView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.alpha = 0
        container.isHidden = true

        label.font = AppTheme.scaledFont(size: 14, weight: .medium, textStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        button.titleLabel?.font = AppTheme.scaledFont(size: 14, weight: .semibold, textStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = "phone-toast-action"
        button.accessibilityHint = "Performs this action once"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        [label, button].forEach(stack.addArrangedSubview)
        container.contentView.addSubview(stack)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -11),
        ])
    }

    func show(
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = 3.5
    ) {
        hideWorkItem?.cancel()
        label.text = message
        button.removeAction(identifiedBy: Self.actionIdentifier, for: .touchUpInside)
        button.setTitle(actionTitle, for: .normal)
        button.isHidden = actionTitle == nil
        pendingAction = action
        if let action {
            button.addAction(
                UIAction(identifier: Self.actionIdentifier) { [weak self] _ in
                    guard let self, self.pendingAction != nil else { return }
                    // Clear before invoking the callback. Even if the callback presents
                    // another status immediately, a second activation can never reach
                    // the previous deletion token or an unrelated Undo stack entry.
                    self.pendingAction = nil
                    self.button.isEnabled = false
                    self.dismiss(animated: true)
                    action()
                },
                for: .touchUpInside
            )
        }
        button.isEnabled = action != nil
        container.isHidden = false
        UIView.animate(withDuration: 0.22) { self.container.alpha = 1 }
        let announcement = actionTitle.map { "\(message) \($0) available." } ?? message
        UIAccessibility.post(notification: .announcement, argument: announcement)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        hideWorkItem = workItem
        let minimumActionDuration: TimeInterval = UIAccessibility.isVoiceOverRunning ? 20 : 8
        let effectiveDuration = actionTitle == nil ? duration : max(duration, minimumActionDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: workItem)
    }

    private func dismiss(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        pendingAction = nil
        button.removeAction(identifiedBy: Self.actionIdentifier, for: .touchUpInside)
        let changes = { self.container.alpha = 0 }
        let completion: (Bool) -> Void = { _ in
            self.container.isHidden = true
            self.button.isEnabled = false
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }
}

private extension SyncEngine.State {
    var isSyncing: Bool {
        if case .syncing = self { return true }
        return false
    }

    var requiresSyncAttention: Bool {
        switch self {
        case .offline, .needsAuthentication, .waitingForVault, .halted:
            return true
        case .disabled, .idle, .syncing:
            return false
        }
    }
}
