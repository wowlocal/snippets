#!/usr/bin/env python3
"""Exercise the real IBus engine and Snippets bridge inside gnome_session.py.

Default mode checks an explicitly created IBus input context on the private lab
bus. --gtk and --chromium instead use real Wayland application receivers and a
virtual keyboard in that same owned headless session.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lab", type=Path)
    parser.add_argument("binaries", type=Path)
    parser.add_argument("--gtk", action="store_true", help="send virtual keyboard events through Mutter to a GTK4 entry")
    parser.add_argument("--chromium", type=Path, help="Chromium executable for a real Wayland DOM receiver")
    parser.add_argument("--chromium-ime", choices=("wayland", "gtk"), default="wayland")
    parser.add_argument("--installed", action="store_true", help="use binaries at their installed location")
    parser.add_argument("--restart-ibus", action="store_true", help="GTK: restart only the owned lab input daemon")
    parser.add_argument("--clipboard", action="store_true", help="GTK: check clipboard placeholder through the enabled companion")
    args = parser.parse_args()
    if args.clipboard and not args.gtk:
        parser.error("--clipboard requires --gtk")
    if args.restart_ibus and not args.gtk:
        parser.error("--restart-ibus requires --gtk")
    lab = json.loads((args.lab / "environment.json").read_text())
    # A lab directory and its private bus are mandatory; never fall back to the
    # caller's normal IBus address or user library.
    assert lab["XDG_RUNTIME_DIR"] == str(args.lab.absolute() / "runtime")
    assert lab["IBUS_ADDRESS"].startswith(f"unix:path={args.lab.absolute()}/runtime/")
    os.environ.update(lab)
    import gi
    gi.require_version("IBus", "1.0")
    from gi.repository import GLib, IBus
    IBus.init()
    bus = IBus.Bus.new()
    assert bus.is_connected()
    context = GLib.MainContext.default()

    def settle(seconds=0.05):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            while context.pending():
                context.iteration(False)
            time.sleep(0.002)

    def wait(predicate):
        until = time.monotonic() + 5
        while not predicate():
            assert time.monotonic() < until, "engine fixture timed out"
            settle()

    children = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="ibus-fixture-", dir=args.lab) as tmp:
        root = Path(tmp)
        installed = args.binaries.resolve() if args.installed else root / "installed"
        if not args.installed:
            installed.mkdir()
        library = root / "library"
        env = dict(os.environ, SNIPPETS_SUPPORT_DIR=str(library))
        if not args.installed:
            for name in ("snippets", "snippets-cli", "snippets-owner-auth", "snippets-ibus"):
                shutil.copy2(args.binaries / name, installed / name)
        engine_link = args.lab / "engine-current"
        if not args.installed:
            engine_link.symlink_to(installed)

        def cli(*arguments):
            result = subprocess.run([str(installed / "snippets-cli"), *arguments],
                                    env=env, capture_output=True, text=True, timeout=8)
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def spawn(name, *arguments):
            log = (args.lab / f"fixture-{name}.log").open("wb")
            logs.append(log)
            child = subprocess.Popen([str(installed / name), *arguments], env=env,
                                     stdout=log, stderr=log, start_new_session=True)
            children.append(child)
            return child

        try:
            cli("add", "--name", "Public exact fixture", "--keyword", "gnometest",
                "--content", "Public GNOME expansion", "--enabled")
            gui = spawn("snippets", "--background")
            wait(lambda: cli("expansion", "status")["appAvailable"])
            cli("expansion", "enable")
            wait(lambda: (Path(lab["XDG_RUNTIME_DIR"]) / "snippets-ibus.sock").is_socket())
            if not args.installed:
                engine = spawn("snippets-ibus", "--ibus")
                settle(0.4)
                assert engine.poll() is None
            subprocess.run(["gsettings", "set", "org.gnome.desktop.input-sources", "sources",
                            "[('ibus', 'snippets')]"], env=env, check=True)
            settle(0.5)
            if args.gtk or args.chromium:
                if args.chromium:
                    from gnome_browser import run
                    run(args.chromium, args.lab, settle, wait, args.chromium_ime)
                else:
                    def restart_ibus():
                        disconnected = []
                        signal = bus.connect("disconnected", lambda _bus: disconnected.append(True))
                        try:
                            nonce = uuid.uuid4().hex
                            (args.lab / "restart-ibus.request").write_text(nonce)
                            receipt = args.lab / "restart-ibus.done"
                            wait(lambda: receipt.exists() and receipt.read_text() == nonce)
                            wait(lambda: bool(disconnected))
                            wait(bus.is_connected)
                            wait(lambda: bus.get_global_engine() is not None and
                                 bus.get_global_engine().get_name() == "snippets")
                        finally:
                            bus.disconnect(signal)
                    gtk_smoke(settle, wait, cli, restart_ibus if args.restart_ibus else None, args.clipboard)
                subprocess.run([str(installed / "snippets"), "--quit"], env=env, check=True, timeout=8)
                gui.wait(timeout=8)
                return
            client = bus.create_input_context("snippets-ibus-public-fixture")
            committed, candidates, preedit = [], [], []
            client.connect("commit-text", lambda _context, text: committed.append(text.get_text()))
            client.connect("update-lookup-table", lambda _context, table, visible:
                           candidates.append(table.get_number_of_candidates() if visible else 0))
            client.connect("update-preedit-text", lambda _context, text, cursor, visible:
                           preedit.append(text.get_text() if visible else ""))
            client.set_capabilities(int(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS |
                                        IBus.Capabilite.LOOKUP_TABLE))
            client.focus_in()
            assert bus.set_global_engine("snippets"), "IBus refused the registered fixture engine"
            client.set_engine("snippets")
            client.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints(0))
            settle(0.2)

            def type_text(text):
                for char in text:
                    handled = client.process_key_event(IBus.unicode_to_keyval(char), 0, 0)
                    if not handled:
                        committed.append(char)
                    client.process_key_event(IBus.unicode_to_keyval(char), 0, IBus.ModifierType.RELEASE_MASK)
                    settle(0.03)

            type_text("\\gnometest")
            try:
                wait(lambda: "".join(committed) == "Public GNOME expansion")
            except AssertionError:
                # All values here belong to this explicitly fictional fixture.
                print("fixture state:", repr(committed), candidates, cli("expansion", "status"),
                      client.get_engine().get_name(), flush=True)
                raise
            assert any(candidates), "lookup candidates were never published"
            for accept in (IBus.KEY_Return, IBus.KEY_Tab):
                committed.clear()
                type_text("\\gn")
                client.process_key_event(accept, 0, 0)
                client.process_key_event(accept, 0, IBus.ModifierType.RELEASE_MASK)
                wait(lambda: "".join(committed) == "Public GNOME expansion")
            committed.clear()
            client.reset()
            for value in (IBus.KEY_dead_acute, IBus.KEY_e):
                client.process_key_event(value, 0, 0)
                client.process_key_event(value, 0, IBus.ModifierType.RELEASE_MASK)
                settle()
            wait(lambda: "".join(committed) == "é")
            committed.clear()
            for value in (IBus.KEY_Multi_key, IBus.KEY_minus, IBus.KEY_backslash):
                client.process_key_event(value, 0, 0)
                client.process_key_event(value, 0, IBus.ModifierType.RELEASE_MASK)
                settle()
            wait(lambda: "".join(committed) == "⍀")
            committed.clear()
            type_text("\\gn")
            for value in (IBus.KEY_ISO_Level3_Shift, IBus.KEY_ISO_Level5_Shift):
                client.process_key_event(value, 0, 0)
                client.process_key_event(value, 0, IBus.ModifierType.RELEASE_MASK)
            type_text("ometest")
            wait(lambda: "".join(committed) == "Public GNOME expansion")
            for purpose, hints in [(IBus.InputPurpose.PASSWORD, 0),
                                   (IBus.InputPurpose.PIN, 0),
                                   (IBus.InputPurpose.FREE_FORM, 1 << 11),
                                   (IBus.InputPurpose.FREE_FORM, 1 << 12),
                                   (IBus.InputPurpose.FREE_FORM, 1 << 29)]:
                committed.clear()
                client.reset()
                client.set_content_type(purpose, IBus.InputHints(hints))
                settle()
                type_text("\\gnometest")
                settle(0.2)
                assert "".join(committed) == "\\gnometest", "private field consumed or expanded input"
            client.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints(0))
            settle()
            for revoke in (client.reset, client.focus_out,
                           lambda: client.set_content_type(IBus.InputPurpose.PASSWORD, IBus.InputHints(0))):
                committed.clear()
                type_text("\\gn")
                revoke()
                settle(0.3)
                assert not committed, "revoked composition committed into another context"
                assert not preedit or not preedit[-1], "revoked preedit remained visible"
                client.focus_in()
                client.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints(0))
                settle()
            type_text("\\gn")
            wait(lambda: bool(candidates and candidates[-1]))
            cli("expansion", "disable")
            wait(lambda: not candidates[-1])
            assert not committed, "disabled composition committed"
            assert not preedit or not preedit[-1], "disabled preedit remained visible"
            cli("expansion", "enable")
            wait(lambda: (Path(lab["XDG_RUNTIME_DIR"]) / "snippets-ibus.sock").is_socket())
            type_text("\\gn")
            wait(lambda: bool(candidates[-1]))
            subprocess.run([str(installed / "snippets"), "--quit"], env=env, check=True, timeout=8)
            gui.wait(timeout=8)
            wait(lambda: not candidates[-1])
            committed.clear()
            type_text("\\gnometest")
            assert "".join(committed) == "\\gnometest", "absent app consumed keyboard input"
            gui = spawn("snippets", "--background")
            wait(lambda: cli("expansion", "status")["appAvailable"])
            wait(lambda: (Path(lab["XDG_RUNTIME_DIR"]) / "snippets-ibus.sock").is_socket())
            committed.clear()
            type_text("\\gnometest")
            wait(lambda: "".join(committed) == "Public GNOME expansion")
            client.focus_out()
            client.destroy()
            cli("expansion", "disable")
            subprocess.run([str(installed / "snippets"), "--quit"], env=env, check=True, timeout=8)
            gui.wait(timeout=8)
            print("IBus engine smoke: exact expansion, candidates, private-field pass-through, "
                  "Compose/dead keys, level modifiers, reset/focus/content-type cancellation, "
                  "consent revocation and app restart passed")
        finally:
            try:
                subprocess.run(["gsettings", "set", "org.gnome.desktop.input-sources", "sources",
                                "[('xkb', 'us')]"], env=env, check=False, timeout=5)
            except subprocess.TimeoutExpired:
                pass  # A failed lab bus must not prevent owned process cleanup.
            for child in reversed(children):
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
            for child in children:
                try:
                    child.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            for log in logs:
                log.close()
            if not args.installed:
                engine_link.unlink()


def gtk_smoke(settle, wait, cli, restart_ibus=None, check_clipboard=False):
    # The caller has checked both private runtime and IBus addresses before any
    # GTK or D-Bus connection is opened. No real desktop input is reachable here.
    os.environ["GTK_IM_MODULE"] = "wayland"
    os.environ["GDK_BACKEND"] = "wayland"
    import gi
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gio, GLib, Gtk, IBus, Gdk, GObject
    connection = Gio.bus_get_sync(Gio.BusType.SESSION)
    destination = "org.gnome.Mutter.RemoteDesktop"
    path = connection.call_sync(destination, "/org/gnome/Mutter/RemoteDesktop", destination,
                                "CreateSession", None, None, 0, 3000, None).unpack()[0]

    def remote(method, arguments=None):
        return connection.call_sync(destination, path, destination + ".Session", method,
                                    arguments, None, 0, 3000, None)

    def key(value):
        remote("NotifyKeyboardKeysym", GLib.Variant("(ub)", (value, True)))
        remote("NotifyKeyboardKeysym", GLib.Variant("(ub)", (value, False)))
        settle(0.05)

    def type_text(value):
        for char in value:
            key(IBus.unicode_to_keyval(char))

    window = Gtk.Window(title="Snippets GNOME public test")
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
    entry, password, other = Gtk.Entry(), Gtk.Entry(), Gtk.Entry()
    password.set_visibility(False)
    # GTK explicitly separates visual masking from input-purpose. A custom
    # widget that masks text without declaring privacy is indistinguishable
    # from a public field to IBus; cover the actual PASSWORD protocol here.
    password.set_input_purpose(Gtk.InputPurpose.PASSWORD)
    for field in (entry, password, other):
        box.append(field)
    window.set_child(box)
    window.set_default_size(700, 300)
    try:
        remote("Start")
        window.present()
        entry.grab_focus()
        settle(1)
        # A fresh headless Shell starts in its overview. Escape dismisses that
        # owned lab overview; it never addresses the user's Shell or keyboard.
        key(0xff1b)
        window.present()
        entry.grab_focus()
        settle(0.3)
        type_text("\\gnometest")
        try:
            wait(lambda: entry.get_text() == "Public GNOME expansion")
        except AssertionError:
            print("GTK fixture state:", repr(entry.get_text()), window.is_active(),
                  cli("expansion", "status"), flush=True)
            raise
        if check_clipboard:
            cli("add", "--name", "Public clipboard placeholder", "--keyword", "clipfixture",
                "--content", "Before {clipboard} After", "--enabled")
            clipboard = window.get_display().get_clipboard()
            assert clipboard.set_content(Gdk.ContentProvider.new_for_value(
                GObject.Value(GObject.TYPE_STRING, "Public clipboard ✓")))
            entry.set_text("")
            settle(0.3)
            type_text("\\clipfixture")
            wait(lambda: entry.get_text() == "Before Public clipboard ✓ After")
            print("GTK IBus: clipboard placeholder reads exact text through companion", flush=True)
        password.grab_focus()
        settle()
        type_text("\\gnometest")
        assert password.get_text() == "\\gnometest", (
            "GTK hidden fixture mismatch", repr(password.get_text()), repr(entry.get_text()),
            window.get_focus(), password.get_input_purpose())
        entry.set_text("")
        entry.grab_focus()
        settle()
        type_text("\\gn")
        other.grab_focus()
        settle()
        type_text("ometest")
        assert other.get_text() == "ometest", "composition crossed GTK focus boundary"
        assert "Public GNOME expansion" not in entry.get_text()
        entry.set_text("")
        entry.grab_focus()
        settle()
        type_text("\\gn")

        def shield(method, arguments=None):
            return connection.call_sync("org.gnome.Shell", "/org/gnome/ScreenSaver",
                                        "org.gnome.ScreenSaver", method, arguments,
                                        None, 0, 3000, None)

        shield("SetActive", GLib.Variant("(b)", (True,)))
        wait(lambda: shield("GetActive").unpack()[0])
        settle(0.3)
        shield("SetActive", GLib.Variant("(b)", (False,)))
        wait(lambda: not shield("GetActive").unpack()[0])
        window.present()
        entry.grab_focus()
        settle(1.7)
        type_text("ometest")
        assert entry.get_text() == "ometest", "composition survived GNOME screen shield"
        # Reconfigure only this keyfile-backed lab. Existing source lists on
        # the user's desktop are never read or written by the test.
        def source(value):
            subprocess.run(['gsettings', 'set', 'org.gnome.desktop.input-sources',
                            'sources', value], check=True)
            settle(0.5)

        entry.set_text('')
        type_text('\\gn')
        source("[('xkb', 'us')]")
        type_text('ometest')
        assert entry.get_text() == 'ometest', 'composition survived input-source switch'
        source("[('xkb', 'us'), ('ibus', 'snippets')]")
        # Selecting an engine through the public IBus API models the source
        # switch without relying on a Shell Eval or a private UI object.
        input_bus = IBus.Bus.new()
        assert input_bus.set_global_engine('snippets')
        settle(0.3)
        entry.set_text('')
        type_text('\\gnometest')
        wait(lambda: entry.get_text() == 'Public GNOME expansion')
        print('GTK4 IBus: input-source switch cancels, fresh query expands after return', flush=True)
        if restart_ibus:
            source("[('ibus', 'snippets')]")
            entry.set_text('')
            type_text('\\gn')
            restart_ibus()
            settle(0.5)
            assert entry.get_text() == '', 'restart committed the old composition'
            type_text('ometest')
            assert entry.get_text() == 'ometest', 'composition survived input-service restart'
            entry.set_text('')
            type_text('\\gnometest')
            wait(lambda: entry.get_text() == 'Public GNOME expansion')
            print('GTK4 IBus: daemon restart revokes old composition; installed engine recovers fresh expansion', flush=True)
        print("GTK4 Wayland E2E: Mutter keyboard → Shell → IBus → real entry; "
              "exact expansion, password pass-through, focus and screen-shield cancellation passed", flush=True)
    finally:
        window.destroy()
        remote("Stop")


if __name__ == "__main__":
    main()
