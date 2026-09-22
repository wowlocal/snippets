import AppKit

/// Local commands for the first nine results in an open, keyboard-enabled picker.
/// These are never registered as global shortcuts or used by inline suggestions.
enum PickerQuickSelection {
    static func row(for event: NSEvent) -> Int? {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
        else { return nil }

        // Hardware digit keys also work with layouts whose unshifted number row
        // produces punctuation. Caps Lock and numeric-pad flags are immaterial.
        switch event.keyCode {
        case 18, 83: return 0
        case 19, 84: return 1
        case 20, 85: return 2
        case 21, 86: return 3
        case 23, 87: return 4
        case 22, 88: return 5
        case 26, 89: return 6
        case 28, 91: return 7
        case 25, 92: return 8
        default: return nil
        }
    }

    static func label(forRow row: Int) -> String? {
        (0..<9).contains(row) ? "⌘\(row + 1)" : nil
    }
}
