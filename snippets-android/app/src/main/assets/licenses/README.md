# Bundled third-party files

## JetBrains Mono

- File: `app/src/main/res/font/jetbrains_mono.ttf`, the variable font (`wght` axis 100 to 800).
  The app uses weights 400, 500 and 600.
- Source: the official release archive `JetBrainsMono-2.304.zip` of
  https://github.com/JetBrains/JetBrainsMono (tag `v2.304`), member
  `fonts/variable/JetBrainsMono[wght].ttf`, renamed. Not modified.
- Version: 2.304 (the font's own `head.fontRevision`).
- SHA-256 of the font file: `662a196d58f1183bf2d77428b6d5283fe3f45161ab021bea4036bc98e5cac016`
- SHA-256 of the release archive: `6f6376c6ed2960ea8a963cd7387ec9d76e3f629125bc33d1fdcd7eb7012f7bbf`
- Licence: SIL Open Font License 1.1, in `JetBrainsMono-OFL.txt` (the archive's `OFL.txt`,
  unchanged). Copyright 2020 The JetBrains Mono Project Authors.

## Material Symbols

- Files: `app/src/main/res/drawable/ic_*.xml` except `ic_launcher_foreground.xml`.
- Source: https://github.com/google/material-design-icons, directory `symbols/android`, the
  Outlined style at weight 400, grade 0, optical size 24 (`ic_push_pin_fill.xml` is the `FILL 1`
  variant). The tint attribute was removed and the fill colour set to black; path data is
  unchanged.
- Licence: Apache License 2.0.
