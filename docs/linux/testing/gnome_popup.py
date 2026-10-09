#!/usr/bin/env python3
"""Native candidate-panel check in an owned headless GNOME lab only.

Requires pyatspi. Approves only the lab's screenshot permission using its virtual
keyboard, then saves real portal screenshots. Never moves any pointer.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from urllib.parse import unquote, urlparse


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lab', type=Path)
    parser.add_argument('binaries', type=Path)
    parser.add_argument('--chromium', type=Path)
    args = parser.parse_args()
    root = args.lab.absolute()
    env = json.loads((root / 'environment.json').read_text())
    assert env['XDG_RUNTIME_DIR'] == str(root / 'runtime')
    assert env['XDG_DATA_HOME'] == str(root / 'data')
    assert env['WAYLAND_DISPLAY'] == 'snippets-lab'
    assert env['GSETTINGS_BACKEND'] == 'keyfile'
    assert env['DBUS_SESSION_BUS_ADDRESS'] != os.environ.get('DBUS_SESSION_BUS_ADDRESS')
    os.environ.update(env)
    library = tempfile.TemporaryDirectory(prefix='popup-library-', dir=root)
    os.environ['SNIPPETS_SUPPORT_DIR'] = library.name
    os.environ.pop('DISPLAY', None)
    os.environ.update(GTK_IM_MODULE='wayland', GDK_BACKEND='wayland', GTK_A11Y='none')
    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('IBus', '1.0')
    from gi.repository import Gio, GLib, Gtk, IBus
    import pyatspi
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def call(dest, path, interface, method, value=None):
        return bus.call_sync(dest, path, interface, method, value, None, 0, 3000, None)

    shell_pid = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                     'GetConnectionUnixProcessID', GLib.Variant('(s)', ('org.gnome.Shell',))).unpack()[0]
    shell = Path(f'/proc/{shell_pid}')
    assert shell.stat().st_uid == os.getuid()
    assert b'--headless' in (shell / 'cmdline').read_bytes().split(b'\0')
    assert ('XDG_RUNTIME_DIR=' + env['XDG_RUNTIME_DIR']).encode() in (shell / 'environ').read_bytes().split(b'\0')

    def settle(seconds=0.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.01)

    def wait(predicate, description):
        end = time.monotonic() + 10
        while not predicate():
            assert time.monotonic() < end, description
            settle()

    def nodes(node, depth=0):
        if depth > 30:
            return
        yield node
        for child in node:
            yield from nodes(child, depth + 1)

    def visible():
        return [(app.name, n.getRoleName(), n.name) for app in pyatspi.Registry.getDesktop(0)
                for n in nodes(app) if n.name and n.getState().contains(pyatspi.STATE_SHOWING)]

    bodies = {'Public Alpha\npanelalpha': 'Alpha body ✓', 'Public Beta\npanelbeta': 'Beta body ✓'}

    def candidates():
        return [name for app, role, name in visible() if app == 'gnome-shell' and name in bodies]

    def wait_candidates():
        wait(lambda: set(candidates()) == set(bodies), 'both native candidate rows')
        return candidates()

    def wait_hidden():
        wait(lambda: not candidates(), 'native candidate panel did not close')

    def cli(*arguments):
        result = subprocess.run([str(args.binaries / 'snippets-cli'), *arguments],
                                capture_output=True, text=True, timeout=8, check=True)
        return json.loads(result.stdout)

    remote_dest = 'org.gnome.Mutter.RemoteDesktop'
    remote_path = call(remote_dest, '/org/gnome/Mutter/RemoteDesktop', remote_dest, 'CreateSession').unpack()[0]

    def remote(method, value=None):
        return call(remote_dest, remote_path, remote_dest + '.Session', method, value)

    def key(symbol):
        for pressed in [True, False]:
            remote('NotifyKeyboardKeysym', GLib.Variant('(ub)', (symbol, pressed)))
        settle(0.07)

    def type_text(text):
        for char in text:
            key(IBus.unicode_to_keyval(char))

    def screenshot(name, allow_permission=False):
        responses = []
        portal = 'org.freedesktop.portal.Desktop'
        token = 'public_popup_' + name
        request_path = '/org/freedesktop/portal/desktop/request/' + bus.get_unique_name()[1:].replace('.', '_') + '/' + token
        signal = bus.signal_subscribe(portal, 'org.freedesktop.portal.Request', 'Response', request_path,
                                      None, 0, lambda *args: responses.append(args[5].unpack()))
        try:
            result = call(portal, '/org/freedesktop/portal/desktop', 'org.freedesktop.portal.Screenshot',
                          'Screenshot', GLib.Variant('(sa{sv})', ('', {'handle_token': GLib.Variant('s', token), 'interactive': GLib.Variant('b', False)})))
            assert result.unpack()[0] == request_path
            settle(1)
            if not responses and allow_permission:
                names = {name for app, role, name in visible() if app == 'gnome-shell'}
                assert 'Allow Apps to Take Screenshots?' in names
                for _ in range(5):
                    focused = [n.name for app in pyatspi.Registry.getDesktop(0) if app.name == 'gnome-shell'
                               for n in nodes(app) if n.getState().contains(pyatspi.STATE_FOCUSED)]
                    if 'Allow' in focused:
                        key(IBus.KEY_Return)
                        break
                    key(IBus.KEY_Tab)
            wait(lambda: responses, 'screenshot response')
            code, values = responses[0]
            assert code == 0, 'screenshot refused'
            uri = urlparse(values['uri'])
            assert uri.scheme == 'file' and not uri.netloc
            destination = root / (name + '.png')
            destination.write_bytes(Path(unquote(uri.path)).read_bytes())
            print('SCREENSHOT', str(destination), flush=True)
        finally:
            bus.signal_unsubscribe(signal)

    desktop = Gio.Settings.new('org.gnome.desktop.input-sources')
    old_sources = desktop.get_value('sources')
    window = None
    gui = None
    log = (root / 'popup-app.log').open('w')
    try:
        remote('Start')
        key(IBus.KEY_Shift_L)
        cli('add', '--name', 'Public Alpha', '--keyword', 'panelalpha', '--content', 'Alpha body ✓', '--enabled')
        cli('add', '--name', 'Public Beta', '--keyword', 'panelbeta', '--content', 'Beta body ✓', '--enabled')
        gui = subprocess.Popen([str(args.binaries / 'snippets'), '--background'], stdout=log, stderr=log)
        wait(lambda: cli('expansion', 'status')['appAvailable'], 'primary app')
        cli('expansion', 'enable')
        wait(lambda: (root / 'runtime/snippets-ibus.sock').is_socket(), 'native bridge')
        desktop.set_value('sources', GLib.Variant('a(ss)', [('ibus', 'snippets')]))
        settle(0.7)
        Gtk.init()
        window = Gtk.Window(title='Public GNOME candidate receiver')
        window.set_default_size(700, 320)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
        box.set_margin_top(48)
        box.set_margin_start(48)
        box.set_margin_end(48)
        entry, other, password = Gtk.Entry(), Gtk.Entry(), Gtk.Entry()
        password.set_visibility(False)
        password.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        box.append(Gtk.Label(label='Snippets — native GNOME candidate panel'))
        box.append(entry)
        box.append(other)
        box.append(password)
        window.set_child(box)
        window.present()
        call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
             GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))))
        entry.grab_focus()
        settle(0.7)
        screenshot('permission', allow_permission=True)
        window.present()
        entry.grab_focus()
        settle(0.5)
        type_text('\\panel')
        order = wait_candidates()
        screenshot('candidates')
        key(IBus.KEY_Down)
        screenshot('candidates_selected')
        key(IBus.KEY_Return)
        wait(lambda: entry.get_text() == bodies[order[1]], 'Down/Enter selected wrong row')
        wait_hidden()
        entry.set_text('')
        type_text('\\panel')
        order = wait_candidates()
        key(IBus.KEY_Tab)
        wait(lambda: entry.get_text() == bodies[order[0]], 'Tab selected wrong row')
        wait_hidden()
        entry.set_text('')
        type_text('\\panel')
        wait_candidates()
        key(IBus.KEY_Escape)
        wait(lambda: entry.get_text() == '\\panel', 'Escape failed to preserve literal query')
        wait_hidden()
        entry.set_text('')
        type_text('\\panel')
        wait_candidates()
        other.grab_focus()
        settle()
        wait_hidden()
        type_text('alpha')
        assert other.get_text() == 'alpha' and entry.get_text() == ''
        entry.grab_focus()
        settle()
        type_text('\\panel')
        wait_candidates()
        cli('expansion', 'disable')
        wait_hidden()
        type_text('alpha')
        assert entry.get_text() == 'alpha', 'disabled composition still expanded'
        cli('expansion', 'enable')
        password.grab_focus()
        settle(0.3)
        type_text('\\panel')
        assert password.get_text() == '\\panel'
        wait_hidden()
        print('PASS: actual GNOME rows, Down/Enter and Tab selection, Escape literal, focus and consent cancellation, password suppression', flush=True)
        if args.chromium:
            window.destroy()
            window = None
            cli('expansion', 'enable')
            settle(0.3)
            from gnome_popup_browser import run
            run(args.chromium, root, settle, wait, key, type_text, wait_candidates, wait_hidden, screenshot)
    finally:
        if window:
            window.destroy()
        if gui:
            gui.terminate()
            try:
                gui.wait(timeout=8)
            except subprocess.TimeoutExpired:
                gui.kill()
                gui.wait()
        desktop.set_value('sources', old_sources)
        remote('Stop')
        log.close()
        library.cleanup()


if __name__ == '__main__':
    main()
