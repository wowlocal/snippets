import AVFoundation
import CoreMedia
import CoreVideo
import IOSurface
import UIKit

/// The only view allowed to present secure-body pixels on iOS and iPadOS.
/// It deliberately never participates in hit testing; the suppressed text view
/// underneath continues to own editing, scrolling, and keyboard interaction.
@MainActor
final class SecureSnippetCaptureSurfaceView: UIView {
    var onLayout: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { false }
}

/// UIKit-specific secure renderer. It rasterizes the current visible TextKit
/// viewport into an IOSurface-backed pixel buffer and enqueues that buffer only
/// into an AVSampleBufferDisplayLayer protected from capture.
///
/// Protection, opacity, and the neutral fallback are installed before the first
/// frame is created. There is intentionally no UIImage/CALayer fallback for
/// plaintext: every failure leaves only the opaque neutral surface visible.
@MainActor
final class SecureSnippetCaptureRenderer {
    struct RenderedFrameInspection {
        let pixelBuffer: CVPixelBuffer
        let geometry: SecureSnippetCaptureFrameGeometry
    }

    private unowned let textView: SecureSnippetTextView
    private unowned let surfaceView: SecureSnippetCaptureSurfaceView
    private var displayLayer: AVSampleBufferDisplayLayer
    private let fallbackLayer: CALayer
    private var frameGeneration: UInt64 = 0
    private var isRendering = false
    private var isFailingClosed = false
    private var pendingPresentationGeneration: UInt64?
    private var flushCompletionOverrideForTesting: (((@escaping () -> Void)) -> Void)?
    private var rendererFailedOverrideForTesting: Bool?
    private var decodeFailureObserver: NSObjectProtocol?
    private var outputProtectionObserver: NSObjectProtocol?

    var onFailure: (() -> Void)?
    var onPlaintextPresented: (() -> Void)?

    init(textView: SecureSnippetTextView, surfaceView: SecureSnippetCaptureSurfaceView) {
        self.textView = textView
        self.surfaceView = surfaceView

        let displayLayer = Self.makeDisplayLayer()
        self.displayLayer = displayLayer

        let fallbackLayer = CALayer()
        fallbackLayer.isOpaque = true
        fallbackLayer.actions = Self.disabledLayerActions
        fallbackLayer.isHidden = false
        self.fallbackLayer = fallbackLayer

        surfaceView.layer.addSublayer(fallbackLayer)
        surfaceView.layer.addSublayer(displayLayer)
        surfaceView.onLayout = { [weak self] in self?.surfaceDidLayout() }

        installDisplayLayerObservers()
    }

    private func installDisplayLayerObservers() {
        decodeFailureObserver = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification,
            object: displayLayer.sampleBufferRenderer,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.failClosed() }
        }
        outputProtectionObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name.AVSampleBufferDisplayLayerOutputObscuredDueToInsufficientExternalProtectionDidChange,
            object: displayLayer,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.displayLayer.isOutputObscuredDueToInsufficientExternalProtection else { return }
                self.failClosed()
            }
        }
    }

    private func removeDisplayLayerObservers() {
        if let decodeFailureObserver {
            NotificationCenter.default.removeObserver(decodeFailureObserver)
            self.decodeFailureObserver = nil
        }
        if let outputProtectionObserver {
            NotificationCenter.default.removeObserver(outputProtectionObserver)
            self.outputProtectionObserver = nil
        }
    }

    deinit {
        if let decodeFailureObserver {
            NotificationCenter.default.removeObserver(decodeFailureObserver)
        }
        if let outputProtectionObserver {
            NotificationCenter.default.removeObserver(outputProtectionObserver)
        }
    }

    /// Arms an allocation-free protected neutral presentation. Redaction never
    /// enqueues an AV frame; the opaque fallback is the complete visible result.
    func arm() -> Bool {
        guard displayLayer.preventsCapture,
              displayLayer.superlayer === surfaceView.layer,
              !rendererHasFailed,
              !displayLayer.isOutputObscuredDueToInsufficientExternalProtection else {
            failClosed()
            return false
        }
        hideAndFlushToFallback()
        updateLayerGeometry()
        updateFallbackColor()
        return true
    }

    /// A display renderer can enter a terminal failed state while the app is
    /// suspended. Rebuild only the protected AV surface after foregrounding;
    /// the opaque fallback stays visible throughout and no plaintext survives
    /// into the replacement renderer.
    func recoverAfterFailure() -> Bool {
        clear(keepFallbackVisible: true)
        removeDisplayLayerObservers()
        displayLayer.removeFromSuperlayer()

        displayLayer = Self.makeDisplayLayer()
        surfaceView.layer.addSublayer(displayLayer)
        installDisplayLayerObservers()
        return arm()
    }

    func renderPlaintext() -> Bool {
        if isRendering { return true }
        guard isHealthyForPlaintextPresentation,
              textView.secureCaptureMayPresentPlaintextNow,
              let geometry = frameGeometry(permitsPlaceholder: false) else {
            failClosed()
            return false
        }

        isRendering = true
        defer { isRendering = false }
        updateLayerGeometry()
        updateFallbackColor()

        // The first disclosed frame crosses the redaction boundary, so keep the
        // synchronous hide/flush and asynchronous lifecycle gate. Once a protected
        // frame is already visible, leave it in place while rasterizing and enqueue
        // its replacement directly into the same preventsCapture layer. Hiding the
        // old frame on an ordinary caret/selection redraw produces a blank flash.
        let replacesVisibleProtectedFrame = pendingPresentationGeneration == nil
            && !displayLayer.isHidden
        let generation: UInt64
        if replacesVisibleProtectedFrame {
            frameGeneration &+= 1
            generation = frameGeneration
        } else {
            generation = hideAndFlushToFallback()
        }
        guard let pixelBuffer = makePixelBuffer(for: geometry),
              draw(kind: .plaintext, into: pixelBuffer, geometry: geometry),
              let sampleBuffer = makeSampleBuffer(
                from: pixelBuffer,
                presentationGeneration: generation
              ) else {
            failClosed()
            return false
        }

        pendingPresentationGeneration = generation
        if replacesVisibleProtectedFrame {
            presentPlaintextIfCurrent(
                sampleBuffer,
                generation: generation,
                replacesVisibleProtectedFrame: true
            )
        } else {
            flushBeforePresentingPlaintext { [weak self] in
                guard let self else { return }
                self.presentPlaintextIfCurrent(
                    sampleBuffer,
                    generation: generation,
                    replacesVisibleProtectedFrame: false
                )
            }
        }
        return true
    }

    func renderRedaction() -> Bool {
        hideAndFlushToFallback()
        updateLayerGeometry()
        updateFallbackColor()
        return true
    }

    func invalidate(plaintext: Bool) {
        guard !surfaceView.isHidden else { return }
        _ = plaintext ? renderPlaintext() : renderRedaction()
    }

    /// Removes every queued or displayed protected image. The neutral fallback
    /// remains visible unless the owner has already cleared secure text storage
    /// and is restoring an ordinary editor.
    func clear(keepFallbackVisible: Bool) {
        frameGeneration &+= 1
        pendingPresentationGeneration = nil
        surfaceView.isHidden = false
        displayLayer.isHidden = true
        fallbackLayer.isHidden = false
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        fallbackLayer.isHidden = !keepFallbackVisible
        surfaceView.isHidden = !keepFallbackVisible
    }

    func failClosed() {
        guard !isFailingClosed else { return }
        isFailingClosed = true
        clear(keepFallbackVisible: true)
        onFailure?()
        isFailingClosed = false
    }

    /// Exercises the same IOSurface/TextKit path without enqueueing its output
    /// into an ordinary on-screen layer.
    func renderFrameForInspection(plaintext: Bool) -> RenderedFrameInspection? {
        guard let geometry = frameGeometry(permitsPlaceholder: false),
              let pixelBuffer = makePixelBuffer(for: geometry),
              draw(kind: plaintext ? .plaintext : .redaction, into: pixelBuffer, geometry: geometry)
        else { return nil }
        return RenderedFrameInspection(pixelBuffer: pixelBuffer, geometry: geometry)
    }

    var captureProtectionEnabledForInspection: Bool { displayLayer.preventsCapture }
    var frameGenerationForInspection: UInt64 { frameGeneration }
    var displayLayerIsAttachedForInspection: Bool {
        displayLayer.superlayer === surfaceView.layer
    }
    var preventsDisplaySleepForInspection: Bool {
        displayLayer.preventsDisplaySleepDuringVideoPlayback
    }
    var displayLayerIsHiddenForInspection: Bool { displayLayer.isHidden }
    var fallbackLayerIsVisibleForInspection: Bool {
        !surfaceView.isHidden && !fallbackLayer.isHidden
    }
    var pendingPresentationGenerationForInspection: UInt64? {
        pendingPresentationGeneration
    }
    var canBeginPlaintextPresentation: Bool {
        isReadyForHiddenPlaintextPresentation
    }

    func setFlushCompletionOverrideForTesting(
        _ override: (((@escaping () -> Void)) -> Void)?
    ) {
        flushCompletionOverrideForTesting = override
    }

    func setRendererFailedOverrideForTesting(_ failed: Bool?) {
        rendererFailedOverrideForTesting = failed
    }

    private enum FrameKind {
        case redaction
        case plaintext
    }

    private static func makeDisplayLayer() -> AVSampleBufferDisplayLayer {
        let displayLayer = AVSampleBufferDisplayLayer()
        // Security-critical ordering: all capture/display properties are set before
        // the layer is attached or can receive a plaintext frame.
        displayLayer.preventsCapture = true
        displayLayer.isOpaque = true
        displayLayer.videoGravity = .resize
        displayLayer.preventsDisplaySleepDuringVideoPlayback = false
        displayLayer.actions = disabledLayerActions
        displayLayer.isHidden = true
        return displayLayer
    }

    /// Allocation-free synchronous redaction boundary. The AV layer stays hidden
    /// after this method returns; no completion is allowed to reverse that fact.
    @discardableResult
    private func hideAndFlushToFallback() -> UInt64 {
        frameGeneration &+= 1
        let generation = frameGeneration
        pendingPresentationGeneration = nil
        surfaceView.isHidden = false
        fallbackLayer.isHidden = false
        displayLayer.isHidden = true
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true,
            completionHandler: nil
        )
        return generation
    }

    private func flushBeforePresentingPlaintext(completion: @escaping () -> Void) {
        if let flushCompletionOverrideForTesting {
            flushCompletionOverrideForTesting(completion)
            return
        }
        displayLayer.sampleBufferRenderer.flush(
            removingDisplayedImage: true
        ) {
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func presentPlaintextIfCurrent(
        _ sampleBuffer: CMSampleBuffer,
        generation: UInt64,
        replacesVisibleProtectedFrame: Bool
    ) {
        // A stale completion belongs to a generation that has already been
        // synchronously hidden/flushed, so it must be an inert no-op. A current
        // completion is different: failure of either renderer health or the
        // lifecycle/source gate must actively fail closed and clear plaintext.
        guard generation == frameGeneration,
              pendingPresentationGeneration == generation else { return }
        let presentationSurfaceIsReady = replacesVisibleProtectedFrame
            ? isReadyForVisiblePlaintextReplacement
            : isReadyForHiddenPlaintextPresentation
        guard presentationSurfaceIsReady else {
            failClosed()
            return
        }
        guard textView.secureCaptureMayPresentPlaintextNow else {
            textView.secureCapturePresentationWasRevoked()
            return
        }

        displayLayer.sampleBufferRenderer.enqueue(sampleBuffer)
        guard generation == frameGeneration,
              pendingPresentationGeneration == generation else { return }
        guard !rendererHasFailed, isHealthyForPlaintextPresentation else {
            failClosed()
            return
        }
        guard textView.secureCaptureMayPresentPlaintextNow else {
            textView.secureCapturePresentationWasRevoked()
            return
        }

        pendingPresentationGeneration = nil
        if !replacesVisibleProtectedFrame {
            displayLayer.isHidden = false
        }
        CATransaction.flush()
        guard generation == frameGeneration else { return }
        guard !rendererHasFailed,
              isHealthyForPlaintextPresentation,
              !displayLayer.isHidden else {
            failClosed()
            return
        }
        guard textView.secureCaptureMayPresentPlaintextNow else {
            textView.secureCapturePresentationWasRevoked()
            return
        }
        onPlaintextPresented?()
    }

    private var isHealthyForPlaintextPresentation: Bool {
        displayLayer.preventsCapture
            && displayLayer.superlayer === surfaceView.layer
            && !surfaceView.isHidden
            && !displayLayer.isOutputObscuredDueToInsufficientExternalProtection
            && !rendererHasFailed
    }

    private var isReadyForHiddenPlaintextPresentation: Bool {
        isHealthyForPlaintextPresentation
            && displayLayer.isHidden
            && !fallbackLayer.isHidden
    }

    private var isReadyForVisiblePlaintextReplacement: Bool {
        isHealthyForPlaintextPresentation && !displayLayer.isHidden
    }

    private var rendererHasFailed: Bool {
        rendererFailedOverrideForTesting
            ?? (displayLayer.sampleBufferRenderer.status == .failed)
    }

    private func surfaceDidLayout() {
        updateLayerGeometry()
        guard !surfaceView.isHidden else { return }
        textView.secureCaptureSurfaceDidLayout()
    }

    private func updateLayerGeometry() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = surfaceView.bounds
        fallbackLayer.frame = surfaceView.bounds
        let scale = max(textView.traitCollection.displayScale, 1)
        displayLayer.contentsScale = scale
        fallbackLayer.contentsScale = scale
        CATransaction.commit()
    }

    private func updateFallbackColor() {
        let color = resolvedBackgroundColor()
        surfaceView.backgroundColor = color
        fallbackLayer.backgroundColor = color.cgColor
        displayLayer.backgroundColor = color.cgColor
    }

    private func frameGeometry(permitsPlaceholder: Bool) -> SecureSnippetCaptureFrameGeometry? {
        var viewport = textView.bounds
        if viewport.width <= 0 || viewport.height <= 0 {
            guard permitsPlaceholder else { return nil }
            viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let scale = max(textView.traitCollection.displayScale, 1)
        return SecureSnippetCaptureFrameGeometry.make(viewport: viewport, displayScale: scale)
    }

    private func makePixelBuffer(
        for geometry: SecureSnippetCaptureFrameGeometry
    ) -> CVPixelBuffer? {
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
        geometry: SecureSnippetCaptureFrameGeometry
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

        let background = resolvedBackgroundColor()
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: geometry.pixelWidth, height: geometry.pixelHeight))
        guard kind == .plaintext else { return true }

        context.saveGState()
        defer { context.restoreGState() }
        // Pixel-buffer rows are top-down while a bitmap CGContext starts bottom-
        // left. TextKit uses UIKit's top-left coordinates, so explicitly invert Y.
        context.translateBy(x: 0, y: CGFloat(geometry.pixelHeight))
        context.scaleBy(x: geometry.displayScale, y: -geometry.displayScale)
        context.translateBy(x: -geometry.viewport.origin.x, y: -geometry.viewport.origin.y)

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        drawTextViewport(geometry.viewport)
        return true
    }

    private func drawTextViewport(_ viewport: CGRect) {
        let layoutManager = textView.layoutManager
        let textContainer = textView.textContainer
        layoutManager.ensureLayout(for: textContainer)

        let origin = CGPoint(
            x: textView.textContainerInset.left,
            y: textView.textContainerInset.top
        )
        let containerViewport = viewport.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphRange = layoutManager.glyphRange(
            forBoundingRect: containerViewport,
            in: textContainer
        )
        layoutManager.drawBackground(forGlyphRange: glyphRange, at: origin)
        drawSelection(
            layoutManager: layoutManager,
            textContainer: textContainer,
            visibleGlyphRange: glyphRange,
            origin: origin
        )
        layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: origin)
        drawCaret(layoutManager: layoutManager, textContainer: textContainer, origin: origin)
    }

    private func drawSelection(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        visibleGlyphRange: NSRange,
        origin: CGPoint
    ) {
        let characterRange = textView.selectedRange
        let textLength = (textView.text as NSString?)?.length ?? 0
        guard characterRange.location != NSNotFound,
              characterRange.location < textLength,
              characterRange.length > 0 else { return }

        let clamped = NSRange(
            location: characterRange.location,
            length: min(characterRange.length, textLength - characterRange.location)
        )
        let selectedGlyphs = layoutManager.glyphRange(
            forCharacterRange: clamped,
            actualCharacterRange: nil
        )
        let visibleSelection = NSIntersectionRange(selectedGlyphs, visibleGlyphRange)
        guard visibleSelection.length > 0 else { return }

        resolvedSelectionColor().setFill()
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: visibleSelection,
            withinSelectedGlyphRange: selectedGlyphs,
            in: textContainer
        ) { rect, _ in
            UIRectFill(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
    }

    private func drawCaret(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        origin: CGPoint
    ) {
        guard textView.isFirstResponder,
              textView.isEditable,
              textView.selectedRange.length == 0 else { return }

        let textLength = (textView.text as NSString?)?.length ?? 0
        let characterIndex = min(textView.selectedRange.location, textLength)
        let scale = max(textView.traitCollection.displayScale, 1)
        let caretWidth = max(1 / scale, 1)
        let font = textView.font ?? .preferredFont(forTextStyle: .body)
        var caretRect: CGRect

        if textLength == 0 || layoutManager.numberOfGlyphs == 0 {
            caretRect = CGRect(
                x: origin.x + textContainer.lineFragmentPadding,
                y: origin.y,
                width: caretWidth,
                height: font.lineHeight
            )
        } else if characterIndex == textLength {
            let lastGlyph = layoutManager.numberOfGlyphs - 1
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: lastGlyph, length: 1),
                in: textContainer
            )
            caretRect = CGRect(
                x: origin.x + glyphRect.maxX,
                y: origin.y + glyphRect.minY,
                width: caretWidth,
                height: max(glyphRect.height, font.lineHeight)
            )
        } else {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
            let lineRect = layoutManager.lineFragmentUsedRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            caretRect = CGRect(
                x: origin.x + layoutManager.location(forGlyphAt: glyphIndex).x,
                y: origin.y + lineRect.minY,
                width: caretWidth,
                height: max(lineRect.height, font.lineHeight)
            )
        }
        textView.secureCaptureCaretColor.setFill()
        UIRectFill(caretRect)
    }

    private func makeSampleBuffer(
        from pixelBuffer: CVPixelBuffer,
        presentationGeneration: UInt64? = nil
    ) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else { return nil }

        let timestampGeneration: UInt64
        if let presentationGeneration {
            timestampGeneration = presentationGeneration
        } else {
            frameGeneration &+= 1
            timestampGeneration = frameGeneration
        }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampGeneration), timescale: 60),
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

    private func resolvedBackgroundColor() -> UIColor {
        textView.secureCaptureBackgroundColor.resolvedColor(with: textView.traitCollection)
    }

    private func resolvedSelectionColor() -> UIColor {
        UIColor.systemBlue.withAlphaComponent(textView.isFirstResponder ? 0.32 : 0.18)
    }

    private static let disabledLayerActions: [String: CAAction] = [
        "bounds": NSNull(),
        "contents": NSNull(),
        "contentsScale": NSNull(),
        "hidden": NSNull(),
        "position": NSNull(),
    ]
}

struct SecureSnippetCaptureFrameGeometry: Equatable {
    static let maximumPixelDimension = 16_384
    static let maximumPixelCount = 16_777_216

    let viewport: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
    let displayScale: CGFloat

    static func make(
        viewport rawViewport: CGRect,
        displayScale rawDisplayScale: CGFloat,
        maximumPixelDimension: Int = maximumPixelDimension,
        maximumPixelCount: Int = maximumPixelCount
    ) -> SecureSnippetCaptureFrameGeometry? {
        let viewport = rawViewport.standardized
        guard viewport.origin.x.isFinite,
              viewport.origin.y.isFinite,
              viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.width > 0,
              viewport.height > 0,
              rawDisplayScale.isFinite,
              rawDisplayScale > 0,
              maximumPixelDimension > 0,
              maximumPixelCount > 0 else { return nil }

        let pixelWidthValue = ceil(viewport.width * rawDisplayScale)
        let pixelHeightValue = ceil(viewport.height * rawDisplayScale)
        guard pixelWidthValue.isFinite,
              pixelHeightValue.isFinite,
              pixelWidthValue >= 1,
              pixelHeightValue >= 1,
              pixelWidthValue <= CGFloat(maximumPixelDimension),
              pixelHeightValue <= CGFloat(maximumPixelDimension) else { return nil }

        let pixelWidth = Int(pixelWidthValue)
        let pixelHeight = Int(pixelHeightValue)
        let (pixelCount, overflowed) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflowed, pixelCount <= maximumPixelCount else { return nil }
        return SecureSnippetCaptureFrameGeometry(
            viewport: viewport,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            displayScale: rawDisplayScale
        )
    }
}
