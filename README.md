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

## Notes

- App Sandbox is disabled in project settings so global key monitoring and text injection can work.
- This is an MVP clone focused on core expansion workflow.
