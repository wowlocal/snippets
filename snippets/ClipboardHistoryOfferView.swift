import AppKit

/// A quiet invitation in the library; neither button becomes a default action.
@MainActor
final class ClipboardHistoryOfferView: NSView {
    var onEnable: (() -> Void)?
    var onDismiss: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        let title = NSTextField(wrappingLabelWithString: "Recently copied, close at hand")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString:
            "Keep copied text and links for 7 days and find them with ⌘⇧V. History stays encrypted on this Mac and is never synced.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        let copy = NSStackView(views: [title, detail])
        copy.orientation = .vertical
        copy.distribution = .fill
        copy.alignment = .leading
        copy.spacing = 4
        title.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true
        detail.widthAnchor.constraint(equalTo: copy.widthAnchor).isActive = true

        let enable = NSButton(title: "Enable History", target: self, action: #selector(enableHistory))
        let dismiss = NSButton(title: "Not Now", target: self, action: #selector(dismissOffer))
        enable.setAccessibilityIdentifier("clipboardHistoryOfferEnable")
        dismiss.setAccessibilityIdentifier("clipboardHistoryOfferDismiss")
        let actions = NSStackView(views: [enable, dismiss])
        actions.orientation = .vertical
        actions.distribution = .fill
        actions.alignment = .trailing
        actions.spacing = 4
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)

        let content = NSStackView(views: [copy, actions])
        content.orientation = .horizontal
        content.distribution = .fill
        content.alignment = .centerY
        content.spacing = 16
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(divider)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -12),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityIdentifier("clipboardHistoryOffer")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func enableHistory() { onEnable?() }
    @objc private func dismissOffer() { onDismiss?() }
}
