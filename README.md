# Snippets (Raycast-style MVP for macOS)

This project now implements a local snippet expander app for macOS.

## What it does

- Create, edit, enable, and delete snippets.
- Each snippet has:
  - `Name`
  - `Snippet` text/template
  - `Keyword` (for example: `\\tp`)
- Expands snippets globally in other apps by replacing the typed keyword with snippet content.
- Persists snippets to:
  - `~/Library/Application Support/SnippetsClone/snippets.json`
- Imports snippets from JSON.
- Exports snippets to JSON.
- Pins snippets to keep them at the top.
- Supports dynamic placeholders:
  - `{clipboard}`
  - `{date}`
  - `{time}`
  - `{datetime}`
  - `{date:yyyy-MM-dd}` (custom date/time format)

## Permissions required

The app needs macOS privacy permissions:

- Accessibility
- Input Monitoring

Use the buttons in the top banner to open these settings.

## Build

Open `/Users/mike/src/tries/2026-02-15-snippets/snippets/snippets.xcodeproj` in Xcode and run the `snippets` scheme.

## Current trigger behavior

- Keywords that start with punctuation (like `\\tp`) can expand immediately when fully typed.
- Any keyword can also expand when followed by `Space`, `Tab`, or `Return`.

## Import / Export

- Use the `Import` button to load snippets from a `.json` file.
- Use the `Export` button to save all current snippets into a `.json` file.
- Import merges by snippet `id` first, then by `keyword` (case-insensitive) if IDs differ.

## Keyboard Navigation

- Raycast-style list navigation:
  - `↑/↓`: move between snippets.
  - `↩`: copy selected snippet.
  - `⌘K`: open actions panel.
  - `⌘N`: create a new snippet.
  - `Esc`: close actions panel / return to list focus.
- Raycast-style actions panel keymap:
  - `⌘↩`: paste selected snippet.
  - `⌘E`: edit selected snippet.
  - `⌘D`: duplicate selected snippet.
  - `⌘.`: pin or unpin selected snippet.
  - `⌘N`: create a new snippet.
- App-specific convenience shortcuts:
  - `⌘⇧I`: import snippets from JSON.
  - `⌘⇧E`: export snippets to JSON.
  - `⌘⌫`: delete selected snippet.

## Notes

- App Sandbox is disabled in project settings so global key monitoring and text injection can work.
- This is an MVP clone focused on core expansion workflow.
