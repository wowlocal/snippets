import UIKit

final class SnippetListViewController: UIViewController {
    weak var delegate: SnippetListViewControllerDelegate?

    private let environment: AppEnvironment
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let tagScrollView = UIScrollView()
    private let tagStack = UIStackView()
    private let statusLabel = UILabel()
    private let emptyView = EmptyLibraryView()
    private let searchController = UISearchController(searchResultsController: nil)
    private var visibleSnippets: [Snippet] = []
    private var activeTagKeys = Set<String>()
    private var selectedID: UUID?
    private var statusWorkItem: DispatchWorkItem?

    var firstVisibleSnippetID: UUID? { visibleSnippets.first?.id }

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Snippets"
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true
        view.backgroundColor = .systemBackground

        configureSearch()
        configureToolbar()
        configureTags()
        configureTable()
        configureEmptyView()
        reload(keepingSelection: false)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Search", action: #selector(focusSearch), input: "f", modifierFlags: .command)]
    }

    func reload(keepingSelection: Bool) {
        let query = searchController.searchBar.text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let existingTagKeys = Set(environment.store.allTags().map(SnippetTagging.filterKey(for:)))
        activeTagKeys.formIntersection(existingTagKeys)

        visibleSnippets = environment.store.snippetsSortedForDisplay().filter { snippet in
            let matchesSearch = query.isEmpty
                || snippet.displayName.lowercased().contains(query)
                || snippet.normalizedKeyword.lowercased().contains(query)
                || snippet.content.lowercased().contains(query)
                || snippet.tags.contains { $0.lowercased().contains(query) }
            let matchesTags = activeTagKeys.allSatisfy { snippet.hasTag(withKey: $0) }
            return matchesSearch && matchesTags
        }

        rebuildTagButtons()
        tableView.reloadData()
        updateEmptyState(query: query)

        if keepingSelection, let selectedID,
           let row = visibleSnippets.firstIndex(where: { $0.id == selectedID }) {
            tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
        } else if !keepingSelection {
            selectedID = nil
        }
    }

    func select(id: UUID) {
        selectedID = id
        guard let row = visibleSnippets.firstIndex(where: { $0.id == id }) else { return }
        tableView.selectRow(at: IndexPath(row: row, section: 0), animated: false, scrollPosition: .none)
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

    func applyTheme() {
        view.tintColor = AppTheme.tint
        rebuildTagButtons()
        tableView.reloadData()
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search snippets"
        searchController.searchBar.accessibilityIdentifier = "snippet-search"
        searchController.searchBar.searchTextField.accessibilityIdentifier = "snippet-search"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func configureToolbar() {
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
            UIAction(title: "Export", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetListRequestedExport(self)
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

    private func configureTags() {
        tagScrollView.translatesAutoresizingMaskIntoConstraints = false
        tagScrollView.showsHorizontalScrollIndicator = false
        tagScrollView.accessibilityIdentifier = "tag-filters"

        tagStack.translatesAutoresizingMaskIntoConstraints = false
        tagStack.axis = .horizontal
        tagStack.spacing = 8
        tagStack.alignment = .center
        tagScrollView.addSubview(tagStack)

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .caption1)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 1
        statusLabel.isHidden = true

        view.addSubview(tagScrollView)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            tagScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            tagScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tagScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tagScrollView.heightAnchor.constraint(equalToConstant: 44),
            tagStack.leadingAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            tagStack.trailingAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            tagStack.topAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.topAnchor),
            tagStack.bottomAnchor.constraint(equalTo: tagScrollView.contentLayoutGuide.bottomAnchor),
            tagStack.heightAnchor.constraint(equalTo: tagScrollView.frameLayoutGuide.heightAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
    }

    private func configureTable() {
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.delegate = self
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SnippetListCell.self, forCellReuseIdentifier: SnippetListCell.reuseIdentifier)
        tableView.accessibilityIdentifier = "snippet-list"
        view.insertSubview(tableView, belowSubview: statusLabel)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: tagScrollView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
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
        emptyView.onSync = { [weak self] in
            guard let self else { return }
            self.delegate?.snippetListRequestedSettings(self)
        }
    }

    private func rebuildTagButtons() {
        tagStack.arrangedSubviews.forEach { view in
            tagStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let tags = environment.store.tagUsage()
        tagScrollView.isHidden = tags.isEmpty

        if !activeTagKeys.isEmpty {
            let clear = TagFilterButton(title: "Clear", selected: false)
            clear.addAction(UIAction { [weak self] _ in
                self?.activeTagKeys.removeAll()
                self?.reload(keepingSelection: true)
            }, for: .touchUpInside)
            tagStack.addArrangedSubview(clear)
        }

        for item in tags {
            let key = SnippetTagging.filterKey(for: item.tag)
            let button = TagFilterButton(
                title: "\(item.tag)  \(item.count)",
                selected: activeTagKeys.contains(key)
            )
            button.accessibilityLabel = "Filter by \(item.tag), \(item.count) snippets"
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                if !self.activeTagKeys.insert(key).inserted {
                    self.activeTagKeys.remove(key)
                }
                self.reload(keepingSelection: true)
            }, for: .touchUpInside)
            tagStack.addArrangedSubview(button)
        }
    }

    private func updateEmptyState(query: String) {
        guard visibleSnippets.isEmpty else {
            tableView.backgroundView = nil
            return
        }
        if environment.store.snippetsSortedForDisplay().isEmpty {
            emptyView.configure(
                title: "Your snippet library is empty",
                message: "Create your first snippet, import an existing library, or turn on iCloud Sync.",
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
        guard !environment.store.isSecure(snippet.id) else { return }
        let clipboard = UIPasteboard.general.string
        UIPasteboard.general.string = PlaceholderResolver.resolve(
            template: snippet.content,
            clipboard: { clipboard }
        )
        showStatus("Copied “\(snippet.displayName)”.")
    }

    private func copyLink(_ snippet: Snippet) {
        do {
            UIPasteboard.general.url = try SnippetDeepLink.url(for: snippet, isSecure: false)
            showStatus("Copied share link.")
        } catch {
            showStatus("Couldn’t copy link: \(error)")
        }
    }

    private func contextMenu(for snippet: Snippet) -> UIMenu {
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
        ]
        if !isSecure {
            actions.append(contentsOf: [
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(snippet) },
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

    @objc private func focusSearch() {
        searchController.isActive = true
        DispatchQueue.main.async { [weak self] in
            self?.searchController.searchBar.searchTextField.becomeFirstResponder()
        }
    }
}

extension SnippetListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        reload(keepingSelection: true)
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
            selectedColor: AppTheme.selectedRow
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let snippet = snippet(at: indexPath)
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
}

private final class SnippetListCell: UITableViewCell {
    static let reuseIdentifier = "SnippetListCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let stateImage = UIImageView()
    private let pinImage = UIImageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectedBackgroundView = UIView()

        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 1
        stateImage.contentMode = .scaleAspectFit
        pinImage.contentMode = .scaleAspectFit

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 3
        let row = UIStackView(arrangedSubviews: [stateImage, text, pinImage])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
            stateImage.widthAnchor.constraint(equalToConstant: 18),
            stateImage.heightAnchor.constraint(equalToConstant: 18),
            pinImage.widthAnchor.constraint(equalToConstant: 16),
            pinImage.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(snippet: Snippet, isSecure: Bool, selectedColor: UIColor) {
        titleLabel.text = snippet.displayName
        var details: [String] = []
        if !snippet.normalizedKeyword.isEmpty { details.append("\\\(snippet.normalizedKeyword)") }
        if !snippet.tags.isEmpty { details.append(snippet.tags.map { "#\($0)" }.joined(separator: "  ")) }
        detailLabel.text = details.isEmpty ? "No keyword" : details.joined(separator: "  •  ")
        stateImage.image = UIImage(systemName: isSecure ? "lock.fill" : (snippet.isEnabled ? "circle.fill" : "circle"))
        stateImage.tintColor = isSecure ? AppTheme.warning : AppTheme.enabled
        pinImage.image = snippet.isPinned ? UIImage(systemName: "pin.fill") : nil
        pinImage.tintColor = AppTheme.pin
        contentView.alpha = snippet.isEnabled ? 1 : 0.58
        selectedBackgroundView?.backgroundColor = selectedColor
        accessibilityIdentifier = "snippet-row-\(snippet.id.uuidString)"
        accessibilityLabel = snippet.displayName
        accessibilityValue = [isSecure ? "Secure" : nil, snippet.isPinned ? "Pinned" : nil, snippet.isEnabled ? "Enabled" : "Disabled"]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

private final class TagFilterButton: UIButton {
    init(title: String, selected: Bool) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.baseForegroundColor = selected ? .white : AppTheme.tint
        configuration.baseBackgroundColor = selected ? AppTheme.tint : AppTheme.tint.withAlphaComponent(0.10)
        self.configuration = configuration
        accessibilityTraits = selected ? [.button, .selected] : .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class EmptyLibraryView: UIView {
    var onCreate: (() -> Void)?
    var onImport: (() -> Void)?
    var onSync: (() -> Void)?

    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actions = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .title3)
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actions.axis = .vertical
        actions.spacing = 10
        actions.alignment = .fill
        let create = actionButton(title: "Create Snippet", symbol: "plus") { [weak self] in self?.onCreate?() }
        create.accessibilityIdentifier = "empty-create"
        let importButton = actionButton(title: "Import Library", symbol: "square.and.arrow.down") { [weak self] in self?.onImport?() }
        let sync = actionButton(title: "Set Up iCloud Sync", symbol: "icloud") { [weak self] in self?.onSync?() }
        [create, importButton, sync].forEach(actions.addArrangedSubview)

        let stack = UIStackView(arrangedSubviews: [UIImageView(image: UIImage(systemName: "text.page")), titleLabel, messageLabel, actions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .center
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),
            actions.widthAnchor.constraint(equalToConstant: 220),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, message: String, showsActions: Bool) {
        titleLabel.text = title
        messageLabel.text = message
        actions.isHidden = !showsActions
    }

    private func actionButton(title: String, symbol: String, handler: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePadding = 8
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        return button
    }
}
