import UIKit

final class SnippetEditorViewController: UIViewController {
    weak var delegate: SnippetEditorViewControllerDelegate?

    private let environment: AppEnvironment
    private let scrollView = UIScrollView()
    private let formStack = UIStackView()
    private let emptyView = UIContentUnavailableView(configuration: .empty())
    private let bodyTextView = SecureSnippetTextView()
    private let bodyContainer = UIView()
    private let bodyPlaceholderLabel = UILabel()
    private let lockedOverlay = UIView()
    private let revealButton = UIButton(type: .system)
    private let previewSection = UIStackView()
    private let previewSurface = UIView()
    private let previewLabel = UILabel()
    private let keywordField = UITextField()
    private let keywordPrefixLabel = UILabel()
    private let keywordStatusLabel = UILabel()
    private let suggestionsStack = UIStackView()
    private let nameField = UITextField()
    private let tagField = TagTokenField()
    private let enabledSwitch = UISwitch()
    private let secureSwitch = UISwitch()
    private let enabledButton = UIButton(type: .system)
    private let secureButton = UIButton(type: .system)
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

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        updateBodyPlaceholder()
        updateToggleButtons()
        updateSecurePresentation()
        refreshDerivedUI()
        updateNavigationActions()
    }

    @discardableResult
    func focusBody() -> Bool {
        guard let selectedID,
              !environment.store.isSecure(selectedID) || secureContentIsRevealed else { return false }
        return bodyTextView.becomeFirstResponder()
    }

    @discardableResult
    func focusFirstEditorField() -> Bool {
        if focusBody() { return true }
        guard selectedID != nil else { return false }
        return keywordField.becomeFirstResponder()
    }

    /// Matches the macOS editor loop: Snippet → Keyword → Name → Tags → Snippet.
    /// Returning false for Shift-Tab from Snippet lets the split controller hand
    /// focus back to the selected sidebar row.
    @discardableResult
    func moveEditorFocus(forward: Bool) -> Bool {
        guard selectedID != nil else { return false }

        if bodyTextView.isFirstResponder {
            return forward ? keywordField.becomeFirstResponder() : false
        }
        if keywordField.isFirstResponder {
            return forward ? nameField.becomeFirstResponder() : focusBody()
        }
        if nameField.isFirstResponder {
            return forward ? tagField.focusInput() : keywordField.becomeFirstResponder()
        }
        if tagField.isInputFirstResponder {
            return forward ? focusFirstEditorField() : nameField.becomeFirstResponder()
        }
        return false
    }

    func prepareForModalPresentation() {
        guard isViewLoaded else { return }
        view.endEditing(true)
        flushPendingSecureContent()
        commitPlainEditTransaction()
    }

    private func configureForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = false
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 16

        scrollView.addSubview(formStack)
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
            formStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            formStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            formStack.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            formStack.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            formStack.centerXAnchor.constraint(equalTo: scrollView.frameLayoutGuide.centerXAnchor),
            formStack.widthAnchor.constraint(lessThanOrEqualToConstant: 820),
            formStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48).withPriority(.defaultHigh),
            emptyView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyView.topAnchor.constraint(equalTo: view.topAnchor),
            emptyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        configureBody()
        configureTextFields()
        configureSwitches()

        let snippetHeader = sectionLabel("Snippet")
        let snippetHeaderRow = UIStackView(arrangedSubviews: [snippetHeader, UIView(), secureButton])
        snippetHeaderRow.axis = .horizontal
        snippetHeaderRow.alignment = .center
        snippetHeaderRow.spacing = 8
        let snippetSection = UIStackView(arrangedSubviews: [snippetHeaderRow, bodyContainer])
        snippetSection.axis = .vertical
        snippetSection.spacing = 8

        formStack.addArrangedSubview(snippetSection)
        formStack.addArrangedSubview(previewSection)
        formStack.addArrangedSubview(section(title: "Keyword", content: keywordSection()))
        formStack.addArrangedSubview(section(title: "Name", content: nameField))
        formStack.addArrangedSubview(section(title: "Tags", content: tagField))
        formStack.addArrangedSubview(enabledButton)

        footerStatusLabel.font = AppTheme.scaledFont(size: 11, textStyle: .caption1)
        footerStatusLabel.adjustsFontForContentSizeCategory = true
        footerStatusLabel.textColor = .secondaryLabel
        footerStatusLabel.numberOfLines = 0
        footerStatusLabel.accessibilityIdentifier = "editor-status"
        formStack.addArrangedSubview(footerStatusLabel)
    }

    private func configureBody() {
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        AppTheme.configureSurface(bodyContainer, cornerRadius: 10)

        bodyTextView.translatesAutoresizingMaskIntoConstraints = false
        bodyTextView.font = AppTheme.scaledFont(size: 14, textStyle: .body, monospaced: true)
        bodyTextView.adjustsFontForContentSizeCategory = true
        bodyTextView.backgroundColor = .clear
        bodyTextView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        bodyTextView.delegate = self
        bodyTextView.accessibilityIdentifier = "snippet-content"
        bodyTextView.smartDashesType = .no
        bodyTextView.smartQuotesType = .no

        bodyPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyPlaceholderLabel.text = "Paste or type"
        bodyPlaceholderLabel.font = bodyTextView.font
        bodyPlaceholderLabel.textColor = .placeholderText
        bodyPlaceholderLabel.isUserInteractionEnabled = false

        lockedOverlay.translatesAutoresizingMaskIntoConstraints = false
        lockedOverlay.backgroundColor = AppTheme.editorSurface
        let lockImage = UIImageView(image: UIImage(systemName: "lock.fill"))
        lockImage.tintColor = AppTheme.warning
        var revealConfiguration = UIButton.Configuration.tinted()
        revealConfiguration.title = "Reveal Secure Content"
        revealConfiguration.image = UIImage(systemName: "lock.open")
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
        bodyTextView.addSubview(bodyPlaceholderLabel)
        bodyContainer.addSubview(lockedOverlay)
        lockedOverlay.addSubview(lockStack)
        NSLayoutConstraint.activate([
            bodyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
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
            bodyPlaceholderLabel.leadingAnchor.constraint(equalTo: bodyTextView.leadingAnchor, constant: 15),
            bodyPlaceholderLabel.topAnchor.constraint(equalTo: bodyTextView.topAnchor, constant: 12),
            bodyPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: bodyTextView.trailingAnchor, constant: -15),
        ])

        previewSection.axis = .vertical
        previewSection.spacing = 8
        let previewTitle = sectionLabel("Preview")
        previewSurface.translatesAutoresizingMaskIntoConstraints = false
        AppTheme.configureSurface(
            previewSurface,
            cornerRadius: 10,
            backgroundColor: AppTheme.previewSurface
        )
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = AppTheme.scaledFont(size: 13, weight: .medium, textStyle: .body, monospaced: true)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.numberOfLines = 8
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.textColor = .secondaryLabel
        previewLabel.accessibilityIdentifier = "snippet-preview"
        previewSurface.addSubview(previewLabel)
        previewSection.addArrangedSubview(previewTitle)
        previewSection.addArrangedSubview(previewSurface)
        NSLayoutConstraint.activate([
            previewSurface.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            previewLabel.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: 10),
            previewLabel.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -10),
            previewLabel.topAnchor.constraint(equalTo: previewSurface.topAnchor, constant: 9),
            previewLabel.bottomAnchor.constraint(equalTo: previewSurface.bottomAnchor, constant: -9),
        ])
    }

    private func configureTextFields() {
        configure(field: keywordField, placeholder: "sig", identifier: "snippet-keyword")
        keywordField.autocapitalizationType = .none
        keywordField.autocorrectionType = .no
        configure(field: nameField, placeholder: "First line is used when blank", identifier: "snippet-name")
        keywordField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        nameField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        keywordField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        nameField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        keywordField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        nameField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)
        tagField.onChange = { [weak self] _ in self?.editorChanged() }

        keywordPrefixLabel.text = "\\"
        keywordPrefixLabel.font = AppTheme.scaledFont(
            size: 16,
            weight: .medium,
            textStyle: .body,
            monospaced: true
        )
        keywordPrefixLabel.adjustsFontForContentSizeCategory = true
        keywordPrefixLabel.textColor = .tertiaryLabel
        keywordPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)

        keywordStatusLabel.font = AppTheme.scaledFont(size: 11, textStyle: .caption1)
        keywordStatusLabel.adjustsFontForContentSizeCategory = true
        keywordStatusLabel.textColor = AppTheme.warning
        keywordStatusLabel.numberOfLines = 0
        suggestionsStack.axis = .horizontal
        suggestionsStack.alignment = .center
        suggestionsStack.spacing = 8
    }

    private func configureSwitches() {
        enabledSwitch.accessibilityIdentifier = "snippet-enabled"
        enabledSwitch.accessibilityLabel = "Enabled"
        enabledSwitch.accessibilityHint = "Controls whether this keyword can expand on Mac."
        secureSwitch.accessibilityIdentifier = "snippet-secure"
        secureSwitch.accessibilityLabel = "Secure"
        secureSwitch.accessibilityHint = "Moves the content between the encrypted vault and the ordinary library."

        enabledButton.accessibilityIdentifier = "snippet-enabled"
        enabledButton.accessibilityLabel = "Enabled"
        enabledButton.accessibilityHint = "Double-tap to change whether this keyword can expand on Mac."
        enabledButton.contentHorizontalAlignment = .leading
        enabledButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.enabledSwitch.isOn.toggle()
            self.updateToggleButtons()
            self.editorChanged()
        }, for: .touchUpInside)

        secureButton.accessibilityIdentifier = "snippet-secure"
        secureButton.accessibilityLabel = "Make Secure"
        secureButton.accessibilityHint = "Moves the content between the encrypted vault and the ordinary library."
        secureButton.setContentHuggingPriority(.required, for: .horizontal)
        secureButton.addAction(UIAction { [weak self] _ in
            self?.secureSwitchChanged()
        }, for: .touchUpInside)
    }

    private func configureActions() {
        updateNavigationActions()
    }

    private func configureNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(vaultWillLock(_:)),
            name: .snippetsVaultWillLock,
            object: environment.vaultSession
        )
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
        field.borderStyle = .none
        field.backgroundColor = AppTheme.editorSurface
        field.layer.cornerRadius = 9
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        field.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        field.font = AppTheme.scaledFont(size: 15, textStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 1))
        field.rightViewMode = .always
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
        label.font = AppTheme.scaledFont(size: 13, weight: .semibold, textStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        return label
    }

    private func keywordSection() -> UIStackView {
        let fieldRow = UIStackView(arrangedSubviews: [keywordPrefixLabel, keywordField])
        fieldRow.axis = .horizontal
        fieldRow.alignment = .center
        fieldRow.spacing = 4
        let stack = UIStackView(arrangedSubviews: [fieldRow, keywordStatusLabel, suggestionsStack])
        stack.axis = .vertical
        stack.spacing = 7
        return stack
    }

    private func showEmptyEditor() {
        selectedID = nil
        title = "Snippets"
        scrollView.isHidden = true
        emptyView.isHidden = false
        navigationItem.rightBarButtonItems = nil
        enabledButton.isEnabled = false
        secureButton.isEnabled = false
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
        bodyTextView.isSecureContentMode = secure
        bodyTextView.accessibilityLabel = secure && !secureContentIsRevealed
            ? "Secure content locked"
            : "Snippet content"
        updateBodyPlaceholder()
        updateToggleButtons()
    }

    private func updateBodyPlaceholder() {
        let contentIsLocked = selectedID.map(environment.store.isSecure) == true
            && !secureContentIsRevealed
        bodyPlaceholderLabel.isHidden = contentIsLocked || !(bodyTextView.text ?? "").isEmpty
    }

    private func updateToggleButtons() {
        let hasSelection = selectedID != nil
        let isSecure = selectedID.map(environment.store.isSecure) == true
        let isEnabled = enabledSwitch.isOn

        var enabledConfiguration = UIButton.Configuration.plain()
        enabledConfiguration.title = "Enabled"
        enabledConfiguration.image = UIImage(
            systemName: isEnabled ? "checkmark.square.fill" : "square"
        )
        enabledConfiguration.imagePadding = 7
        enabledConfiguration.contentInsets = .zero
        enabledConfiguration.baseForegroundColor = .label
        enabledConfiguration.imageColorTransformer = UIConfigurationColorTransformer { _ in
            isEnabled ? AppTheme.tint : .secondaryLabel
        }
        enabledButton.configuration = enabledConfiguration
        enabledButton.isEnabled = hasSelection
        enabledButton.accessibilityValue = isEnabled ? "On" : "Off"

        var secureConfiguration = UIButton.Configuration.plain()
        secureConfiguration.image = UIImage(systemName: isSecure ? "lock.fill" : "lock")
        secureConfiguration.buttonSize = .small
        secureConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        secureConfiguration.baseForegroundColor = isSecure ? AppTheme.warning : .secondaryLabel
        secureButton.configuration = secureConfiguration
        secureButton.isEnabled = hasSelection
        secureButton.accessibilityLabel = isSecure ? "Make Ordinary" : "Make Secure"
        secureButton.accessibilityValue = isSecure ? "Secure" : "Ordinary"
    }

    private func refreshDerivedUI() {
        guard let id = selectedID,
              let snippet = environment.store.snippetForDisplay(id: id) else { return }
        applyDerivedUI(for: snippet)
    }

    private func applyDerivedUI(for snippet: Snippet) {
        title = snippet.displayName
        updateNamePlaceholder(for: snippet)
        updatePreview()
        updateKeywordStatus(for: snippet)
        updateSuggestions(for: snippet)
        footerStatusLabel.text = environment.store.isSecure(snippet.id)
            ? (secureContentIsRevealed ? "Secure content is revealed until the vault locks." : "Content is encrypted and hidden. Metadata remains searchable.")
            : (snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))
        updateNavigationActions()
        updateToggleButtons()
    }

    private func updateNamePlaceholder(for snippet: Snippet) {
        guard snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nameField.placeholder = "First line is used when blank"
            return
        }
        let fallback = environment.store.isSecure(snippet.id) ? "" : snippet.contentFirstLine
        nameField.placeholder = fallback.isEmpty ? "Untitled Snippet" : fallback
    }

    private func updatePreview() {
        updateBodyPlaceholder()
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
            try environment.performLocalEditorChange {
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
            }
            let refreshed = environment.store.snippetForDisplay(id: id) ?? current
            applyDerivedUI(for: refreshed)
        } catch {
            footerStatusLabel.text = "Couldn’t save: \(error)"
        }
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
        view.endEditing(true)
        commitPlainEditTransaction()
        environment.store.flushPendingWrites()

        let pendingCreation: SecureSnippetStore.PendingVaultCreation?
        do {
            pendingCreation = try environment.performLocalSecureChange {
                try environment.secureStore.prepareVaultCreationIfNeeded()
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
                        try SecureSnippetTransitionCoordinator.promote(
                            snippetID: id,
                            store: self.environment.store,
                            secureStore: self.environment.secureStore)
                    }
                    self.bind(to: id)
                } catch {
                    self.showError(title: "Couldn’t Make Snippet Secure", error: error)
                }
            }
        }

        guard let pendingCreation else {
            continuePromotion()
            return
        }
        showRecoveryKey(pendingCreation) { [weak self] in
            guard let self else { return }
            do {
                _ = try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.commitVaultCreation(pendingCreation)
                }
                continuePromotion()
            } catch {
                self.showError(title: "Couldn’t Set Up Secure Snippets", error: error)
            }
        }
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
            self.view.endEditing(true)
            self.flushPendingSecureContent()
            Task { @MainActor in
                do {
                    try await self.environment.vaultSession.withOneUseAuthentication(
                        reason: "Make this secure snippet ordinary"
                    ) {
                        try self.environment.performLocalSecureChange {
                            try SecureSnippetTransitionCoordinator.demote(
                                recordID: id,
                                store: self.environment.store,
                                secureStore: self.environment.secureStore)
                        }
                    }
                    self.bind(to: id)
                } catch {
                    self.showError(title: "Couldn’t Make Snippet Ordinary", error: error)
                }
            }
        })
        present(alert, animated: true)
    }

    private func showRecoveryKey(
        _ pending: SecureSnippetStore.PendingVaultCreation,
        completion: @escaping () -> Void
    ) {
        let key = pending.recoveryKeyText
        let alert = UIAlertController(
            title: "Save Your Recovery Key",
            message: "Store this somewhere safe. It is the only way to recover secure snippets if the shared Keychain key is lost.\n\n\(key)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Copy & Continue", style: .default) { _ in
            RecoveryKeyPasteboard.copy(key)
            completion()
        })
        alert.addAction(UIAlertAction(title: "I’ve Saved It", style: .default) { _ in completion() })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in pending.cancel() })
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
            try environment.performLocalEditorChange {
                try environment.performLocalSecureChange {
                    try environment.secureStore.setContent(bodyTextView.text ?? "", for: id)
                }
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

    @discardableResult
    func copySelectedSnippet() -> String? {
        guard let id = selectedID,
              !environment.store.isSecure(id),
              let snippet = environment.store.snippet(id: id) else { return nil }
        switch environment.snippetActions.copyOrdinary(snippet) {
        case .copied(let name, _):
            footerStatusLabel.text = "Copied “\(name)”."
            return name
        case .empty(let name):
            footerStatusLabel.text = "“\(name)” has no content to copy."
            return nil
        }
    }

    @objc private func copySnippet() { copySelectedSnippet() }

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

    @objc private func vaultWillLock(_ notification: Notification) {
        guard let session = notification.object as? VaultSession,
              session === environment.vaultSession else { return }
        flushPendingSecureContent()
    }

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
        updateBodyPlaceholder()
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
