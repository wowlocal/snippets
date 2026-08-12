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

private struct RasterDifference {
    let firstRow: Int
    let lastRow: Int
    let changedPixelsByRow: [Int]
}

@MainActor
private func rasterDifference(
    plaintext: CVPixelBuffer,
    redaction: CVPixelBuffer
) -> RasterDifference? {
    guard CVPixelBufferGetWidth(plaintext) == CVPixelBufferGetWidth(redaction),
          CVPixelBufferGetHeight(plaintext) == CVPixelBufferGetHeight(redaction),
          CVPixelBufferLockBaseAddress(plaintext, .readOnly) == kCVReturnSuccess
    else { return nil }
    defer { CVPixelBufferUnlockBaseAddress(plaintext, .readOnly) }

    guard CVPixelBufferLockBaseAddress(redaction, .readOnly) == kCVReturnSuccess else {
        return nil
    }
    defer { CVPixelBufferUnlockBaseAddress(redaction, .readOnly) }

    guard let plaintextBase = CVPixelBufferGetBaseAddress(plaintext),
          let redactionBase = CVPixelBufferGetBaseAddress(redaction) else { return nil }

    let width = CVPixelBufferGetWidth(plaintext)
    let height = CVPixelBufferGetHeight(plaintext)
    let plaintextBytesPerRow = CVPixelBufferGetBytesPerRow(plaintext)
    let redactionBytesPerRow = CVPixelBufferGetBytesPerRow(redaction)
    var changedPixelsByRow = Array(repeating: 0, count: height)

    for row in 0 ..< height {
        let plaintextRow = plaintextBase
            .advanced(by: row * plaintextBytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        let redactionRow = redactionBase
            .advanced(by: row * redactionBytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
        for column in 0 ..< width {
            let offset = column * 4
            let colorDelta = (0 ..< 3).reduce(0) { partial, channel in
                partial + abs(Int(plaintextRow[offset + channel]) - Int(redactionRow[offset + channel]))
            }
            if colorDelta > 12 {
                changedPixelsByRow[row] += 1
            }
        }
    }

    guard let firstRow = changedPixelsByRow.firstIndex(where: { $0 > 0 }),
          let lastRow = changedPixelsByRow.lastIndex(where: { $0 > 0 }) else { return nil }
    return RasterDifference(
        firstRow: firstRow,
        lastRow: lastRow,
        changedPixelsByRow: changedPixelsByRow
    )
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

    let orientationView = SnippetContentTextView(
        frame: NSRect(x: 0, y: 0, width: 180, height: 400)
    )
    orientationView.font = .monospacedSystemFont(ofSize: 72, weight: .black)
    orientationView.textColor = .black
    orientationView.appearance = NSAppearance(named: .aqua)
    orientationView.drawsBackground = false
    orientationView.isRichText = false
    orientationView.textContainerInset = NSSize(width: 12, height: 112)
    orientationView.textContainer?.lineFragmentPadding = 0
    orientationView.string = "F"
    let orientationScrollView = NSScrollView(
        frame: NSRect(x: 0, y: 0, width: 180, height: 200)
    )
    orientationScrollView.documentView = orientationView
    orientationScrollView.contentView.scroll(to: NSPoint(x: 0, y: 100))
    orientationScrollView.reflectScrolledClipView(orientationScrollView.contentView)
    let orientationPlaintext = orientationView.secureCaptureFrameForInspection(plaintext: true)!
    let orientationRedaction = orientationView.secureCaptureFrameForInspection(plaintext: false)!
    require(
        orientationPlaintext.geometry.viewport.origin.y == 100,
        "shipping orientation fixture must exercise a nonzero viewport origin"
    )
    let orientationDifference = rasterDifference(
        plaintext: orientationPlaintext.pixelBuffer,
        redaction: orientationRedaction.pixelBuffer
    )!
    require(
        orientationDifference.firstRow < orientationPlaintext.geometry.pixelHeight / 4,
        "shipping glyph must begin near the top of the top-down video raster"
    )
    require(
        orientationDifference.lastRow < orientationPlaintext.geometry.pixelHeight / 2,
        "shipping glyph must not be vertically mirrored into the raster bottom"
    )
    let orientationGlyphHeight = orientationDifference.lastRow - orientationDifference.firstRow + 1
    let orientationBandHeight = max(1, orientationGlyphHeight / 3)
    let orientationUpperBand = orientationDifference.changedPixelsByRow[
        orientationDifference.firstRow ..< orientationDifference.firstRow + orientationBandHeight
    ].reduce(0, +)
    let orientationLowerBand = orientationDifference.changedPixelsByRow[
        orientationDifference.lastRow - orientationBandHeight + 1 ... orientationDifference.lastRow
    ].reduce(0, +)
    require(
        orientationUpperBand > orientationLowerBand,
        "shipping asymmetric glyph must be upright rather than vertically mirrored"
    )

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
    textView.isSecureContentMode = true
    require(textView.setSecurePresentationEnabled(true), "shipping renderer must arm")
    require(textView.secureCapturePolicy.phase == .protectedRedaction, "arming must start redacted")
    require(textView.secureCaptureProtectionEnabledForInspection, "preventsCapture must be set")
    require(textView.secureCaptureObservesScrollForInspection, "clip-view scroll observer must be installed")
    require(textView.secureHoverTracksPointerForInspection, "secure presentation must install hover tracking")
    require(!textView.secureHoverRevealsPixelsForInspection, "arming must not reveal on synthetic state")
    textView.string = "Protected layer fixture"
    let firstUnprotectedBacking = unprotectedViewChecksum(textView)
    textView.string = "Entirely different protected fixture"
    let secondUnprotectedBacking = unprotectedViewChecksum(textView)
    require(
        firstUnprotectedBacking == secondUnprotectedBacking,
        "ordinary AppKit backing must not change with secure glyphs"
    )
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    require(textView.secureCapturePolicy.phase == .protectedRedaction, "window inactivity must remain redacted")
    require(!textView.secureHoverRevealsPixelsForInspection, "window inactivity must never reveal pixels")

    let generationBeforeTeardownClear = textView.secureCaptureFrameGenerationForInspection
    require(textView.redactSecurePixelsBeforePlaintextClear(), "teardown must retain redaction")
    textView.clearSecurePlaintextStorageForTeardown()
    require(
        textView.secureCaptureFrameGenerationForInspection == generationBeforeTeardownClear,
        "post-redaction storage clear must not enqueue a frame"
    )
    require(textView.setSecurePresentationEnabled(false), "cleared editor must restore ordinary mode")
    textView.isSecureContentMode = false
    require(textView.secureCapturePolicy.phase == .ordinary, "teardown must restore ordinary mode")
    require(!textView.secureHoverTracksPointerForInspection, "teardown must remove hover tracking")
    print("PASS: shipping protected layer, upright IOSurface pixels, selection/caret/scroll/hover-redaction/clear")
}

MainActor.assumeIsolated {
    run()
}
