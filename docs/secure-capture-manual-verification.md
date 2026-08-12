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

1. Unlock/reveal it with the cursor initially outside the content viewport. The body must stay
   redacted and the centered eye plus “Hover to reveal and edit secure snippet” affordance must be visible.
   Move the real pointer into the visible `SnippetContentTextView` viewport; only then may
   protected glyphs appear, and the affordance must disappear immediately. Move it out (including
   during a selection drag): redaction and the affordance must return immediately. Repeat with the
   pointer already inside at unlock, across scroll/resize, after moving the window, and after making
   another app/window active. Inactivity, minimization, teardown, rebind, and renderer failure must
   never leave glyph pixels or a stale affordance visible. A fabricated enter event by itself must
   not reveal content.
2. Give the editor keyboard focus, move the pointer outside until the affordance returns, and
   try typing, deletion, paste, drag/drop, Undo, Redo, and an input method. The body must not
   change and rejected Undo/Redo must remain available. Move the real pointer back inside; the
   same editing actions must work only while the protected plaintext is visible. Selection and
   navigation may remain available while redacted, but no content or character-attribute change
   may occur. Also test wrapped lines, a trailing newline, scroll/resize, Retina/non-Retina
   displays, and Light/Dark appearance without exposing a plain AppKit text frame.
3. While genuinely hovered, capture the window and display with Screenshot.app, `screencapture`,
   QuickTime, and an app using ScreenCaptureKit. Record the result for each OS/tool in a
   verification matrix. Secure glyphs must not be present or readable; the protected area
   may be black, transparent, obscured, or replaced depending on the capture path. While the
   pointer is outside, the safe hover affordance must remain visible in the capture.
4. Hide, lock, switch snippets, background the app, and force a renderer failure during a
   local edit. No old frame may remain, ordinary snippets must retain their bodies, and a
   renderer failure must save the bound edit before clearing and covering the editor.
5. Inspect the view hierarchy: the `NSTextView` must remain drawing-suppressed throughout a
   secure session. Only the `AVSampleBufferDisplayLayer` may display secure glyphs. The
   unprotected layer below it is an opaque neutral fallback and never receives text pixels. The
   hover affordance must be a click-through sibling above the scroll view, not a child or frame of
   the capture-protected plaintext surface; it must contain only the fixed safe instruction.

Do not use real secrets in this verification.

Hover is only a physical-camera/shoulder-surfing exposure reduction. A camera can still record
the plaintext during the interval in which the real pointer is inside the editor, and software
cannot reliably detect or block an external camera. Do not describe hover as physical-camera
protection or as an absolute confidentiality guarantee.
