import UIKit

@MainActor
enum SyncRecoveryConfirmation {
    static func makeAlert(
        action: SyncRecoveryAction,
        statusDescription: String,
        onConfirm: @escaping () -> Void
    ) -> UIAlertController {
        precondition(
            action.confirmationTitle != nil
                && action.confirmationButtonTitle != nil)
        let alert = UIAlertController(
            title: action.confirmationTitle,
            message: statusDescription + "\n\n" + action.explanation,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(
            title: action.confirmationButtonTitle,
            style: action.isDestructiveConfirmation ? .destructive : .default
        ) { _ in
            onConfirm()
        })
        return alert
    }
}
