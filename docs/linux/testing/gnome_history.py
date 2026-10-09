#!/usr/bin/env python3
"""Real history UI/keyring check under the disposable headless GNOME account."""
import argparse
import ctypes
import html
import shlex
import json
import os
from pathlib import Path
import pwd
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    args = parser.parse_args()
    account = pwd.getpwuid(os.getuid())
    assert account.pw_name == 'snippets-gnome-test'
    home = Path(account.pw_dir)
    assert home == Path('/var/lib/snippets-gnome-test')
    assert os.environ['XDG_RUNTIME_DIR'] == f'/run/user/{os.getuid()}'
    assert os.environ['DBUS_SESSION_BUS_ADDRESS'] == f'unix:path=/run/user/{os.getuid()}/bus'
    assert not os.environ.get('SNIPPETS_SUPPORT_DIR')
    root = args.directory.absolute()
    assert root.parent == home
    root.mkdir(mode=0o700, exist_ok=False)
    (root / 'data').mkdir(mode=0o700)
    os.environ.update(XDG_DATA_HOME=str(root / 'data'), WAYLAND_DISPLAY='snippets-lab',
                      GTK_IM_MODULE='wayland', GDK_BACKEND='wayland', GTK_A11Y='none')
    os.environ.pop('DISPLAY', None)
    import gi
    gi.require_version('Gtk', '4.0')
    from gi.repository import Gio, GLib, Gtk, Gdk, GObject
    import pyatspi
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def call(dest, path, interface, method, parameters=None):
        return bus.call_sync(dest, path, interface, method, parameters, None, 0, 3000, None)

    shell_pid = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                     'GetConnectionUnixProcessID', GLib.Variant('(s)', ('org.gnome.Shell',))).unpack()[0]
    assert Path(f'/proc/{shell_pid}').stat().st_uid == os.getuid()
    assert b'--headless' in Path(f'/proc/{shell_pid}/cmdline').read_bytes().split(b'\0')
    assert not call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                    'NameHasOwner', GLib.Variant('(s)', ('com.khm.snippets.linux',))).unpack()[0]

    def settle(seconds=0.1):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.01)

    def wait(test, description):
        end = time.monotonic() + 15
        while not test():
            if time.monotonic() >= end:
                print('History UI on failure:', [(n.getRoleName(), n.name) for n in nodes(history())] if history() else 'absent', flush=True)
                raise AssertionError(description)
            settle()

    def nodes(node, depth=0):
        if depth > 48:
            return
        yield node
        for child in node:
            yield from nodes(child, depth + 1)

    def history():
        for app in pyatspi.Registry.getDesktop(0):
            for window in app:
                if window.name == 'Clipboard History' and window.getState().contains(pyatspi.STATE_SHOWING):
                    return window
        return None

    def find(name, role=None):
        window = history()
        if window:
            return next((node for node in nodes(window) if node.name == name and
                         (role is None or node.getRoleName() == role)), None)
        return None

    def click(name):
        wait(lambda: find(name, 'button'), 'missing ' + name)
        assert find(name, 'button').queryAction().doAction(0)
        settle(0.3)

    remote_dest = 'org.gnome.Mutter.RemoteDesktop'
    remote_path = call(remote_dest, '/org/gnome/Mutter/RemoteDesktop', remote_dest, 'CreateSession').unpack()[0]

    def remote(method, parameters=None):
        return call(remote_dest, remote_path, remote_dest + '.Session', method, parameters)

    def chord(*codes):
        for code in codes:
            remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (code, True)))
        for code in reversed(codes):
            remote('NotifyKeyboardKeycode', GLib.Variant('(ub)', (code, False)))
        settle(0.3)

    def focus_producer():
        call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
             GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))))
        window.present()
        settle(0.5)
        for _ in range(4):
            if window.is_active():
                break
            chord(56, 1)
        wait(window.is_active, 'producer keyboard focus')
        entry.grab_focus()
        settle(0.5)

    def publish(text):
        assert window.is_active(), 'clipboard producer must own focus'
        assert window.get_display().get_clipboard().set_content(
            Gdk.ContentProvider.new_for_value(GObject.Value(GObject.TYPE_STRING, text)))
        settle(0.5)

    def close_history():
        assert history().getState().contains(pyatspi.STATE_ACTIVE)
        chord(56, 62)
        wait(window.is_active, 'producer focus after closing history')
        entry.grab_focus()
        settle(0.3)

    def open_history():
        subprocess.run([str(binary), '--clipboard-history'], env=gui_env, stdout=log, stderr=log, check=True, timeout=8)
        wait(lambda: history(), 'history reopened')
        settle(0.5)
        # A command launched without an activation token need not steal focus.
        # Cycle the owned lab windows, observing focus after each real key chord.
        for _ in range(4):
            if history().getState().contains(pyatspi.STATE_ACTIVE):
                break
            chord(56, 1)  # Alt+Escape
            settle(0.3)
        wait(lambda: history() and history().getState().contains(pyatspi.STATE_ACTIVE), 'history activation')
        settle(0.5)
        click('Refresh')

    def encrypted():
        return image.read_bytes() if image.exists() else None

    def unchanged(before):
        settle(1.6)
        assert encrypted() == before, 'refused clipboard offer altered history'

    def exclusions(values):
        click('App Exclusions…')
        wait(lambda: any(n.getRoleName() == 'text' and n.getState().contains(pyatspi.STATE_EDITABLE)
                         for n in nodes(history())), 'exclusions editor')
        editor = next(n for n in nodes(history()) if n.getRoleName() == 'text' and
                      n.getState().contains(pyatspi.STATE_EDITABLE))
        assert editor.queryEditableText().setTextContents('\n'.join(values))
        click('Save Exclusions')

    binary = home / '.local/bin/snippets'
    gui_env = dict(os.environ)
    gui_env.pop('GTK_A11Y')
    gui = None
    browser = None
    window = None
    log = (root / 'application.log').open('w')
    try:
        remote('Start')
        chord(42)
        Gtk.init()
        producer = Gtk.Application(application_id='com.khm.snippets.historyfixture')
        assert producer.register(None)
        window = Gtk.ApplicationWindow(application=producer, title='Public clipboard history producer')
        entry = Gtk.Entry()
        window.set_child(entry)
        window.set_default_size(600, 220)
        window.present()
        entry.grab_focus()
        call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
             GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))))
        wait(window.is_active, 'producer focus')
        publish('Public pre-existing clipboard')
        gui = subprocess.Popen([str(binary), '--clipboard-history'], env=gui_env, stdout=log, stderr=log)
        click('Enable Clipboard History…')
        click('Enable')
        wait(lambda: find('Collecting new text copies · retained locally for seven days.'), 'collector ready')
        image = root / 'data/snippets/ClipboardHistory/history.bin'
        assert not image.exists(), 'pre-existing clipboard was imported'
        close_history()
        body = 'Public GNOME retained clipboard ✓'
        publish(body)
        wait(image.exists, 'encrypted history was not saved')
        assert body.encode() not in encrypted(), 'plaintext history payload on disk'
        assert gui.poll() is None, 'closing history quit the collector'
        open_history()
        wait(lambda: find(body), 'retained text did not decrypt into history UI')
        preference_file = root / 'data/snippets/clipboard-history.json'
        original_exclusions = json.loads(preference_file.read_text())['excludedApps']
        exclusions(original_exclusions + ['com.khm.snippets.historyfixture'])
        close_history()
        before = encrypted()
        publish('Public excluded application copy')
        unchanged(before)
        open_history()
        exclusions(original_exclusions)
        close_history()
        entry.set_visibility(False)
        entry.set_input_purpose(Gtk.InputPurpose.PASSWORD)
        settle(0.3)
        publish('Public password-field fixture')
        unchanged(before)
        entry.set_visibility(True)
        entry.set_input_purpose(Gtk.InputPurpose.FREE_FORM)
        settle(0.3)
        sensitive = Gdk.ContentProvider.new_union([
            Gdk.ContentProvider.new_for_value(GObject.Value(GObject.TYPE_STRING, 'Public marked-sensitive copy')),
            Gdk.ContentProvider.new_for_bytes('application/x-keepassxc', GLib.Bytes.new(b'public marker')),
        ])
        assert window.get_display().get_clipboard().set_content(sensitive)
        unchanged(before)
        call('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
             'DisableExtension', GLib.Variant('(s)', ('snippets@wowlocal.github.io',)))
        publish('Public disabled-companion copy')
        unchanged(before)
        call('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
             'EnableExtension', GLib.Variant('(s)', ('snippets@wowlocal.github.io',)))
        unchanged(before)  # Reconnection must skip that existing offer.
        publish('Public copy after companion restart')
        wait(lambda: encrypted() != before, 'collection did not reconnect')
        open_history()
        wait(lambda: find('Public copy after companion restart'), 'reconnected entry missing')
        close_history()
        before = encrypted()
        gui.terminate()
        gui.wait(timeout=8)
        publish('Public copy while collector stopped')
        gui = subprocess.Popen([str(binary), '--clipboard-history'], env=gui_env, stdout=log, stderr=log)
        wait(lambda: history(), 'restarted history')
        wait(lambda: find('Collecting new text copies · retained locally for seven days.'), 'restarted collector')
        close_history()
        unchanged(before)
        publish('Public copy after application restart')
        wait(lambda: encrypted() != before, 'collector did not resume after application restart')
        open_history()
        wait(lambda: find('Public copy after application restart'), 'restart entry missing')
        row = find('Public copy after application restart')
        while row.getRoleName() != 'list item':
            row = row.parent
            assert row is not None
        assert row.parent.querySelection().selectChild(row.getIndexInParent())
        click('Copy')
        copied = []
        clipboard = window.get_display().get_clipboard()
        clipboard.read_text_async(None, lambda cb, result: copied.append(cb.read_text_finish(result)))
        wait(lambda: bool(copied), 'history clipboard read')
        assert copied == ['Public copy after application restart']
        before = encrypted()
        unchanged(before)
        click('Clear History…')
        click('Clear History')
        wait(lambda: not image.exists(), 'history clear persistence')
        click('Refresh')
        assert not find(body) and not find('Public copy after application restart')
        close_history()

        print('PASS: restart baseline/recovery, literal Copy without recapture and Clear', flush=True)

        # Drive a genuine delayed GTK offer, then cancel an in-flight read.
        provider_path = root / 'provider.so'
        flags = shlex.split(subprocess.check_output(['pkg-config', '--cflags', '--libs', 'gtk4'], text=True))
        subprocess.run(['cc', '-shared', '-fPIC', '-Wall', '-Wextra', '-Werror',
                        str(Path(__file__).with_name('gnome_clipboard_provider.c')),
                        '-o', str(provider_path), *flags], check=True)
        native = ctypes.CDLL(str(provider_path))
        native.snippets_delayed_provider_get_type.restype = ctypes.c_size_t
        assert native.snippets_delayed_provider_get_type()
        provider_type = GObject.type_from_name('SnippetsDelayedProvider')
        for cancellation in ['focus', 'shield', 'disable']:
            focus_producer()
            before = encrypted()
            delayed = GObject.new(provider_type)
            assert clipboard.set_content(delayed)
            wait(lambda: delayed.get_property('requests') > 0, 'history transfer did not start')
            if cancellation == 'focus':
                other = Gtk.Window(title='Public cancellation target')
                other.set_child(Gtk.Entry())
                other.present()
                wait(other.is_active, 'other window focus')
            elif cancellation == 'shield':
                for active in [True, False]:
                    call('org.gnome.Shell', '/org/gnome/ScreenSaver', 'org.gnome.ScreenSaver',
                         'SetActive', GLib.Variant('(b)', (active,)))
            else:
                call('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
                     'DisableExtension', GLib.Variant('(s)', ('snippets@wowlocal.github.io',)))
            unchanged(before)
            print('PASS: pending history read cancelled by ' + cancellation, flush=True)
            if cancellation == 'focus':
                other.destroy()
            if cancellation == 'disable':
                call('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions', 'org.gnome.Shell.Extensions',
                     'EnableExtension', GLib.Variant('(s)', ('snippets@wowlocal.github.io',)))
            settle(0.5)
        focus_producer()
        publish('Public recovered history after cancellation')
        wait(lambda: encrypted() != before, 'collector recovery after cancelled transfers')

        # Prepopulate only this fictional page; Ctrl+A/C uses Chromium's real clipboard path.
        browser_body = 'Public Chromium history copy ✓'
        page = root / 'clipboard.html'
        page.write_text('<!doctype html><meta charset="utf-8"><title>Public history browser</title>'
                        '<textarea autofocus>' + html.escape(browser_body) + '</textarea>')
        before = encrypted()
        browser = subprocess.Popen([
            '/snap/chromium/current/usr/lib/chromium-browser/chrome',
            '--ozone-platform=wayland', '--enable-wayland-ime', '--wayland-text-input-version=3',
            '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
            '--password-store=basic', '--start-maximized',
            '--user-data-dir=' + str(root / 'chromium-profile'), page.as_uri()],
            env=gui_env, stdout=log, stderr=log)
        wait(lambda: not window.is_active(), 'Chromium focus')
        settle(2)
        assert browser.poll() is None
        chord(29, 30)  # Ctrl+A
        chord(29, 46)  # Ctrl+C
        wait(lambda: encrypted() != before, 'Chromium copy was not retained')
        browser.terminate()
        browser.wait(timeout=8)
        open_history()
        wait(lambda: find(browser_body), 'Chromium copy did not decrypt exactly')
        print('PASS: application restart baseline/recovery, literal Copy, Clear, pending focus/shield/disable cancellation and native Chromium Copy', flush=True)
        click('Turn Off Collection')
        close_history()
        before = encrypted()
        publish('Public copy after opting out')
        unchanged(before)
        print('PASS: consent, baseline, closed-window collection, encrypted disk/decrypted UI, exclusions, password/MIME privacy, companion recovery and opt-out', flush=True)
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=8)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait()
        if gui and gui.poll() is None:
            gui.terminate()
            try:
                gui.wait(timeout=8)
            except subprocess.TimeoutExpired:
                gui.kill()
                gui.wait()
        if window:
            window.destroy()
        remote('Stop')
        log.close()


if __name__ == '__main__':
    main()
