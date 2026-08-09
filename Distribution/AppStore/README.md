# App Store listing assets

This directory is the source of truth for the editable iOS/iPadOS App Store
listing. It deliberately excludes credentials, review-contact details, builds,
and submission state.

## Contents

- `metadata/` contains the English and Russian app-info and version metadata.
- `screenshots/en-US/` contains deterministic raw captures from the UI test.
- `screenshots/config/` contains the English and Russian Koubou layouts.
- `screenshots/marketing/` contains the framed, captioned, upload-ready output.
- `privacy.json` declares that the developer does not collect app data. Applying
  or publishing it requires an authenticated Apple web session.

The App Store icon is compiled from `snippets/Snippet.icon`; App Store Connect
does not accept a separate icon upload.

## Validation

Generate all 12 upload-ready screenshots with Koubou 0.18.1 and validate them
with `asc`:

```sh
./scripts/generate-app-store-screenshots.sh
```

The first run downloads Koubou's current device-frame catalog. The layouts use
the local SF Pro fonts installed with Apple's font package and keep the real app
UI unchanged beneath the marketing captions.

To validate metadata separately, run:


```sh
asc metadata validate \
  --dir Distribution/AppStore/metadata
```

`asc web privacy apply` changes the privacy draft but never publishes it.
Publishing the privacy declaration and submitting the app for review are
intentional, separate actions and must not be folded into routine metadata sync.
