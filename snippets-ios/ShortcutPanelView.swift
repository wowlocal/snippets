import UIKit

final class ShortcutPanelView: UIView {
    var onDismiss: (() -> Void)?

    private struct Descriptor {
        let title: String
        let shortcut: String
        let isEssential: Bool
    }

    private static let descriptors: [Descriptor] = [
        Descriptor(title: "Expand a Snippet", shortcut: "\\keyword", isEssential: true),
        Descriptor(title: "Insert a Placeholder", shortcut: "{", isEssential: true),
        Descriptor(title: "Copy Snippet", shortcut: "↩", isEssential: true),
        Descriptor(title: "Search", shortcut: "⌘F", isEssential: true),
        Descriptor(title: "Toggle Sidebar", shortcut: "⌘B", isEssential: true),
        Descriptor(title: "Create New Snippet", shortcut: "⌘N", isEssential: true),
        Descriptor(title: "New from Clipboard", shortcut: "⇧⌘N", isEssential: true),
        Descriptor(title: "Edit Snippet", shortcut: "⌘E", isEssential: true),
        Descriptor(title: "Delete Snippet", shortcut: "⌘⌫", isEssential: true),
        Descriptor(title: "Next Field", shortcut: "⇥", isEssential: true),
        Descriptor(title: "Previous Field", shortcut: "⇧⇥", isEssential: true),
        Descriptor(title: "Dismiss Panel", shortcut: "esc", isEssential: true),
        Descriptor(title: "Import", shortcut: "⇧⌘I", isEssential: false),
        Descriptor(title: "Export", shortcut: "⇧⌘E", isEssential: false),
        Descriptor(title: "Undo", shortcut: "⌘Z", isEssential: false),
        Descriptor(title: "Redo", shortcut: "⇧⌘Z", isEssential: false),
        Descriptor(title: "Next Snippet", shortcut: "↓  /  ⌃N", isEssential: false),
        Descriptor(title: "Previous Snippet", shortcut: "↑  /  ⌃P", isEssential: false),
        Descriptor(title: "Toggle Shortcuts", shortcut: "⌘K", isEssential: false),
    ]

    private let backgroundButton = UIButton(type: .custom)
    private let panelShadowView = UIView()
    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let tipLabel = UILabel()
    private var shortcutRows: [(view: UIView, isEssential: Bool)] = []

    private(set) var isPresented = false
    private(set) var showsAllShortcuts = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        panelShadowView.layer.shadowPath = UIBezierPath(
            roundedRect: panelShadowView.bounds,
            cornerRadius: 20
        ).cgPath
    }

    func present(animated: Bool) {
        guard !isPresented else { return }
        isPresented = true
        isHidden = false
        accessibilityViewIsModal = true
        setShowsAllShortcuts(false, animated: false)

        guard animated else {
            alpha = 1
            panelShadowView.transform = .identity
            return
        }

        alpha = 0
        panelShadowView.transform = CGAffineTransform(scaleX: 0.97, y: 0.97)
        UIView.animate(
            withDuration: 0.2,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.alpha = 1
            self.panelShadowView.transform = .identity
        }
    }

    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard isPresented else {
            completion?()
            return
        }
        isPresented = false
        accessibilityViewIsModal = false

        let finish = {
            self.isHidden = true
            self.alpha = 1
            self.panelShadowView.transform = .identity
            self.setShowsAllShortcuts(false, animated: false)
            completion?()
        }
        guard animated else {
            finish()
            return
        }

        UIView.animate(
            withDuration: 0.16,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            self.alpha = 0
            self.panelShadowView.transform = CGAffineTransform(scaleX: 0.98, y: 0.98)
        } completion: { _ in
            finish()
        }
    }

    func setShowsAllShortcuts(_ showAll: Bool, animated: Bool) {
        guard showAll != showsAllShortcuts || tipLabel.text == nil else { return }
        showsAllShortcuts = showAll

        let updates = {
            for row in self.shortcutRows {
                row.view.isHidden = !showAll && !row.isEssential
            }
            self.tipLabel.text = showAll
                ? "Release ⌥ for essentials."
                : "Hold ⌥ for all shortcuts."
            self.layoutIfNeeded()
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState],
                animations: updates
            )
        } else {
            updates()
        }
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isHidden = true
        accessibilityIdentifier = "shortcut-panel"

        backgroundButton.translatesAutoresizingMaskIntoConstraints = false
        backgroundButton.backgroundColor = UIColor.black.withAlphaComponent(0.08)
        backgroundButton.accessibilityLabel = "Dismiss Shortcuts"
        backgroundButton.addAction(UIAction { [weak self] _ in
            self?.onDismiss?()
        }, for: .touchUpInside)

        panelShadowView.translatesAutoresizingMaskIntoConstraints = false
        panelShadowView.layer.shadowColor = UIColor.black.cgColor
        panelShadowView.layer.shadowOpacity = 0.18
        panelShadowView.layer.shadowRadius = 24
        panelShadowView.layer.shadowOffset = CGSize(width: 0, height: 10)

        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.layer.cornerRadius = 20
        materialView.layer.cornerCurve = .continuous
        materialView.clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = false

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 3

        let titleLabel = UILabel()
        titleLabel.text = "Shortcuts"
        titleLabel.font = AppTheme.scaledFont(size: 18, weight: .semibold, textStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.accessibilityTraits = .header
        contentStack.addArrangedSubview(titleLabel)
        contentStack.setCustomSpacing(12, after: titleLabel)

        shortcutRows = Self.descriptors.map { descriptor in
            let row = ShortcutRowView(title: descriptor.title, shortcut: descriptor.shortcut)
            contentStack.addArrangedSubview(row)
            return (row, descriptor.isEssential)
        }

        tipLabel.font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        tipLabel.adjustsFontForContentSizeCategory = true
        tipLabel.textColor = .tertiaryLabel
        tipLabel.textAlignment = .center
        tipLabel.accessibilityIdentifier = "shortcut-panel-tip"
        contentStack.addArrangedSubview(tipLabel)
        contentStack.setCustomSpacing(12, after: shortcutRows.last?.view ?? titleLabel)

        addSubview(backgroundButton)
        addSubview(panelShadowView)
        panelShadowView.addSubview(materialView)
        materialView.contentView.addSubview(scrollView)
        scrollView.addSubview(contentStack)

        let preferredWidth = panelShadowView.widthAnchor.constraint(equalToConstant: 350)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = panelShadowView.heightAnchor.constraint(
            equalTo: contentStack.heightAnchor,
            constant: 32
        )
        preferredHeight.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            backgroundButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundButton.topAnchor.constraint(equalTo: topAnchor),
            backgroundButton.bottomAnchor.constraint(equalTo: bottomAnchor),

            panelShadowView.centerXAnchor.constraint(equalTo: centerXAnchor),
            panelShadowView.centerYAnchor.constraint(equalTo: centerYAnchor),
            panelShadowView.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 20),
            panelShadowView.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -20),
            panelShadowView.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor, constant: 20),
            panelShadowView.bottomAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -20),
            preferredWidth,
            preferredHeight,

            materialView.leadingAnchor.constraint(equalTo: panelShadowView.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: panelShadowView.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: panelShadowView.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: panelShadowView.bottomAnchor),

            scrollView.leadingAnchor.constraint(equalTo: materialView.contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: materialView.contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: materialView.contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: materialView.contentView.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 18),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -14),
            contentStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])

        setShowsAllShortcuts(false, animated: false)
    }
}

private final class ShortcutRowView: UIStackView {
    init(title: String, shortcut: String) {
        super.init(frame: .zero)

        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = AppTheme.scaledFont(size: 13, textStyle: .body)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label

        let shortcutLabel = UILabel()
        shortcutLabel.text = shortcut
        shortcutLabel.font = AppTheme.scaledFont(
            size: 13,
            weight: .semibold,
            textStyle: .body,
            monospaced: true
        )
        shortcutLabel.adjustsFontForContentSizeCategory = true
        shortcutLabel.textColor = .secondaryLabel
        shortcutLabel.textAlignment = .right
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        axis = .horizontal
        alignment = .firstBaseline
        spacing = 12
        isLayoutMarginsRelativeArrangement = true
        directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        addArrangedSubview(titleLabel)
        addArrangedSubview(shortcutLabel)
        accessibilityLabel = "\(title), \(shortcut)"
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
