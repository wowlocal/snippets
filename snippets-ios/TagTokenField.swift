import UIKit

final class TagTokenField: UIView, UITextFieldDelegate {
    var onChange: (([String]) -> Void)?

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let textField = BackspaceTextField()
    private var tags: [String] = []
    private var availableTags: [String] = []
    private var completionButtons: [UIButton] = []
    private var isUpdating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        layer.borderWidth = 1 / max(traitCollection.displayScale, 1)
        layer.borderColor = UIColor.separator.withAlphaComponent(0.45).cgColor
        backgroundColor = AppTheme.editorSurface

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 7

        textField.placeholder = "work, email"
        textField.font = AppTheme.scaledFont(size: 15, textStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.returnKeyType = .done
        textField.delegate = self
        textField.accessibilityIdentifier = "tags-input"
        textField.onDeleteWhenEmpty = { [weak self] in self?.removeLastTag() }
        textField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        textField.addTarget(self, action: #selector(inputChanged), for: .editingDidBegin)
        textField.addTarget(self, action: #selector(editingEnded), for: .editingDidEnd)

        stack.addArrangedSubview(textField)
        scrollView.addSubview(stack)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            textField.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }

        // The horizontal scroller fills the bordered surface, while its actual
        // text field is only as wide as the placeholder or pending text. Route
        // taps on the otherwise-empty scroller/stack background to that input;
        // token buttons and their remove actions keep their normal hit targets.
        if hit === self || hit === scrollView || hit === stack {
            return textField
        }
        return hit
    }

    func setTags(_ tags: [String]) {
        isUpdating = true
        self.tags = SnippetTagging.normalizedTags(tags)
        rebuildTokens()
        isUpdating = false
    }

    /// Supplies the library vocabulary used by the macOS token field's prefix
    /// completion. Suggestions stay inside this field's horizontal scroller so
    /// appearing and disappearing candidates never move the editor below it.
    func setAvailableTags(_ tags: [String]) {
        availableTags = SnippetTagging.normalizedTags(tags)
        updateCompletions()
    }

    func currentTags() -> [String] {
        commitPendingText(notify: false)
        return tags
    }

    var isInputFirstResponder: Bool { textField.isFirstResponder }
    var hasPendingCompletion: Bool { !completionCandidates().isEmpty }

    @discardableResult
    func focusInput() -> Bool {
        textField.becomeFirstResponder()
    }

    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard string.contains(",") || string.contains("\n") else { return true }
        let existing = textField.text ?? ""
        guard let swiftRange = Range(range, in: existing) else { return false }
        let candidate = existing.replacingCharacters(in: swiftRange, with: string)
        addTags(candidate.components(separatedBy: CharacterSet(charactersIn: ",\n")))
        textField.text = ""
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if !completePendingTag() {
            commitPendingText()
        }
        return false
    }

    /// Accepts the first alphabetical prefix match, mirroring the default item
    /// offered by `NSTokenField`. Used by Return and by the iPad hardware-Tab
    /// focus loop before Tab advances to the next editor field.
    @discardableResult
    func completePendingTag() -> Bool {
        guard let completion = completionCandidates().first else { return false }
        acceptCompletion(completion)
        return true
    }

    private func addTags(_ incoming: [String]) {
        let normalized = SnippetTagging.normalizedTags(tags + incoming)
        guard normalized != tags else { return }
        tags = normalized
        rebuildTokens()
        notifyChange()
    }

    private func remove(tag: String) {
        let key = SnippetTagging.filterKey(for: tag)
        tags.removeAll { SnippetTagging.filterKey(for: $0) == key }
        rebuildTokens()
        notifyChange()
    }

    private func removeLastTag() {
        guard !tags.isEmpty else { return }
        tags.removeLast()
        rebuildTokens()
        notifyChange()
    }

    private func commitPendingText(notify: Bool = true) {
        let value = textField.text ?? ""
        textField.text = ""
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let previous = tags
        tags = SnippetTagging.normalizedTags(tags + value.components(separatedBy: ","))
        rebuildTokens()
        if notify, previous != tags { notifyChange() }
    }

    private func rebuildTokens() {
        completionButtons.removeAll()
        for view in stack.arrangedSubviews where view !== textField {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, tag) in tags.enumerated() {
            var configuration = UIButton.Configuration.tinted()
            configuration.title = tag
            configuration.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .bold))
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 5
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            let color = AppTheme.tagColor(for: tag)
            configuration.baseForegroundColor = color
            configuration.baseBackgroundColor = AppTheme.tagFillColor(for: tag)
            let button = UIButton(configuration: configuration)
            button.accessibilityLabel = "Remove tag \(tag)"
            button.addAction(UIAction { [weak self] _ in self?.remove(tag: tag) }, for: .touchUpInside)
            stack.insertArrangedSubview(button, at: index)
        }
        updateCompletions()
    }

    private func completionCandidates() -> [String] {
        guard textField.isFirstResponder,
              let query = SnippetTagging.normalizedTags([textField.text ?? ""]).first
        else { return [] }

        let queryKey = SnippetTagging.filterKey(for: query)
        let selectedKeys = Set(tags.map(SnippetTagging.filterKey(for:)))
        return availableTags.filter { tag in
            let tagKey = SnippetTagging.filterKey(for: tag)
            return tagKey.hasPrefix(queryKey) && !selectedKeys.contains(tagKey)
        }
    }

    private func updateCompletions() {
        for button in completionButtons {
            stack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        completionButtons.removeAll()

        for (index, tag) in completionCandidates().prefix(8).enumerated() {
            var configuration = UIButton.Configuration.gray()
            configuration.title = tag
            configuration.image = UIImage(
                systemName: "arrow.turn.down.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            )
            configuration.imagePadding = 5
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 4,
                leading: 8,
                bottom: 4,
                trailing: 8
            )
            configuration.baseForegroundColor = .secondaryLabel
            configuration.baseBackgroundColor = UIColor.secondarySystemFill
            let button = UIButton(configuration: configuration)
            button.accessibilityIdentifier = "tag-completion-\(index)"
            button.accessibilityLabel = "Complete tag \(tag)"
            button.addAction(UIAction { [weak self] _ in
                self?.acceptCompletion(tag)
            }, for: .touchUpInside)
            stack.addArrangedSubview(button)
            completionButtons.append(button)
        }

        guard !completionButtons.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  textField.isFirstResponder,
                  let firstCompletion = completionButtons.first
            else { return }
            stack.layoutIfNeeded()
            scrollView.scrollRectToVisible(
                textField.frame.union(firstCompletion.frame).insetBy(dx: -12, dy: 0),
                animated: false
            )
        }
    }

    private func acceptCompletion(_ tag: String) {
        textField.text = ""
        addTags([tag])
    }

    private func notifyChange() {
        guard !isUpdating else { return }
        onChange?(tags)
    }

    @objc private func inputChanged() { updateCompletions() }

    @objc private func editingEnded() { commitPendingText() }
}

private final class BackspaceTextField: UITextField {
    var onDeleteWhenEmpty: (() -> Void)?

    override func deleteBackward() {
        if text?.isEmpty != false { onDeleteWhenEmpty?() }
        super.deleteBackward()
    }
}
