import AppKit

/// How a matched run reads inside the suggestion panel.
///
/// Four renditions ship side by side so the look can be judged in the real panel,
/// over a real backdrop, instead of from a mockup. Switch them in
/// Settings ▸ General, or launch with `-snippetsMatchHighlightStyle wash` — the
/// argument domain, because a `defaults write` from a shell never reaches a
/// running app.
enum MatchHighlightStyle: String, CaseIterable {
    /// What the panel shipped with: `controlAccentColor` at semibold.
    ///
    /// Kept so the other three have a baseline. It is the least legible of the
    /// four. `controlAccentColor` is a single fixed value in both appearances —
    /// #007AFF on the default accent — so it is tuned for neither, and it is also
    /// the colour the panel washes the *selected* row with. Accent glyphs on an
    /// accent pill measure 2.32:1 in dark and 3.14:1 in light, under the 4.5:1
    /// body text wants and under even the 3:1 large-text floor.
    case accent

    /// No tint at all: unmatched text steps down to `secondaryLabelColor` and the
    /// match keeps `labelColor` at semibold.
    ///
    /// The contrast then comes from two tones AppKit already guarantees against
    /// whatever the glass is sitting on — 10.5:1 in dark, 13.7:1 in light, in
    /// every row state and on every accent colour.
    case emphasis

    /// The accent hue, re-rendered per appearance until it clears 4.5:1 against
    /// the hardest row this panel can draw. Keeps "a match is tinted" and fixes
    /// only the contrast.
    case tint

    /// A tinted pill behind the matched run, like a find-in-page highlight, with
    /// the glyphs flipped to whichever of black/white that pill can carry.
    case wash

    var menuTitle: String {
        switch self {
        case .accent: return "Accent Colour (original)"
        case .emphasis: return "Bold, No Tint"
        case .tint: return "Legible Accent Tint"
        case .wash: return "Highlighter Wash"
        }
    }

    var summary: String {
        switch self {
        case .accent:
            return "The original look: matches take the system accent colour. Measures 2.3:1 against a selected row in dark mode — below the 4.5:1 body text needs."
        case .emphasis:
            return "Matches stay at full label colour and go semibold while the rest of the line steps back. 10.5:1 dark / 13.7:1 light in every row state, on any accent colour."
        case .tint:
            return "Matches keep the accent hue, re-rendered per appearance until it clears 4.5:1 against the busiest row the panel draws."
        case .wash:
            return "Matches sit on a tinted pill, like a find-in-page highlight, with the glyphs flipped to whichever of black or white the pill carries."
        }
    }
}

@MainActor
enum MatchHighlightPreference {
    static let defaultsKey = "snippetsMatchHighlightStyle"

    /// `.tint` rather than `.accent`: the shipped accent never reaches 4.5:1 in
    /// any row state, so leaving it as the default would leave the legibility
    /// problem in place for anyone who never opens Settings. `.tint` fixes that
    /// without giving up the tinted match — the panel goes on saying "these are
    /// the letters you typed" in the user's own accent colour, just in a
    /// rendition of it the row can carry.
    static let fallback: MatchHighlightStyle = .tint

    static var style: MatchHighlightStyle {
        get {
            guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
                  let style = MatchHighlightStyle(rawValue: raw) else {
                return fallback
            }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            NotificationCenter.default.post(name: .snippetsMatchHighlightStyleChanged, object: nil)
        }
    }
}

/// The colours the four renditions draw with.
///
/// Everything accent-derived is solved rather than picked: the accent is a user
/// preference, so a hand-chosen tint that works for blue turns illegible on
/// yellow. Each solve targets 4.5:1 against `referenceRowLevel` and stops there,
/// which keeps as much of the hue as the contrast allows.
@MainActor
enum MatchHighlightPalette {
    /// The range of greys a row in this panel can put behind a glyph.
    ///
    /// Dark runs from the panel material itself (0.17) up to the selected pill's
    /// 13% white wash over it, which lands near #474747 — call it 0.30, a shade
    /// lighter still, leaving headroom for a bright host window coming up through
    /// the glass. Light runs the other way, from the plain row at 0.95 down to the
    /// Increase-Contrast selected pill's 24% accent wash near #B8CFEC — call it
    /// 0.72, a shade darker.
    private static func rowLevelRange(isDark: Bool) -> (darkest: CGFloat, lightest: CGFloat) {
        isDark ? (0.17, 0.30) : (0.72, 0.95)
    }

    /// The row where a tint has the least room to work: the lightest one in dark
    /// mode, the darkest in light. Clearing it clears every other row too.
    private static func referenceRowLevel(isDark: Bool) -> CGFloat {
        let range = rowLevelRange(isDark: isDark)
        return isDark ? range.lightest : range.darkest
    }

    private static let targetContrastRatio: CGFloat = 4.5

    /// Alpha for the wash pill. Heavier in light mode: a saturated tint over a
    /// near-white row separates by hue more than by luminance, and a light wash
    /// reads as a smudge rather than a highlight.
    private static func washAlpha(isDark: Bool) -> CGFloat {
        isDark ? 0.45 : 0.55
    }

    /// How dark the wash's dark option is. Not pure black: the glyphs sit on a
    /// tinted pill, not on paper, and full black on it reads as a hole.
    private static let washDarkTextAlpha: CGFloat = 0.9

    static func matchedColor(for style: MatchHighlightStyle) -> NSColor {
        switch style {
        case .accent: return .controlAccentColor
        case .emphasis: return .labelColor
        case .tint: return tintColor
        case .wash: return washTextColor
        }
    }

    static func unmatchedColor(for style: MatchHighlightStyle, base: NSColor) -> NSColor {
        // Only `.emphasis` earns its contrast by stepping the rest of the line
        // back; the other three leave the line exactly as it was.
        style == .emphasis ? .secondaryLabelColor : base
    }

    static func washColor(for style: MatchHighlightStyle) -> NSColor? {
        guard style == .wash else { return nil }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor.controlAccentColor.withAlphaComponent(washAlpha(isDark: isDark))
        }
    }

    /// The accent, pushed along one axis until it clears the target ratio.
    private static var tintColor: NSColor {
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let backdrop = referenceRowLevel(isDark: isDark)
            let target = targetLuminance(againstLevel: backdrop, isDark: isDark)
            return solvedTint(
                from: resolvedAccent(in: appearance),
                isDark: isDark,
                targetLuminance: target
            )
        }
    }

    /// Black or white, whichever the pill can carry — `TagChipView`'s rule for a
    /// filled chip, but judged on the worst row for each candidate rather than on
    /// one sample. The pill is translucent, so it lightens with the row under it:
    /// white is at its worst over the lightest row, black over the darkest, and
    /// picking on a single mid sample is what puts white text on a pale periwinkle
    /// pill in light mode.
    private static var washTextColor: NSColor {
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let accent = resolvedAccent(in: appearance)
            let alpha = washAlpha(isDark: isDark)
            let range = rowLevelRange(isDark: isDark)

            let palestPill = composite(accent, alpha: alpha, overLevel: range.lightest)
            let darkestPill = composite(accent, alpha: alpha, overLevel: range.darkest)

            let whiteWorstCase = contrastRatio(.white, palestPill)
            let blackWorstCase = contrastRatio(
                composite(.black, alpha: washDarkTextAlpha, overColor: darkestPill),
                darkestPill
            )
            return whiteWorstCase >= blackWorstCase
                ? .white
                : NSColor.black.withAlphaComponent(washDarkTextAlpha)
        }
    }

    // MARK: - Solving

    private static func resolvedAccent(in appearance: NSAppearance) -> NSColor {
        var resolved = NSColor.systemBlue
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return resolved
    }

    /// The luminance a glyph needs so that it and `level` are `targetContrastRatio`
    /// apart. Dark mode solves for the lighter of the pair, light mode the darker.
    private static func targetLuminance(againstLevel level: CGFloat, isDark: Bool) -> CGFloat {
        let backdrop = relativeLuminance(NSColor(srgbRed: level, green: level, blue: level, alpha: 1))
        return isDark
            ? targetContrastRatio * (backdrop + 0.05) - 0.05
            : (backdrop + 0.05) / targetContrastRatio - 0.05
    }

    /// Walks the accent toward legibility along a single parameter and stops at
    /// the first value that reaches `targetLuminance`, so a hue that is already
    /// bright enough — yellow on dark, say — comes back untouched.
    ///
    /// Dark desaturates and brightens together, because brightness alone cannot
    /// get a fully saturated blue past the target: #0000FF sits at 0.07 luminance
    /// at full brightness. Light only darkens, where the same axis is enough.
    private static func solvedTint(
        from accent: NSColor,
        isDark: Bool,
        targetLuminance target: CGFloat
    ) -> NSColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        accent.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        func candidate(_ t: CGFloat) -> NSColor {
            isDark
                ? NSColor(
                    hue: hue,
                    saturation: saturation * (1 - t),
                    brightness: brightness + (1 - brightness) * t,
                    alpha: 1
                )
                : NSColor(hue: hue, saturation: saturation, brightness: brightness * (1 - t), alpha: 1)
        }

        // Luminance is monotonic in t on both axes (t = 1 is white in dark mode,
        // black in light), so a bisection lands on the smallest sufficient push.
        var low: CGFloat = 0
        var high: CGFloat = 1
        for _ in 0..<18 {
            let mid = (low + high) / 2
            let luminance = relativeLuminance(candidate(mid))
            let reached = isDark ? luminance >= target : luminance <= target
            if reached { high = mid } else { low = mid }
        }
        return candidate(high)
    }

    private static func composite(_ color: NSColor, alpha: CGFloat, overLevel level: CGFloat) -> NSColor {
        composite(color, alpha: alpha, overColor: NSColor(srgbRed: level, green: level, blue: level, alpha: 1))
    }

    private static func composite(_ color: NSColor, alpha: CGFloat, overColor backdrop: NSColor) -> NSColor {
        guard let srgb = color.usingColorSpace(.sRGB),
              let back = backdrop.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            srgbRed: srgb.redComponent * alpha + back.redComponent * (1 - alpha),
            green: srgb.greenComponent * alpha + back.greenComponent * (1 - alpha),
            blue: srgb.blueComponent * alpha + back.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private static func contrastRatio(_ one: NSColor, _ other: NSColor) -> CGFloat {
        let a = relativeLuminance(one)
        let b = relativeLuminance(other)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> CGFloat {
        guard let srgb = color.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(srgb.redComponent)
            + 0.7152 * linear(srgb.greenComponent)
            + 0.0722 * linear(srgb.blueComponent)
    }
}

/// One rendered label: the string plus, for `.wash`, the runs that need a pill
/// behind them. The pill cannot live in the attributed string — AppKit's
/// `.backgroundColor` attribute paints an unpadded square box — so it travels
/// alongside and `MatchHighlightLabel` draws it.
struct MatchHighlightRendering {
    let string: NSAttributedString
    let washRanges: [NSRange]
    let washColor: NSColor?
}

@MainActor
enum MatchHighlightRenderer {
    static func render(
        _ string: String,
        font: NSFont,
        baseColor: NSColor,
        matchRanges: [NSRange],
        // Passed in rather than defaulted to `MatchHighlightPreference.style`: a
        // default argument is evaluated outside the actor, and the caller is
        // already reading the preference once per cell.
        style: MatchHighlightStyle
    ) -> MatchHighlightRendering {
        let plain = NSMutableAttributedString(
            string: string,
            attributes: [.font: font, .foregroundColor: baseColor]
        )
        let fullRange = NSRange(location: 0, length: (string as NSString).length)
        let valid = matchRanges.filter { NSIntersectionRange($0, fullRange).length == $0.length }

        guard !string.isEmpty, !valid.isEmpty else {
            return MatchHighlightRendering(string: plain, washRanges: [], washColor: nil)
        }

        let attributed = NSMutableAttributedString(
            string: string,
            attributes: [
                .font: font,
                .foregroundColor: MatchHighlightPalette.unmatchedColor(for: style, base: baseColor)
            ]
        )
        let matchedFont = emphasizedFont(for: font)
        let matchedColor = MatchHighlightPalette.matchedColor(for: style)
        for range in valid {
            attributed.addAttributes([.font: matchedFont, .foregroundColor: matchedColor], range: range)
        }

        let washColor = MatchHighlightPalette.washColor(for: style)
        return MatchHighlightRendering(
            string: attributed,
            // FuzzyMatch emits one range per matched character, so neighbours have
            // to be merged or the pill comes out scalloped at every seam.
            washRanges: washColor == nil ? [] : merged(valid),
            washColor: washColor
        )
    }

    static func emphasizedFont(for font: NSFont) -> NSFont {
        if font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
            return .monospacedSystemFont(ofSize: font.pointSize, weight: .semibold)
        }

        return .systemFont(ofSize: font.pointSize, weight: .semibold)
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.filter { $0.length > 0 }.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= last.location + last.length {
                let end = max(last.location + last.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: last.location, length: end - last.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

/// A label that can paint a rounded wash behind ranges of its own text.
///
/// The wash and the glyphs come out of one `NSLayoutManager`, laid out in the
/// cell's own title rect, so they cannot drift apart. With no wash set the field
/// falls straight through to `NSTextField`'s drawing — the three styles that need
/// no pill never leave the path they have always used.
final class MatchHighlightLabel: NSTextField {
    private var washRanges: [NSRange] = []
    private var washColor: NSColor?

    /// Enough to clear the glyphs without the pill closing up the space between
    /// two neighbouring words; the vertical inset shrinks the line fragment so
    /// pills on a wrapped second line never touch the first.
    private static let washHorizontalInset: CGFloat = -1.5
    private static let washVerticalInset: CGFloat = 1
    private static let washCornerRadius: CGFloat = 3.5

    func applyWash(ranges: [NSRange], color: NSColor?) {
        let resolved = color == nil ? [] : ranges
        guard resolved != washRanges || color != washColor else { return }
        washRanges = resolved
        washColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let washColor, !washRanges.isEmpty, attributedStringValue.length > 0 else {
            super.draw(dirtyRect)
            return
        }

        let titleRect = (cell as? NSTextFieldCell)?.titleRect(forBounds: bounds) ?? bounds
        // The storage owns the layout manager, not the other way round, so it has
        // to outlive the drawing.
        let storage = NSTextStorage(attributedString: attributedStringValue)
        let container = NSTextContainer(
            size: NSSize(width: titleRect.width, height: .greatestFiniteMagnitude)
        )
        // 2, not 0: `NSTextFieldCell` keeps TextKit's default padding, and dropping
        // it slides every glyph 2pt left of where the other three styles draw.
        container.lineFragmentPadding = 2
        container.maximumNumberOfLines = maximumNumberOfLines
        container.lineBreakMode = lineBreakMode
        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        NSGraphicsContext.saveGraphicsState()
        // `drawGlyphs` wants a top-left origin. A label is not flipped, so put the
        // *context* into text coordinates rather than flipping the view: flipping
        // the view would change how `super.draw` lays out for every other style.
        if !isFlipped {
            let flip = NSAffineTransform()
            flip.translateX(by: 0, yBy: bounds.height)
            flip.scaleX(by: 1, yBy: -1)
            flip.concat()
        }

        // Everything below is in those top-left coordinates, including the title
        // rect, which arrives measured from the bottom on an unflipped view.
        //
        // No vertical centring here: `titleRect(forBounds:)` has already done it,
        // so the text starts at that rect's top edge. Centring the laid-out block
        // inside it a second time is what pushed the glyphs 2pt down. Measured
        // against a stock NSTextField this lands at Δ0 on both axes for the name
        // label, the wrapped two-line name, and the monospaced keyword.
        let origin = NSPoint(
            x: titleRect.minX,
            y: isFlipped ? titleRect.minY : bounds.height - titleRect.maxY
        )

        washColor.setFill()
        let emptySelection = NSRange(location: NSNotFound, length: 0)
        for range in washRanges {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: emptySelection,
                in: container
            ) { rect, _ in
                let pill = rect
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: Self.washHorizontalInset, dy: Self.washVerticalInset)
                guard pill.width > 0, pill.height > 0 else { return }
                NSBezierPath(
                    roundedRect: pill,
                    xRadius: Self.washCornerRadius,
                    yRadius: Self.washCornerRadius
                ).fill()
            }
        }

        layoutManager.drawGlyphs(
            forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs),
            at: origin
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}
