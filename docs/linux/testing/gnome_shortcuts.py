#!/usr/bin/env python3
"""Exercise the real shortcut portal only inside an owned headless GNOME lab.

Requires python3-pyatspi. Approves only the fixture's three public bindings in
the isolated GNOME Settings dialog. No input reaches the user's desktop.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lab", type=Path)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--application", type=Path, help="also check real GTK window activation")
    parser.add_argument("--restart-portal", action="store_true", help="also qualify delivery after a frontend crash")
    args = parser.parse_args()
    root = args.lab.absolute()
    assert str(root).startswith("/tmp/snippets-gnome-")
    environment = json.loads((root / "environment.json").read_text())
    assert environment["XDG_RUNTIME_DIR"] == str(root / "runtime")
    assert environment["WAYLAND_DISPLAY"] == "snippets-lab"
    assert environment["XDG_DATA_HOME"] == str(root / "data")
    assert environment["GSETTINGS_BACKEND"] == "keyfile"
    assert environment["DBUS_SESSION_BUS_ADDRESS"] != os.environ.get("DBUS_SESSION_BUS_ADDRESS")
    os.environ.update(environment)
    os.environ.pop("DISPLAY", None)
    # Older running labs may predate exporting the display before bus startup.
    subprocess.run(["dbus-update-activation-environment", "WAYLAND_DISPLAY"], check=True)
    desktop = root / "data/applications/com.khm.snippets.linux.desktop"
    desktop.parent.mkdir(parents=True, exist_ok=True)
    previous = desktop.read_bytes() if desktop.exists() else None
    desktop.write_text("[Desktop Entry]\nType=Application\nName=Snippets test fixture\n"
                       "Exec=/bin/false\n")

    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gio, GLib, Gtk
    import pyatspi

    connection = Gio.bus_get_sync(Gio.BusType.SESSION)
    destination = "org.gnome.Mutter.RemoteDesktop"
    path = connection.call_sync(destination, "/org/gnome/Mutter/RemoteDesktop", destination,
                                "CreateSession", None, None, 0, 3000, None).unpack()[0]

    def remote(method, value=None):
        return connection.call_sync(destination, path, destination + ".Session", method,
                                    value, None, 0, 3000, None)

    def key(code, pressed):
        remote("NotifyKeyboardKeycode", GLib.Variant("(ub)", (code, pressed)))

    def chord(code):
        try:
            for item in (125, 56, code):
                key(item, True)
        finally:
            for item in (code, 56, 125):
                key(item, False)

    def descendants(node, depth=0):
        if depth > 24:
            return
        yield node
        for child in node:
            yield from descendants(child, depth + 1)

    def approve_fixture_dialog():
        for app in pyatspi.Registry.getDesktop(0):
            if app.name != "gnome-control-center-global-shortcuts-provider":
                continue
            for window in app:
                if window.name != "Add Keyboard Shortcuts":
                    continue
                nodes = list(descendants(window))
                names = {node.name for node in nodes}
                expected = {"Open Snippets", "Snippets paste picker", "Capture clipboard text",
                            "Alt+Super+N", "Alt+Super+P", "Alt+Super+C"}
                if not expected <= names:
                    raise RuntimeError("unexpected fixture shortcut bindings")
                for node in nodes:
                    if node.getRoleName() == "button" and node.name == "Add":
                        if not node.queryAction().doAction(0):
                            raise RuntimeError("fixture dialog approval failed")
                        print("Approved the three fixture bindings in GNOME Settings", flush=True)

    child = None
    receiver = None
    log = (root / "portal-test.log").open("w")
    status = root / "portal-fixture-status"
    status.unlink(missing_ok=True)
    try:
        remote("Start")
        key(42, True)
        key(42, False)  # Create the virtual keyboard before any receivers.
        Gtk.init()
        receiver = Gtk.Window(title="Public shortcut receiver")
        receiver.set_child(Gtk.Entry())
        receiver.present()
        # Keep a real application active: GNOME intentionally doesn't deliver
        # normal-mode global shortcuts while the empty-desktop overview is up.
        until = time.monotonic() + 1
        while time.monotonic() < until:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.02)
        env = dict(os.environ, SNIPPETS_GNOME_SHORTCUT_LIVE=str(root))
        if args.restart_portal:
            env["SNIPPETS_GNOME_PORTAL_RESTART"] = "1"
        child = subprocess.Popen([
            "cargo", "test", "--locked", "--manifest-path", "snippets-linux/Cargo.toml",
            "--no-default-features", "--features", "desktop,ibus", "--lib",
            "native_gnome_portal_keyboard_fixture", "--", "--ignored", "--nocapture",
        ], cwd=args.repository.absolute(), env=env, stdout=log, stderr=log, start_new_session=True)
        deadline = time.monotonic() + 240
        last = ""
        while child.poll() is None:
            if time.monotonic() >= deadline:
                raise RuntimeError("portal fixture timed out")
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            approve_fixture_dialog()
            value = status.read_text().strip() if status.exists() else ""
            if value and value != last:
                print(value, flush=True)
                last = value
                if value == "registered":
                    chord(49)
                elif value == "received 1":
                    chord(25)
                elif value == "received 2":
                    chord(46)
                elif value in ("reconnected", "replacement-registered"):
                    chord(49)
                elif value == "revoke-owner":
                    pid = connection.call_sync(
                        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                        "GetConnectionUnixProcessID",
                        GLib.Variant("(s)", ("org.freedesktop.portal.Desktop",)),
                        None, 0, 3000, None).unpack()[0]
                    process_env = (Path("/proc") / str(pid) / "environ").read_bytes().split(b"\0")
                    expected = ("DBUS_SESSION_BUS_ADDRESS=" + environment["DBUS_SESSION_BUS_ADDRESS"]).encode()
                    assert expected in process_env, "refuse to stop a portal outside the owned lab"
                    os.kill(pid, signal.SIGTERM)
            time.sleep(0.1)
        if child.returncode != 0 or status.read_text().strip() != "passed":
            raise RuntimeError("real portal keyboard fixture failed")
        print("GNOME portal E2E passed", flush=True)
        if args.application:
            with tempfile.TemporaryDirectory(prefix="shortcut-ui-", dir=root) as library:
                preference = Path(library) / "global-shortcuts.json"
                preference.write_text('{"schema":1,"enabled":true}\n')
                preference.chmod(0o600)
                app_env = dict(os.environ, SNIPPETS_SUPPORT_DIR=library)
                executable = str(args.application.absolute())
                child = subprocess.Popen([executable, "--background"], env=app_env,
                                         stdout=log, stderr=log, start_new_session=True)
                try:
                    time.sleep(2)
                    for code, title in ((49, "Snippets"), (25, "Snippets Picker")):
                        chord(code)
                        until = time.monotonic() + 10
                        while True:
                            while GLib.MainContext.default().pending():
                                GLib.MainContext.default().iteration(False)
                            if child.poll() is not None:
                                raise RuntimeError("GTK app exited before activation")
                            active = False
                            for app in pyatspi.Registry.getDesktop(0):
                                for window in app:
                                    state = window.getState()
                                    if (window.name == title and state.contains(pyatspi.STATE_SHOWING)
                                            and state.contains(pyatspi.STATE_ACTIVE)):
                                        active = True
                            if active:
                                print(f"Real GTK window active: {title}", flush=True)
                                break
                            if time.monotonic() >= until:
                                raise RuntimeError(f"shortcut did not activate {title}")
                            time.sleep(0.1)
                finally:
                    subprocess.run([executable, "--quit"], env=app_env,
                                   stdout=log, stderr=log, timeout=10, check=True)
                    child.wait(timeout=10)
    finally:
        if child and child.poll() is None:
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        remote("Stop")
        if receiver:
            receiver.destroy()
        log.close()
        print((root / "portal-test.log").read_text()[-5000:], flush=True)
        if previous is None:
            desktop.unlink()
        else:
            desktop.write_bytes(previous)


if __name__ == "__main__":
    main()
