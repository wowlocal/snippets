#!/usr/bin/env swift

import AppKit
import CoreVideo
@testable import Snippets_Debug

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@MainActor
private func checksum(_ buffer: CVPixelBuffer) -> UInt64 {
    guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return 0 }
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let bytes = UnsafeRawBufferPointer(
        start: CVPixelBufferGetBaseAddress(buffer),
        count: CVPixelBufferGetDataSize(buffer)
    )
    return bytes.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
}

@MainActor
private func unprotectedViewChecksum(_ view: NSView) -> UInt64 {
    let rect = view.visibleRect.intersection(view.bounds)
    guard !rect.isEmpty,
          let representation = view.bitmapImageRepForCachingDisplay(in: rect) else { return 0 }
    view.cacheDisplay(in: rect, to: representation)
    guard let bytes = representation.bitmapData else { return 0 }
    let data = UnsafeRawBufferPointer(
        start: bytes,
        count: representation.bytesPerRow * representation.pixelsHigh
    )
    return data.reduce(UInt64(14_695_981_039_346_656_037)) {
        ($0 ^ UInt64($1)) &* 1_099_511_628_211
    }
}

@MainActor
private func run() {
    _ = NSApplication.shared
    let textView = SnippetContentTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 600))
    textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
    textView.textColor = .textColor
    textView.drawsBackground = false
    textView.isRichText = false
    textView.isEditable = true
    textView.isVerticallyResizable = true
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.containerSize = NSSize(width: 300, height: 10_000)

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 112))
    scrollView.documentView = textView
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 112),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = scrollView
    window.makeKeyAndOrderFront(nil)
    require(window.makeFirstResponder(textView), "text view must become first responder")

    // Exercise the shipping rasterizer offline first. No frame is ever put on an
    // ordinary layer, and a headless AV renderer cannot asynchronously reset this
    // deterministic pixel test.
    let body = (1 ... 18).map { "Line \($0): protected shipping renderer" }.joined(separator: "\n")
    textView.string = body
    require(textView.string == body, "shipping renderer must retain fixture body")
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let base = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(CVPixelBufferGetIOSurface(base.pixelBuffer) != nil, "shipping pixel buffer must be IOSurface-backed")
    require(base.geometry.backingScale >= 1, "backing scale must be valid")

    let selection = NSRange(location: 5, length: 20)
    textView.setSelectedRanges(
        [NSValue(range: selection)],
        affinity: .downstream,
        stillSelecting: false
    )
    require(
        textView.selectedRange() == selection,
        "text view must retain the selection (actual \(textView.selectedRange()))"
    )
    let selected = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(checksum(base.pixelBuffer) != checksum(selected.pixelBuffer), "selection must alter shipping pixels")

    textView.setSelectedRange(NSRange(location: 12, length: 0))
    let caret = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(checksum(base.pixelBuffer) != checksum(caret.pixelBuffer), "caret movement must alter shipping pixels")

    textView.setSelectedRange(NSRange(location: (body as NSString).length, length: 0))
    let endCaret = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(checksum(base.pixelBuffer) != checksum(endCaret.pixelBuffer), "end caret must render safely")

    let topChecksum = checksum(endCaret.pixelBuffer)
    scrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let scrolled = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(topChecksum != checksum(scrolled.pixelBuffer), "scroll must change shipping viewport")

    let redaction = textView.secureCaptureFrameForInspection(plaintext: false)!
    require(checksum(scrolled.pixelBuffer) != checksum(redaction.pixelBuffer), "hide must replace glyph pixels")

    textView.appearance = NSAppearance(named: .aqua)
    let light = textView.secureCaptureFrameForInspection(plaintext: true)!
    textView.appearance = NSAppearance(named: .darkAqua)
    let dark = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(checksum(light.pixelBuffer) != checksum(dark.pixelBuffer), "appearance must alter shipping pixels")
    textView.appearance = nil

    let wideWidth = base.geometry.pixelWidth
    scrollView.setFrameSize(NSSize(width: 220, height: 112))
    textView.setFrameSize(NSSize(width: 220, height: 600))
    textView.textContainer?.containerSize = NSSize(width: 220, height: 10_000)
    let resized = textView.secureCaptureFrameForInspection(plaintext: true)!
    require(resized.geometry.pixelWidth < wideWidth, "resize must change shipping pixel geometry")

    textView.string = ""
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    let emptyCaret = textView.secureCaptureFrameForInspection(plaintext: true)!
    let emptyRedaction = textView.secureCaptureFrameForInspection(plaintext: false)!
    require(checksum(emptyCaret.pixelBuffer) != checksum(emptyRedaction.pixelBuffer), "empty caret must render safely")

    textView.string = "Trailing newline\n"
    textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
    require(
        textView.secureCaptureFrameForInspection(plaintext: true) != nil,
        "trailing-newline caret must render safely"
    )
    textView.string = ""
    scrollView.contentView.scroll(to: .zero)
    require(textView.setSecurePresentationEnabled(true), "shipping renderer must arm")
    require(textView.secureCapturePolicy.phase == .protectedRedaction, "arming must start redacted")
    require(textView.secureCaptureProtectionEnabledForInspection, "preventsCapture must be set")
    require(textView.secureCaptureObservesScrollForInspection, "clip-view scroll observer must be installed")
    textView.string = "Protected layer fixture"
    let firstUnprotectedBacking = unprotectedViewChecksum(textView)
    textView.string = "Entirely different protected fixture"
    let secondUnprotectedBacking = unprotectedViewChecksum(textView)
    require(
        firstUnprotectedBacking == secondUnprotectedBacking,
        "ordinary AppKit backing must not change with secure glyphs"
    )
    require(textView.setSecurePixelsVisible(true), "protected plaintext frame must enqueue")
    require(textView.setSecurePixelsVisible(false), "protected hide frame must enqueue")
    require(textView.secureCapturePolicy.phase == .protectedRedaction, "hide must remain protected")

    textView.string = ""
    require(textView.setSecurePresentationEnabled(false), "cleared editor must restore ordinary mode")
    require(textView.secureCapturePolicy.phase == .ordinary, "teardown must restore ordinary mode")
    print("PASS: shipping protected layer, IOSurface pixels, selection/caret/scroll/hide/clear")
}

MainActor.assumeIsolated {
    run()
}
