#!/usr/bin/env python3
"""Real GTK picker insertion in an owned GNOME session with the companion enabled."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lab', type=Path)
    parser.add_argument('binaries', type=Path)
    parser.add_argument('--chromium', type=Path)
    parser.add_argument('--clipboard', action='store_true')
    args = parser.parse_args()
    root = args.lab.absolute()
    lab = json.loads((root / 'environment.json').read_text())
    assert lab['XDG_RUNTIME_DIR'] == str(root / 'runtime')
    assert lab['WAYLAND_DISPLAY'] == 'snippets-lab'
    assert lab['XDG_DATA_HOME'] == str(root / 'data')
    os.environ.update(lab)
    os.environ.pop('DISPLAY', None)
    os.environ['GTK_IM_MODULE'] = 'wayland'
    os.environ['GTK_A11Y'] = 'none'  # AT-SPI may inspect the app, never synchronously call this receiver itself.
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gio, GLib, Gtk, Gdk, GObject
    import pyatspi
    Gtk.init()
    connection = Gio.bus_get_sync(Gio.BusType.SESSION)
    destination = 'org.gnome.Mutter.RemoteDesktop'
    path = connection.call_sync(destination, '/org/gnome/Mutter/RemoteDesktop', destination,
                                'CreateSession', None, None, 0, 3000, None).unpack()[0]

    def remote(method, value=None):
        return connection.call_sync(destination, path, destination + '.Session', method,
                                    value, None, 0, 3000, None)

    def settle(seconds=0.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.005)

    def wait(predicate, description):
        end = time.monotonic() + 10
        while not predicate():
            if time.monotonic() >= end:
                print("field lengths:",len(plain.get_text()),len(password.get_text()),flush=True)
                print("receiver active:", window.is_active() if window else None, "visible/mapped:", (window.get_visible(),window.get_mapped()) if window else None, flush=True)
                for app in pyatspi.Registry.getDesktop(0):
                    print("fixture app:",app.name, [(w.name,w.getState().contains(pyatspi.STATE_ACTIVE)) for w in app],flush=True)
                raise RuntimeError(description)
            settle()

    def chord(*codes):
        try:
            for code in codes:
                remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (code, True)))
            settle(0.05)
        finally:
            for code in reversed(codes):
                remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (code, False)))
        settle(0.15)

    def descendants(node, depth=0):
        if node is None or depth > 24:
            return
        yield node
        for child in node:
            yield from descendants(child, depth + 1)

    def picker():
        for app in pyatspi.Registry.getDesktop(0):
            for window in app:
                if window.name == 'Snippets Picker' and window.getState().contains(pyatspi.STATE_ACTIVE):
                    return window
        return None

    def approve():
        found = False
        for app in pyatspi.Registry.getDesktop(0):
            if app.name != 'gnome-control-center-global-shortcuts-provider':
                continue
            for window in app:
                if window.name != 'Add Keyboard Shortcuts':
                    continue
                nodes = list(descendants(window))
                labels = {node.name for node in nodes}
                assert {'Open Snippets', 'Snippets paste picker', 'Capture clipboard text',
                        'Alt+Super+N', 'Alt+Super+P', 'Alt+Super+C'} <= labels
                for node in nodes:
                    if node.getRoleName() == 'button' and node.name == 'Add':
                        assert node.queryAction().doAction(0)
                        found = True
        return found

    def open_picker(targeted):
        chord(125, 56, 25)
        wait(lambda: picker() is not None, 'global shortcut did not activate the picker')
        labels = {node.name for node in descendants(picker())}
        expected = 'Return to paste into the original window' if targeted else 'Return to copy resolved text'
        assert expected in labels, f'picker did not report its expected target mode: {expected}'

    gui = None
    window = None
    log = (root / 'picker-test.log').open('w')
    desktop = root / 'data/applications/com.khm.snippets.linux.desktop'
    previous = desktop.read_bytes() if desktop.exists() else None
    desktop.parent.mkdir(parents=True, exist_ok=True)
    desktop.write_text('[Desktop Entry]\nType=Application\nName=Snippets test fixture\nExec=/bin/false\n')
    try:
        remote('Start')
        chord(42)  # Prime virtual keyboard before creating Wayland receivers.
        chord(1)  # Leave the fresh headless Shell's initial overview.
        with tempfile.TemporaryDirectory(prefix='picker-fixture-', dir=root) as tmp:
            installed = Path(tmp) / 'installed'
            installed.mkdir()
            for name in ('snippets', 'snippets-cli', 'snippets-owner-auth', 'snippets-ibus'):
                shutil.copy2(args.binaries / name, installed / name)
            library = Path(tmp) / 'library'
            env = dict(os.environ, SNIPPETS_SUPPORT_DIR=str(library))
            env.pop('GTK_A11Y', None)
            result = subprocess.run([str(installed / 'snippets-cli'), 'add', '--name', 'Public picker fixture',
                                     '--keyword', 'pickerfixture', '--content', 'Public picker insertion', '--enabled'],
                                    env=env, stdout=subprocess.DEVNULL, stderr=log, timeout=10)
            assert result.returncode == 0
            (library / 'global-shortcuts.json').write_text('{"schema":1,"enabled":true}\n')
            gui = subprocess.Popen([str(installed / 'snippets'), '--background'], env=env, stdout=log, stderr=log)
            window = Gtk.Window(title='Public GNOME picker receiver')
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
            plain = Gtk.Entry()
            password = Gtk.Entry(visibility=False, input_purpose=Gtk.InputPurpose.PASSWORD)
            box.append(plain)
            box.append(password)
            window.set_child(box)
            window.present()
            plain.grab_focus()
            # A new lab needs system-dialog approval; a reused one retains only
            # these fictional bindings. The subsequent real chord is the oracle.
            approved = False
            end = time.monotonic() + 8
            while time.monotonic() < end:
                if not approved and approve():
                    approved = True
                    print('Approved fixture shortcuts',flush=True)
                settle()
            window.present()
            plain.grab_focus()
            settle(0.4)
            wait(window.is_active, 'receiver never gained focus before picker')
            try:
                for method, parameters in [('Capture', None), ('ReadClipboard', None),
                        ('Focus', GLib.Variant('(s)', ('public-invalid-ticket',))),
                        ('Commit', GLib.Variant('(ss)', ('public-invalid-ticket', 'Public rejected text')))]:
                    try:
                        connection.call_sync('org.gnome.Shell', '/com/khm/Snippets/Gnome',
                                             'com.khm.Snippets.Gnome1', method, parameters,
                                             None, 0, 2000, None)
                        raise AssertionError('foreign connection was authorized')
                    except GLib.Error as error:
                        assert Gio.DBusError.get_remote_error(error) == 'com.khm.Snippets.Unavailable'
                print('GNOME companion: foreign D-Bus connection refused', flush=True)
                clipboard = window.get_display().get_clipboard()
                baseline = Gdk.ContentProvider.new_for_value(GObject.Value(GObject.TYPE_STRING, 'Public clipboard baseline'))
                assert clipboard.set_content(baseline)
                settle(0.2)
                open_picker(True)
                chord(28)
                wait(lambda: plain.get_text() == 'Public picker insertion', 'picker text never reached the GTK entry')
                print('GTK picker: exact text committed into original entry', flush=True)
                observed_clipboard = []
                clipboard.read_text_async(None, lambda obj, result: observed_clipboard.append(obj.read_text_finish(result)))
                wait(lambda: bool(observed_clipboard), 'clipboard baseline read did not finish')
                assert observed_clipboard == ['Public clipboard baseline']
                print('GTK picker: successful insertion preserves the clipboard', flush=True)
                plain.set_text('')
                password.grab_focus()
                settle(0.2)
                open_picker(False)
                chord(28)
                settle(0.4)
                assert password.get_text() == '' and plain.get_text() == ''
                chord(1)
                print('GTK picker: password target refused', flush=True)
                window.present()
                plain.grab_focus()
                settle(0.2)
                open_picker(True)
                chord(56, 15)  # User switches away before making a selection.
                wait(window.is_active, 'Alt+Tab did not return to the owned receiver')
                chord(56, 15)
                wait(lambda: picker() is not None, 'Alt+Tab did not return to the picker')
                chord(28)
                settle(0.5)
                assert plain.get_text() == '' and password.get_text() == ''
                print('GTK picker: intervening window focus cancels insertion', flush=True)
                chord(1)
                window.present()
                plain.grab_focus()
                settle(0.2)
                open_picker(True)
                subprocess.run(['gnome-extensions', 'disable', 'snippets@wowlocal.github.io'],
                               env=env, check=True, timeout=5)
                chord(28)
                settle(0.4)
                assert plain.get_text() == ''
                print('GTK picker: companion disable cancels pending insertion', flush=True)
                chord(1)
                subprocess.run(['gnome-extensions', 'enable', 'snippets@wowlocal.github.io'],
                               env=env, check=True, timeout=5)
                window.present()
                plain.grab_focus()
                settle(0.4)
                open_picker(True)
                chord(28)
                wait(lambda: plain.get_text() == 'Public picker insertion', 'companion did not recover after enable')
                print('GTK picker: fresh target works after companion re-enable', flush=True)
                plain.set_text('')
                settle(0.2)
                open_picker(True)
                for active in (True, False):
                    connection.call_sync('org.gnome.Shell', '/org/gnome/ScreenSaver',
                                         'org.gnome.ScreenSaver', 'SetActive', GLib.Variant('(b)', (active,)),
                                         None, 0, 2000, None)
                    settle(0.3)
                wait(lambda: picker() is not None, 'picker did not regain focus after headless shield')
                chord(28)
                settle(0.4)
                assert plain.get_text() == ''
                print('GTK picker: screen-shield cycle cancels pending insertion', flush=True)
                if args.clipboard:
                    chord(1)
                    settle(2)  # Respect the post-shield session revocation interval.
                    from gnome_clipboard import run as clipboard_test
                    clipboard_test(Gtk, Gdk, GObject, GLib, pyatspi, window, plain, password, settle, wait, chord)
                if args.chromium:
                    chord(1)
                    window.destroy()
                    window = None
                    settle(0.2)
                    if args.clipboard:
                        chord(125, 35)  # Minimize the library left by the GTK Capture check.
                    body = 'Первая строка\nSecond line — ✓'
                    result = subprocess.run([str(installed / 'snippets-cli'), 'add', '--name', 'Public Unicode picker',
                                             '--keyword', 'unicodefixture', '--content', body, '--enabled'],
                                            env=env, stdout=subprocess.DEVNULL, stderr=log, timeout=10)
                    assert result.returncode == 0
                    settle(0.3)
                    def unicode_picker(targeted):
                        open_picker(targeted)
                        codes = {'u': 22, 'n': 49, 'i': 23, 'c': 46, 'o': 24, 'd': 32,
                                 'e': 18, 'f': 33, 'x': 45, 't': 20, 'r': 19}
                        for char in 'unicodefixture':
                            chord(codes[char])
                        settle(0.3)
                        assert 'Public Unicode picker' in {node.name for node in descendants(picker())}
                    from gnome_picker_browser import run
                    capture_browser = None
                    if args.clipboard:
                        from gnome_clipboard import capture_browser as capture_test
                        capture_browser = lambda text: capture_test(pyatspi, settle, wait, chord, text)
                    run(args.chromium, root, settle, wait, unicode_picker, chord, picker, body, capture_browser)
            finally:
                subprocess.run([str(installed / 'snippets'), '--quit'], env=env,
                               stdout=log, stderr=log, timeout=10, check=True)
                gui.wait(timeout=10)
    finally:
        if gui and gui.poll() is None:
            gui.terminate()
            gui.wait(timeout=5)
        if window:
            window.destroy()
        remote('Stop')
        log.close()
        if previous is None:
            desktop.unlink()
        else:
            desktop.write_bytes(previous)


if __name__ == '__main__':
    main()
