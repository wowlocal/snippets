import AppKit

/// One labelled section of the editor form — "Keyword", and everything that
/// belongs to the keyword — as a label above its fields.
///
/// This used to flip between a stacked shape and a wide one that moved the label
/// into a right-aligned column beside its fields. The wide shape saved real
/// vertical space and looked wrong doing it: a fixed label column leaves a dead
/// gutter down the left of the pane and pulls every label away from the field it
/// names. One shape, at every width.
@MainActor
final class EditorFormSection {
    let row: NSStackView
    let fieldColumn: NSStackView
    let label: NSTextField?

    /// - Parameters:
    ///   - title: nil builds a label-less section (the Enabled checkbox).
    ///   - row: an existing stack to build into, for the one section the view
    ///     controller already holds a reference to and hides by hand.
    ///   - pinsFieldWidths: false leaves the fields at their own width, for a
    ///     control that should hug its title instead of spanning the form.
    init(
        title: String?,
        fields: [NSView],
        row: NSStackView? = nil,
        fieldSpacing: CGFloat = 6,
        pinsFieldWidths: Bool = true,
        labelSpacing: CGFloat = 8
    ) {
        let row = row ?? NSStackView()
        self.row = row
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

        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .vertical
        row.alignment = .leading
        row.distribution = .fill
        row.spacing = label == nil ? 0 : labelSpacing

        if let label {
            row.addArrangedSubview(label)
        }
        row.addArrangedSubview(fieldColumn)
        fieldColumn.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
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
