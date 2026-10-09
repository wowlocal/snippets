#!/usr/bin/env python3
"""Two-phase Settings test in the disposable systemd-managed GNOME account.

Run prepare, restart the owned GNOME session, then run enable. This intentionally
refuses the normal user's account and never starts or stops desktop services.
See README.md for the headless session setup and the limits of this test.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('phase', choices=['prepare', 'upgrade', 'enable'])
    args = parser.parse_args()
    account = pwd.getpwuid(os.getuid())
    assert account.pw_name == 'snippets-gnome-test'
    home = Path(account.pw_dir)
    assert home == Path('/var/lib/snippets-gnome-test')
    runtime = Path(f'/run/user/{os.getuid()}')
    assert os.environ['XDG_RUNTIME_DIR'] == str(runtime)
    assert os.environ['DBUS_SESSION_BUS_ADDRESS'] == f'unix:path={runtime}/bus'
    assert os.environ['WAYLAND_DISPLAY'] == 'snippets-lab'
    assert not os.environ.get('SNIPPETS_SUPPORT_DIR')
    assert not os.environ.get('IBUS_COMPONENT_PATH')
    os.environ.pop('DISPLAY', None)
    import gi
    gi.require_version('IBus', '1.0')
    from gi.repository import Gio, GLib, IBus
    import pyatspi
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def call(dest, path, interface, method, parameters=None):
        return bus.call_sync(dest, path, interface, method, parameters, None, 0, 3000, None)

    def unit_property(unit, interface, prop):
        path = call('org.freedesktop.systemd1', '/org/freedesktop/systemd1',
                    'org.freedesktop.systemd1.Manager', 'LoadUnit',
                    GLib.Variant('(s)', (unit,))).unpack()[0]
        return call('org.freedesktop.systemd1', path, 'org.freedesktop.DBus.Properties',
                    'Get', GLib.Variant('(ss)', (interface, prop))).unpack()[0]

    service = 'org.freedesktop.IBus.session.GNOME.service'
    pid = unit_property(service, 'org.freedesktop.systemd1.Service', 'MainPID')
    assert pid > 0
    shell_pid = unit_property('org.gnome.Shell@ubuntu.service',
                              'org.freedesktop.systemd1.Service', 'MainPID')
    shell = Path(f'/proc/{shell_pid}')
    assert shell.stat().st_uid == os.getuid()
    assert b'--headless' in (shell / 'cmdline').read_bytes().split(b'\0')
    IBus.init()
    ibus = IBus.Bus.new()
    engines = {engine.get_name() for engine in ibus.list_engines()}
    sources = Gio.Settings.new('org.gnome.desktop.input-sources')
    expected_sources = [('xkb', 'us'), ('xkb', 'ru')]
    prefix = home / '.local'
    config = home / '.config/systemd/user' / (service + '.d/90-snippets.conf')
    receipt = home / 'setup-receipt.json'
    if args.phase != 'enable':
        assert 'snippets' not in engines
        if args.phase == 'prepare':
            assert not config.exists() and not receipt.exists()
        else:
            assert config.read_text().startswith('# Snippets GNOME integration v1\n')
        assert sources.get_value('sources').unpack() == expected_sources
    else:
        previous = json.loads(receipt.read_text())
        assert previous['ibus_pid'] != pid and previous['shell_pid'] != shell_pid
        assert 'snippets' in engines
        assert sources.get_value('sources').unpack() == expected_sources
        effective = (Path(f'/proc/{pid}') / 'environ').read_bytes().split(b'\0')
        expected = f'IBUS_COMPONENT_PATH={prefix}/share/ibus/component:/usr/share/ibus/component'
        assert expected.encode() in effective

    connection = call('org.gnome.Mutter.RemoteDesktop', '/org/gnome/Mutter/RemoteDesktop',
                      'org.gnome.Mutter.RemoteDesktop', 'CreateSession').unpack()[0]
    def key(pressed):
        call('org.gnome.Mutter.RemoteDesktop', connection,
             'org.gnome.Mutter.RemoteDesktop.Session', 'NotifyKeyboardKeycode',
             GLib.Variant('(ub)', (42, pressed)))
    call('org.gnome.Mutter.RemoteDesktop', connection, 'org.gnome.Mutter.RemoteDesktop.Session', 'Start')
    key(True)
    key(False)
    call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
         GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))))

    def nodes(node, depth=0):
        if depth > 48:
            return
        yield node
        for child in node:
            yield from nodes(child, depth + 1)

    def find(name, role=None):
        for app in pyatspi.Registry.getDesktop(0):
            for window in app:
                if window.name == 'Settings':
                    for node in nodes(window):
                        if node.name == name and (role is None or node.getRoleName() == role):
                            return node
        return None

    def wait(test, description):
        deadline = time.monotonic() + 20
        while not test():
            assert time.monotonic() < deadline, description
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            time.sleep(0.03)

    def click(name, role='button'):
        wait(lambda: find(name, role), 'missing ' + name)
        assert find(name, role).queryAction().doAction(0)

    with (home / ('setup-' + args.phase + '.log')).open('w') as log:
        gui = subprocess.Popen([str(prefix / 'bin/snippets'), '--settings'],
                               env=dict(os.environ, GTK_IM_MODULE='wayland'), stdout=log, stderr=log)
        try:
            click('GNOME Integration', 'page tab')
            if args.phase != 'enable':
                click('Prepare Integration')
                wait(lambda: find('Integration is prepared. Sign out and back in, then return here and choose Enable Integration.'), 'preparation status')
                expected = [str(prefix / 'share/ibus/component'), '/usr/share/ibus/component']
                assert json.loads(config.read_text().splitlines()[1][2:]) == expected
                assert 'ExecStartPre=-/usr/bin/ibus write-cache\n' in config.read_text()
                assert unit_property(service, 'org.freedesktop.systemd1.Service', 'MainPID') == pid
                assert 'snippets' not in {engine.get_name() for engine in ibus.list_engines()}
                assert sources.get_value('sources').unpack() == expected_sources
                receipt.write_text(json.dumps({'ibus_pid': pid, 'shell_pid': shell_pid}))
                print('PASS: Settings prepared real systemd service; running IBus and input sources unchanged', flush=True)
            else:
                click('Enable Integration')
                wait(lambda: find('Snippets input is selected and the companion is enabled. Enable Inline Expansion separately in Input & Clipboard.'), 'activation status')
                wait(lambda: ibus.get_global_engine() and ibus.get_global_engine().get_name() == 'snippets', 'selected IBus engine')
                wait(lambda: sources.get_value('sources').unpack() == expected_sources + [('ibus', 'snippets')], 'preserved sources after asynchronous settings notification')
                print('PASS: new systemd GNOME session discovered installed engine; Settings enabled companion and selected Snippets while preserving US/RU', flush=True)
        finally:
            gui.terminate()
            try:
                gui.wait(timeout=8)
            except subprocess.TimeoutExpired:
                gui.kill()
                gui.wait()
            call('org.gnome.Mutter.RemoteDesktop', connection, 'org.gnome.Mutter.RemoteDesktop.Session', 'Stop')


if __name__ == '__main__':
    main()
