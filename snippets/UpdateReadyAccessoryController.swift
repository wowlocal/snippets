import AppKit

final class UpdateReadyAccessoryController: NSTitlebarAccessoryViewController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let actionButton = NSButton(title: "Restart to Apply", target: nil, action: nil)
    private let stackView = NSStackView()

    override init(nibName nibNameOrNil: NSNib.Name?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
        setupViewHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViewHierarchy()
    }

    private func setupViewHierarchy() {
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        actionButton.bezelStyle = .rounded
        actionButton.controlSize = .small
        actionButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 9
        stackView.edgeInsets = NSEdgeInsets(top: 2, left: 24, bottom: 2, right: 0)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(actionButton)

        // Titlebar accessory views start with a zero frame unless we provide a
        // meaningful size. Using the stack view directly avoids the width=0
        // autoresizing constraint conflicts seen in debug logs.
        view = stackView
        view.frame = NSRect(x: 0, y: 0, width: 280, height: 28)
        view.translatesAutoresizingMaskIntoConstraints = false
        preferredContentSize = view.fittingSize
    }

    func configure(version: String?, isApplying: Bool, target: AnyObject, action: Selector) {
        if let version, !version.isEmpty {
            titleLabel.stringValue = "Update \(version) ready"
        } else {
            titleLabel.stringValue = "Update ready"
        }

        actionButton.title = isApplying ? "Applying..." : "Restart to Apply"
        actionButton.isEnabled = !isApplying
        actionButton.target = target
        actionButton.action = action
        preferredContentSize = stackView.fittingSize
    }
}
