import UIKit

private enum PhoneLibraryLayout {
    static let horizontalInset: CGFloat = 18
    static let headerHorizontalInset: CGFloat = 20
}

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
        let title: String?
        let snippets: [Snippet]
    }

    private enum DefaultsKey {
        static let showedGestureCoaching = "SnippetsPhoneGestureCoachingShown"
    }

    weak var delegate: PhoneLibraryViewControllerDelegate?

    private let environment: AppEnvironment
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private let searchController = UISearchController(searchResultsController: nil)
    private let emptyView = PhoneEmptyLibraryView()
    private let syncStatusHeader = UIView()
    private let syncStatusBanner = PhoneSyncStatusBanner()
    private let filterButton = UIButton(type: .system)
    private let moreButton: UIButton = {
        var configuration = UIButton.Configuration.glass()
        configuration.image = UIImage(systemName: "ellipsis.circle")
        configuration.baseForegroundColor = .label
        configuration.contentInsets = .zero
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.showsMenuAsPrimaryAction = true
        button.accessibilityIdentifier = "phone-library-more"
        button.accessibilityLabel = "More"
        return button
    }()
    private let toastPresenter = AppToastPresenter()
    private let copyFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
    private var filterItem: UIBarButtonItem?
    private var activeTagKeys = Set<String>()
    private var sections: [Section] = []
    private var syncObservation: UUID?
    private var pendingCoachingWorkItem: DispatchWorkItem?
    private var hasCompletedSync: Bool
    private weak var moreButtonNavigationBar: UINavigationBar?
    private var moreButtonBottomConstraint: NSLayoutConstraint?
    private let searchIndex = SnippetSearchIndex()
    private lazy var searchPipeline = SnippetSearchPipeline(index: searchIndex)

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
        title = "Snippets"
        view.backgroundColor = .systemBackground
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
        installMoreButton()
        reload()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        removeMoreButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateSyncHeaderLayout()
        pinEmptyLibraryToScrollEdge()
        updateMoreButtonPosition()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController?.isBeingDismissed == true, let syncObservation {
            environment.syncCoordinator.removeStateObserver(syncObservation)
            self.syncObservation = nil
        }
    }

    func reload() {
        searchPipeline.cancelPending()
        let existingTags = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTags)

        let snippets = environment.store.snippetsSortedForDisplay()
        let searchText = searchController.searchBar.text ?? ""
        let matches: [Snippet]
        if SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty {
            matches = SnippetSearchSnapshot.resultsForEmptySearch(
                in: snippets,
                activeTagKeys: activeTagKeys
            )
        } else {
            matches = searchIndex.results(
                in: snippets,
                searchText: searchText,
                activeTagKeys: activeTagKeys
            )
        }
        applySearchMatches(matches)
    }

    private func reloadSearchResults() {
        let existingTags = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTags)

        let snippets = environment.store.snippetsSortedForDisplay()
        let searchText = searchController.searchBar.text ?? ""
        guard !SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty else {
            reload()
            return
        }
        let tagKeys = activeTagKeys
        searchPipeline.submit(
            snippets: snippets,
            searchText: searchText,
            activeTagKeys: tagKeys
        ) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self, self.searchPipeline.isCurrent(response.generation) else { return }
                self.applySearchMatches(response.snippets)
            }
        }
    }

    private func applySearchMatches(_ matches: [Snippet]) {
        sections = []
        let pinned = matches.filter(\.isPinned)
        let unpinned = matches.filter { !$0.isPinned }
        if !pinned.isEmpty {
            sections.append(Section(title: "Pinned", snippets: pinned))
        }
        if !unpinned.isEmpty {
            sections.append(Section(title: nil, snippets: unpinned))
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
            copyFeedbackGenerator.impactOccurred(intensity: 0.75)
            scheduleGestureCoachingIfNeeded()
        case .empty(let name):
            toastPresenter.show(message: "“\(name)” has no content to copy.")
            copyFeedbackGenerator.impactOccurred(intensity: 0.5)
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
        // The large title should behave like Mail's: expanded at the scroll edge and
        // compact as soon as the library moves. Search remains in the floating toolbar.
        navigationItem.hidesSearchBarWhenScrolling = true
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
        moreButton.menu = menu
        navigationItem.rightBarButtonItem = nil
    }

    /// UIKit keeps ordinary bar-button items in the compact row while a large title is
    /// expanded. The library's only navigation action belongs with the title instead,
    /// so it is hosted by the navigation bar and follows the bar's lower edge. As the
    /// large title collapses, that same lower edge becomes the compact navigation row.
    private func installMoreButton() {
        guard let navigationBar = navigationController?.navigationBar else { return }
        if moreButtonNavigationBar !== navigationBar {
            removeMoreButton()
            navigationBar.addSubview(moreButton)
            let bottom = moreButton.bottomAnchor.constraint(equalTo: navigationBar.bottomAnchor)
            NSLayoutConstraint.activate([
                moreButton.widthAnchor.constraint(equalToConstant: 44),
                moreButton.heightAnchor.constraint(equalToConstant: 44),
                moreButton.trailingAnchor.constraint(
                    equalTo: navigationBar.layoutMarginsGuide.trailingAnchor
                ),
                bottom,
            ])
            moreButtonNavigationBar = navigationBar
            moreButtonBottomConstraint = bottom
        }
        navigationBar.bringSubviewToFront(moreButton)
        updateMoreButtonPosition()
    }

    private func removeMoreButton() {
        moreButton.removeFromSuperview()
        moreButtonNavigationBar = nil
        moreButtonBottomConstraint = nil
    }

    private func updateMoreButtonPosition() {
        guard let navigationBar = moreButtonNavigationBar,
              let moreButtonBottomConstraint else { return }
        // The expanded large-title glyphs sit a few points above the bottom of their
        // row, while the compact controls are vertically centered. Interpolate that
        // small optical correction as UIKit collapses the navigation bar.
        let expansion = min(max((navigationBar.bounds.height - 44) / 52, 0), 1)
        let desiredConstant = -4 * expansion
        guard moreButtonBottomConstraint.constant != desiredConstant else { return }
        moreButtonBottomConstraint.constant = desiredConstant
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
        tableView.contentInsetAdjustmentBehavior = .always
        tableView.keyboardDismissMode = .onDrag
        tableView.sectionHeaderTopPadding = 8
        tableView.estimatedSectionHeaderHeight = 38
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionFooterHeight = .leastNormalMagnitude
        tableView.estimatedRowHeight = 96
        tableView.rowHeight = UITableView.automaticDimension
        // PhoneSnippetCell owns its divider and horizontal geometry. UITableView can
        // rewrite cell/contentView margins while cells enter and leave the reuse queue.
        tableView.separatorStyle = .none
        tableView.insetsContentViewsToSafeArea = true
        tableView.register(PhoneSnippetCell.self, forCellReuseIdentifier: PhoneSnippetCell.reuseIdentifier)
        tableView.register(
            PhoneSectionHeaderView.self,
            forHeaderFooterViewReuseIdentifier: PhoneSectionHeaderView.reuseIdentifier
        )
        tableView.accessibilityIdentifier = "phone-snippet-list"

        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in
            self?.requestedRefresh()
        }, for: .valueChanged)
        tableView.refreshControl = refresh

        syncStatusHeader.backgroundColor = .clear
        syncStatusHeader.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0,
            leading: PhoneLibraryLayout.headerHorizontalInset,
            bottom: 0,
            trailing: PhoneLibraryLayout.headerHorizontalInset
        )
        syncStatusBanner.onRequestResume = { [weak self] in
            self?.confirmResumeAfterReview()
        }
        syncStatusHeader.addSubview(syncStatusBanner)
        NSLayoutConstraint.activate([
            syncStatusBanner.leadingAnchor.constraint(
                equalTo: syncStatusHeader.layoutMarginsGuide.leadingAnchor
            ),
            syncStatusBanner.trailingAnchor.constraint(
                lessThanOrEqualTo: syncStatusHeader.layoutMarginsGuide.trailingAnchor
            ),
            syncStatusBanner.topAnchor.constraint(equalTo: syncStatusHeader.topAnchor, constant: 2),
            syncStatusBanner.bottomAnchor.constraint(equalTo: syncStatusHeader.bottomAnchor, constant: -10),
        ])

        // The table remains underneath both bars so native iOS controls can refract its
        // content. Sync status is part of the table's content and scrolls away with it.
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        toastPresenter.install(in: view)
    }

    private func updateSyncHeaderLayout() {
        guard !syncStatusBanner.isHidden else {
            if tableView.tableHeaderView != nil {
                tableView.tableHeaderView = nil
            }
            return
        }

        let width = tableView.bounds.width
        guard width > 0 else { return }
        if tableView.tableHeaderView !== syncStatusHeader {
            syncStatusHeader.frame = CGRect(x: 0, y: 0, width: width, height: 1)
            tableView.tableHeaderView = syncStatusHeader
        }

        syncStatusHeader.bounds.size.width = width
        syncStatusHeader.setNeedsLayout()
        syncStatusHeader.layoutIfNeeded()
        let fittingSize = syncStatusHeader.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = ceil(fittingSize.height)
        guard abs(syncStatusHeader.frame.width - width) > 0.5
                || abs(syncStatusHeader.frame.height - height) > 0.5 else { return }
        syncStatusHeader.frame = CGRect(x: 0, y: 0, width: width, height: height)
        // UITableView snapshots this frame when the header is assigned.
        tableView.tableHeaderView = syncStatusHeader
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
            tableView.isScrollEnabled = true
            tableView.backgroundView = nil
            return
        }

        // With no rows, UITableView's only vertical movement is refresh-control bounce.
        // That movement still collapses the navigation bar's large title, making an
        // otherwise static empty screen appear to have scrollable content. The nested
        // empty-state scroll view remains available for accessibility Dynamic Type.
        tableView.isScrollEnabled = false
        pinEmptyLibraryToScrollEdge()

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

    private func pinEmptyLibraryToScrollEdge() {
        guard sections.isEmpty, !tableView.isScrollEnabled else { return }
        let scrollEdgeY = -tableView.adjustedContentInset.top
        guard abs(tableView.contentOffset.y - scrollEdgeY) > 0.5 else { return }
        tableView.setContentOffset(CGPoint(x: 0, y: scrollEdgeY), animated: false)
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
            view.setNeedsLayout()
            return
        }

        syncStatusBanner.isHidden = false
        syncStatusBanner.configure(
            state: environment.syncCoordinator.state,
            status: environment.syncCoordinator.statusDescription,
            isFirstFetch: !hasCompletedSync
        )
        // State changes are visual only. Pull-to-refresh owns the haptic for an explicit
        // user gesture; background polling must never manufacture one by moving insets.
        view.setNeedsLayout()
    }

    private func confirmResumeAfterReview() {
        guard case .halted(let reason, _) = environment.syncCoordinator.state,
              reason.isUserRecoverable,
              presentedViewController == nil else { return }

        let alert = SyncResumeConfirmation.makeAlert(
            statusDescription: environment.syncCoordinator.statusDescription
        ) { [weak self] in
            self?.environment.syncCoordinator.clearHaltAfterUserReview()
        }
        present(alert, animated: true)
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
                message: "Tip: swipe right to edit. Swipe left to pin or delete.",
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
        reloadSearchResults()
    }
}

extension PhoneLibraryViewController: UITableViewDataSource, UITableViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateMoreButtonPosition()
    }

    func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        sections[section].snippets.count
    }

    func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int
    ) -> UIView? {
        guard let title = sections[section].title else { return nil }
        let header = tableView.dequeueReusableHeaderFooterView(
            withIdentifier: PhoneSectionHeaderView.reuseIdentifier
        ) as! PhoneSectionHeaderView
        header.configure(title: title)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title == nil
            ? .leastNormalMagnitude
            : UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, estimatedHeightForHeaderInSection section: Int) -> CGFloat {
        sections[section].title == nil ? 0 : 38
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: PhoneSnippetCell.reuseIdentifier,
            for: indexPath
        ) as! PhoneSnippetCell
        let snippet = snippet(at: indexPath)
        cell.configure(
            snippet: snippet,
            isSecure: environment.store.isSecure(snippet.id),
            showsSeparator: indexPath.row < sections[indexPath.section].snippets.count - 1
        )
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
        delegate?.phoneLibrary(self, requestedCopy: snippet(at: indexPath).id)
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        copyFeedbackGenerator.prepare()
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
        let edit = UIContextualAction(style: .normal, title: "Edit") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.delegate?.phoneLibrary(self, requestedEdit: snippet.id)
            completion(true)
        }
        edit.image = UIImage(systemName: "pencil")
        edit.backgroundColor = AppTheme.tint
        let configuration = UISwipeActionsConfiguration(actions: [edit])
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
        let configuration = UISwipeActionsConfiguration(actions: [delete, pin])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private final class PhoneSectionHeaderView: UITableViewHeaderFooterView {
    static let reuseIdentifier = "PhoneSectionHeaderView"

    private let titleLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        backgroundConfiguration = .clear()
        contentView.backgroundColor = .clear

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = AppTheme.scaledFont(
            size: 14,
            weight: .semibold,
            textStyle: .subheadline
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.accessibilityIdentifier = "phone-section-title"
        contentView.addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PhoneLibraryLayout.horizontalInset
            ),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor,
                constant: -PhoneLibraryLayout.horizontalInset
            ),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            titleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String) {
        titleLabel.text = title
    }
}

private final class PhoneSnippetCell: UITableViewCell {
    static let reuseIdentifier = "PhoneSnippetCell"

    private let highlightView = UIView()
    private let rowContentView = UIView()
    private let separatorView = UIView()
    private lazy var separatorHeightConstraint = separatorView.heightAnchor.constraint(
        equalToConstant: 0.5
    )
    private let secureSymbolView = UIImageView(image: UIImage(systemName: "lock.fill"))
    private let pinnedSymbolView = UIImageView(image: UIImage(systemName: "pin.fill"))
    private let disabledSymbolView = UIImageView(image: UIImage(systemName: "pause.circle.fill"))
    private let statusSymbols = UIStackView()
    private let nameLabel = UILabel()
    private let dateLabel = UILabel()
    private let detailLabel = UILabel()
    private let titleRow = UIStackView()
    private let tagsStack = UIStackView()
    private let tagsSpacer = UIView()
    private let tagPillLabels = (0..<3).map { _ in PhoneTagPillLabel() }
    private let moreTagsLabel: UILabel = {
        let label = UILabel()
        label.font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }()
    private let contentStack = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .default
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        automaticallyUpdatesBackgroundConfiguration = false
        backgroundConfiguration = .clear()
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = .clear
        preservesSuperviewLayoutMargins = false

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.backgroundColor = AppTheme.selectedRow
        highlightView.layer.cornerRadius = 20
        highlightView.layer.cornerCurve = .continuous
        highlightView.alpha = 0

        rowContentView.translatesAutoresizingMaskIntoConstraints = false
        rowContentView.backgroundColor = .clear
        rowContentView.accessibilityIdentifier = "phone-snippet-row-content"

        separatorView.translatesAutoresizingMaskIntoConstraints = false
        separatorView.backgroundColor = .separator

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

        nameLabel.font = AppTheme.scaledFont(size: 17, weight: .semibold, textStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        dateLabel.font = AppTheme.scaledFont(size: 13, textStyle: .subheadline)
        dateLabel.adjustsFontForContentSizeCategory = true
        dateLabel.textColor = .tertiaryLabel
        dateLabel.setContentHuggingPriority(.required, for: .horizontal)
        dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateLabel.accessibilityElementsHidden = true

        detailLabel.font = AppTheme.scaledFont(size: 15, textStyle: .subheadline)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingTail

        tagsStack.axis = .horizontal
        tagsStack.spacing = 5
        tagsStack.alignment = .center
        tagsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tagsSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagPillLabels.forEach { label in
            label.isHidden = true
            tagsStack.addArrangedSubview(label)
        }
        moreTagsLabel.isHidden = true
        tagsStack.addArrangedSubview(moreTagsLabel)
        tagsStack.addArrangedSubview(tagsSpacer)

        [statusSymbols, nameLabel, dateLabel].forEach(titleRow.addArrangedSubview)
        titleRow.axis = .horizontal
        titleRow.spacing = 7
        titleRow.alignment = .center
        [titleRow, detailLabel, tagsStack].forEach(contentStack.addArrangedSubview)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 5

        contentView.addSubview(highlightView)
        contentView.addSubview(rowContentView)
        contentView.addSubview(separatorView)
        rowContentView.addSubview(contentStack)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            highlightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            highlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            // Fixed anchors, rather than layoutMarginsGuide, keep every reused row on
            // exactly the same horizontal grid.
            rowContentView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PhoneLibraryLayout.horizontalInset
            ),
            rowContentView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PhoneLibraryLayout.horizontalInset
            ),
            rowContentView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowContentView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),

            contentStack.leadingAnchor.constraint(equalTo: rowContentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: rowContentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: rowContentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: rowContentView.bottomAnchor),

            separatorView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: PhoneLibraryLayout.horizontalInset
            ),
            separatorView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -PhoneLibraryLayout.horizontalInset
            ),
            separatorView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            separatorHeightConstraint,
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: PhoneSnippetCell, _: UITraitCollection) in
            cell.updateTagLayout()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        separatorHeightConstraint.constant = 1 / max(traitCollection.displayScale, 1)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityCustomActions = nil
        separatorView.isHidden = false
        updateHighlight(animated: false)
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updateHighlight(animated: animated)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateHighlight(animated: animated)
    }

    func configure(snippet: Snippet, isSecure: Bool, showsSeparator: Bool) {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        separatorView.isHidden = !showsSeparator
        nameLabel.text = snippet.displayName
        dateLabel.text = Self.updatedText(for: snippet.updatedAt)
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

        for (index, label) in tagPillLabels.enumerated() {
            guard index < snippet.tags.count else {
                label.isHidden = true
                continue
            }
            label.configure(tag: snippet.tags[index])
            label.isHidden = false
        }
        let additionalTagCount = max(snippet.tags.count - tagPillLabels.count, 0)
        moreTagsLabel.text = additionalTagCount > 0 ? "+\(additionalTagCount)" : nil
        moreTagsLabel.isHidden = additionalTagCount == 0
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

    private func updateHighlight(animated: Bool) {
        let changes = {
            self.highlightView.alpha = self.isHighlighted || self.isSelected ? 1 : 0
        }
        if animated {
            UIView.animate(
                withDuration: 0.16,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction],
                animations: changes
            )
        } else {
            changes()
        }
    }

    private func updateTagLayout() {
        let usesVerticalTags = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        nameLabel.numberOfLines = usesVerticalTags ? 0 : 1
        dateLabel.isHidden = usesVerticalTags
        tagsStack.axis = usesVerticalTags ? .vertical : .horizontal
        tagsStack.alignment = usesVerticalTags ? .leading : .center
        tagsSpacer.isHidden = usesVerticalTags
    }

    private static func updatedText(for date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }
        if let sixDaysAgo = calendar.date(byAdding: .day, value: -6, to: Date()),
           date >= sixDaysAgo {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private final class PhoneTagPillLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "phone-tag-pill"
        font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        adjustsFontForContentSizeCategory = true
        numberOfLines = 1
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        setContentHuggingPriority(.required, for: .horizontal)
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
    var onClearFilters: (() -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let connectButton = UIButton(type: .system)
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
        actions.alignment = .center
        [connectButton, clearFiltersButton].forEach(actions.addArrangedSubview)

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        [titleLabel, messageLabel, actions].forEach(stack.addArrangedSubview)
        stack.setCustomSpacing(18, after: messageLabel)

        addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(stack)
        let viewportHeight = contentView.heightAnchor.constraint(
            equalTo: scrollView.frameLayoutGuide.heightAnchor
        )
        viewportHeight.priority = .defaultLow
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
            viewportHeight,
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -24),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            stack.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24),
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
        titleLabel.text = offersICloud ? "Bring Your Library to iPhone" : "Your Library Is Empty"
        messageLabel.text = offersICloud
            ? "Connect iCloud to fetch the library you already use on Mac and iPad."
            : "\(syncStatus) You can also create a snippet on this device."
        connectButton.isHidden = !offersICloud
        connectButton.configuration?.title = "Connect iCloud"
        connectButton.configuration?.image = UIImage(systemName: "icloud")
        connectButton.accessibilityIdentifier = "phone-connect-icloud"
        clearFiltersButton.isHidden = true
        actions.isHidden = !offersICloud
    }

    func configureFirstFetch(syncStatus: String, canRetry: Bool) {
        primaryButtonStartsSync = true
        titleLabel.text = canRetry ? "Library Hasn’t Been Fetched" : "Fetching Your Library"
        messageLabel.text = syncStatus
        connectButton.configuration?.title = "Try Again"
        connectButton.configuration?.image = UIImage(systemName: "arrow.clockwise")
        connectButton.accessibilityIdentifier = "phone-sync-now"
        connectButton.isHidden = !canRetry
        clearFiltersButton.isHidden = true
        actions.isHidden = !canRetry
    }

    func configureNoResults(
        title: String,
        message: String,
        offersClearFilters: Bool
    ) {
        primaryButtonStartsSync = false
        titleLabel.text = title
        messageLabel.text = message
        connectButton.isHidden = true
        clearFiltersButton.isHidden = !offersClearFilters
        actions.isHidden = !offersClearFilters
    }

    private func updateForContentSizeCategory() {
        let isAccessibilitySize = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
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

final class PhoneSyncStatusBanner: UIVisualEffectView {
    private let symbolView = UIImageView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let statusLabel = UILabel()
    private let resumeLabel = UILabel()
    private let resumeSymbolView = UIImageView()
    private let resumeGroup = UIStackView()
    private var isResumeAvailable = false

    var onRequestResume: (() -> Void)?

    init() {
        let glass = UIGlassEffect(style: .regular)
        glass.tintColor = AppTheme.tint.withAlphaComponent(0.035)
        super.init(effect: glass)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 17
        layer.cornerCurve = .continuous
        clipsToBounds = true
        accessibilityIdentifier = "phone-sync-status"
        isAccessibilityElement = true
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(requestResume)))

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.tintColor = AppTheme.tint
        symbolView.contentMode = .scaleAspectFit
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.color = AppTheme.tint

        statusLabel.font = AppTheme.scaledFont(size: 12, weight: .medium, textStyle: .footnote)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resumeLabel.font = AppTheme.scaledFont(size: 12, weight: .semibold, textStyle: .footnote)
        resumeLabel.adjustsFontForContentSizeCategory = true
        resumeLabel.textColor = AppTheme.tint
        resumeLabel.text = "Resume"
        resumeLabel.accessibilityIdentifier = "phone-sync-resume-label"

        resumeSymbolView.image = UIImage(systemName: "chevron.right")
        resumeSymbolView.tintColor = AppTheme.tint
        resumeSymbolView.contentMode = .scaleAspectFit
        resumeSymbolView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            resumeSymbolView.widthAnchor.constraint(equalToConstant: 8),
            resumeSymbolView.heightAnchor.constraint(equalToConstant: 12),
        ])

        resumeGroup.addArrangedSubview(resumeLabel)
        resumeGroup.addArrangedSubview(resumeSymbolView)
        resumeGroup.axis = .horizontal
        resumeGroup.alignment = .center
        resumeGroup.spacing = 4
        resumeGroup.isHidden = true
        resumeGroup.setContentCompressionResistancePriority(.required, for: .horizontal)

        let leadingStatus = UIView()
        leadingStatus.translatesAutoresizingMaskIntoConstraints = false
        leadingStatus.addSubview(symbolView)
        leadingStatus.addSubview(activityIndicator)
        let row = UIStackView(arrangedSubviews: [leadingStatus, statusLabel, resumeGroup])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 7
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            leadingStatus.widthAnchor.constraint(equalToConstant: 16),
            leadingStatus.heightAnchor.constraint(equalToConstant: 16),
            symbolView.centerXAnchor.constraint(equalTo: leadingStatus.centerXAnchor),
            symbolView.centerYAnchor.constraint(equalTo: leadingStatus.centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 15),
            symbolView.heightAnchor.constraint(equalToConstant: 15),
            activityIndicator.centerXAnchor.constraint(equalTo: leadingStatus.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: leadingStatus.centerYAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -13),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
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
            } else if let lastSync {
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                text = "Synced at \(formatter.string(from: lastSync))"
                symbolName = "checkmark.icloud"
            } else {
                text = "iCloud on · Not synced yet"
                symbolName = "checkmark.icloud"
            }
        case .offline:
            text = isFirstFetch ? "First sync paused" : "iCloud unavailable"
            symbolName = "icloud.slash"
        case .needsAuthentication:
            text = "iCloud needs attention"
            symbolName = "person.crop.circle.badge.exclamationmark"
        case .waitingForVault:
            text = "Waiting for Secure Snippets"
            symbolName = "lock.icloud"
        case .halted:
            text = "Sync paused for safety"
            symbolName = "exclamationmark.icloud"
        }

        statusLabel.text = text
        isResumeAvailable = if case .halted(let reason, _) = state {
            reason.isUserRecoverable
        } else {
            false
        }
        resumeGroup.isHidden = !isResumeAvailable
        isUserInteractionEnabled = isResumeAvailable
        accessibilityLabel = "iCloud Sync"
        accessibilityValue = state.requiresSyncAttention ? status : text
        accessibilityTraits = isResumeAvailable ? .button : .staticText
        if isResumeAvailable {
            accessibilityHint = "Review the safety stop and choose whether to resume sync"
        } else {
            accessibilityHint = state.requiresSyncAttention
                ? "Open Settings for details and recovery actions"
                : nil
        }

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

    override func accessibilityActivate() -> Bool {
        performResumeRequestIfAvailable()
    }

    @objc private func requestResume() {
        _ = performResumeRequestIfAvailable()
    }

    private func performResumeRequestIfAvailable() -> Bool {
        guard isResumeAvailable else { return false }
        onRequestResume?()
        return true
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
