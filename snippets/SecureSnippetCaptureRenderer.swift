import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface

/// Renders only the visible part of a secure text view into an IOSurface-backed
/// sample buffer. The sole on-screen destination for those pixels is an
/// `AVSampleBufferDisplayLayer` whose capture protection is enabled before the
/// first frame is made.
///
/// The class is deliberately main-actor-bound: TextKit 1 layout, AppKit colors,
/// and layer ownership all belong to the UI thread. The Core Graphics context is
/// offscreen and is never installed as the view/window backing context.
@MainActor
final class SecureSnippetCaptureRenderer {
    struct RenderedFrameInspection {
        let pixelBuffer: CVPixelBuffer
        let geometry: SecureCaptureFrameGeometry
    }

    private unowned let textView: SnippetContentTextView
    private let displayLayer: AVSampleBufferDisplayLayer
    private let fallbackLayer: CALayer
    private var frameGeneration: UInt64 = 0
    private var isRendering = false
    private weak var observedClipView: NSClipView?
    private var clipViewObserver: NSObjectProtocol?
    private var decodeFailureObserver: NSObjectProtocol?
    private var flushObserverForTesting: ((Bool) -> Void)?

    var onFailure: (() -> Void)?

    init(textView: SnippetContentTextView) {
        self.textView = textView

        let displayLayer = AVSampleBufferDisplayLayer()
        // Security-critical ordering: protection, opacity, and neutral backing are
        // configured before the layer can receive or display a plaintext frame.
        displayLayer.preventsCapture = true
        displayLayer.isOpaque = true
        displayLayer.videoGravity = .resize
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
        displayLayer.actions = Self.disabledLayerActions
        displayLayer.isHidden = true
        self.displayLayer = displayLayer

        let fallbackLayer = CALayer()
        fallbackLayer.isOpaque = true
        fallbackLayer.actions = Self.disabledLayerActions
        fallbackLayer.isHidden = true
        self.fallbackLayer = fallbackLayer

        textView.wantsLayer = true
        guard let rootLayer = textView.layer else { return }
        rootLayer.addSublayer(fallbackLayer)
        rootLayer.addSublayer(displayLayer)

        decodeFailureObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: displayLayer.sampleBufferRenderer,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.failClosed()
            }
        }
    }

    deinit {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
        }
        if let decodeFailureObserver {
            NotificationCenter.default.removeObserver(decodeFailureObserver)
        }
    }

    func arm() -> Bool {
        guard displayLayer.preventsCapture, displayLayer.superlayer != nil else {
            failClosed()
            return false
        }

        installClipViewObserver()
        updateLayerGeometry()
        updateFallbackColor()
        fallbackLayer.isHidden = false
        displayLayer.isHidden = false
        return enqueueFrame(kind: .redaction)
    }

    func renderPlaintext() -> Bool {
        enqueueFrame(kind: .plaintext)
    }

    func renderRedaction() -> Bool {
        enqueueFrame(kind: .redaction)
    }

    func invalidate() {
        guard !textView.isClearingSecurePlaintextStorageForTeardown else { return }
        guard textView.secureCapturePolicy.keepsProtectedLayerVisible else { return }
        if textView.secureCapturePolicy.rendersPlaintextPixels {
            _ = renderPlaintext()
        } else {
            _ = renderRedaction()
        }
    }

    /// Synchronously removes the last protected frame from the presentation tree.
    /// The retained CoreMedia/CoreVideo objects are local to `enqueueFrame` and are
    /// released after enqueue; flushing removes AVFoundation's retained image.
    func clear() {
        frameGeneration &+= 1
        removeClipViewObserver()
        displayLayer.isHidden = true
        flush(removingDisplayedImage: true)
        fallbackLayer.isHidden = true
    }

    func failClosed() {
        guard textView.secureCapturePolicy.phase != .failedClosed else { return }
        clear()
        // The owner gets one synchronous chance to save the suppressed text. Only
        // the owner knows whether this view is still bound to the selected record.
        onFailure?()
        textView.secureCaptureRendererDidFail()
    }

    /// Test/manual-verification boundary. It exercises the exact IOSurface and
    /// TextKit raster path used by the protected layer but never enqueues the
    /// result into an ordinary on-screen layer.
    func renderFrameForInspection(plaintext: Bool) -> RenderedFrameInspection? {
        guard let geometry = frameGeometry(),
              let pixelBuffer = makePixelBuffer(for: geometry),
              draw(kind: plaintext ? .plaintext : .redaction, into: pixelBuffer, geometry: geometry)
        else { return nil }
        return RenderedFrameInspection(pixelBuffer: pixelBuffer, geometry: geometry)
    }

    var captureProtectionEnabledForInspection: Bool { displayLayer.preventsCapture }

    var frameGenerationForInspection: UInt64 { frameGeneration }

    var observesScrollForInspection: Bool {
        observedClipView === textView.enclosingScrollView?.contentView && clipViewObserver != nil
    }

    func setFlushObserverForTesting(_ observer: ((Bool) -> Void)?) {
        flushObserverForTesting = observer
    }

    private enum FrameKind {
        case redaction
        case plaintext
    }

    @discardableResult
    private func enqueueFrame(kind: FrameKind) -> Bool {
        // TextKit may synchronously ask the view to redraw its insertion point or
        // selection while this pass is laying out the same current state. Coalesce
        // that reentrant invalidation into the active pass; it is not a decoder or
        // protection failure and must never trip the fail-closed path.
        if isRendering { return true }

        guard textView.secureCapturePolicy.keepsProtectedLayerVisible,
              displayLayer.preventsCapture,
              displayLayer.superlayer != nil,
              let geometry = frameGeometry() else {
            failClosed()
            return false
        }

        isRendering = true
        defer { isRendering = false }
        updateLayerGeometry()
        updateFallbackColor()

        if case .redaction = kind {
            // Hiding is synchronous even if AVFoundation completes its flush later:
            // physical observers see the neutral fallback immediately.
            fallbackLayer.isHidden = false
            displayLayer.isHidden = true
            flush(removingDisplayedImage: true)
        }

        guard let pixelBuffer = makePixelBuffer(for: geometry),
              draw(kind: kind, into: pixelBuffer, geometry: geometry),
              let sampleBuffer = makeSampleBuffer(from: pixelBuffer) else {
            failClosed()
            return false
        }

        // A static editor needs one frame, not a playback queue. Discard queued
        // plaintext buffers before each replacement, but retain the currently
        // displayed protected image until the new protected frame is accepted. Using
        // `removingDisplayedImage: true` here exposed the neutral fallback between
        // caret/selection frames and made the complete secure body blink.
        if case .plaintext = kind {
            flush(removingDisplayedImage: false)
        }

        // The layer remains behind an opaque neutral fallback until AVFoundation
        // accepts and presents this protected buffer. There is never an unprotected
        // rendering fallback.
        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        if displayLayer.sampleBufferRenderer.status == .failed {
            failClosed()
            return false
        }

        displayLayer.isHidden = false
        fallbackLayer.isHidden = false
        return true
    }

    private func flush(removingDisplayedImage: Bool) {
        flushObserverForTesting?(removingDisplayedImage)
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: removingDisplayedImage,
            completionHandler: nil
        )
    }

    private func frameGeometry() -> SecureCaptureFrameGeometry? {
        let viewport = textView.visibleRect.intersection(textView.bounds)
        let scale = textView.window?.backingScaleFactor
            ?? textView.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        return SecureCaptureFrameGeometry.make(viewport: viewport, backingScale: scale)
    }

    private func updateLayerGeometry() {
        let viewport = textView.visibleRect.intersection(textView.bounds)
        let frame = CGRect(origin: viewport.origin, size: viewport.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = frame
        fallbackLayer.frame = frame
        displayLayer.contentsScale = textView.window?.backingScaleFactor ?? 1
        fallbackLayer.contentsScale = displayLayer.contentsScale
        CATransaction.commit()
    }

    private func updateFallbackColor() {
        fallbackLayer.backgroundColor = resolvedBackgroundColor().cgColor
    }

    private func makePixelBuffer(for geometry: SecureCaptureFrameGeometry) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            geometry.pixelWidth,
            geometry.pixelHeight,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard result == kCVReturnSuccess,
              let pixelBuffer,
              CVPixelBufferGetIOSurface(pixelBuffer) != nil else { return nil }
        return pixelBuffer
    }

    private func draw(
        kind: FrameKind,
        into pixelBuffer: CVPixelBuffer,
        geometry: SecureCaptureFrameGeometry
    ) -> Bool {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: baseAddress,
                width: geometry.pixelWidth,
                height: geometry.pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: colorSpace,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                    | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else { return false }

        let backgroundColor = resolvedBackgroundColor()
        context.setFillColor(backgroundColor.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: geometry.pixelWidth, height: geometry.pixelHeight))
        guard kind == .plaintext else { return true }

        context.saveGState()
        defer { context.restoreGState() }

        // CVPixelBuffer video rows are top-down, while a bitmap CGContext starts
        // with Quartz's bottom-left coordinate system. TextKit supplies geometry in
        // this flipped NSTextView's top-left coordinate system, so map the viewport's
        // top edge to the bitmap's top edge before applying the backing scale. Without
        // this explicit Y inversion AVSampleBufferDisplayLayer presents the complete
        // secure text raster upside down.
        context.translateBy(x: 0, y: CGFloat(geometry.pixelHeight))
        context.scaleBy(x: geometry.backingScale, y: -geometry.backingScale)
        context.translateBy(x: -geometry.viewport.origin.x, y: -geometry.viewport.origin.y)

        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.current = graphicsContext
            drawTextViewport(geometry.viewport)
        }
        return true
    }

    private func drawTextViewport(_ viewport: CGRect) {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        layoutManager.ensureLayout(for: textContainer)
        let containerOrigin = NSPoint(
            x: textView.textContainerOrigin.x,
            y: textView.textContainerOrigin.y
        )
        let containerViewport = viewport.offsetBy(dx: -containerOrigin.x, dy: -containerOrigin.y)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerViewport, in: textContainer)

        layoutManager.drawBackground(forGlyphRange: glyphRange, at: containerOrigin)
        drawSelectionIfNeeded(
            layoutManager: layoutManager,
            textContainer: textContainer,
            visibleGlyphRange: glyphRange,
            origin: containerOrigin
        )
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: containerOrigin)
        drawCaretIfNeeded(layoutManager: layoutManager, textContainer: textContainer, origin: containerOrigin)
    }

    private func drawSelectionIfNeeded(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        visibleGlyphRange: NSRange,
        origin: CGPoint
    ) {
        let selectionColor = textView.window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        selectionColor.setFill()
        let textLength = (textView.string as NSString).length

        for rangeValue in textView.selectedRanges {
            let characterRange = rangeValue.rangeValue
            guard characterRange.location != NSNotFound,
                  characterRange.location < textLength,
                  characterRange.length > 0 else { continue }
            let clampedCharacterRange = NSRange(
                location: characterRange.location,
                length: min(characterRange.length, textLength - characterRange.location)
            )
            let selectionGlyphRange = layoutManager.glyphRange(
                forCharacterRange: clampedCharacterRange,
                actualCharacterRange: nil
            )
            let visibleSelection = NSIntersectionRange(selectionGlyphRange, visibleGlyphRange)
            guard visibleSelection.length > 0 else { continue }

            layoutManager.enumerateEnclosingRects(
                forGlyphRange: visibleSelection,
                withinSelectedGlyphRange: selectionGlyphRange,
                in: textContainer
            ) { rect, _ in
                rect.offsetBy(dx: origin.x, dy: origin.y).fill()
            }
        }
    }

    private func drawCaretIfNeeded(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: CGPoint
    ) {
        guard textView.window?.firstResponder === textView,
              textView.shouldDrawInsertionPoint else { return }
        let selectedRange = textView.selectedRange()
        guard selectedRange.length == 0 else { return }

        let textLength = (textView.string as NSString).length
        let characterIndex = min(selectedRange.location, textLength)
        let caretWidth = max(1 / (textView.window?.backingScaleFactor ?? 1), 1)
        let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)

        // NSTextView already exposes its exact TextKit insertion geometry, including
        // bidi text, empty storage, wrapped lines, end-of-document, and the extra line
        // fragment after a trailing newline. Convert its screen rect back into this
        // view instead of reimplementing those rules when attached to a window.
        if let window = textView.window {
            let screenRect = textView.firstRect(
                forCharacterRange: NSRange(location: characterIndex, length: 0),
                actualRange: nil
            )
            if screenRect.origin.x.isFinite,
               screenRect.origin.y.isFinite,
               screenRect.height.isFinite,
               screenRect.height > 0 {
                var viewRect = textView.convert(window.convertFromScreen(screenRect), from: nil)
                viewRect.size.width = caretWidth
                textView.insertionPointColor.setFill()
                viewRect.fill()
                return
            }
        }

        let rect: NSRect
        if textLength == 0 || layoutManager.numberOfGlyphs == 0 {
            rect = NSRect(
                x: origin.x + (textContainer.lineFragmentPadding),
                y: origin.y,
                width: caretWidth,
                height: layoutManager.defaultLineHeight(for: font)
            )
        } else if characterIndex == textLength {
            let lastGlyph = layoutManager.numberOfGlyphs - 1
            var lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: lastGlyph,
                effectiveRange: nil,
                withoutAdditionalLayout: false
            )
            let textEndsInNewline = (textView.string as NSString).character(at: textLength - 1) == 0x0A
                || (textView.string as NSString).character(at: textLength - 1) == 0x0D
            if textEndsInNewline {
                lineRect.origin.x = textContainer.lineFragmentPadding
                lineRect.origin.y = lineRect.maxY
                lineRect.size.height = layoutManager.defaultLineHeight(for: font)
            } else {
                let glyphRect = layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: lastGlyph, length: 1),
                    in: textContainer
                )
                lineRect.origin.x = glyphRect.maxX
            }
            lineRect.origin.x += origin.x
            lineRect.origin.y += origin.y
            lineRect.size.width = caretWidth
            rect = lineRect
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            var lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: false
            )
            lineRect.origin.x += layoutManager.location(forGlyphAt: glyphIndex).x + origin.x
            lineRect.origin.y += origin.y
            lineRect.size.width = caretWidth
            lineRect.size.height = max(lineRect.height, layoutManager.defaultLineHeight(for: font))
            rect = lineRect
        }
        textView.insertionPointColor.setFill()
        rect.fill()
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        frameGeneration &+= 1
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frameGeneration), timescale: 60),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary], let attachment = attachments.first {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }

    private func resolvedBackgroundColor() -> NSColor {
        var resolved = NSColor.white
        textView.effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.textBackgroundColor.usingColorSpace(.sRGB) ?? .white
        }
        return resolved
    }

    private func installClipViewObserver() {
        let clipView = textView.enclosingScrollView?.contentView
        guard clipView !== observedClipView else { return }
        removeClipViewObserver()
        guard let clipView else { return }
        clipView.postsBoundsChangedNotifications = true
        observedClipView = clipView
        clipViewObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // Re-evaluate hover first: if a viewport change moved the
                // visible document away from the physical pointer, redact and
                // flush the old plaintext frame before drawing new geometry.
                self?.textView.secureVisibleViewportDidChange()
                self?.textView.invalidateSecureCaptureRenderer()
            }
        }
    }

    private func removeClipViewObserver() {
        if let clipViewObserver {
            NotificationCenter.default.removeObserver(clipViewObserver)
        }
        clipViewObserver = nil
        observedClipView = nil
    }

    private static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "contentsScale": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
    ]
}
