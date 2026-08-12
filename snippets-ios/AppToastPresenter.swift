import UIKit

/// Shared non-modal status surface used by both the iPhone library and iPad split view.
/// The tinted glass stays out of the responder chain while remaining visible and
/// accessible long enough for concise action feedback.
final class AppToastPresenter {
    private static let actionIdentifier = UIAction.Identifier("AppToastAction")

    private let container = AppTheme.glassView(tintColor: AppTheme.tint.withAlphaComponent(0.06))
    private let label = UILabel()
    private let button = UIButton(type: .system)
    private let stack = UIStackView()
    private var hideWorkItem: DispatchWorkItem?
    private var pendingAction: (() -> Void)?

    func install(in view: UIView) {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 18
        container.layer.cornerCurve = .continuous
        container.clipsToBounds = true
        container.alpha = 0
        container.isHidden = true
        container.accessibilityIdentifier = "app-toast"

        label.font = AppTheme.scaledFont(size: 14, weight: .medium, textStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.accessibilityIdentifier = "app-toast-message"
        button.titleLabel?.font = AppTheme.scaledFont(size: 14, weight: .semibold, textStyle: .subheadline)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.accessibilityIdentifier = "phone-toast-action"
        button.accessibilityHint = "Performs this action once"
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        [label, button].forEach(stack.addArrangedSubview)
        container.contentView.addSubview(stack)
        view.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: container.contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.contentView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: container.contentView.topAnchor, constant: 11),
            stack.bottomAnchor.constraint(equalTo: container.contentView.bottomAnchor, constant: -11),
        ])
    }

    func show(
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        duration: TimeInterval = 3.5
    ) {
        hideWorkItem?.cancel()
        label.text = message
        button.removeAction(identifiedBy: Self.actionIdentifier, for: .touchUpInside)
        button.setTitle(actionTitle, for: .normal)
        button.isHidden = actionTitle == nil
        pendingAction = action
        if let action {
            button.addAction(
                UIAction(identifier: Self.actionIdentifier) { [weak self] _ in
                    guard let self, self.pendingAction != nil else { return }
                    // Clear before invoking the callback. Even if the callback presents
                    // another status immediately, a second activation cannot reach the
                    // previous deletion token or an unrelated Undo stack entry.
                    self.pendingAction = nil
                    self.button.isEnabled = false
                    self.dismiss(animated: true)
                    action()
                },
                for: .touchUpInside
            )
        }
        button.isEnabled = action != nil
        container.superview?.bringSubviewToFront(container)
        container.isHidden = false
        UIView.animate(withDuration: 0.22) { self.container.alpha = 1 }
        let announcement = actionTitle.map { "\(message) \($0) available." } ?? message
        UIAccessibility.post(notification: .announcement, argument: announcement)

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss(animated: true)
        }
        hideWorkItem = workItem
        let minimumActionDuration: TimeInterval = UIAccessibility.isVoiceOverRunning ? 20 : 8
        let effectiveDuration = actionTitle == nil ? duration : max(duration, minimumActionDuration)
        DispatchQueue.main.asyncAfter(deadline: .now() + effectiveDuration, execute: workItem)
    }

    private func dismiss(animated: Bool) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        pendingAction = nil
        button.removeAction(identifiedBy: Self.actionIdentifier, for: .touchUpInside)
        let changes = { self.container.alpha = 0 }
        let completion: (Bool) -> Void = { _ in
            self.container.isHidden = true
            self.button.isEnabled = false
        }
        if animated {
            UIView.animate(withDuration: 0.2, animations: changes, completion: completion)
        } else {
            changes()
            completion(true)
        }
    }
}
