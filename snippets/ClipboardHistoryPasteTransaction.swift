import AppKit

/// Choosing history makes it the current clipboard. No loan, readback, or delayed restore
/// may keep the picker busy or overwrite a later copy after the shortcut is dispatched.
@MainActor
enum ClipboardHistoryPasteTransaction {
    static let internalType = NSPasteboard.PasteboardType(ClipboardHistoryCapturePolicy.internalType)

    enum Result: Equatable {
        case dispatched
        case interrupted
        case eventCreationFailed
        case clipboardUnavailable
        case pasteboardSuperseded

        var message: String? {
            switch self {
            case .dispatched: nil
            case .interrupted: "Paste canceled because the original field changed."
            case .eventCreationFailed: "Could not send the paste shortcut."
            case .clipboardUnavailable: "Could not write to the clipboard. Try again."
            case .pasteboardSuperseded: "The clipboard changed before paste. Try again."
            }
        }
    }

    /// Returns the generation we wrote, so a newer copy can prevent stale dispatch.
    static func write(_ text: String, to pasteboard: any SnippetPasteboardAccess) -> Int? {
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string),
              item.setString("", forType: internalType) else { return nil }
        let changeCount = pasteboard.clearContents()
        guard pasteboard.changeCount == changeCount, pasteboard.writeObjects([item]) else { return nil }
        return changeCount
    }

    static func paste(
        _ text: String,
        to pasteboard: any SnippetPasteboardAccess,
        validateTarget: () -> DiagnosticPasteReason?,
        prepareClipboard: () -> Bool,
        prepareShortcut: () -> (() -> Void)?
    ) -> Result {
        let startedAt = ContinuousClock.now
        var outcome = DiagnosticPasteOutcome.interrupted
        var progress = DiagnosticPasteProgress()
        progress.transport = .clipboardHistory
        defer {
            let elapsed = startedAt.duration(to: .now).components
            Diagnostics.record(.pasteDelivery(outcome: outcome, restoration: .notBorrowed,
                durationMilliseconds: elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000,
                hadFingerprint: false, progress: progress))
        }
        if let reason = validateTarget() {
            progress.reason = reason
            return .interrupted
        }
        progress.stage = .eventPreparation
        guard let postShortcut = prepareShortcut() else {
            outcome = .eventCreationFailed
            progress.reason = .eventCreationFailed
            return .eventCreationFailed
        }
        progress.stage = .clipboardAcquisition
        guard prepareClipboard() else {
            outcome = .clipboardUnavailable
            progress.reason = .clipboardUnavailable
            return .clipboardUnavailable
        }
        if let reason = validateTarget() {
            progress.reason = reason
            return .interrupted
        }
        guard let writtenChangeCount = write(text, to: pasteboard) else {
            outcome = .clipboardUnavailable
            progress.reason = .clipboardUnavailable
            return .clipboardUnavailable
        }
        progress.stage = .dispatch
        if let reason = validateTarget() {
            progress.reason = reason
            return .interrupted
        }
        guard pasteboard.changeCount == writtenChangeCount else {
            outcome = .pasteboardSuperseded
            progress.reason = .pasteboardSuperseded
            return .pasteboardSuperseded
        }
        postShortcut()
        progress.pastePosted = true
        outcome = .dispatched
        return .dispatched
    }
}
