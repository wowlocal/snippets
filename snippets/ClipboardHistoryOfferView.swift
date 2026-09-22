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

        let icon = NSImageView(image: NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Clipboard History")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let shortcut = NSTextField(labelWithString: "⌘⇧V")
        shortcut.font = .systemFont(ofSize: 11, weight: .medium)
        shortcut.textColor = .secondaryLabelColor
        let detail = NSTextField(wrappingLabelWithString:
            "Keep copied text and links for 7 days. Encrypted on this Mac, never synced.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // The text defines the banner's height. A center-aligned horizontal stack
        // can absorb the window's surplus height even when its wrapper hugs tightly,
        // because the wrapper has no intrinsic size of its own.
        [title, detail].forEach {
            $0.setContentHuggingPriority(.required, for: .vertical)
            $0.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        title.setContentHuggingPriority(.required, for: .horizontal)

        let enable = NSButton(title: "Enable History", target: self, action: #selector(enableHistory))
        enable.controlSize = .small
        enable.bezelStyle = .rounded
        enable.setContentHuggingPriority(.required, for: .horizontal)
        enable.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dismiss = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)!,
            target: self, action: #selector(dismissOffer))
        dismiss.isBordered = false
        dismiss.contentTintColor = .secondaryLabelColor
        dismiss.imageScaling = .scaleProportionallyDown
        dismiss.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        dismiss.setAccessibilityLabel("Not Now")
        dismiss.toolTip = "Not Now — you can enable Clipboard History in Settings later."
        enable.setAccessibilityIdentifier("clipboardHistoryOfferEnable")
        dismiss.setAccessibilityIdentifier("clipboardHistoryOfferDismiss")

        let divider = NSBox()
        divider.boxType = .separator
        [icon, title, shortcut, detail, enable, dismiss, divider].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            shortcut.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            shortcut.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            shortcut.trailingAnchor.constraint(lessThanOrEqualTo: enable.leadingAnchor, constant: -16),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: enable.leadingAnchor, constant: -16),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            detail.bottomAnchor.constraint(equalTo: divider.topAnchor, constant: -12),
            enable.centerYAnchor.constraint(equalTo: centerYAnchor),
            enable.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -8),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dismiss.centerYAnchor.constraint(equalTo: centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 24),
            dismiss.heightAnchor.constraint(equalToConstant: 24),
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
