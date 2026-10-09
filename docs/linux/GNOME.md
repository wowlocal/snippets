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
- An explicit `unsupportedDesktop` expansion status on GNOME.

Not implemented: IBus expansion, caret suggestions, GNOME global shortcuts,
clipboard-history capture and cross-application insertion. Existing Hyprland
window-target and Wayland peer checks remain required for those mechanisms.
The preview is not a claim that the full application has passed GNOME UI testing.

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

IBus needs its own engine/focus lifecycle and popup integration. The existing
Fcitx bridge also depends on a fresh Hyprland window/process target; routing IBus
into it without that target would weaken the insertion checks. Share the snippet
matching/expansion logic, while keeping input-context ownership and cancellation
specific to each backend. Add GTK and Chromium end-to-end insertion, focus loss,
password-field, lock and restart tests before claiming GNOME expansion support.

Reference: GNOME Shell implements the read-only ScreenSaver interface at
`/org/gnome/ScreenSaver` on its own bus connection. Modern GNOME can also expose
the public `org.gnome.ScreenSaver` bus name through a separate forwarding process.
The adapter therefore resolves `org.gnome.Shell`, calls its unique owner, checks
ownership again after the reply and accepts signals only from that owner.
See the [upstream implementation](https://github.com/GNOME/gnome-shell/blob/main/js/ui/shellDBus.js)
and [interface definition](https://github.com/GNOME/gnome-shell/blob/main/data/dbus-interfaces/org.gnome.ScreenSaver.xml).
