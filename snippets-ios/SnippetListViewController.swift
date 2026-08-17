import UIKit

final class SnippetListViewController: UIViewController {
    weak var delegate: SnippetListViewControllerDelegate?
    var onFocusEntered: (() -> Void)?

    private let environment: AppEnvironment
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let tagFilterBar = SidebarTagFilterView()
    private let footerView = UIView()
    private let statusLabel = UILabel()
    private let emptyView = EmptyLibraryView()
    private let searchController = UISearchController(searchResultsController: nil)
    private var tagBarHeightConstraint: NSLayoutConstraint?
    private lazy var tableFadeContainer = ScrollFadeContainerView(containing: tableView)
    private var visibleSnippets: [Snippet] = []
    private var activeTagKeys = Set<String>()
    private var selectedID: UUID?
    private var statusWorkItem: DispatchWorkItem?
    private var syncObservation: UUID?
    private let searchIndex = SnippetSearchIndex()
    private lazy var searchPipeline = SnippetSearchPipeline(index: searchIndex)

    var firstVisibleSnippetID: UUID? { visibleSnippets.first?.id }
    var selectedSnippetID: UUID? { selectedID }
    var searchTextField: UISearchTextField { searchController.searchBar.searchTextField }

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        guard let syncObservation else { return }
        let coordinator = environment.syncCoordinator
        Task { @MainActor in
            coordinator.removeStateObserver(syncObservation)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        navigationItem.largeTitleDisplayMode = .never
        navigationController?.navigationBar.prefersLargeTitles = false
        view.backgroundColor = .secondarySystemBackground

        configureSearch()
        configureToolbar()
        configureTags()
        configureFooter()
        configureTable()
        configureEmptyView()
        syncObservation = environment.syncCoordinator.addStateObserver { [weak self] _ in
            // Rebuild the menu so its subtitle follows Syncing / Last synced / error
            // transitions even while this long-lived split-view controller stays open.
            self?.configureToolbar()
        }
        reload(keepingSelection: selectedID != nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTagBarHeight()
        tableView.layoutIfNeeded()
        tableFadeContainer.updateFade()
    }

    override var canBecomeFirstResponder: Bool { true }

    func reload(keepingSelection: Bool) {
        searchPipeline.cancelPending()
        let searchText = searchController.searchBar.text ?? ""

        let existingTagKeys = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTagKeys)

        let snippets = environment.store.snippetsSortedForDisplay()
        let normalizedQuery = SnippetSearchSnapshot.normalizedQuery(searchText)
        let matches: [Snippet]
        if normalizedQuery.isEmpty {
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
        applySearchMatches(
            matches,
            keepingSelection: keepingSelection,
            normalizedQuery: normalizedQuery
        )
    }

    /// An editor mutation is deliberately coalesced by the split controller. Cancel
    /// any query over the pre-edit snapshot immediately, then let the trailing refresh
    /// use the worker when a search is active. Empty searches stay on the cheap,
    /// synchronous tag-only path in `reload(keepingSelection:)`.
    func prepareForDeferredEditorReload() {
        searchPipeline.cancelPending()
    }

    func reloadAfterEditorChanges() {
        reloadSearchResults()
    }

    private func reloadSearchResults() {
        let searchText = searchController.searchBar.text ?? ""
        let existingTagKeys = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTagKeys)

        let snippets = environment.store.snippetsSortedForDisplay()
        guard !SnippetSearchSnapshot.normalizedQuery(searchText).isEmpty else {
            reload(keepingSelection: true)
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
                self.applySearchMatches(
                    response.snippets,
                    keepingSelection: true,
                    normalizedQuery: SnippetSearchSnapshot.normalizedQuery(searchText)
                )
            }
        }
    }

    private func applySearchMatches(
        _ matches: [Snippet],
        keepingSelection: Bool,
        normalizedQuery: String
    ) {
        if !keepingSelection {
            selectedID = nil
        }
        visibleSnippets = matches

        rebuildTagFilters()
        tableView.reloadData()
        updateEmptyState(query: normalizedQuery)

        if keepingSelection, let selectedID,
           let row = visibleSnippets.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
        } else if let selectedRow = tableView.indexPathForSelectedRow {
            tableView.deselectRow(at: selectedRow, animated: false)
        }
        tableFadeContainer.setNeedsLayout()
    }

    func select(id: UUID, ensureVisible: Bool = false) {
        selectedID = id
        guard let row = visibleSnippets.firstIndex(where: { $0.id == id }) else { return }
        let indexPath = IndexPath(row: row, section: 0)
        tableView.selectRow(at: indexPath, animated: false, scrollPosition: .none)
        if ensureVisible {
            tableView.scrollToRow(at: indexPath, at: .none, animated: false)
        }
    }

    func showStatus(_ message: String) {
        statusWorkItem?.cancel()
        statusLabel.text = message
        statusLabel.isHidden = false
        let workItem = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.2) {
                self?.statusLabel.alpha = 0
            } completion: { _ in
                self?.statusLabel.isHidden = true
                self?.statusLabel.alpha = 1
            }
        }
        statusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }


    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search"
        searchController.searchBar.accessibilityIdentifier = "snippet-search"
        searchController.searchBar.searchTextField.accessibilityIdentifier = "snippet-search"
        searchController.searchBar.searchTextField.addTarget(
            self,
            action: #selector(searchFocusEntered),
            for: .editingDidBegin
        )
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        definesPresentationContext = true
    }

    private func configureToolbar() {
        let syncEnabled = SyncCoordinator.isEnabled
        let coordinator = environment.syncCoordinator
        let recoveryAction = coordinator.recoveryAction
        let syncNeedsSettings = coordinator.requiresSyncSettingsAttention
        let syncTitle: String
        let syncImage: String
        if let recoveryAction {
            syncTitle = recoveryAction.buttonTitle
            syncImage = "exclamationmark.shield"
        } else if syncNeedsSettings {
            syncTitle = "Open Sync Settings"
            syncImage = "exclamationmark.triangle"
        } else if syncEnabled {
            syncTitle = "Sync Now"
            syncImage = "arrow.triangle.2.circlepath"
        } else {
            syncTitle = "Connect \(environment.backendSelection.provider.displayName)"
            syncImage = "icloud"
        }
        let addMenu = UIMenu(children: [
            UIAction(title: "New Snippet", image: UIImage(systemName: "plus")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedNewSnippet(self)
            },
            UIAction(title: "New from Clipboard", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedClipboardSnippet(self)
            },
        ])
        let add = UIBarButtonItem(image: UIImage(systemName: "plus"), menu: addMenu)
        add.accessibilityIdentifier = "new-snippet"

        let moreMenu = UIMenu(children: [
            UIAction(title: "Import", image: UIImage(systemName: "square.and.arrow.down")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedImport(self)
            },
            UIAction(title: "Export for Sharing", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedExport(self)
            },
            UIAction(title: "Encrypted Backup (Includes Secure Snippets)", image: UIImage(systemName: "lock.doc")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedEncryptedBackup(self)
            },
            UIAction(
                title: syncTitle,
                subtitle: coordinator.statusDescription,
                image: UIImage(systemName: syncImage)
            ) { [weak self] _ in
                guard let self else { return }
                if let action = self.environment.syncCoordinator.recoveryAction {
                    self.performSyncRecovery(action)
                } else if self.environment.syncCoordinator.requiresSyncSettingsAttention {
                    self.delegate?.snippetListRequestedSettings(self)
                } else if SyncCoordinator.isEnabled {
                    self.showStatus("Syncing\u{2026}")
                    self.environment.syncCoordinator.syncNow()
                } else {
                    self.showStatus("Connecting\u{2026}")
                    self.environment.syncCoordinator.setEnabled(true)
                }
            },
            UIAction(title: "Keyboard Shortcuts", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedShortcuts(self)
            },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedSettings(self)
            },
        ])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu)
        navigationItem.rightBarButtonItems = [add, more]
    }

    private func performSyncRecovery(_ action: SyncRecoveryAction) {
        guard presentedViewController == nil else { return }
        guard action.confirmationTitle != nil else {
            environment.syncCoordinator.performRecovery(action)
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

    private func configureTags() {
        tagFilterBar.onToggleTag = { [weak self] tag in
            guard let self else { return }
            let key = SnippetTagging.filterKey(for: tag)
            if !self.activeTagKeys.insert(key).inserted {
                self.activeTagKeys.remove(key)
            }
            self.reload(keepingSelection: true)
        }
        tagFilterBar.onClearFilters = { [weak self] in
            self?.activeTagKeys.removeAll()
            self?.reload(keepingSelection: true)
        }
        tagFilterBar.onHeightChange = { [weak self] in
            self?.updateTagBarHeight()
        }

        view.addSubview(tagFilterBar)
        let height = tagFilterBar.heightAnchor.constraint(equalToConstant: 0)
        tagBarHeightConstraint = height
        NSLayoutConstraint.activate([
            tagFilterBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tagFilterBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tagFilterBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            height,
        ])
    }

    private func configureFooter() {
        footerView.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = AppTheme.scaledFont(size: 11, textStyle: .caption1)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .secondaryLabel
        statusLabel.textAlignment = .right
        statusLabel.numberOfLines = 1
        statusLabel.isHidden = true

        footerView.addSubview(statusLabel)
        view.addSubview(footerView)
        NSLayoutConstraint.activate([
            footerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 42),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: footerView.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
        ])
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.backgroundColor = .clear
        tableView.rowHeight = 68
        tableView.contentInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SnippetListCell.self, forCellReuseIdentifier: SnippetListCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "snippet-list"
        view.insertSubview(tableFadeContainer, belowSubview: footerView)
        NSLayoutConstraint.activate([
            tableFadeContainer.topAnchor.constraint(equalTo: tagFilterBar.bottomAnchor),
            tableFadeContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableFadeContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableFadeContainer.bottomAnchor.constraint(equalTo: footerView.topAnchor),
        ])
    }

    private func configureEmptyView() {
        emptyView.onCreate = { [weak self] in
            guard let self else { return }
            self.delegate?.snippetListRequestedNewSnippet(self)
        }
        emptyView.onImport = { [weak self] in
            guard let self else { return }
            self.delegate?.snippetListRequestedImport(self)
        }
        emptyView.onClipboard = { [weak self] in
            guard let self else { return }
            self.delegate?.snippetListRequestedClipboardSnippet(self)
        }
    }

    private func rebuildTagFilters() {
        let tags = environment.store.tagUsage()
        tagFilterBar.isHidden = tags.isEmpty
        tagFilterBar.update(
            items: tags.map { SidebarTagFilterView.Item(tag: $0.tag, count: $0.count) },
            activeKeys: activeTagKeys
        )
        updateTagBarHeight()
    }

    private func updateTagBarHeight() {
        guard let tagBarHeightConstraint else { return }
        let width = tagFilterBar.bounds.width > 1 ? tagFilterBar.bounds.width : view.bounds.width
        let nextHeight = tagFilterBar.isHidden || width <= 1
            ? 0
            : tagFilterBar.sizeThatFits(
                CGSize(width: width, height: .greatestFiniteMagnitude)
            ).height
        guard abs(tagBarHeightConstraint.constant - nextHeight) > 0.5 else { return }
        tagBarHeightConstraint.constant = nextHeight
        view.setNeedsLayout()
    }

    private func updateEmptyState(query: String) {
        guard visibleSnippets.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        if environment.store.isLibraryQuarantined {
            emptyView.configure(
                title: "Library Recovery Required",
                message: "The ordinary snippet library could not be read and remains "
                    + "preserved. Import a complete Snippets JSON export, then open Sync "
                    + "Settings and choose Check Again.",
                showsActions: true,
                importOnly: true
            )
        } else if environment.store.snippetsSortedForDisplay().isEmpty {
            emptyView.configure(
                title: "Your snippet library is empty",
                message: "Create a snippet, start from the clipboard, or import an existing library.",
                showsActions: true
            )
        } else if !query.isEmpty {
            emptyView.configure(
                title: "No results for “\(query)”",
                message: activeTagKeys.isEmpty ? "Try a different search." : "Try clearing a tag filter.",
                showsActions: false
            )
        } else {
            emptyView.configure(
                title: "No snippets match these tags",
                message: "Clear a filter to see more snippets.",
                showsActions: false
            )
        }
        tableView.backgroundView = emptyView
    }

    private func snippet(at indexPath: IndexPath) -> Snippet { visibleSnippets[indexPath.row] }

    private func togglePin(_ snippet: Snippet) {
        do {
            if environment.store.isSecure(snippet.id) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(id: snippet.id, isPinned: !snippet.isPinned)
                }
            } else {
                environment.store.togglePinned(snippetID: snippet.id)
            }
        } catch {
            showStatus("Couldn’t update pin: \(error)")
        }
    }

    private func toggleEnabled(_ snippet: Snippet) {
        do {
            if environment.store.isSecure(snippet.id) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(id: snippet.id, isEnabled: !snippet.isEnabled)
                }
            } else {
                environment.store.toggleEnabled(snippetID: snippet.id)
            }
        } catch {
            showStatus("Couldn’t update snippet: \(error)")
        }
    }

    private func copy(_ snippet: Snippet) {
        delegate?.snippetList(self, requestedCopy: snippet.id)
    }

    private func copyLink(_ snippet: Snippet) {
        do {
            UIPasteboard.general.url = try SnippetDeepLink.url(for: snippet, isSecure: false)
            showStatus("Copied share link.")
        } catch {
            showStatus("Couldn’t copy link: \(error)")
        }
    }

    func contextMenu(for snippet: Snippet) -> UIMenu {
        let isSecure = environment.store.isSecure(snippet.id)
        var actions: [UIMenuElement] = [
            UIAction(
                title: snippet.isPinned ? "Unpin" : "Pin",
                image: UIImage(systemName: snippet.isPinned ? "pin.slash" : "pin")
            ) { [weak self] _ in self?.togglePin(snippet) },
            UIAction(
                title: snippet.isEnabled ? "Disable" : "Enable",
                image: UIImage(systemName: snippet.isEnabled ? "pause.circle" : "checkmark.circle")
            ) { [weak self] _ in self?.toggleEnabled(snippet) },
            UIAction(
                title: isSecure ? "Make Ordinary" : "Make Secure",
                image: UIImage(systemName: isSecure ? "lock.open" : "lock")
            ) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetList(self, requestedToggleSecurity: snippet.id)
            },
            UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(snippet)
            },
        ]
        if !isSecure {
            actions.append(contentsOf: [
                UIAction(title: "Copy Share Link", image: UIImage(systemName: "link")) { [weak self] _ in self?.copyLink(snippet) },
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                    guard let self else { return }
                    self.delegate?.snippetList(self, requestedDuplicate: snippet.id)
                },
            ])
        }
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            guard let self else { return }
            self.delegate?.snippetList(self, requestedDelete: snippet.id)
        })
        return UIMenu(children: actions)
    }

    func focusSearch() {
        onFocusEntered?()
        let searchField = searchTextField
        if !searchField.becomeFirstResponder() {
            DispatchQueue.main.async { [weak searchField] in
                searchField?.becomeFirstResponder()
            }
        }
    }

    func focusList() {
        searchController.isActive = false
        focusFilteredList()
    }

    func focusFilteredList() {
        onFocusEntered?()
        searchTextField.resignFirstResponder()
        if !tableView.becomeFirstResponder() {
            becomeFirstResponder()
        }
    }

    func adjacentSnippetID(forward: Bool) -> UUID? {
        guard !visibleSnippets.isEmpty else { return nil }
        guard let selectedID,
              let current = visibleSnippets.firstIndex(where: { $0.id == selectedID }) else {
            return visibleSnippets[0].id
        }
        let next = forward
            ? min(current + 1, visibleSnippets.count - 1)
            : max(current - 1, 0)
        return visibleSnippets[next].id
    }

    var ownsFirstResponder: Bool {
        isSearchFocused
            || tableView.isFirstResponder
            || isFirstResponder
    }

    var isSearchFocused: Bool {
        searchTextField.isFirstResponder
    }

    var isListFocused: Bool {
        tableView.isFirstResponder || isFirstResponder
    }

    @objc private func searchFocusEntered() {
        onFocusEntered?()
    }
}

extension SnippetListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        reloadSearchResults()
    }
}

extension SnippetListViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        visibleSnippets.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: SnippetListCell.reuseIdentifier,
            for: indexPath
        ) as! SnippetListCell
        let snippet = snippet(at: indexPath)
        cell.configure(
            snippet: snippet,
            isSecure: environment.store.isSecure(snippet.id),
            isSelected: snippet.id == selectedID
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let snippet = snippet(at: indexPath)
        focusFilteredList()
        selectedID = snippet.id
        delegate?.snippetList(self, selected: snippet.id)
    }

    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let snippet = snippet(at: indexPath)
        return UIContextMenuConfiguration(identifier: snippet.id.uuidString as NSString, previewProvider: nil) { [weak self] _ in
            self?.contextMenu(for: snippet)
        }
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let snippet = snippet(at: indexPath)
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            self.delegate?.snippetList(self, requestedDelete: snippet.id)
            completion(true)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === tableView else { return }
        tableFadeContainer.updateFade()
    }
}

private final class SnippetListCell: UITableViewCell {
    static let reuseIdentifier = "SnippetListCell"

    private let highlightView = UIView()
    private let titleLabel = UILabel()
    private let keywordLabel = UILabel()
    private let previewLabel = UILabel()
    private let tagsStack = UIStackView()
    private let tagDots = (0..<6).map { _ in SnippetTagDotView() }
    private let tagOverflowLabel = UILabel()
    private let stateImage = UIImageView()
    private var isPointerHovering = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none
        focusStyle = .custom
        focusEffect = nil

        highlightView.translatesAutoresizingMaskIntoConstraints = false
        highlightView.layer.cornerRadius = 11
        highlightView.layer.cornerCurve = .continuous
        highlightView.isHidden = true
        highlightView.isUserInteractionEnabled = false
        contentView.addSubview(highlightView)

        let hoverRecognizer = UIHoverGestureRecognizer(target: self, action: #selector(hoverChanged(_:)))
        addGestureRecognizer(hoverRecognizer)

        titleLabel.font = AppTheme.scaledFont(size: 14, weight: .semibold, textStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        keywordLabel.font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        keywordLabel.adjustsFontForContentSizeCategory = true
        keywordLabel.numberOfLines = 1
        keywordLabel.setContentHuggingPriority(.required, for: .horizontal)
        keywordLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previewLabel.font = AppTheme.scaledFont(size: 12, textStyle: .caption1)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 1
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stateImage.contentMode = .scaleAspectFit
        stateImage.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

        tagsStack.axis = .horizontal
        tagsStack.alignment = .center
        tagsStack.spacing = 4
        tagsStack.setContentHuggingPriority(.required, for: .horizontal)
        tagsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagDots.forEach { dot in
            dot.isHidden = true
            tagsStack.addArrangedSubview(dot)
        }
        tagOverflowLabel.font = AppTheme.scaledFont(
            size: 9,
            weight: .medium,
            textStyle: .caption2
        )
        tagOverflowLabel.adjustsFontForContentSizeCategory = true
        tagOverflowLabel.textColor = .tertiaryLabel
        tagOverflowLabel.setContentHuggingPriority(.required, for: .horizontal)
        tagOverflowLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        tagOverflowLabel.isHidden = true
        tagsStack.addArrangedSubview(tagOverflowLabel)

        let topSpacer = UIView()
        topSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let topRow = UIStackView(arrangedSubviews: [titleLabel, topSpacer, tagsStack])
        topRow.axis = .horizontal
        topRow.alignment = .center
        topRow.spacing = 6

        let bottomSpacer = UIView()
        bottomSpacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        let bottomRow = UIStackView(arrangedSubviews: [previewLabel, bottomSpacer, keywordLabel])
        bottomRow.axis = .horizontal
        bottomRow.alignment = .firstBaseline
        bottomRow.spacing = 6

        let text = UIStackView(arrangedSubviews: [topRow, bottomRow])
        text.axis = .vertical
        text.alignment = .fill
        text.spacing = 3

        let row = UIStackView(arrangedSubviews: [stateImage, text])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            highlightView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            highlightView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            highlightView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            highlightView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -2),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            stateImage.widthAnchor.constraint(equalToConstant: 11),
            stateImage.heightAnchor.constraint(equalToConstant: 11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snippet: Snippet, isSecure: Bool, isSelected: Bool) {
        titleLabel.text = snippet.displayName
        let hasKeyword = !snippet.normalizedKeyword.isEmpty
        keywordLabel.text = hasKeyword ? "\\\(snippet.normalizedKeyword)" : "No keyword"
        keywordLabel.textColor = snippet.isEnabled
            ? (hasKeyword ? .secondaryLabel : AppTheme.warning)
            : .tertiaryLabel

        let hasName = !snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let preview = isSecure ? "••••••••" : snippet.contentFirstLineUntruncated
        previewLabel.text = preview
        previewLabel.isHidden = preview.isEmpty || (!isSecure && !hasName)
        previewLabel.textColor = snippet.isEnabled ? .secondaryLabel : .tertiaryLabel
        titleLabel.textColor = snippet.isEnabled ? .label : .secondaryLabel

        if snippet.isPinned {
            stateImage.image = UIImage(systemName: "pin.fill")
            stateImage.tintColor = AppTheme.pin
        } else if snippet.isEnabled && !hasKeyword {
            stateImage.image = UIImage(systemName: "circle")
            stateImage.tintColor = AppTheme.warning
        } else {
            stateImage.image = UIImage(systemName: "circle.fill")
            stateImage.tintColor = snippet.isEnabled ? AppTheme.enabled : AppTheme.disabled
        }

        rebuildTags(snippet.tags, muted: !snippet.isEnabled)
        setSelected(isSelected, animated: false)
        accessibilityIdentifier = "snippet-row-\(snippet.id.uuidString)"
        accessibilityLabel = snippet.displayName
        accessibilityValue = [isSecure ? "Secure" : nil, snippet.isPinned ? "Pinned" : nil, snippet.isEnabled ? "Enabled" : "Disabled"]
            .compactMap { $0 }.joined(separator: ", ")
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        updateHighlight()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        updateHighlight()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isPointerHovering = false
        setSelected(false, animated: false)
    }

    @objc private func hoverChanged(_ recognizer: UIHoverGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            isPointerHovering = true
        default:
            isPointerHovering = false
        }
        updateHighlight()
    }

    private func updateHighlight() {
        let showsHighlight = isSelected || isHighlighted || isPointerHovering
        highlightView.isHidden = !showsHighlight
        highlightView.backgroundColor = isSelected ? AppTheme.selectedRow : AppTheme.hoveredRow
        highlightView.layer.borderWidth = isSelected ? 1 / max(traitCollection.displayScale, 1) : 0
        highlightView.layer.borderColor = AppTheme.selectedRowBorder
            .resolvedColor(with: traitCollection)
            .cgColor
        if isSelected {
            accessibilityTraits.insert(.selected)
        } else {
            accessibilityTraits.remove(.selected)
        }
    }

    private func rebuildTags(_ tags: [String], muted: Bool) {
        for (index, dot) in tagDots.enumerated() {
            guard tags.indices.contains(index) else {
                dot.isHidden = true
                continue
            }
            dot.configure(tag: tags[index], muted: muted)
            dot.isHidden = false
        }

        let remainingTagCount = max(tags.count - tagDots.count, 0)
        if remainingTagCount > 0 {
            let hiddenTags = tags.dropFirst(tagDots.count)
            tagOverflowLabel.text = "+\(remainingTagCount)"
            tagOverflowLabel.accessibilityLabel = "\(remainingTagCount) more tags: "
                + hiddenTags.joined(separator: ", ")
            tagOverflowLabel.isHidden = false
        } else {
            tagOverflowLabel.isHidden = true
        }
        tagsStack.isHidden = tags.isEmpty
    }
}

private final class EmptyLibraryView: UIView {
    var onCreate: (() -> Void)?
    var onClipboard: (() -> Void)?
    var onImport: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actions = UIStackView()
    private lazy var createButton = actionButton(
        title: "New Snippet", symbol: "plus") { [weak self] in self?.onCreate?() }
    private lazy var clipboardButton = actionButton(
        title: "New from Clipboard", symbol: "doc.on.clipboard") {
            [weak self] in self?.onClipboard?()
        }
    private lazy var importButton = actionButton(
        title: "Import…", symbol: "square.and.arrow.down") { [weak self] in self?.onImport?() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = AppTheme.scaledFont(size: 15, weight: .semibold, textStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.accessibilityIdentifier = "empty-library-title"
        messageLabel.font = AppTheme.scaledFont(size: 13, textStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.accessibilityIdentifier = "empty-library-message"

        actions.axis = .vertical
        actions.spacing = 7
        actions.alignment = .fill
        createButton.accessibilityIdentifier = "empty-create"
        clipboardButton.accessibilityIdentifier = "empty-clipboard"
        importButton.accessibilityIdentifier = "empty-import"
        [createButton, clipboardButton, importButton].forEach(actions.addArrangedSubview)

        let icon = UIImageView(image: UIImage(systemName: "text.page"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        icon.tintColor = .tertiaryLabel
        let stack = UIStackView(arrangedSubviews: [icon, titleLabel, messageLabel, actions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 10
        stack.alignment = .center
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            actions.widthAnchor.constraint(equalToConstant: 200),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(
        title: String,
        message: String,
        showsActions: Bool,
        importOnly: Bool = false
    ) {
        titleLabel.text = title
        messageLabel.text = message
        actions.isHidden = !showsActions
        createButton.isHidden = importOnly
        clipboardButton.isHidden = importOnly
        importButton.isHidden = false
    }

    private func actionButton(title: String, symbol: String, handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 7
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.baseForegroundColor = AppTheme.tint
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }
}

private final class SnippetTagDotView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = 3.5
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        isAccessibilityElement = true
        accessibilityTraits = .staticText

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 7),
            heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(tag: String, muted: Bool) {
        backgroundColor = muted ? .tertiaryLabel : AppTheme.tagColor(for: tag)
        accessibilityLabel = "Tag: \(tag)"
    }
}
