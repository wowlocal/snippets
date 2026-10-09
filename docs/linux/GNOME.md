# GNOME desktop preview

## Scope

The first GNOME milestone targets stock Ubuntu GNOME on Wayland, preserving its
IBus input system. It shares the GTK application and library with the Hyprland
build. It does not replace input methods, install a Shell extension or enable
Shell Eval.

Implemented:

- A `desktop` build independent of the optional `fcitx` feature. Default Cargo
  builds retain `desktop,fcitx` for Hyprland.
- Desktop detection for colon-separated `XDG_CURRENT_DESKTOP` values, including
  `ubuntu:GNOME`. Ambiguous GNOME/Hyprland environments remain unavailable.
- Read-only session-lock observation through GNOME Shell's
  `org.gnome.ScreenSaver` interface, alongside the existing logind sleep monitor.
  Missing owners, malformed replies, closed connections and stale observations
  cannot authorize protected operations. Lock/unlock cycles revoke in-flight
  work even when both signals arrive between UI ticks.
- A GNOME install mode which neither requires nor installs the Fcitx addon.
- An explicit `unsupportedDesktop` expansion status in the desktop-only build.
- An experimental `ibus` feature with a separate native engine built against
  public libibus and xkbcommon APIs. It shares matching and bounded candidate
  metadata with Fcitx, but commits through an IBus input context. The Fcitx path
  still requires its original Hyprland window/process witness.

Not yet qualified: IBus expansion and caret suggestions across applications.
An experimental GNOME GlobalShortcuts portal adapter registers Open, Picker and
Capture actions through the system permission dialog. Receiving these actions is
separate from the unfinished GNOME capture and insertion mechanisms.
Not implemented: GNOME clipboard-history capture and cross-application insertion. Existing Hyprland
window-target and Wayland peer checks remain required for those mechanisms.
The installer still builds only the desktop preview. The `ibus` feature is an
engineering opt-in until the remaining lifecycle and installation acceptance cases are complete.

## Build and install

Requires Rust 1.92 or newer, GTK >= 4.12 and libadwaita >= 1.5. This was exercised
on Ubuntu 26.04.1 arm64 with GNOME Shell 50.1, GTK 4.22.4 and libadwaita 1.9.1.
Older distributions may need newer development packages; they are not qualified.

```sh
sudo apt install build-essential cargo pkg-config libgtk-4-dev libadwaita-1-dev \
  libicu-dev libsecret-1-dev libpam0g-dev libaudit-dev libcap-ng-dev \
  libqrencode-dev libwayland-dev wayland-protocols libxkbcommon-dev libjson-c-dev
./scripts/install-linux.sh --desktop gnome
```

`--desktop auto` (the default) selects GNOME from `XDG_CURRENT_DESKTOP`, otherwise
it selects the existing Hyprland build. SSH or VM execution tools may omit the
desktop environment, so select `--desktop gnome` explicitly there. GNOME build
artifacts default to `snippets-linux/target/gnome`, separate from the Hyprland
artifacts. `CARGO_TARGET_DIR` can override either directory. Library storage is
preserved. Switching an existing prefix does not remove old Fcitx addon files or
change a running input-method service; use a separate prefix for this preview.

## Verification

Run the feature matrix on Linux:

```sh
cargo test --locked --manifest-path snippets-linux/Cargo.toml
cargo test --locked --manifest-path snippets-linux/Cargo.toml --no-default-features --features desktop
cargo check --locked --manifest-path snippets-linux/Cargo.toml --no-default-features
```

The GNOME module tests use a real private `dbus-daemon` and a fictional Shell.
They cover locked/unlocked states, rapid cycles, foreign signals, loss of Shell,
separate ownership of the public ScreenSaver service and connection closure.
They never lock or unlock the actual desktop.

For a running GNOME session with **no existing Snippets primary process**:

```sh
SNIPPETS_GNOME_LIVE=read-only cargo test --locked \
  --manifest-path snippets-linux/Cargo.toml --no-default-features --features desktop \
  --test gnome-desktop -- --ignored --test-threads=1
```

Run from the desktop session so its D-Bus and Wayland environment is inherited.
The test reads the real screen-lock state, starts the actual GTK app in the
background with a temporary library, exercises CLI expansion controls, verifies
`unsupportedDesktop`, and checks that one Quit terminates the app. It leaves the
real library, input configuration, keyboard, pointer and clipboard untouched.
It passed on the Ubuntu VM with the screen locked on 2026-10-09. Interactive
editing, unlock/relock and IBus text insertion are separate, outstanding checks.

The Ubuntu desktop feature suite completed with **1090 passed, 89 ignored**;
the live GNOME test is a separate additional pass. The headless configuration
also passed `cargo check`. An isolated installer smoke check using staged debug
executables verified the links, desktop entry and absence of Fcitx files; this
was a file-layout check, not a qualified Release build.

The Hyprland/default-feature library run passed 1057 tests, failed 10 and
ignored 87 under parallel VM load. All 10 failures passed when rerun sequentially
without changing application code or timeouts; the same rerun also passed all
six desktop adapter tests. This is not a clean full parallel run. Prefer bounded
test concurrency for the expensive restoration fixtures on this VM. Strict
`cargo clippy --all-targets -- -D warnings` passed for the default build.

## Next implementation boundary

The IBus prototype owns composition generations across reset, focus and content
type changes; drops pending work on connection loss or consent revocation; and
checks GNOME Shell's unlocked state through its unique bus owner before delivering
a reply. Candidate rows contain ordinary-snippet metadata, never vault bodies.
Its popup currently uses GNOME's native IBus candidate presentation.

The owned GTK4/Wayland receiver passed exact expansion, password pass-through,
cross-field cancellation and screen-shield activation/deactivation. The last case
uses a headless Shell with authentication locking disabled; it is not a test of
an authenticated unlock or logind session suspension.

Chromium 155.0.8059.39 passed exact expansion, password pass-through and cross-field
cancellation with composition finished, using native Wayland text-input-v3 and a
fresh profile. The Ubuntu snap's binary was launched directly with the guest's
system libraries; this does not qualify the confined snap launcher or default
browser flags. The runner explicitly enables Wayland IME and text-input-v3.

The earlier first-key failure came from the test keyboard: Mutter creates its
virtual keyboard lazily, and hot-plugging it during the first composition caused
Chromium to reset that composition. The runner now primes the keyboard before
starting Chromium and retains it throughout the run. No product-code focus/reset
checks were relaxed. The alternate GTK IME browser path remains unqualified.
Input-source/IBus restart coverage, popup presentation, installation and
cross-application insertion remain outstanding.

The shortcut adapter owns a private portal connection and session. It registers
the native desktop application identity before other portal calls, checks sender
and session identity, bounds and expires queued activations, and discards sessions
when their portal owner disappears. Permission revocation and existing lock-epoch
checks still apply in the common worker. Wayland activation tokens are passed only
to the window opening for that event. The adapter supports portal version 1; on
version 2 it additionally exposes Change Keys through ConfigureShortcuts. On
version 1, bindings are edited in the application's page in GNOME Settings.

The real portal fixture passed all three action bindings, clean disconnect and
reconnect, explicit session closure, and opening/activating the actual GTK main
window and picker. The targeted shortcut suite passed 12 tests (two separate
native fixtures ignored by default) on both Ubuntu and Omarchy. Strict all-target
Clippy passed for `desktop,ibus` on Ubuntu and the default Fcitx build on Omarchy.

**Open restart failure:** terminating the owned `xdg-desktop-portal` frontend
correctly revokes the existing adapter. A replacement frontend then accepts a new
registration but does not deliver its real shortcut on this Ubuntu image. The
`--restart-portal` fixture requires delivery and fails; registration alone is not
counted as recovery. Restarting only the owned GNOME portal backend restored
normal delivery in the test lab. This suggests stale backend bindings after a
frontend crash, but the upstream cause is not yet fully established. The app does
not restart desktop services as a workaround. This remains a qualification gap.

See the public [GlobalShortcuts interface](https://github.com/flatpak/xdg-desktop-portal/blob/main/data/org.freedesktop.portal.GlobalShortcuts.xml)
and [native application registry](https://github.com/flatpak/xdg-desktop-portal/blob/main/data/org.freedesktop.host.portal.Registry.xml).
The event age check is GNOME-specific: its backend forwards Mutter's wrapping
32-bit monotonic millisecond timestamp; it is not assumed to be a portable clock
for other portal backends. See the [GNOME implementation](https://gitlab.gnome.org/GNOME/xdg-desktop-portal-gnome/-/blob/main/src/globalshortcuts.c).

The experimental feature's build, four Rust bridge tests, 27 filtered worker
tests, native IBus protocol smoke and GTK4 receiver passed in the Ubuntu VM.
The protocol smoke includes application stop/restart and reconnect. The shared
refactor also passed strict all-target Clippy and five bridge tests on Omarchy,
including the native Fcitx state fixture. These targeted checks do not replace
the remaining GNOME acceptance cases.

Privacy detection depends on the application's input-purpose/hint declarations.
GTK's visual `visibility=false` alone does **not** declare a password field; GTK
documents that applications must also set password/PIN input-purpose. IBus cannot
distinguish such an undeclared masked widget from an ordinary field. Password,
PIN, PRIVATE, HIDDEN_TEXT and unknown hint bits are rejected when reported.
See [GtkText visibility](https://docs.gtk.org/gtk4/method.Text.set_visibility.html).

For reproducible, isolated engineering runs, see
[the GNOME test harness](testing/README.md#owned-gnome-session).

Reference: GNOME Shell implements the read-only ScreenSaver interface at
`/org/gnome/ScreenSaver` on its own bus connection. Modern GNOME can also expose
the public `org.gnome.ScreenSaver` bus name through a separate forwarding process.
The adapter therefore resolves `org.gnome.Shell`, calls its unique owner, checks
ownership again after the reply and accepts signals only from that owner.
See the [upstream implementation](https://github.com/GNOME/gnome-shell/blob/main/js/ui/shellDBus.js)
and [interface definition](https://github.com/GNOME/gnome-shell/blob/main/data/dbus-interfaces/org.gnome.ScreenSaver.xml).
