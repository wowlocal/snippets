# Native input diagnostics

These are engineering helpers for owned fictional libraries/browser profiles.
They are not app logging backends or additional acceptance groups.

`input-persistent.c` keeps one virtual keyboard/keymap for an existing core run.
It accepts only the fixed fixture text, selection keys, modifier chords and saved
Snippets shortcut commands. Physical evdev quarantine must remain enabled.

`wire-browser.c` captures numeric Wayland protocol events in an owned browser.
It suppresses protocol argument text and covers Chromium's fortified logging
trampolines. Run its no-desktop privacy smoke with:

```sh
python3 docs/linux/testing/test-wire-browser.py
```

`chromium-field-state.gdb` is pinned to the installed Arch Chromium
152.0.7977.82 ELF build. It compares the five properties that Chromium uses to
notify a text-input change, recording only type/mode/flag enums, booleans and
monotonic time. DOM node and view identities are compared in memory and never
written. The capture refuses another ELF build or a normal browser profile.
Launch only an isolated `snippets-core-*` fixture profile, set
`SNIPPETS_IME_PROFILE` to that exact profile and `SNIPPETS_IME_STATE_FILE` to a
precreated private regular file (mode 0600). This is a diagnostic run, not a
qualified app check: software breakpoints can change scheduling. Never attach it
to a user browser. The ordinary qualification uses neither GDB nor DevTools.

Do not repeat the temporary startup-tracing FIFO approach. Chromium replaces that
path with a regular trace file rather than streaming into the pipe; those owned
temporary traces were sanitized and removed. No raw browser trace is retained in
app diagnostics or packaged artifacts.
