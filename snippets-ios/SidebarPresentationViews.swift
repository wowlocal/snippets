import UIKit

/// A wrapping, two-row tag filter for the iPad sidebar.
///
/// The Mac app uses the same interaction: tags stay visible without a horizontal
/// gesture, and a compact disclosure chip expands unusually large tag libraries.
final class SidebarTagFilterView: UIView {
    struct Item: Equatable {
        let tag: String
        let count: Int
    }

    var onToggleTag: ((String) -> Void)?
    var onClearFilters: (() -> Void)?
    var onHeightChange: (() -> Void)?

    private let clearButton = UIButton(type: .system)
    private let flowView = SidebarTagFlowView()
    private let contentInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
    private let clearSlotWidth: CGFloat = 24
    private var items: [Item] = []
    private var activeKeys = Set<String>()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "tag-filters"

        var clearConfiguration = UIButton.Configuration.plain()
        clearConfiguration.image = UIImage(systemName: "xmark.circle.fill")
        clearConfiguration.buttonSize = .small
        clearConfiguration.contentInsets = .zero
        clearConfiguration.baseForegroundColor = .secondaryLabel
        clearButton.configuration = clearConfiguration
        clearButton.accessibilityLabel = "Clear tag filters"
        clearButton.accessibilityIdentifier = "clear-tag-filters"
        clearButton.isPointerInteractionEnabled = true
        clearButton.isHidden = true
        clearButton.addAction(UIAction { [weak self] _ in
            self?.onClearFilters?()
        }, for: .touchUpInside)

        flowView.collapsedRowLimit = 2
        flowView.onHeightChange = { [weak self] in
            self?.setNeedsLayout()
            self?.onHeightChange?()
        }

        addSubview(clearButton)
        addSubview(flowView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(items: [Item], activeKeys: Set<String>) {
        guard items != self.items || activeKeys != self.activeKeys else { return }
        self.items = items
        self.activeKeys = activeKeys

        let chips = items.map { item -> SidebarTagChipButton in
            let key = SnippetTagging.filterKey(for: item.tag)
            let isActive = activeKeys.contains(key)
            let chip = SidebarTagChipButton()
            chip.configure(tag: item.tag, isSelected: isActive)
            chip.accessibilityLabel = "Filter by tag \(item.tag), \(isActive ? "on" : "off"), \(item.count) snippet\(item.count == 1 ? "" : "s")"
            chip.accessibilityIdentifier = "tag-filter-\(key)"
            chip.accessibilityValue = isActive ? "Selected" : "Not selected"
            chip.accessibilityTraits = isActive ? [.button, .selected] : .button
            chip.addAction(UIAction { [weak self] _ in
                self?.onToggleTag?(item.tag)
            }, for: .touchUpInside)
            return chip
        }

        flowView.setChips(chips)
        clearButton.isHidden = activeKeys.isEmpty
        setNeedsLayout()
        onHeightChange?()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        guard !items.isEmpty else { return CGSize(width: size.width, height: 0) }
        let flowWidth = max(0, size.width - contentInsets.left - contentInsets.right - clearSlotWidth)
        let flowHeight = flowView.sizeThatFits(
            CGSize(width: flowWidth, height: .greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: size.width,
            height: ceil(contentInsets.top + flowHeight + contentInsets.bottom)
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let flowX = contentInsets.left + clearSlotWidth
        let flowWidth = max(0, bounds.width - flowX - contentInsets.right)
        let flowHeight = max(0, bounds.height - contentInsets.top - contentInsets.bottom)
        flowView.frame = CGRect(x: flowX, y: contentInsets.top, width: flowWidth, height: flowHeight)

        let clearSize: CGFloat = 20
        clearButton.frame = CGRect(
            x: contentInsets.left,
            y: contentInsets.top + 3,
            width: clearSize,
            height: clearSize
        )
    }
}

private final class SidebarTagFlowView: UIView {
    var horizontalSpacing: CGFloat = 6
    var verticalSpacing: CGFloat = 6
    var collapsedRowLimit: Int?
    var onHeightChange: (() -> Void)?

    private let disclosureButton = SidebarTagChipButton()
    private var chips: [SidebarTagChipButton] = []
    private var isExpanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        disclosureButton.accessibilityIdentifier = "tag-filters-disclosure"
        disclosureButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isExpanded.toggle()
            self.setNeedsLayout()
            self.onHeightChange?()
        }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setChips(_ newChips: [SidebarTagChipButton]) {
        chips.forEach { $0.removeFromSuperview() }
        disclosureButton.removeFromSuperview()
        chips = newChips
        chips.forEach(addSubview)
        addSubview(disclosureButton)
        if chips.isEmpty { isExpanded = false }
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: makeLayout(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let result = makeLayout(width: bounds.width)
        for (index, chip) in chips.enumerated() {
            if let frame = result.chipFrames[index] {
                chip.isHidden = false
                chip.frame = frame
            } else {
                chip.isHidden = true
                chip.frame = .zero
            }
        }
        disclosureButton.isHidden = result.disclosureFrame == nil
        disclosureButton.frame = result.disclosureFrame ?? .zero
    }

    private struct LayoutResult {
        let chipFrames: [CGRect?]
        let disclosureFrame: CGRect?
        let height: CGFloat
    }

    private func makeLayout(width: CGFloat) -> LayoutResult {
        guard width > 1, !chips.isEmpty else {
            return LayoutResult(
                chipFrames: Array(repeating: nil, count: chips.count),
                disclosureFrame: nil,
                height: 0
            )
        }

        let chipSizes = chips.map { fittedSize(for: $0, maximumWidth: width) }
        let totalRows = rowCount(for: chipSizes, width: width)
        let needsDisclosure = collapsedRowLimit.map { totalRows > $0 } ?? false

        var visibleCount = chips.count
        if needsDisclosure, !isExpanded, let rowLimit = collapsedRowLimit {
            visibleCount = collapsedVisibleCount(
                chipSizes: chipSizes,
                width: width,
                rowLimit: rowLimit
            )
        }

        var sequence = Array(chipSizes.prefix(visibleCount))
        var disclosureSize: CGSize?
        if needsDisclosure {
            let hiddenCount = chips.count - visibleCount
            let title = isExpanded ? "Less" : "+\(hiddenCount)"
            disclosureButton.configureDisclosure(title: title, expanded: isExpanded)
            let size = fittedSize(for: disclosureButton, maximumWidth: width)
            disclosureSize = size
            sequence.append(size)
        }

        let frames = frames(for: sequence, width: width)
        var chipFrames = Array<CGRect?>(repeating: nil, count: chips.count)
        for index in 0..<visibleCount {
            chipFrames[index] = frames.frames[index]
        }
        let disclosureFrame = disclosureSize == nil ? nil : frames.frames.last
        return LayoutResult(
            chipFrames: chipFrames,
            disclosureFrame: disclosureFrame,
            height: frames.height
        )
    }

    private func collapsedVisibleCount(
        chipSizes: [CGSize],
        width: CGFloat,
        rowLimit: Int
    ) -> Int {
        guard !chipSizes.isEmpty else { return 0 }

        for candidate in stride(from: chipSizes.count - 1, through: 0, by: -1) {
            let hiddenCount = chipSizes.count - candidate
            disclosureButton.configureDisclosure(title: "+\(hiddenCount)", expanded: false)
            let disclosureSize = fittedSize(for: disclosureButton, maximumWidth: width)
            let sizes = Array(chipSizes.prefix(candidate)) + [disclosureSize]
            if rowCount(for: sizes, width: width) <= rowLimit {
                return candidate
            }
        }
        return 0
    }

    private func fittedSize(for button: UIButton, maximumWidth: CGFloat) -> CGSize {
        let measured = button.sizeThatFits(
            CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        return CGSize(
            width: min(maximumWidth, ceil(measured.width)),
            height: ceil(measured.height)
        )
    }

    private func rowCount(for sizes: [CGSize], width: CGFloat) -> Int {
        guard !sizes.isEmpty else { return 0 }
        var rows = 1
        var x: CGFloat = 0
        for size in sizes {
            if x > 0, x + size.width > width {
                rows += 1
                x = 0
            }
            x += size.width + horizontalSpacing
        }
        return rows
    }

    private func frames(for sizes: [CGSize], width: CGFloat) -> (frames: [CGRect], height: CGFloat) {
        guard !sizes.isEmpty else { return ([], 0) }
        let rowHeight = sizes.map(\.height).max() ?? 0
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0

        for size in sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + verticalSpacing
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: rowHeight))
            x += size.width + horizontalSpacing
        }
        return (frames, y + rowHeight)
    }
}

private final class SidebarTagChipButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isPointerInteractionEnabled = true
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.lineBreakMode = .byTruncatingTail
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(tag: String, isSelected: Bool) {
        let color = AppTheme.tagColor(for: tag)
        var configuration = isSelected
            ? UIButton.Configuration.filled()
            : UIButton.Configuration.tinted()
        configuration.title = tag
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4,
            leading: 9,
            bottom: 4,
            trailing: 9
        )
        configuration.baseForegroundColor = isSelected
            ? AppTheme.contrastingTextColor(on: color)
            : color
        configuration.baseBackgroundColor = AppTheme.tagFillColor(for: tag, selected: isSelected)
        configuration.titleTextAttributesTransformer = Self.titleAttributes
        self.configuration = configuration
    }

    func configureDisclosure(title: String, expanded: Bool) {
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = expanded ? UIImage(systemName: "chevron.up") : nil
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 3
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .small
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4,
            leading: 9,
            bottom: 4,
            trailing: 9
        )
        configuration.baseForegroundColor = .secondaryLabel
        configuration.baseBackgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.12)
        configuration.titleTextAttributesTransformer = Self.titleAttributes
        self.configuration = configuration
        accessibilityLabel = expanded ? "Show fewer tags" : "Show more tags"
    }

    private static let titleAttributes = UIConfigurationTextAttributesTransformer { incoming in
        var outgoing = incoming
        outgoing.font = AppTheme.scaledFont(size: 11, weight: .medium, textStyle: .caption1)
        return outgoing
    }
}

/// Masks a scroll view only at edges that have more content behind them.
final class ScrollFadeContainerView: UIView {
    private struct MaskState: Equatable {
        let bounds: CGRect
        let topIntensity: CGFloat
        let bottomIntensity: CGFloat
    }

    private weak var scrollView: UIScrollView?
    private let maskLayer = CAGradientLayer()
    private let topFadeHeight: CGFloat = 24
    private let bottomFadeHeight: CGFloat = 20
    private var appliedMaskState: MaskState?

    private(set) var topFadeIntensity: CGFloat = 0
    private(set) var bottomFadeIntensity: CGFloat = 0

    init(containing scrollView: UIScrollView) {
        self.scrollView = scrollView
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.mask = maskLayer
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ScrollFadeContainerView, _: UITraitCollection) in
            view.appliedMaskState = nil
            view.updateFade()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFade()
    }

    func updateFade() {
        guard let scrollView, bounds.height > 1 else {
            applyMask(topIntensity: 0, bottomIntensity: 0)
            return
        }

        let inset = scrollView.adjustedContentInset
        let minimumY = -inset.top
        let maximumY = max(
            minimumY,
            scrollView.contentSize.height - bounds.height + inset.bottom
        )
        guard maximumY - minimumY > 1 else {
            applyMask(topIntensity: 0, bottomIntensity: 0)
            return
        }

        let topHiddenDistance = max(0, scrollView.contentOffset.y - minimumY)
        let bottomHiddenDistance = max(0, maximumY - scrollView.contentOffset.y)
        applyMask(
            topIntensity: min(topHiddenDistance / topFadeHeight, 1),
            bottomIntensity: min(bottomHiddenDistance / bottomFadeHeight, 1)
        )
    }

    private func applyMask(topIntensity: CGFloat, bottomIntensity: CGFloat) {
        self.topFadeIntensity = topIntensity
        self.bottomFadeIntensity = bottomIntensity

        let maskState = MaskState(
            bounds: bounds,
            topIntensity: topIntensity,
            bottomIntensity: bottomIntensity
        )
        guard maskState != appliedMaskState else { return }

        let height = max(bounds.height, 1)
        let topFade = min(topFadeHeight / height, 0.45)
        let bottomFade = min(bottomFadeHeight / height, 0.45)
        let opaque = UIColor.black.cgColor
        let topEdge = UIColor.black.withAlphaComponent(1 - topIntensity).cgColor
        let bottomEdge = UIColor.black.withAlphaComponent(1 - bottomIntensity).cgColor

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        maskLayer.endPoint = CGPoint(x: 0.5, y: 1)
        maskLayer.colors = [topEdge, opaque, opaque, bottomEdge]
        maskLayer.locations = [
            0,
            NSNumber(value: Double(topFade)),
            NSNumber(value: Double(max(topFade, 1 - bottomFade))),
            1,
        ]
        CATransaction.commit()
        appliedMaskState = maskState
    }
}
