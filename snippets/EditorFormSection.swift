import AppKit

/// Which shape the editor form is in. Chosen from the editor pane's width, not
/// the window's: the split divider and ⌘B move the pane without the window
/// changing size at all.
enum EditorLayoutMode {
    case stacked
    case wide
}

/// One labelled section of the editor form — "Keyword", and everything that
/// belongs to the keyword — in a shape that works both ways up.
///
/// Stacked, the label sits above its fields and every field spans the form.
/// Wide, the same label moves into a fixed right-aligned column beside them,
/// which is where the vertical saving comes from: four label rows stop being
/// rows at all.
///
/// Nothing is ever re-parented between the two. The row owns exactly two
/// children for its whole life and a flip changes the row's orientation plus
/// two width constraints, so it cannot disturb a field editor mid-keystroke,
/// cannot reorder anything the hand-wired tab loop walks, and cannot leak an
/// arranged subview however many times it runs.
@MainActor
final class EditorFormSection {
    /// Wide enough for "Keyword", the longest of the five, at 13pt semibold.
    /// Measured rather than guessed — see the layout harness in the commit
    /// message. A label that somehow exceeded it would truncate rather than
    /// break the row, because its compression resistance is left at default.
    static let labelColumnWidth: CGFloat = 58
    static let labelColumnGap: CGFloat = 12
    static var labelColumnInset: CGFloat { labelColumnWidth + labelColumnGap }

    let row: NSStackView
    let labelHolder = NSView()
    let fieldColumn: NSStackView
    let label: NSTextField?

    private let stackedSpacing: CGFloat
    private let wideLabelTopInset: CGFloat
    private var labelTopConstraint: NSLayoutConstraint?
    private var stackedConstraints: [NSLayoutConstraint] = []
    private var wideConstraints: [NSLayoutConstraint] = []
    private(set) var mode: EditorLayoutMode = .stacked

    /// - Parameters:
    ///   - title: nil builds a label-less section whose fields simply indent
    ///     past the label column when wide (the Enabled checkbox).
    ///   - row: an existing stack to build into, for the one section the view
    ///     controller already holds a reference to and hides by hand.
    ///   - pinsFieldWidths: false leaves the fields at their own width, for a
    ///     control that should hug its title instead of spanning the form.
    ///   - wideLabelTopInset: how far the label drops inside its column so it
    ///     sits level with the first line of the field beside it. Containers
    ///     have no baseline to align to, so this is measured per section.
    init(
        title: String?,
        fields: [NSView],
        row: NSStackView? = nil,
        fieldSpacing: CGFloat = 6,
        pinsFieldWidths: Bool = true,
        stackedSpacing: CGFloat = 8,
        wideLabelTopInset: CGFloat = 0
    ) {
        let row = row ?? NSStackView()
        self.row = row
        self.stackedSpacing = title == nil ? 0 : stackedSpacing
        self.wideLabelTopInset = wideLabelTopInset
        self.fieldColumn = EditorFormSection.makeColumn(
            fields,
            spacing: fieldSpacing,
            pinsWidths: pinsFieldWidths
        )

        if let title {
            let made = NSTextField(labelWithString: title)
            made.font = .systemFont(ofSize: 13, weight: .semibold)
            made.textColor = .secondaryLabelColor
            made.alignment = .left
            made.translatesAutoresizingMaskIntoConstraints = false
            label = made
        } else {
            label = nil
        }

        labelHolder.translatesAutoresizingMaskIntoConstraints = false

        row.translatesAutoresizingMaskIntoConstraints = false
        row.distribution = .fill
        row.addArrangedSubview(labelHolder)
        row.addArrangedSubview(fieldColumn)

        if let label {
            labelHolder.addSubview(label)
            let top = label.topAnchor.constraint(equalTo: labelHolder.topAnchor)
            labelTopConstraint = top
            NSLayoutConstraint.activate([
                top,
                // Trailing-pinned with a slack leading edge is what right-aligns
                // the label in the wide column; in the stacked shape the holder
                // is exactly the label's width, so the same pair reads as left.
                label.trailingAnchor.constraint(equalTo: labelHolder.trailingAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: labelHolder.leadingAnchor),
                label.bottomAnchor.constraint(equalTo: labelHolder.bottomAnchor)
            ])
            stackedConstraints.append(labelHolder.widthAnchor.constraint(equalTo: label.widthAnchor))
        } else {
            // Nothing in it and no height either, so the stacked shape does not
            // pay a row for a label that does not exist.
            labelHolder.heightAnchor.constraint(equalToConstant: 0).isActive = true
            stackedConstraints.append(labelHolder.widthAnchor.constraint(equalToConstant: 0))
        }

        stackedConstraints.append(fieldColumn.widthAnchor.constraint(equalTo: row.widthAnchor))

        wideConstraints.append(
            labelHolder.widthAnchor.constraint(equalToConstant: EditorFormSection.labelColumnWidth)
        )
        wideConstraints.append(
            fieldColumn.widthAnchor.constraint(
                equalTo: row.widthAnchor,
                constant: -EditorFormSection.labelColumnInset
            )
        )

        applyLayout(.stacked)
    }

    /// Idempotent by construction — every call ends with exactly one of the two
    /// constraint sets active — but the caller guards on the mode anyway so a
    /// divider drag does not churn constraints on every frame.
    func applyLayout(_ mode: EditorLayoutMode) {
        self.mode = mode

        switch mode {
        case .stacked:
            NSLayoutConstraint.deactivate(wideConstraints)
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = stackedSpacing
            labelTopConstraint?.constant = 0
            NSLayoutConstraint.activate(stackedConstraints)
        case .wide:
            NSLayoutConstraint.deactivate(stackedConstraints)
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = EditorFormSection.labelColumnGap
            labelTopConstraint?.constant = wideLabelTopInset
            NSLayoutConstraint.activate(wideConstraints)
        }
    }

    static func makeColumn(_ views: [NSView], spacing: CGFloat, pinsWidths: Bool) -> NSStackView {
        let column = NSStackView(views: views)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = spacing
        column.distribution = .fill
        column.translatesAutoresizingMaskIntoConstraints = false

        if pinsWidths {
            for view in views {
                // A TagFlowView reports no intrinsic width and derives its height
                // from its bounds, so it is only ever laid out correctly inside a
                // container whose width is stated.
                view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        return column
    }
}
