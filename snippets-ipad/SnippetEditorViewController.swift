import UIKit

final class SnippetEditorViewController: UIViewController {
    weak var delegate: SnippetEditorViewControllerDelegate?

    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let formStack = UIStackView()
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let bodyTextView = UITextView()
    private let bodyContainer = UIView()
    private let lockedOverlay = UIView()
    private let revealButton = UIButton(type: .system)
    private let previewSection = UIStackView()
    private let previewLabel = UILabel()
    private let keywordField = UITextField()
    private let keywordStatusLabel = UILabel()
    private let suggestionsStack = UIStackView()
    private let nameField = UITextField()
    private let tagField = TagTokenField()
    private let enabledSwitch = UISwitch()
    private let secureSwitch = UISwitch()
    private let footerStatusLabel = UILabel()

    private var selectedID: UUID?
    private var isBinding = false
    private var isPublishingEditorChange = false
    private var secureContentIsRevealed = false
    private var secureSaveWorkItem: DispatchWorkItem?

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        configureForm()
        configureActions()
        configureNotifications()
        bind(to: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        flushPendingSecureContent()
        commitPlainEditTransaction()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Copy Snippet", action: #selector(copySnippet), input: "\r", modifierFlags: .command),
            UIKeyCommand(title: "Delete Snippet", action: #selector(deleteSnippet), input: UIKeyCommand.inputDelete, modifierFlags: .command),
        ]
    }

    func bind(to id: UUID?, preserveFirstResponder: Bool = false) {
        guard isViewLoaded else {
            selectedID = id
            return
        }
        if preserveFirstResponder, id == selectedID,
           view.findFirstResponder() != nil || isPublishingEditorChange {
            refreshDerivedUI()
            return
        }

        flushPendingSecureContent()
        commitPlainEditTransaction()
        selectedID = id
        secureContentIsRevealed = false

        guard let id, let snippet = environment.store.snippetForDisplay(id: id) else {
            showEmptyEditor()
            return
        }

        isBinding = true
        title = snippet.displayName
        nameField.text = snippet.name
        keywordField.text = snippet.normalizedKeyword
        tagField.setTags(snippet.tags)
        enabledSwitch.isOn = snippet.isEnabled
        secureSwitch.isOn = environment.store.isSecure(id)
        bodyTextView.text = environment.store.isSecure(id) ? "" : snippet.content
        isBinding = false

        scrollView.isHidden = false
        emptyView.isHidden = true
        updateSecurePresentation()
        refreshDerivedUI()
        updateNavigationActions()
    }

    func focusBody() {
        guard !environment.store.isSecure(selectedID ?? UUID()) else { return }
        bodyTextView.becomeFirstResponder()
    }

    func prepareForModalPresentation() {
        guard isViewLoaded else { return }
        view.endEditing(true)
        flushPendingSecureContent()
        commitPlainEditTransaction()
    }

    func applyTheme() {
        view.tintColor = AppTheme.tint
        suggestionsStack.arrangedSubviews.compactMap { $0 as? UIButton }.forEach {
            $0.configuration?.baseForegroundColor = AppTheme.tint
            $0.configuration?.baseBackgroundColor = AppTheme.tint.withAlphaComponent(0.12)
        }
    }

    private func configureForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 22

        let glass = AppTheme.glassView()
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 22
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.contentView.addSubview(formStack)
        scrollView.addSubview(glass)
        view.addSubview(scrollView)

        emptyView.translatesAutoresizingMaskIntoConstraints = false
        var emptyConfiguration = UIContentUnavailableConfiguration.empty()
        emptyConfiguration.image = UIImage(systemName: "text.page")
        emptyConfiguration.text = "Select a snippet"
        emptyConfiguration.secondaryText = "Choose a snippet from the sidebar or create a new one."
        emptyView.configuration = emptyConfiguration
        view.addSubview(emptyView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            glass.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            glass.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 20),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -20),
            glass.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            glass.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            glass.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -40).withPriority(.defaultHigh),
            formStack.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -24),
            formStack.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 24),
            formStack.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -24),
            emptyView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureBody()
        configureTextFields()
        configureSwitches()

        formStack.addArrangedSubview(section(title: "Content", content: bodyContainer))
        formStack.addArrangedSubview(previewSection)
        formStack.addArrangedSubview(section(title: "Keyword", content: keywordSection()))
        formStack.addArrangedSubview(section(title: "Name", content: nameField))
        formStack.addArrangedSubview(section(title: "Tags", content: tagField))
        formStack.addArrangedSubview(switchRow(title: "Enabled", detail: "Available to the Mac app’s expansion engine.", control: enabledSwitch))
        formStack.addArrangedSubview(switchRow(title: "Secure", detail: "Encrypt content and require Face ID, Touch ID, or device passcode to reveal it.", control: secureSwitch))

        footerStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        footerStatusLabel.textColor = .secondaryLabel
        footerStatusLabel.numberOfLines = 0
        footerStatusLabel.accessibilityIdentifier = "editor-status"
        formStack.addArrangedSubview(footerStatusLabel)
    }

    private func configureBody() {
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.layer.cornerRadius = 12
        bodyContainer.layer.cornerCurve = .continuous
        bodyContainer.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        bodyContainer.layer.borderColor = UIColor.separator.cgColor
        bodyContainer.clipsToBounds = true

        bodyTextView.translatesAutoresizingMaskIntoConstraints = false
        bodyTextView.font = .preferredFont(forTextStyle: .body)
        bodyTextView.adjustsFontForContentSizeCategory = true
        bodyTextView.backgroundColor = .secondarySystemBackground
        bodyTextView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        bodyTextView.delegate = self
        bodyTextView.accessibilityIdentifier = "snippet-content"
        bodyTextView.smartDashesType = .no
        bodyTextView.smartQuotesType = .no

        lockedOverlay.translatesAutoresizingMaskIntoConstraints = false
        lockedOverlay.backgroundColor = .secondarySystemBackground
        let lockImage = UIImageView(image: UIImage(systemName: "lock.fill"))
        lockImage.tintColor = AppTheme.warning
        var revealConfiguration = UIButton.Configuration.tinted()
        revealConfiguration.title = "Reveal Secure Content"
        revealConfiguration.image = UIImage(systemName: "faceid")
        revealConfiguration.imagePadding = 8
        revealConfiguration.cornerStyle = .capsule
        revealButton.configuration = revealConfiguration
        revealButton.accessibilityIdentifier = "reveal-secure-content"
        revealButton.addAction(UIAction { [weak self] _ in self?.revealSecureContent() }, for: .touchUpInside)
        let lockStack = UIStackView(arrangedSubviews: [lockImage, revealButton])
        lockStack.translatesAutoresizingMaskIntoConstraints = false
        lockStack.axis = .vertical
        lockStack.alignment = .center
        lockStack.spacing = 14

        bodyContainer.addSubview(bodyTextView)
        bodyContainer.addSubview(lockedOverlay)
        lockedOverlay.addSubview(lockStack)
        NSLayoutConstraint.activate([
            bodyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            bodyTextView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            bodyTextView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            bodyTextView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            bodyTextView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            lockedOverlay.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            lockedOverlay.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            lockedOverlay.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            lockedOverlay.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            lockStack.centerXAnchor.constraint(equalTo: lockedOverlay.centerXAnchor),
            lockStack.centerYAnchor.constraint(equalTo: lockedOverlay.centerYAnchor),
        ])

        previewSection.axis = .vertical
        previewSection.spacing = 7
        let previewTitle = sectionLabel("Preview")
        previewLabel.font = .preferredFont(forTextStyle: .body)
        previewLabel.numberOfLines = 0
        previewLabel.textColor = .secondaryLabel
        previewLabel.accessibilityIdentifier = "snippet-preview"
        previewSection.addArrangedSubview(previewTitle)
        previewSection.addArrangedSubview(previewLabel)
    }

    private func configureTextFields() {
        configure(field: keywordField, placeholder: "sig", identifier: "snippet-keyword")
        keywordField.autocapitalizationType = .none
        keywordField.autocorrectionType = .no
        configure(field: nameField, placeholder: "Snippet name", identifier: "snippet-name")
        keywordField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        nameField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        keywordField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        nameField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        keywordField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        nameField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        tagField.onChange = { [weak self] _ in self?.editorChanged() }

        keywordStatusLabel.font = .preferredFont(forTextStyle: .caption1)
        keywordStatusLabel.textColor = AppTheme.warning
        keywordStatusLabel.numberOfLines = 0
        suggestionsStack.axis = .horizontal
        suggestionsStack.alignment = .center
        suggestionsStack.spacing = 8
    }

    private func configureSwitches() {
        enabledSwitch.accessibilityIdentifier = "snippet-enabled"
        secureSwitch.accessibilityIdentifier = "snippet-secure"
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.editorChanged() }, for: .valueChanged)
        secureSwitch.addAction(UIAction { [weak self] _ in self?.secureSwitchChanged() }, for: .valueChanged)
    }

    private func configureActions() {
        updateNavigationActions()
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultStateChanged),
            name: .snippetsVaultStateChanged,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(willResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    private func configure(field: UITextField, placeholder: String, identifier: String) {
        field.borderStyle = .roundedRect
        field.backgroundColor = .secondarySystemBackground
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func section(title: String, content: UIView) -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [sectionLabel(title), content])
        stack.axis = .vertical
        stack.spacing = 7
        return stack
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func keywordSection() -> UIStackView {
        let stack = UIStackView(arrangedSubviews: [keywordField, keywordStatusLabel, suggestionsStack])
        stack.axis = .vertical
        stack.spacing = 7
        return stack
    }

    private func switchRow(title: String, detail: String, control: UISwitch) -> UIView {
        let titleLabel = sectionLabel(title)
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 3
        let row = UIStackView(arrangedSubviews: [labels, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        return row
    }

    private func showEmptyEditor() {
        selectedID = nil
        title = "Snippets"
        scrollView.isHidden = true
        emptyView.isHidden = false
        navigationItem.rightBarButtonItems = nil
    }

    private func updateNavigationActions() {
        guard let id = selectedID, let snippet = environment.store.snippetForDisplay(id: id) else {
            navigationItem.rightBarButtonItems = nil
            return
        }
        let isSecure = environment.store.isSecure(id)
        let copy = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            style: .plain,
            target: self,
            action: #selector(copySnippet)
        )
        copy.isEnabled = !isSecure
        copy.accessibilityIdentifier = "copy-snippet"

        var children: [UIMenuElement] = [
            UIAction(title: snippet.isPinned ? "Unpin" : "Pin", image: UIImage(systemName: "pin")) { [weak self] _ in self?.togglePin() },
        ]
        if !isSecure {
            children.append(contentsOf: [
                UIAction(title: "Copy Share Link", image: UIImage(systemName: "link")) { [weak self] _ in self?.copyShareLink() },
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSnippet() },
            ])
        }
        children.append(contentsOf: [
            UIAction(title: "Keyboard Shortcuts", image: UIImage(systemName: "keyboard")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetEditorRequestedShortcuts(self)
            },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                guard let self else { return }
                self.delegate?.snippetEditorRequestedSettings(self)
            },
            UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.deleteSnippet() },
        ])
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: children))
        navigationItem.rightBarButtonItems = [more, copy]
    }

    private func updateSecurePresentation() {
        guard let selectedID else { return }
        let secure = environment.store.isSecure(selectedID)
        lockedOverlay.isHidden = !secure || secureContentIsRevealed
        bodyTextView.isEditable = !secure || secureContentIsRevealed
        bodyTextView.accessibilityLabel = secure && !secureContentIsRevealed
            ? "Secure content locked"
            : "Snippet content"
    }

    private func refreshDerivedUI() {
        guard let id = selectedID,
              let snippet = environment.store.snippetForDisplay(id: id) else { return }
        title = snippet.displayName
        updatePreview()
        updateKeywordStatus(for: snippet)
        updateSuggestions(for: snippet)
        footerStatusLabel.text = environment.store.isSecure(id)
            ? (secureContentIsRevealed ? "Secure content is revealed until the vault locks." : "Content is encrypted and hidden. Metadata remains searchable.")
            : (snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))
        updateNavigationActions()
    }

    private func updatePreview() {
        let template = bodyTextView.text ?? ""
        let hasPlaceholders = PlaceholderResolver.containsResolvablePlaceholder(in: template)
        previewSection.isHidden = !hasPlaceholders || (selectedID.map(environment.store.isSecure) == true && !secureContentIsRevealed)
        guard !previewSection.isHidden else { return }
        previewLabel.text = PlaceholderResolver.resolveForPreview(
            template: template,
            clipboard: { "[Clipboard content]" }
        )
    }

    private func updateKeywordStatus(for snippet: Snippet) {
        let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        let trigger = "\\\(snippet.normalizedKeyword)"
        guard !keyword.isEmpty else {
            keywordStatusLabel.text = "Add a keyword to make this available for expansion on Mac."
            return
        }
        guard snippet.isEnabled else {
            keywordStatusLabel.text = "Disabled — \(trigger) won’t expand."
            return
        }
        guard !snippet.normalizedKeyword.contains(where: { $0.unicodeScalars.count > 1 }) else {
            keywordStatusLabel.text = "\(trigger) needs letters, digits, or hyphens."
            return
        }

        let candidates = environment.store.enabledSnippetsSorted()
            + environment.secureStore.enabledShellsSortedForDisplay()
        for other in candidates where other.id != snippet.id {
            switch KeywordRelation.between(keyword, SnippetTagging.filterKey(for: other.normalizedKeyword)) {
            case .duplicate:
                keywordStatusLabel.text = "\(trigger) is already used by \(other.displayName)."
                return
            case .blockedByLonger:
                keywordStatusLabel.text = "\(trigger) is blocked by \\(other.normalizedKeyword)."
                return
            case .blocksShorter:
                keywordStatusLabel.text = "This prevents \\(other.normalizedKeyword) from expanding."
                return
            case .unrelated:
                continue
            }
        }
        keywordStatusLabel.text = ""
    }

    private func updateSuggestions(for snippet: Snippet) {
        suggestionsStack.arrangedSubviews.forEach { view in
            suggestionsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard snippet.normalizedKeyword.isEmpty else {
            suggestionsStack.isHidden = true
            return
        }
        let existing = (environment.store.enabledSnippetsSorted() + environment.secureStore.enabledShellsSortedForDisplay())
            .filter { $0.id != snippet.id }
            .map { SnippetTagging.filterKey(for: $0.normalizedKeyword) }
        let suggestions = KeywordSuggestions.candidates(
            name: snippet.name,
            contentFirstLine: environment.store.isSecure(snippet.id) ? "" : snippet.contentFirstLine
        ).filter { candidate in
            existing.allSatisfy { KeywordRelation.between(candidate, $0) == .unrelated }
        }.prefix(3)

        for suggestion in suggestions {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = "\\\(suggestion)"
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.baseForegroundColor = AppTheme.tint
            configuration.baseBackgroundColor = AppTheme.tint.withAlphaComponent(0.12)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = "Use keyword \(suggestion)"
            button.addAction(UIAction { [weak self] _ in
                self?.keywordField.text = suggestion
                self?.editorChanged()
            }, for: .touchUpInside)
            suggestionsStack.addArrangedSubview(button)
        }
        suggestionsStack.isHidden = suggestions.isEmpty
    }

    private func editorChanged() {
        guard !isBinding, let id = selectedID,
              let current = environment.store.snippetForDisplay(id: id) else { return }

        isPublishingEditorChange = true
        defer { isPublishingEditorChange = false }

        let sanitizedKeyword = Snippet.sanitizedKeyword(keywordField.text ?? "")
        if keywordField.text != sanitizedKeyword { keywordField.text = sanitizedKeyword }

        do {
            if environment.store.isSecure(id) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(
                        id: id,
                        name: nameField.text ?? "",
                        keyword: sanitizedKeyword,
                        tags: tagField.currentTags(),
                        isEnabled: enabledSwitch.isOn
                    )
                }
            } else {
                guard var updated = environment.store.snippet(id: id) else { return }
                updated.name = nameField.text ?? ""
                updated.keyword = sanitizedKeyword
                updated.content = bodyTextView.text ?? ""
                updated.tags = tagField.currentTags()
                updated.isEnabled = enabledSwitch.isOn
                environment.store.update(updated)
            }
            let refreshed = environment.store.snippetForDisplay(id: id) ?? current
            refreshDerivedUIForImmediateEdit(refreshed)
        } catch {
            footerStatusLabel.text = "Couldn’t save: \(error)"
        }
    }

    private func refreshDerivedUIForImmediateEdit(_ snippet: Snippet) {
        title = snippet.displayName
        updatePreview()
        updateKeywordStatus(for: snippet)
        updateSuggestions(for: snippet)
    }

    private func beginPlainEditTransaction() {
        guard let selectedID, !environment.store.isSecure(selectedID) else { return }
        environment.store.beginEditTransaction()
    }

    private func commitPlainEditTransaction() {
        guard let selectedID, !environment.store.isSecure(selectedID) else { return }
        environment.store.commitEditTransaction()
    }

    private func secureSwitchChanged() {
        guard !isBinding, let id = selectedID else { return }
        secureSwitch.setOn(environment.store.isSecure(id), animated: true)
        if environment.store.isSecure(id) {
            makeOrdinary(id: id)
        } else {
            makeSecure(id: id)
        }
    }

    private func makeSecure(id: UUID) {
        var recoveryKey: String?
        do {
            _ = try environment.performLocalSecureChange {
                try environment.secureStore.createVaultIfNeeded { key in
                    recoveryKey = key
                    return true
                }
            }
        } catch {
            showError(title: "Couldn’t Set Up Secure Snippets", error: error)
            return
        }

        let continuePromotion = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.environment.vaultSession.unlock(
                        reason: "Make this snippet secure"
                    )
                    try self.environment.performLocalSecureChange {
                        try self.environment.secureStore.promote(snippetID: id)
                    }
                    self.bind(to: id)
                } catch {
                    self.showError(title: "Couldn’t Make Snippet Secure", error: error)
                }
            }
        }

        guard let recoveryKey else {
            continuePromotion()
            return
        }
        showRecoveryKey(recoveryKey, completion: continuePromotion)
    }

    private func makeOrdinary(id: UUID) {
        let alert = UIAlertController(
            title: "Make This Snippet Ordinary?",
            message: "Its content will be decrypted and stored in the ordinary library, where it can be copied, shared, and exported.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Make Ordinary", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.environment.vaultSession.unlock(reason: "Decrypt this secure snippet")
                    try self.environment.performLocalSecureChange {
                        try self.environment.secureStore.demote(recordID: id)
                    }
                    self.bind(to: id)
                } catch {
                    self.showError(title: "Couldn’t Make Snippet Ordinary", error: error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func showRecoveryKey(_ key: String, completion: @escaping () -> Void) {
        let alert = UIAlertController(
            title: "Save Your Recovery Key",
            message: "Store this somewhere safe. It is the only way to recover secure snippets if the shared Keychain key is lost.\n\n\(key)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy & Continue", style: .default) { _ in
            UIPasteboard.general.string = key
            completion()
        })
        alert.addAction(UIAlertAction(title: "I’ve Saved It", style: .default) { _ in completion() })
        present(alert, animated: true)
    }

    private func revealSecureContent() {
        guard let id = selectedID, environment.store.isSecure(id) else { return }
        Task { @MainActor in
            do {
                _ = try await environment.vaultSession.unlock(
                    reason: "Reveal “\(environment.store.snippetForDisplay(id: id)?.displayName ?? "secure snippet")”"
                )
                bodyTextView.text = try environment.secureStore.content(for: id)
                secureContentIsRevealed = true
                updateSecurePresentation()
                refreshDerivedUI()
            } catch {
                showError(title: "Couldn’t Reveal Secure Content", error: error)
            }
        }
    }

    private func scheduleSecureContentSave() {
        secureSaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.secureSaveWorkItem = nil
            self?.saveSecureContentNow()
        }
        secureSaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    private func flushPendingSecureContent() {
        guard secureSaveWorkItem != nil else { return }
        secureSaveWorkItem?.cancel()
        secureSaveWorkItem = nil
        saveSecureContentNow()
    }

    private func saveSecureContentNow() {
        guard let id = selectedID,
              environment.store.isSecure(id),
              secureContentIsRevealed else { return }
        do {
            try environment.performLocalSecureChange {
                try environment.secureStore.setContent(bodyTextView.text ?? "", for: id)
            }
        } catch {
            footerStatusLabel.text = "Secure edit wasn’t saved: \(error)"
        }
    }

    private func togglePin() {
        guard let id = selectedID,
              let snippet = environment.store.snippetForDisplay(id: id) else { return }
        do {
            if environment.store.isSecure(id) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(id: id, isPinned: !snippet.isPinned)
                }
            } else {
                environment.store.togglePinned(snippetID: id)
            }
        } catch {
            showError(title: "Couldn’t Update Pin", error: error)
        }
    }

    @objc private func copySnippet() {
        guard let id = selectedID,
              !environment.store.isSecure(id),
              let snippet = environment.store.snippet(id: id) else { return }
        let clipboard = UIPasteboard.general.string
        UIPasteboard.general.string = PlaceholderResolver.resolve(
            template: snippet.content,
            clipboard: { clipboard }
        )
        footerStatusLabel.text = "Copied “\(snippet.displayName)”."
    }

    private func copyShareLink() {
        guard let id = selectedID,
              !environment.store.isSecure(id),
              let snippet = environment.store.snippet(id: id) else { return }
        do {
            UIPasteboard.general.url = try SnippetDeepLink.url(for: snippet, isSecure: false)
            footerStatusLabel.text = "Copied share link."
        } catch {
            showError(title: "Couldn’t Copy Share Link", error: error)
        }
    }

    private func share() {
        guard let id = selectedID,
              !environment.store.isSecure(id),
              let snippet = environment.store.snippet(id: id),
              let url = try? SnippetDeepLink.url(for: snippet, isSecure: false) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }

    private func duplicateSnippet() {
        guard let id = selectedID else { return }
        delegate?.snippetEditorRequestedDuplicate(self, id: id)
    }

    @objc private func deleteSnippet() {
        guard let id = selectedID else { return }
        delegate?.snippetEditorRequestedDelete(self, id: id)
    }

    private func showError(title: String, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    @objc private func fieldChanged() { editorChanged() }
    @objc private func editingBegan() { beginPlainEditTransaction() }
    @objc private func editingEnded() { editorChanged(); commitPlainEditTransaction() }

    @objc private func vaultStateChanged() {
        guard let id = selectedID, environment.store.isSecure(id) else { return }
        guard !environment.vaultSession.state.isUnlocked else { return }
        secureSaveWorkItem?.cancel()
        secureSaveWorkItem = nil
        secureContentIsRevealed = false
        bodyTextView.text = ""
        updateSecurePresentation()
        refreshDerivedUI()
    }

    @objc private func willResignActive() {
        flushPendingSecureContent()
        view.endEditing(true)
    }

    @objc private func keyboardFrameChanged(_ notification: Notification) {
        guard let window = view.window,
              let screenFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return }
        let windowFrame = window.convert(screenFrame, from: window.screen.coordinateSpace)
        let viewFrame = view.convert(windowFrame, from: window)
        updateKeyboardInset(max(0, view.bounds.maxY - viewFrame.minY), notification: notification)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        updateKeyboardInset(0, notification: notification)
    }

    private func updateKeyboardInset(_ overlap: CGFloat, notification: Notification) {
        let bottomInset = max(0, overlap - view.safeAreaInsets.bottom)
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        let options = UIView.AnimationOptions(rawValue: rawCurve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.scrollView.contentInset.bottom = bottomInset
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }
}

extension SnippetEditorViewController: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        beginPlainEditTransaction()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isBinding else { return }
        if let selectedID, environment.store.isSecure(selectedID) {
            scheduleSecureContentSave()
            updatePreview()
        } else {
            editorChanged()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if let selectedID, environment.store.isSecure(selectedID) {
            flushPendingSecureContent()
        } else {
            editorChanged()
            commitPlainEditTransaction()
        }
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

private extension UIView {
    func findFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.findFirstResponder() { return responder }
        }
        return nil
    }
}
