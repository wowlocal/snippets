# README artwork

The README uses actual native UI as screenshot textures in a small Blender scene.
The Mac perspective image separates visual regions into physical layers with rounded
edges, thickness, studio lighting, and soft shadows. This is an editorial composition,
not an Xcode view-hierarchy dump or a different mode of the app.
The studio uses three broad area lights, a neutral environment fill, a transparent
shadow catcher, and restrained reflections so the interface stays legible.
Both Mac compositions, the inline illustration, and the consent preview have transparent PNG canvases
and light captions, designed to blend into GitHub's dark README background.

The inline illustration uses a flat before/after layout for readability: the native
suggestion view sits under a keyword, followed by the message with the saved link.
It uses an orthographic camera and unlit colors, without perspective or raised layers.

## Sources

- `../images/macos-library.jpg`: the native Mac app, running with an isolated,
  fictional library and cloud sync and clipboard history disabled. No live user
  library or secrets were used.
- `../images/inline-native-preview.jpg`: a documentation preview containing the
  app's actual `SuggestionPanelController` view and fictional message text. The view
  was instantiated in a temporary AppKit harness using the repository's production
  UI classes. This illustrates the inline interaction; it is not an end-to-end
  recording or evidence that a synthetic keyboard event triggered expansion.
- `../images/inline-suggestions.png`: the same native 320 × 108 pt suggestion view
  exported through AppKit at 4× (1280 × 432 pixels). The inline illustration reduces
  this asset instead of enlarging a crop from the window screenshot. AppKit's view
  export uses its opaque appearance rather than the screen compositor's live glass
  backdrop; labels, selection, and layout are rendered by the production UI classes.
- `../images/ipad-landscape-*.png`: direct, full-resolution 2752 × 2064 captures
  from the native iPad app on an isolated iPad Pro simulator. A documentation-only
  copy of the existing screenshot UI test used dark mode, landscape orientation, and eight
  fictional entries. The capture test passed. ImageIO normalized the PNG orientation
  metadata for consistent browser display; no frame, background, or UI redesign was
  added. The main repository's app and test sources were not changed.
- `../images/cli-secure-consent.png`: the production AppKit consent-window UI from
  `ControlServer.swift`, instantiated in an isolated preview with fictional snippet
  metadata and a Terminal caller example. `sources/consent-content.png` is a 4×
  native layer export; AppKit omits system glass button surfaces from that export,
  so the renderer restores only those two regions from the 2× native window capture
  in `sources/consent-controls.jpg`. It places the native content on a neutral dark
  frame with the production corner radius and border, preserving the UI layout.
  The final 1920 × 1280 PNG is displayed at 480 CSS pixels wide. No IPC server,
  vault read, authentication, or secret reveal is involved in the preview.
- `../images/macos-clipboard-history.png`: a 4× AppKit export (2720 × 1680) of
  the native `ClipboardHistoryPanelController`, running with the production history service
  and eight fictional entries in an isolated AppKit preview. The fixture injects
  in-memory storage and an empty pasteboard reader, disables the capture timer,
  and uses separate temporary preferences. It never reads the user's clipboard,
  history, or Keychain. Like the inline view export, it uses AppKit's opaque
  appearance instead of the live glass backdrop. It is displayed at 680 CSS pixels
  wide, preserving sharp text on high-density displays.
- iPhone images come from the existing English App Store screenshot set.
- `../images/readme-hero.png`: generated brand artwork. It depicts categories of
  information, not app controls.

The renderer covers the pointer in empty Mac title-bar chrome using a neighboring
piece of that same chrome. Mac UI labels, controls, and content are otherwise preserved.
For inline insertion, the native suggestion view is preserved as a high-resolution texture;
the fictional surrounding message and result are typeset for the illustration.
The original Mac screenshot is retained here as the source texture for both compositions.

## Render

Requires Blender 5.x; the committed outputs were rendered with Blender 5.2 and Cycles.
The scene uses SF Pro Display if it is installed in `/Library/Fonts`, otherwise
Blender's bundled font. No add-ons, network services, or Python packages are needed.

From the repository root:

```sh
/Applications/Blender.app/Contents/MacOS/Blender --background \
  --python scripts/render-readme-artwork.py -- \
  --output docs/images --width 1800 --samples 64
```

Use `--only mac`, `--only inline`, or `--only consent` for a faster iteration.
The consent image was rendered with `--only consent --width 1920 --samples 64`;
the Mac and inline compositions use `--width 1800 --samples 96`.
Add `--save-blend` to
export a portable, texture-packed Mac scene alongside the PNG. The generated `.blend`
file is optional and is not needed to view the README.

All framing, typography, lighting, material, and layer positions live in
[`scripts/render-readme-artwork.py`](../../scripts/render-readme-artwork.py).
The layer coordinates correspond to the committed captures; update those coordinates
when replacing a screenshot with a different window size or layout.

The renderer does not launch Snippets, read its storage, or connect to CloudKit.
