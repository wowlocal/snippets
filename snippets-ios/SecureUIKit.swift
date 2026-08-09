import UIKit
import UniformTypeIdentifiers

/// A text view that removes UIKit's ambient disclosure routes while a secure snippet
/// is revealed. Copying a secure snippet remains an explicit app action backed by
/// `SnippetActionService`, which authenticates and uses an expiring local pasteboard.
final class SecureSnippetTextView: UITextView {
    var isSecureContentMode = false {
        didSet {
            guard oldValue != isSecureContentMode else { return }
            applyContentMode()
        }
    }

    private static let secureAllowedActions: Set<String> = [
        "delete:",
        "paste:",
        "select:",
        "selectAll:",
    ]
    private var disabledUndoRegistration = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        smartDashesType = .no
        smartQuotesType = .no
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        smartDashesType = .no
        smartQuotesType = .no
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        guard isSecureContentMode else {
            return super.canPerformAction(action, withSender: sender)
        }
        let name = NSStringFromSelector(action)
        guard Self.secureAllowedActions.contains(name) else { return false }
        return super.canPerformAction(action, withSender: sender)
    }

    override func copy(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        guard !isSecureContentMode else { return }
        super.cut(sender)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // The text drag interaction can be installed lazily when the view joins a
        // window, after secure mode was first selected.
        if isSecureContentMode { applyContentMode() }
    }

    private func applyContentMode() {
        if isSecureContentMode {
            autocapitalizationType = .none
            autocorrectionType = .no
            spellCheckingType = .no
            textContentType = .password
            smartInsertDeleteType = .no
            smartDashesType = .no
            smartQuotesType = .no
            writingToolsBehavior = .none
            isFindInteractionEnabled = false
            allowsEditingTextAttributes = false
            textDragInteraction?.isEnabled = false
            undoManager?.removeAllActions()
            if !disabledUndoRegistration, undoManager != nil {
                undoManager?.disableUndoRegistration()
                disabledUndoRegistration = true
            }
        } else {
            autocapitalizationType = .sentences
            autocorrectionType = .default
            spellCheckingType = .default
            textContentType = nil
            smartInsertDeleteType = .default
            writingToolsBehavior = .default
            isFindInteractionEnabled = true
            textDragInteraction?.isEnabled = true
            if disabledUndoRegistration {
                undoManager?.enableUndoRegistration()
                disabledUndoRegistration = false
            }
        }
        if isFirstResponder { reloadInputViews() }
    }
}

enum RecoveryKeyPasteboard {
    static let lifetime: TimeInterval = 5 * 60

    static func options(now: Date = Date()) -> [UIPasteboard.OptionsKey: Any] {
        [
            .localOnly: true,
            .expirationDate: now.addingTimeInterval(lifetime),
        ]
    }

    static func copy(
        _ recoveryKey: String,
        to pasteboard: UIPasteboard = .general,
        now: Date = Date()
    ) {
        pasteboard.setItems(
            [[UTType.utf8PlainText.identifier: recoveryKey]],
            options: options(now: now))
    }
}

enum RecoveryKeyInputProtection {
    static func configure(_ field: UITextField) {
        field.isSecureTextEntry = true
        field.textContentType = .password
        field.autocapitalizationType = .allCharacters
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartDashesType = .no
        field.smartQuotesType = .no
        field.smartInsertDeleteType = .no
    }
}
