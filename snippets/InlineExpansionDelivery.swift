import Foundation

/// Each step moves only the selection. The editor must acknowledge its exact UTF-16 range
/// before another key can be sent. Only the last step authorizes a text edit.
struct InlineSelectionPlan {
    enum Command {
        case setRange, selectAll, collapseRight, extendLeft
    }

    struct Step {
        let command: Command
        let before: NSRange
        let range: NSRange
    }

    let steps: [Step]

    // Above this size, prefer a single verified selection request for autocomplete tails.
    private static let longSelectionLength = 120

    init?(proof: VerifiedTriggerSelection, editorHandlesSelection: Bool,
          fieldLength: @autoclosure () -> Int?, canSetRange: @autoclosure () -> Bool) {
        let range = proof.replacementRange
        let longSelection = proof.originalSelection.length > Self.longSelectionLength
        if editorHandlesSelection, longSelection, range.location == 0, range.length == fieldLength() {
            steps = [Step(command: .selectAll, before: proof.originalSelection, range: range)]
            return
        }
        // Autocomplete can select thousands of characters following a short trigger. For a
        // large existing selection keep the verified one-request path when the host offers it.
        if !editorHandlesSelection || (longSelection && canSetRange()) {
            guard editorHandlesSelection || canSetRange() else { return nil }
            steps = [Step(command: .setRange, before: proof.originalSelection, range: range)]
            return
        }

        let end = NSMaxRange(range)
        var selection = NSRange(location: end, length: 0)
        var movements: [Step] = []
        if proof.originalSelection.length > 0 {
            // AX doesn't expose the selection's anchor. Establish one at its far end first.
            movements.append(Step(command: .collapseRight, before: proof.originalSelection, range: selection))
        }
        for character in proof.expectedText.reversed() {
            let width = character.utf16.count
            let before = selection
            selection.location -= width
            selection.length += width
            movements.append(Step(command: .extendLeft, before: before, range: selection))
        }
        steps = movements
    }
}

/// Bounded, single-line renderer output can be confirmed at its original insertion offset.
/// Larger or multiline output uses the caret fingerprint, which can span renderer nodes.
struct InlinePasteReadback {
    let range: NSRange
    let expected: String

    init?(location: Int, text: String) {
        let length = text.utf16.count
        guard location >= 0, length > 0, length <= VerifiedTriggerSelection.maximumReadUTF16Length,
              length <= Int.max - location, !text.contains(where: \.isNewline) else { return nil }
        range = NSRange(location: location, length: length)
        expected = text
    }

    func progress(caret: CFRange?, read: (CFRange) -> String?) -> PasteProgress {
        guard let caret else { return .unreadable }
        guard caret.location == NSMaxRange(range), caret.length == 0 else { return .idle }
        guard let inserted = read(CFRange(location: range.location, length: range.length)) else { return .unreadable }
        return inserted.utf16.elementsEqual(expected.utf16) ? .pasteObserved : .pendingEditObserved
    }
}
