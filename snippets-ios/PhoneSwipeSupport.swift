import UIKit

enum PhoneSnippetSwipeSide: Equatable {
    case leading
    case trailing
}

enum PhoneSnippetSwipeAction: Equatable {
    case edit
    case pin
    case delete
}

enum PhoneSnippetSwipeResolution: Equatable {
    case closed
    case open(PhoneSnippetSwipeSide)
    case triggerLeadingAction
}

enum PhoneSwipePhysics {
    static let projectionTime: CGFloat = 0.18
    static let rubberBandCoefficient: CGFloat = 0.55

    static func displayedOffset(
        for proposedOffset: CGFloat,
        leadingLimit: CGFloat,
        trailingLimit: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        if proposedOffset > leadingLimit {
            return leadingLimit + rubberBandDistance(
                proposedOffset - leadingLimit,
                dimension: containerWidth
            )
        }
        if proposedOffset < -trailingLimit {
            return -trailingLimit - rubberBandDistance(
                -trailingLimit - proposedOffset,
                dimension: containerWidth
            )
        }
        return proposedOffset
    }

    static func resolution(
        rawOffset: CGFloat,
        velocity: CGFloat,
        leadingWidth: CGFloat,
        trailingWidth: CGFloat,
        containerWidth: CGFloat
    ) -> PhoneSnippetSwipeResolution {
        let projectedOffset = rawOffset + velocity * projectionTime
        let fullSwipeThreshold = max(containerWidth * 0.52, leadingWidth + 44)

        if rawOffset > 0,
           projectedOffset >= fullSwipeThreshold {
            return .triggerLeadingAction
        }
        if projectedOffset >= leadingWidth * 0.5 {
            return .open(.leading)
        }
        if projectedOffset <= -trailingWidth * 0.5 {
            return .open(.trailing)
        }
        return .closed
    }

    private static func rubberBandDistance(_ distance: CGFloat, dimension: CGFloat) -> CGFloat {
        let dimension = max(dimension, 1)
        let magnitude = max(distance, 0)
        return (1 - 1 / (magnitude * rubberBandCoefficient / dimension + 1)) * dimension
    }
}

@MainActor
protocol PhoneSnippetCellSwipeDelegate: AnyObject {
    func phoneSnippetCellWillBeginSwipe(_ cell: PhoneSnippetCell)
    func phoneSnippetCellDidCloseSwipe(_ cell: PhoneSnippetCell)
    func phoneSnippetCell(
        _ cell: PhoneSnippetCell,
        requested action: PhoneSnippetSwipeAction
    )
}

final class PhoneSwipeActionButton: UIControl {
    private let symbolView = UIImageView()
    private let titleLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        clipsToBounds = true

        symbolView.contentMode = .scaleAspectFit
        symbolView.tintColor = .white
        symbolView.setContentHuggingPriority(.required, for: .vertical)
        symbolView.setContentCompressionResistancePriority(.required, for: .vertical)

        titleLabel.font = AppTheme.scaledFont(
            size: 12,
            weight: .semibold,
            textStyle: .caption1
        )
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        titleLabel.minimumScaleFactor = 0.75
        titleLabel.adjustsFontSizeToFitWidth = true

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 4
        stack.isUserInteractionEnabled = false
        [symbolView, titleLabel].forEach(stack.addArrangedSubview)
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbolView.widthAnchor.constraint(equalToConstant: 21),
            symbolView.heightAnchor.constraint(equalToConstant: 21),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 5),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -5),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet {
            alpha = isHighlighted ? 0.68 : 1
        }
    }

    func configure(title: String, symbolName: String, color: UIColor) {
        titleLabel.text = title
        symbolView.image = UIImage(systemName: symbolName)
        backgroundColor = color
        accessibilityLabel = title
        accessibilityTraits = .button
    }
}
