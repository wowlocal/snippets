# Secure capture renderer manual verification

The capture renderer is a defense boundary. Run these checks on every supported macOS
release before describing it as screenshot/recording protection.

After a Debug macOS build, exercise the shipping renderer class itself. The harness
contains only generated fixture text and writes no images or user data:

```sh
xcrun swiftc scripts/verify-secure-capture-shipping-renderer.swift \
  -I /tmp/snippets-secure-capture-derived/Build/Products/Debug \
  -Xcc -fmodule-map-file=/tmp/snippets-secure-capture-derived/Build/Intermediates.noindex/GeneratedModuleMaps/CocoaLumberjack.modulemap \
  -Xcc -I/tmp/snippets-secure-capture-derived/SourcePackages/checkouts/CocoaLumberjack/Sources/CocoaLumberjack/include \
  '/tmp/snippets-secure-capture-derived/Build/Products/Debug/Snippets Debug.app/Contents/MacOS/Snippets Debug.debug.dylib' \
  -Xlinker -rpath \
  -Xlinker '/tmp/snippets-secure-capture-derived/Build/Products/Debug/Snippets Debug.app/Contents/MacOS' \
  -Xlinker -rpath \
  -Xlinker '/tmp/snippets-secure-capture-derived/Build/Products/Debug/Snippets Debug.app/Contents/Frameworks' \
  -o /tmp/verify-secure-capture-shipping-renderer

/tmp/verify-secure-capture-shipping-renderer
```

Then use a disposable secure snippet whose body contains only obvious test text. Verify:

1. Reveal it, type, select across wrapped lines, move the caret to the start/end and after a
   trailing newline, scroll, resize, move between Retina/non-Retina displays, and change
   Light/Dark appearance. The protected image must follow each state without showing a plain
   AppKit text frame.
2. While visible, capture the window and display with Screenshot.app, `screencapture`,
   QuickTime, and an app using ScreenCaptureKit. Record the result for each OS/tool in a
   verification matrix. Secure glyphs must not be present or readable; the protected area
   may be black, transparent, obscured, or replaced depending on the capture path.
3. Hide, lock, switch snippets, background the app, and force a renderer failure during a
   local edit. No old frame may remain, ordinary snippets must retain their bodies, and a
   renderer failure must save the bound edit before clearing and covering the editor.
4. Inspect the view hierarchy: the `NSTextView` must remain drawing-suppressed throughout a
   secure session. Only the `AVSampleBufferDisplayLayer` may display secure glyphs. The
   unprotected layer below it is an opaque neutral fallback and never receives text pixels.

Do not use real secrets in this verification.
