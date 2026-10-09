#!/usr/bin/env python3
"""Real Mutter clipboard transport/cancellation in a private GNOME lab.

Claims the primary app name only if vacant. Complements the real application
Capture UI test; this script itself is a protocol client, not the product GUI.
"""
import argparse
import json
import os
from pathlib import Path
import time
import ctypes
import shlex
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lab', type=Path)
    args = parser.parse_args()
    root = args.lab.absolute()
    env = json.loads((root / 'environment.json').read_text())
    assert env['XDG_RUNTIME_DIR'] == str(root / 'runtime') and env['WAYLAND_DISPLAY'] == 'snippets-lab'
    os.environ.update(env)
    os.environ.pop('DISPLAY', None)
    os.environ.update(GTK_IM_MODULE='wayland', GTK_A11Y='none')
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gio, GLib, Gtk, Gdk, GObject
    Gtk.init()
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    owner = bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                         'RequestName', GLib.Variant('(su)', ('com.khm.snippets.linux', 4)), None, 0, 3000, None).unpack()[0]
    assert owner == 1, 'another primary is running; it was not replaced'
    remote_api = 'org.gnome.Mutter.RemoteDesktop'
    remote_path = bus.call_sync(remote_api, '/org/gnome/Mutter/RemoteDesktop', remote_api,
                                'CreateSession', None, None, 0, 3000, None).unpack()[0]
    def remote(method, args=None):
        return bus.call_sync(remote_api, remote_path, remote_api + '.Session', method, args, None, 0, 3000, None)
    remote('Start')
    for pressed in [True, False]:
        remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (42, pressed)))
    window = Gtk.Window(title='Public clipboard transport fixture')
    entry = Gtk.Entry()
    window.set_child(entry)
    window.present(); entry.grab_focus()

    def settle(seconds=0.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.005)

    def wait(test):
        end = time.monotonic() + 5
        while not test():
            assert time.monotonic() < end, 'owned clipboard operation timed out'
            settle(0.01)

    # Use native async ownership; Python virtual async callbacks cannot safely
    # retain GTK's opaque callback data past the vfunc return on this GI build.
    provider_root = tempfile.TemporaryDirectory(prefix='clipboard-provider-', dir=root)
    provider_path = Path(provider_root.name) / 'provider.so'
    flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk4'], text=True))
    subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                    str(Path(__file__).with_name('gnome_clipboard_provider.c')),
                    '-o', str(provider_path), *flags], check=True)
    native = ctypes.CDLL(str(provider_path))
    native.snippets_delayed_provider_get_type.restype = ctypes.c_size_t
    assert native.snippets_delayed_provider_get_type()
    provider_type = GObject.type_from_name('SnippetsDelayedProvider')

    def read():
        results = []
        def done(bus, result):
            try:
                results.append(bus.call_finish(result).unpack())
            except GLib.Error:
                results.append((False, []))
        bus.call('org.gnome.Shell', '/com/khm/Snippets/Gnome', 'com.khm.Snippets.Gnome1', 'ReadClipboard',
                 None, None, 0, 2500, None, done)
        return results

    def shield(active):
        bus.call_sync('org.gnome.Shell', '/org/gnome/ScreenSaver', 'org.gnome.ScreenSaver',
                      'SetActive', GLib.Variant('(b)', (active,)), None, 0, 3000, None)

    def extension(method):
        bus.call_sync('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
                      method, GLib.Variant('(s)', ('snippets@wowlocal.github.io',)), None, 0, 3000, None)

    try:
        bus.call_sync('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
                      GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))), None, 0, 3000, None)
        window.present(); wait(window.is_active); settle(0.3)
        for pressed in [True, False]:
            remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (42, pressed)))
        settle(0.1)
        clipboard = window.get_display().get_clipboard()
        provider = Gdk.ContentProvider.new_for_value(GObject.Value(GObject.TYPE_STRING, 'Public exact text'))
        assert clipboard.set_content(provider)
        settle(0.2)
        result = read(); wait(lambda: bool(result))
        assert result[0][0] and bytes(result[0][1]) == b'Public exact text', ('normal transport failed', result[0][0], len(result[0][1]))
        print('Real Mutter clipboard: exact bounded transfer passed', flush=True)
        for cancel in ['selection', 'shield', 'disable']:
            window.present(); entry.grab_focus(); wait(window.is_active); settle(0.3)
            for pressed in [True, False]:
                remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (42, pressed)))
            settle(0.1)
            delayed = GObject.new(provider_type)
            assert clipboard.set_content(delayed)
            settle(0.2)
            before = delayed.get_property("requests")
            result = read(); wait(lambda: delayed.get_property("requests") > before)
            if cancel == 'selection':
                assert clipboard.set_content(provider)
            elif cancel == 'shield':
                shield(True); shield(False)
            else:
                extension('DisableExtension')
            wait(lambda: bool(result))
            assert not result[0][0] and not result[0][1], ('cancelled read returned data', cancel, result[0][0], len(result[0][1]), delayed.get_property("requests"))
            settle(0.6)  # Drain the owned provider even if transfer was cancelled.
            if cancel == 'disable':
                extension('EnableExtension'); settle(0.3)
            print('Real Mutter clipboard: pending read cancelled by ' + cancel, flush=True)
    finally:
        window.destroy()
        remote('Stop')
        provider_root.cleanup()
        bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName',
                      GLib.Variant('(s)', ('com.khm.snippets.linux',)), None, 0, 3000, None)


if __name__ == '__main__':
    main()
