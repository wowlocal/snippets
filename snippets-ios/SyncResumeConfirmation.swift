import UIKit

@MainActor
enum SyncResumeConfirmation {
    static func makeAlert(
        statusDescription: String,
        onResume: @escaping () -> Void
    ) -> UIAlertController {
        let alert = UIAlertController(
            title: "Resume iCloud Sync?",
            message: statusDescription
                + "\n\nResume only after reviewing this condition. Snippets will clear "
                + "the safety stop and immediately attempt another sync round.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Resume", style: .default) { _ in
            onResume()
        })
        return alert
    }
}
