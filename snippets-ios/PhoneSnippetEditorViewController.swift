import UIKit

@MainActor
protocol PhoneSnippetEditorViewControllerDelegate: AnyObject {
    func phoneSnippetEditor(_ controller: PhoneSnippetEditorViewController, requestedDelete id: UUID)
    func phoneSnippetEditor(_ controller: PhoneSnippetEditorViewController, requestedDuplicate id: UUID)
}

final class PhoneSnippetEditorViewController: UIViewController {
    weak var delegate: PhoneSnippetEditorViewControllerDelegate?

    private let environment: AppEnvironment
    private let snippetID: UUID
    private let modeControl = UISegmentedControl(items: ["Content", "Details"])
    private let copyFeedbackGenerator = UIImpactFeedbackGenerator(style: .soft)
    private let scrollView = UIScrollView()
    private let formStack = UIStackView()
    private let modeContainer = UIView()
    private let contentModeStack = UIStackView()
    private let detailsModeStack = UIStackView()

    private let nameField = UITextField()
    private let bodyContainer = UIView()
    private let bodyTextView = SecureSnippetTextView()
    private let bodyPlaceholderLabel = UILabel()
    private let lockedOverlay = UIView()
    private let revealButton = UIButton(type: .system)
    private let previewDisclosureButton = UIButton(type: .system)
    private let previewSurface = UIView()
    private let previewLabel = UILabel()

    private let keywordField = UITextField()
    private let keywordPrefixLabel = UILabel()
    private let keywordStatusLabel = UILabel()
    private let suggestionsStack = UIStackView()
    private let tagField = TagTokenField()
    private let enabledSwitch = UISwitch()
    private let secureSwitch = UISwitch()
    private let footerStatusLabel = UILabel()

    private var isBinding = false
    private var isPublishingEditorChange = false
    private var secureContentIsRevealed = false
    private var previewIsExpanded = false
    private var secureSaveWorkItem: DispatchWorkItem?
    private var contentModeBottomConstraint: NSLayoutConstraint!
    private var detailsModeBottomConstraint: NSLayoutConstraint!
    private var displayedModeIndex = 0
    private var modeTransitionAnimator: UIViewPropertyAnimator?

    init(environment: AppEnvironment, snippetID: UUID) {
        self.environment = environment
        self.snippetID = snippetID
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
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        configureModeControl()
        configureForm()
        configureNotifications()
        bindFromStore()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        view.endEditing(true)
        flushPendingSecureContent()
        commitPlainEditTransaction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        let remainsInNavigationStack = navigationController?.viewControllers.contains {
            $0 === self
        } == true
        guard !remainsInNavigationStack else { return }
        _ = environment.store.discardBlankDraft(id: snippetID)
    }

    func refreshFromStore(preserveFirstResponder: Bool) {
        guard isViewLoaded else { return }
        if preserveFirstResponder,
           view.phoneFindFirstResponder() != nil || isPublishingEditorChange {
            refreshDerivedUI()
            return
        }
        bindFromStore()
    }

    func focusBody() {
        modeControl.selectedSegmentIndex = 0
        updateMode(animated: false)
        guard !environment.store.isSecure(snippetID) || secureContentIsRevealed else { return }
        bodyTextView.becomeFirstResponder()
    }

    private func configureModeControl() {
        modeControl.selectedSegmentIndex = 0
        modeControl.accessibilityIdentifier = "phone-editor-mode"
        modeControl.addAction(UIAction { [weak self] _ in self?.updateMode(animated: true) }, for: .valueChanged)
        modeControl.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(modeControl)

        let adaptiveWidth = modeControl.widthAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.widthAnchor,
            multiplier: 0.7
        )
        adaptiveWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            adaptiveWidth,
            modeControl.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            modeControl.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            modeControl.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor,
                constant: 16
            ),
            modeControl.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor,
                constant: -16
            ),
            modeControl.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
    }

    private func configureForm() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.contentInset.bottom = 66
        scrollView.verticalScrollIndicatorInsets.bottom = 66
        formStack.translatesAutoresizingMaskIntoConstraints = false
        formStack.axis = .vertical
        formStack.spacing = 16
        contentModeStack.axis = .vertical
        contentModeStack.spacing = 16
        detailsModeStack.axis = .vertical
        detailsModeStack.spacing = 16
        contentModeStack.accessibilityIdentifier = "phone-editor-content-pane"
        detailsModeStack.accessibilityIdentifier = "phone-editor-details-pane"

        view.addSubview(scrollView)
        scrollView.addSubview(formStack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            formStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            formStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            formStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            formStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            formStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        configureTextFields()
        configureBody()
        configurePreview()
        configureDetails()

        contentModeStack.addArrangedSubview(section(title: "Name", content: nameField))
        contentModeStack.addArrangedSubview(section(title: "Snippet", content: bodyContainer))
        contentModeStack.addArrangedSubview(previewDisclosureButton)
        contentModeStack.addArrangedSubview(previewSurface)

        let keywordRow = UIStackView(arrangedSubviews: [keywordPrefixLabel, keywordField])
        keywordRow.axis = .horizontal
        keywordRow.alignment = .center
        keywordRow.spacing = 5
        let keywordStack = UIStackView(arrangedSubviews: [keywordRow, keywordStatusLabel, suggestionsStack])
        keywordStack.axis = .vertical
        keywordStack.spacing = 8
        detailsModeStack.addArrangedSubview(section(title: "Keyword", content: keywordStack))
        detailsModeStack.addArrangedSubview(section(title: "Tags", content: tagField))
        detailsModeStack.addArrangedSubview(
            toggleRow(
                title: "Enabled",
                detail: "Allow this keyword to expand on Mac.",
                control: enabledSwitch
            )
        )
        detailsModeStack.addArrangedSubview(
            toggleRow(
                title: "Secure",
                detail: "Encrypt the body and require device-owner authentication to reveal or copy it.",
                control: secureSwitch
            )
        )

        footerStatusLabel.font = AppTheme.scaledFont(size: 12, textStyle: .footnote)
        footerStatusLabel.adjustsFontForContentSizeCategory = true
        footerStatusLabel.textColor = .secondaryLabel
        footerStatusLabel.numberOfLines = 0
        footerStatusLabel.accessibilityIdentifier = "phone-editor-status"

        modeContainer.translatesAutoresizingMaskIntoConstraints = false
        modeContainer.accessibilityIdentifier = "phone-editor-mode-container"
        modeContainer.clipsToBounds = true
        contentModeStack.translatesAutoresizingMaskIntoConstraints = false
        detailsModeStack.translatesAutoresizingMaskIntoConstraints = false
        modeContainer.addSubview(contentModeStack)
        modeContainer.addSubview(detailsModeStack)
        contentModeBottomConstraint = contentModeStack.bottomAnchor.constraint(
            equalTo: modeContainer.bottomAnchor
        )
        detailsModeBottomConstraint = detailsModeStack.bottomAnchor.constraint(
            equalTo: modeContainer.bottomAnchor
        )
        NSLayoutConstraint.activate([
            contentModeStack.leadingAnchor.constraint(equalTo: modeContainer.leadingAnchor),
            contentModeStack.trailingAnchor.constraint(equalTo: modeContainer.trailingAnchor),
            contentModeStack.topAnchor.constraint(equalTo: modeContainer.topAnchor),
            detailsModeStack.leadingAnchor.constraint(equalTo: modeContainer.leadingAnchor),
            detailsModeStack.trailingAnchor.constraint(equalTo: modeContainer.trailingAnchor),
            detailsModeStack.topAnchor.constraint(equalTo: modeContainer.topAnchor),
            contentModeBottomConstraint,
        ])
        formStack.addArrangedSubview(modeContainer)
        formStack.addArrangedSubview(footerStatusLabel)
        view.bringSubviewToFront(modeControl)
        updateMode(animated: false)
    }

    private func configureTextFields() {
        configure(field: nameField, placeholder: "First line is used when blank", identifier: "snippet-name")
        nameField.textContentType = .name
        nameField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        nameField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        nameField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)

        configure(field: keywordField, placeholder: "sig", identifier: "snippet-keyword")
        keywordField.autocapitalizationType = .none
        keywordField.autocorrectionType = .no
        keywordField.spellCheckingType = .no
        keywordField.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        keywordField.addTarget(self, action: #selector(editingBegan), for: .editingDidBegin)
        keywordField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)

        keywordPrefixLabel.text = "\\"
        keywordPrefixLabel.font = AppTheme.scaledFont(
            size: 17,
            weight: .medium,
            textStyle: .body,
            monospaced: true
        )
        keywordPrefixLabel.textColor = .secondaryLabel
        keywordPrefixLabel.setContentHuggingPriority(.required, for: .horizontal)

        keywordStatusLabel.font = AppTheme.scaledFont(size: 12, textStyle: .footnote)
        keywordStatusLabel.adjustsFontForContentSizeCategory = true
        keywordStatusLabel.textColor = AppTheme.warning
        keywordStatusLabel.numberOfLines = 0

        suggestionsStack.axis = .horizontal
        suggestionsStack.spacing = 8
        suggestionsStack.alignment = .center
        tagField.onChange = { [weak self] _ in self?.editorChanged() }
    }

    private func configureBody() {
        AppTheme.configureSurface(bodyContainer, cornerRadius: 14)
        bodyTextView.translatesAutoresizingMaskIntoConstraints = false
        bodyTextView.font = AppTheme.scaledFont(size: 16, textStyle: .body, monospaced: true)
        bodyTextView.adjustsFontForContentSizeCategory = true
        bodyTextView.backgroundColor = .clear
        bodyTextView.textContainerInset = UIEdgeInsets(top: 14, left: 11, bottom: 14, right: 11)
        bodyTextView.smartDashesType = .no
        bodyTextView.smartQuotesType = .no
        bodyTextView.delegate = self
        bodyTextView.accessibilityIdentifier = "snippet-content"

        bodyPlaceholderLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyPlaceholderLabel.text = "Paste or type"
        bodyPlaceholderLabel.font = bodyTextView.font
        bodyPlaceholderLabel.textColor = .placeholderText
        bodyPlaceholderLabel.isUserInteractionEnabled = false

        lockedOverlay.translatesAutoresizingMaskIntoConstraints = false
        lockedOverlay.backgroundColor = AppTheme.editorSurface
        let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
        lock.tintColor = AppTheme.warning
        lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        var revealConfiguration = UIButton.Configuration.filled()
        revealConfiguration.title = "Reveal Secure Content"
        revealConfiguration.image = UIImage(systemName: "lock.open")
        revealConfiguration.imagePadding = 8
        revealConfiguration.cornerStyle = .capsule
        revealConfiguration.baseBackgroundColor = AppTheme.tint
        revealButton.configuration = revealConfiguration
        revealButton.accessibilityIdentifier = "reveal-secure-content"
        revealButton.addAction(UIAction { [weak self] _ in self?.revealSecureContent() }, for: .touchUpInside)
        let lockStack = UIStackView(arrangedSubviews: [lock, revealButton])
        lockStack.translatesAutoresizingMaskIntoConstraints = false
        lockStack.axis = .vertical
        lockStack.alignment = .center
        lockStack.spacing = 16

        bodyContainer.addSubview(bodyTextView)
        bodyTextView.addSubview(bodyPlaceholderLabel)
        bodyContainer.addSubview(lockedOverlay)
        lockedOverlay.addSubview(lockStack)
        NSLayoutConstraint.activate([
            bodyContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 310),
            bodyTextView.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            bodyTextView.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            bodyTextView.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            bodyTextView.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            bodyPlaceholderLabel.leadingAnchor.constraint(equalTo: bodyTextView.leadingAnchor, constant: 16),
            bodyPlaceholderLabel.topAnchor.constraint(equalTo: bodyTextView.topAnchor, constant: 14),
            lockedOverlay.leadingAnchor.constraint(equalTo: bodyContainer.leadingAnchor),
            lockedOverlay.trailingAnchor.constraint(equalTo: bodyContainer.trailingAnchor),
            lockedOverlay.topAnchor.constraint(equalTo: bodyContainer.topAnchor),
            lockedOverlay.bottomAnchor.constraint(equalTo: bodyContainer.bottomAnchor),
            lockStack.centerXAnchor.constraint(equalTo: lockedOverlay.centerXAnchor),
            lockStack.centerYAnchor.constraint(equalTo: lockedOverlay.centerYAnchor),
        ])
    }

    private func configurePreview() {
        var disclosureConfiguration = UIButton.Configuration.plain()
        disclosureConfiguration.title = "Preview Placeholders"
        disclosureConfiguration.image = UIImage(systemName: "chevron.right")
        disclosureConfiguration.imagePlacement = .leading
        disclosureConfiguration.imagePadding = 8
        disclosureConfiguration.contentInsets = .zero
        disclosureConfiguration.baseForegroundColor = AppTheme.tint
        previewDisclosureButton.configuration = disclosureConfiguration
        previewDisclosureButton.contentHorizontalAlignment = .leading
        previewDisclosureButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.previewIsExpanded.toggle()
            self.updatePreview()
        }, for: .touchUpInside)

        AppTheme.configureSurface(
            previewSurface,
            cornerRadius: 14,
            backgroundColor: AppTheme.previewSurface
        )
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = AppTheme.scaledFont(size: 14, textStyle: .body, monospaced: true)
        previewLabel.adjustsFontForContentSizeCategory = true
        previewLabel.textColor = .secondaryLabel
        previewLabel.numberOfLines = 0
        previewLabel.accessibilityIdentifier = "snippet-preview"
        previewSurface.addSubview(previewLabel)
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: previewSurface.leadingAnchor, constant: 14),
            previewLabel.trailingAnchor.constraint(equalTo: previewSurface.trailingAnchor, constant: -14),
            previewLabel.topAnchor.constraint(equalTo: previewSurface.topAnchor, constant: 12),
            previewLabel.bottomAnchor.constraint(equalTo: previewSurface.bottomAnchor, constant: -12),
        ])
    }

    private func configureDetails() {
        enabledSwitch.accessibilityIdentifier = "snippet-enabled"
        enabledSwitch.accessibilityLabel = "Enabled"
        enabledSwitch.accessibilityHint = "Controls whether this keyword can expand on Mac."
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.editorChanged() }, for: .valueChanged)
        secureSwitch.accessibilityIdentifier = "snippet-secure"
        secureSwitch.accessibilityLabel = "Secure"
        secureSwitch.accessibilityHint = "Moves the content between the encrypted vault and the ordinary library."
        secureSwitch.addAction(UIAction { [weak self] _ in self?.secureSwitchChanged() }, for: .valueChanged)
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

    private func bindFromStore() {
        guard let snippet = environment.store.snippetForDisplay(id: snippetID) else {
            navigationController?.popViewController(animated: true)
            return
        }
        flushPendingSecureContent()
        commitPlainEditTransaction()
        isBinding = true
        nameField.text = snippet.name
        keywordField.text = snippet.normalizedKeyword
        tagField.setTags(snippet.tags)
        enabledSwitch.isOn = snippet.isEnabled
        secureSwitch.isOn = environment.store.isSecure(snippetID)
        bodyTextView.text = environment.store.isSecure(snippetID) ? "" : snippet.content
        secureContentIsRevealed = false
        previewIsExpanded = false
        isBinding = false
        updateSecurePresentation()
        refreshDerivedUI()
    }

    private func updateMode(animated: Bool) {
        let targetIndex = modeControl.selectedSegmentIndex
        let previousIndex = displayedModeIndex
        let targetStack = targetIndex == 0 ? contentModeStack : detailsModeStack
        let otherStack = targetIndex == 0 ? detailsModeStack : contentModeStack

        guard targetIndex != previousIndex,
              animated,
              !UIAccessibility.isReduceMotionEnabled else {
            modeTransitionAnimator?.stopAnimation(true)
            modeTransitionAnimator = nil
            activateBottomConstraint(for: targetIndex)
            contentModeStack.transform = .identity
            detailsModeStack.transform = .identity
            contentModeStack.isHidden = targetIndex != 0
            detailsModeStack.isHidden = targetIndex == 0
            displayedModeIndex = targetIndex
            view.layoutIfNeeded()
            return
        }

        modeTransitionAnimator?.stopAnimation(true)
        modeTransitionAnimator = nil
        contentModeStack.transform = .identity
        detailsModeStack.transform = .identity
        contentModeStack.isHidden = previousIndex != 0
        detailsModeStack.isHidden = previousIndex == 0

        let travel = max(modeContainer.bounds.width, view.bounds.width)
        let direction: CGFloat = targetIndex > previousIndex ? 1 : -1
        targetStack.isHidden = false
        activateBottomConstraint(for: targetIndex)
        view.layoutIfNeeded()
        targetStack.transform = CGAffineTransform(translationX: direction * travel, y: 0)
        otherStack.transform = .identity
        displayedModeIndex = targetIndex

        let animator = UIViewPropertyAnimator(duration: 0.32, dampingRatio: 0.92) {
            targetStack.transform = .identity
            otherStack.transform = CGAffineTransform(translationX: -direction * travel, y: 0)
        }
        animator.addCompletion { [weak self, weak animator] _ in
            guard let self,
                  let animator,
                  self.modeTransitionAnimator === animator else { return }
            self.contentModeStack.isHidden = self.displayedModeIndex != 0
            self.detailsModeStack.isHidden = self.displayedModeIndex == 0
            self.contentModeStack.transform = .identity
            self.detailsModeStack.transform = .identity
            self.modeTransitionAnimator = nil
        }
        modeTransitionAnimator = animator
        animator.startAnimation()
    }

    private func activateBottomConstraint(for modeIndex: Int) {
        contentModeBottomConstraint.isActive = modeIndex == 0
        detailsModeBottomConstraint.isActive = modeIndex == 1
    }

    private func updateSecurePresentation() {
        let secure = environment.store.isSecure(snippetID)
        lockedOverlay.isHidden = !secure || secureContentIsRevealed
        bodyTextView.isEditable = !secure || secureContentIsRevealed
        bodyTextView.isSecureContentMode = secure
        bodyTextView.accessibilityLabel = secure && !secureContentIsRevealed
            ? "Secure content locked"
            : "Snippet content"
        secureSwitch.setOn(secure, animated: false)
        updateBodyPlaceholder()
        updatePreview()
    }

    private func refreshDerivedUI() {
        guard let snippet = environment.store.snippetForDisplay(id: snippetID) else { return }
        applyDerivedUI(for: snippet)
    }

    private func applyDerivedUI(for snippet: Snippet) {
        title = snippet.displayName
        updateNamePlaceholder(for: snippet)
        updateKeywordStatus(for: snippet)
        updateSuggestions(for: snippet)
        updatePreview()
        updateNavigationActions(for: snippet)
        setFooterStatus(environment.store.isSecure(snippetID)
            ? (secureContentIsRevealed
                ? "Secure content is revealed until the vault locks."
                : "Content is encrypted. Metadata remains searchable.")
            : "Saved \(snippet.updatedAt.formatted(date: .abbreviated, time: .shortened))")
    }

    private func updateNavigationActions(for snippet: Snippet) {
        let secure = environment.store.isSecure(snippetID)
        let copy = UIBarButtonItem(
            image: UIImage(systemName: secure ? "lock.open" : "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in self?.copySnippet() }
        )
        copy.accessibilityIdentifier = "copy-snippet"
        copy.accessibilityLabel = secure ? "Authenticate and Copy" : "Copy"

        var actions: [UIMenuElement] = [
            UIAction(
                title: snippet.isPinned ? "Unpin" : "Pin",
                image: UIImage(systemName: snippet.isPinned ? "pin.slash" : "pin")
            ) { [weak self] _ in self?.togglePin() },
        ]
        if !secure {
            actions.append(contentsOf: [
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.share() },
                UIAction(title: "Duplicate", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in self?.duplicateSnippet() },
            ])
        }
        actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.deleteSnippet()
        })
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: actions)),
            copy,
        ]
    }

    private func updateBodyPlaceholder() {
        let locked = environment.store.isSecure(snippetID) && !secureContentIsRevealed
        bodyPlaceholderLabel.isHidden = locked || !(bodyTextView.text ?? "").isEmpty
    }

    private func updateNamePlaceholder(for snippet: Snippet) {
        guard snippet.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            nameField.placeholder = "First line is used when blank"
            return
        }
        let fallback = environment.store.isSecure(snippetID) ? "" : snippet.contentFirstLine
        nameField.placeholder = fallback.isEmpty ? "Untitled Snippet" : fallback
    }

    private func updatePreview() {
        updateBodyPlaceholder()
        let locked = environment.store.isSecure(snippetID) && !secureContentIsRevealed
        let template = bodyTextView.text ?? ""
        let hasPlaceholders = !locked && PlaceholderResolver.containsResolvablePlaceholder(in: template)
        previewDisclosureButton.isHidden = !hasPlaceholders
        previewSurface.isHidden = !hasPlaceholders || !previewIsExpanded

        var configuration = previewDisclosureButton.configuration
        configuration?.image = UIImage(systemName: previewIsExpanded ? "chevron.down" : "chevron.right")
        previewDisclosureButton.configuration = configuration
        guard hasPlaceholders, previewIsExpanded else { return }
        previewLabel.text = PlaceholderResolver.resolveForPreview(
            template: template,
            clipboard: { "[Clipboard content]" }
        )
    }

    private func updateKeywordStatus(for snippet: Snippet) {
        let keyword = SnippetTagging.filterKey(for: snippet.normalizedKeyword)
        let trigger = "\\\(snippet.normalizedKeyword)"
        keywordStatusLabel.textColor = AppTheme.warning
        guard !keyword.isEmpty else {
            keywordStatusLabel.textColor = .secondaryLabel
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
                keywordStatusLabel.text = "\(trigger) is blocked by \\\(other.normalizedKeyword)."
                return
            case .blocksShorter:
                keywordStatusLabel.text = "This prevents \\\(other.normalizedKeyword) from expanding."
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
        let existing = (environment.store.enabledSnippetsSorted()
            + environment.secureStore.enabledShellsSortedForDisplay())
            .filter { $0.id != snippet.id }
            .map { SnippetTagging.filterKey(for: $0.normalizedKeyword) }
        let suggestions = KeywordSuggestions.candidates(
            name: snippet.name,
            contentFirstLine: environment.store.isSecure(snippetID) ? "" : snippet.contentFirstLine
        ).filter { candidate in
            existing.allSatisfy { KeywordRelation.between(candidate, $0) == .unrelated }
        }.prefix(3)

        for suggestion in suggestions {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = "\\\(suggestion)"
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.baseForegroundColor = AppTheme.tint
            let button = UIButton(configuration: configuration)
            button.addAction(UIAction { [weak self] _ in
                self?.keywordField.text = suggestion
                self?.editorChanged()
            }, for: .touchUpInside)
            suggestionsStack.addArrangedSubview(button)
        }
        suggestionsStack.isHidden = suggestions.isEmpty
    }

    private func editorChanged() {
        guard !isBinding,
              let current = environment.store.snippetForDisplay(id: snippetID) else { return }
        isPublishingEditorChange = true
        defer { isPublishingEditorChange = false }

        let sanitizedKeyword = Snippet.sanitizedKeyword(keywordField.text ?? "")
        if keywordField.text != sanitizedKeyword { keywordField.text = sanitizedKeyword }

        do {
            try environment.performLocalEditorChange {
                if environment.store.isSecure(snippetID) {
                    try environment.performLocalSecureChange {
                        try environment.secureStore.updateMetadata(
                            id: snippetID,
                            name: nameField.text ?? "",
                            keyword: sanitizedKeyword,
                            tags: tagField.currentTags(),
                            isEnabled: enabledSwitch.isOn
                        )
                    }
                } else {
                    guard var updated = environment.store.snippet(id: snippetID) else { return }
                    updated.name = nameField.text ?? ""
                    updated.keyword = sanitizedKeyword
                    updated.content = bodyTextView.text ?? ""
                    updated.tags = tagField.currentTags()
                    updated.isEnabled = enabledSwitch.isOn
                    environment.store.update(updated)
                }
            }
            let refreshed = environment.store.snippetForDisplay(id: snippetID) ?? current
            applyDerivedUI(for: refreshed)
        } catch {
            showSaveFailure("Couldn’t save: \(error)")
        }
    }

    private func beginPlainEditTransaction() {
        guard !environment.store.isSecure(snippetID) else { return }
        environment.store.beginEditTransaction()
    }

    private func commitPlainEditTransaction() {
        guard !environment.store.isSecure(snippetID) else { return }
        environment.store.commitEditTransaction()
    }

    private func secureSwitchChanged() {
        guard !isBinding else { return }
        secureSwitch.setOn(environment.store.isSecure(snippetID), animated: true)
        if environment.store.isSecure(snippetID) {
            makeOrdinary()
        } else {
            makeSecure()
        }
    }

    private func makeSecure() {
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

        let promote = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                do {
                    _ = try await self.environment.vaultSession.unlock(reason: "Make this snippet secure")
                    try self.environment.performLocalSecureChange {
                        try SecureSnippetTransitionCoordinator.promote(
                            snippetID: self.snippetID,
                            store: self.environment.store,
                            secureStore: self.environment.secureStore)
                    }
                    self.bindFromStore()
                } catch {
                    self.showError(title: "Couldn’t Make Snippet Secure", error: error)
                }
            }
        }
        guard let pendingCreation else {
            promote()
            return
        }
        showRecoveryKey(pendingCreation) { [weak self] in
            guard let self else { return }
            do {
                _ = try self.environment.performLocalSecureChange {
                    try self.environment.secureStore.commitVaultCreation(pendingCreation)
                }
                promote()
            } catch {
                self.showError(title: "Couldn’t Set Up Secure Snippets", error: error)
            }
        }
    }

    private func makeOrdinary() {
        let alert = UIAlertController(
            title: "Make This Snippet Ordinary?",
            message: "Its content will be decrypted into the ordinary library, where it can be copied, shared, and exported.",
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
                                recordID: self.snippetID,
                                store: self.environment.store,
                                secureStore: self.environment.secureStore)
                        }
                    }
                    self.bindFromStore()
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
        guard environment.store.isSecure(snippetID) else { return }
        Task { @MainActor in
            do {
                let name = environment.store.snippetForDisplay(id: snippetID)?.displayName ?? "secure snippet"
                _ = try await environment.vaultSession.unlock(reason: "Reveal “\(name)”")
                bodyTextView.text = try environment.secureStore.content(for: snippetID)
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
        guard environment.store.isSecure(snippetID), secureContentIsRevealed else { return }
        do {
            try environment.performLocalEditorChange {
                try environment.performLocalSecureChange {
                    try environment.secureStore.setContent(bodyTextView.text ?? "", for: snippetID)
                }
            }
        } catch {
            showSaveFailure("Secure edit wasn’t saved: \(error)")
        }
    }

    private func copySnippet() {
        view.endEditing(true)
        flushPendingSecureContent()
        copyFeedbackGenerator.prepare()
        Task { @MainActor in
            do {
                switch try await environment.snippetActions.copy(id: snippetID) {
                case .copied(let name, let secure):
                    setFooterStatus(secure
                        ? "Copied “\(name)”. Secure clipboard expires in 60 seconds."
                        : "Copied “\(name)”.")
                    copyFeedbackGenerator.impactOccurred(intensity: 0.75)
                case .empty(let name):
                    setFooterStatus("“\(name)” has no content to copy.")
                    copyFeedbackGenerator.impactOccurred(intensity: 0.5)
                }
            } catch {
                showError(title: "Couldn’t Copy Snippet", error: error)
            }
        }
    }

    private func togglePin() {
        guard let snippet = environment.store.snippetForDisplay(id: snippetID) else { return }
        do {
            if environment.store.isSecure(snippetID) {
                try environment.performLocalSecureChange {
                    try environment.secureStore.updateMetadata(
                        id: snippetID,
                        isPinned: !snippet.isPinned
                    )
                }
            } else {
                environment.store.togglePinned(snippetID: snippetID)
            }
            refreshDerivedUI()
        } catch {
            showError(title: "Couldn’t Update Pin", error: error)
        }
    }

    private func share() {
        guard !environment.store.isSecure(snippetID),
              let snippet = environment.store.snippet(id: snippetID),
              let url = try? SnippetDeepLink.url(for: snippet, isSecure: false) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItems?.first
        present(controller, animated: true)
    }

    private func duplicateSnippet() {
        delegate?.phoneSnippetEditor(self, requestedDuplicate: snippetID)
    }

    private func deleteSnippet() {
        delegate?.phoneSnippetEditor(self, requestedDelete: snippetID)
    }

    private func configure(field: UITextField, placeholder: String, identifier: String) {
        field.borderStyle = .none
        field.backgroundColor = .secondarySystemGroupedBackground
        field.layer.cornerRadius = 12
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        field.layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        field.font = AppTheme.scaledFont(size: 16, textStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.placeholder = placeholder
        field.accessibilityIdentifier = identifier
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.rightViewMode = .always
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    private func section(title: String, content: UIView) -> UIStackView {
        let label = UILabel()
        label.text = title
        label.font = AppTheme.scaledFont(size: 13, weight: .semibold, textStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [label, content])
        stack.axis = .vertical
        stack.spacing = 8
        return stack
    }

    private func toggleRow(title: String, detail: String, control: UISwitch) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = AppTheme.scaledFont(size: 16, weight: .semibold, textStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = AppTheme.scaledFont(size: 12, textStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 3
        let row = UIStackView(arrangedSubviews: [labels, control])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 13, left: 14, bottom: 13, right: 14)
        AppTheme.configureSurface(row, cornerRadius: 14, backgroundColor: .secondarySystemGroupedBackground)
        return row
    }

    private func showError(title: String, error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func setFooterStatus(_ message: String) {
        footerStatusLabel.textColor = .secondaryLabel
        footerStatusLabel.text = message
    }

    /// Save failures must remain visible while the keyboard is covering the bottom of
    /// the form. A footer-only colour change is easy to miss and is silent to VoiceOver,
    /// so bring the message into the keyboard-adjusted viewport and announce it.
    private func showSaveFailure(_ message: String) {
        footerStatusLabel.textColor = .systemRed
        footerStatusLabel.text = message
        view.layoutIfNeeded()
        let statusRect = footerStatusLabel
            .convert(footerStatusLabel.bounds, to: scrollView)
            .insetBy(dx: 0, dy: -12)
        scrollView.scrollRectToVisible(statusRect, animated: true)
        UIAccessibility.post(notification: .announcement, argument: message)
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
        guard environment.store.isSecure(snippetID),
              !environment.vaultSession.state.isUnlocked else { return }
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
        let keyboardInset = max(0, overlap - view.safeAreaInsets.bottom)
        let bottomInset = keyboardInset + 66
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval ?? 0.25
        let rawCurve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        let options = UIView.AnimationOptions(rawValue: rawCurve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.scrollView.contentInset.bottom = bottomInset
            self.scrollView.verticalScrollIndicatorInsets.bottom = bottomInset
        }
    }
}

extension PhoneSnippetEditorViewController: UITextViewDelegate {
    func textViewDidBeginEditing(_ textView: UITextView) {
        beginPlainEditTransaction()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isBinding else { return }
        updateBodyPlaceholder()
        if environment.store.isSecure(snippetID) {
            scheduleSecureContentSave()
            updatePreview()
        } else {
            editorChanged()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        if environment.store.isSecure(snippetID) {
            flushPendingSecureContent()
        } else {
            editorChanged()
            commitPlainEditTransaction()
        }
    }
}

private extension UIView {
    func phoneFindFirstResponder() -> UIView? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let responder = subview.phoneFindFirstResponder() { return responder }
        }
        return nil
    }
}
