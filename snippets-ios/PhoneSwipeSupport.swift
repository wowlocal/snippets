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

    static func leadingFullSwipeThreshold(
        leadingWidth: CGFloat,
        containerWidth: CGFloat
    ) -> CGFloat {
        max(containerWidth * 0.52, leadingWidth + 44)
    }

    static func displayedOffset(
        for proposedOffset: CGFloat,
        leadingLimit: CGFloat,
        trailingLimit: CGFloat,
        containerWidth: CGFloat,
        leadingExpansionLimit: CGFloat? = nil
    ) -> CGFloat {
        let effectiveLeadingLimit = max(leadingExpansionLimit ?? leadingLimit, leadingLimit)
        if proposedOffset > effectiveLeadingLimit {
            return effectiveLeadingLimit + rubberBandDistance(
                proposedOffset - effectiveLeadingLimit,
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
        let fullSwipeThreshold = leadingFullSwipeThreshold(
            leadingWidth: leadingWidth,
            containerWidth: containerWidth
        )

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

final class PhoneSwipeActionButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isExclusiveTouch = true
        adjustsImageSizeForAccessibilityContentSizeCategory = true
        titleLabel?.adjustsFontForContentSizeCategory = true
        titleLabel?.minimumScaleFactor = 0.78
        titleLabel?.adjustsFontSizeToFitWidth = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, symbolName: String, color: UIColor) {
        var configuration = UIButton.Configuration.prominentGlass()
        configuration.title = title
        configuration.image = UIImage(systemName: symbolName)
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.cornerStyle = .large
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 8,
            leading: 5,
            bottom: 8,
            trailing: 5
        )
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            incoming in
            var outgoing = incoming
            outgoing.font = AppTheme.scaledFont(
                size: 12,
                weight: .semibold,
                textStyle: .caption1
            )
            return outgoing
        }
        self.configuration = configuration
        accessibilityLabel = title
    }
}
