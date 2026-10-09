# Native input diagnostics

These are engineering helpers for owned fictional libraries/browser profiles.
They are not app logging backends or additional acceptance groups.

`input-persistent.c` keeps one virtual keyboard/keymap for an existing core run.
It accepts only the fixed fixture text, selection keys, modifier chords and saved
Snippets shortcut commands. Physical evdev quarantine must remain enabled.

`pointer-persistent.c` keeps one test pointer alive across receiver windows.
Start both devices before Fcitx and retain them until its test process exits.
Generate `pointer.h` (client-header) and `pointer-protocol.c` (private-code) from
the wlroots `wlr-virtual-pointer-unstable-v1.xml` protocol with `wayland-scanner`,
then compile the helper with those sources and `pkg-config wayland-client` flags.
It accepts `move X Y WIDTH HEIGHT`, `click`, and `quit`; startup returns `ready`
and each completed input command returns `ok`.

For popup selection, first move to a known point outside the future popup in the
owned receiver, type the query, then move into the measured row and click once.
Moving to the cursor's existing coordinates can produce no pointer-enter/motion
event after a popup appears. Recreating the last seat pointer is another known
Hyprland fixture problem. Neither a failed synthetic click nor a passing moved
pointer qualifies a stationary physical pointer. Check the unlocked session and
owned window focus before every input operation, including the click.

`browser_fixture.py` supplies a loopback HTTP receiver and `State` for fictional
45-byte/26-byte expansion bodies and the literal `\nat`. Call `State.advance()`
before opening a case, wait for its sequence acknowledgment and inspect
`State.observation()`. Browser observations carry increasing event numbers; the
server rejects late observations and previous cases. A periodic DOM sample
covers the final edit following `compositionend`. Require the desired body
predicate **and** `composing == false`; a process exit code alone is insufficient.
The runner must return nonzero for any failed or missing case. Use fresh browser
processes, distinguish fresh profiles from reused profiles in the report, and
keep the same input cadence and deadlines when comparing Fcitx versions.

```sh
python3 docs/linux/testing/test-browser-fixture.py
```

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

## Owned GNOME session

`gnome_session.py` starts a headless GNOME Shell, a private session bus and a
separate IBus daemon. All runtime sockets, preferences and application data stay
under a new owned directory. It never uses `--replace`, changes the user's input
sources or sends input to their desktop. Stop its supervisor with SIGTERM to
clean up its process groups.

In an Ubuntu guest with GNOME Shell, Python GI, IBus development headers and the
normal Snippets development dependencies:

```sh
cargo build --locked --manifest-path snippets-linux/Cargo.toml \
  --no-default-features --features desktop,ibus --bins
python3 docs/linux/testing/gnome_session.py /tmp/snippets-gnome-owned
# In another shell, while that supervisor is running:
python3 docs/linux/testing/ibus_engine_smoke.py \
  /tmp/snippets-gnome-owned snippets-linux/target/debug
python3 docs/linux/testing/ibus_engine_smoke.py \
  /tmp/snippets-gnome-owned snippets-linux/target/debug --gtk
python3 docs/linux/testing/ibus_engine_smoke.py \
  /tmp/snippets-gnome-owned snippets-linux/target/debug --chromium /path/to/chromium
```

The first check uses a real IBus client context and fictional library. It covers
exact expansion, Enter/Tab selection, candidate publication, Compose/dead keys,
level modifiers, private fields, reset, focus/content-type changes, consent
revocation and application restart. Ubuntu's current Python
GI/IBus bindings emit floating-object warnings in this protocol fixture; these
are retained in its output. The native engine and GTK receiver do not use those
Python IBus signal callbacks.

`--gtk` sends a virtual keyboard through the owned Mutter RemoteDesktop session
to actual GTK4 entries over Wayland. It asserts resulting text, password handling,
cross-field cancellation and headless screen-shield cancellation. The headless
shield has authentication disabled; it does not qualify an authenticated unlock.

The Chromium receiver uses a fresh disposable profile, virtual keyboard events
and ordered observations from a loopback page. It requires both the expected DOM
value and the end of composition. `--chromium-ime gtk` tests the alternative GTK
IBus client path; it must be reported separately from the default native Wayland
path. Neither uses DevTools or inserts text through JavaScript. Browser failures
are fatal, not skipped. See `../GNOME.md` for the current qualification gap.
