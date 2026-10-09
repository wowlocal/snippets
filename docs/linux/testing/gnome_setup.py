#!/usr/bin/env python3
"""Settings UI + real Shell/IBus activation in an owned headless lab.

The lab has no systemd user manager. A narrow D-Bus fixture supplies its read-only
service properties and records Reload; it never restarts the user's services.
This qualifies the UI/protocol and real input-source activation, not a login.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('lab', type=Path)
    parser.add_argument('prefix', type=Path)
    args = parser.parse_args()
    root = args.lab.absolute()
    env = json.loads((root / 'environment.json').read_text())
    assert env['XDG_RUNTIME_DIR'] == str(root / 'runtime')
    assert env['XDG_DATA_HOME'] == str(root / 'data')
    assert env['WAYLAND_DISPLAY'] == 'snippets-lab'
    os.environ.update(env)
    os.environ.pop('DISPLAY', None)
    import gi
    from gi.repository import Gio, GLib
    import pyatspi
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)

    def call(dest, path, interface, method, args=None):
        return bus.call_sync(dest, path, interface, method, args, None, 0, 3000, None)

    def shell_extensions(method):
        return call('org.gnome.Shell.Extensions', '/org/gnome/Shell/Extensions',
                    'org.gnome.Shell.Extensions', method, GLib.Variant('(s)', ('snippets@wowlocal.github.io',)))

    # Never replace any existing owner, even in the private lab.
    owner = call('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                 'RequestName', GLib.Variant('(su)', ('org.freedesktop.systemd1', 4))).unpack()[0]
    assert owner == 1
    state = {'files': [('/public/custom.env', False)], 'reload': 0}
    manager = '/org/freedesktop/systemd1'
    unit = manager + '/unit/public_fixture'
    interfaces = Gio.DBusNodeInfo.new_for_xml('''<node>
<interface name="org.freedesktop.systemd1.Manager">
<method name="LoadUnit"><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<method name="Reload"/>
<property name="Environment" type="as" access="read"/>
</interface>
<interface name="org.freedesktop.systemd1.Service">
<property name="EnvironmentFiles" type="a(sb)" access="read"/>
<property name="Environment" type="as" access="read"/>
<property name="UnsetEnvironment" type="as" access="read"/>
</interface>
<interface name="org.freedesktop.systemd1.Unit"><property name="NeedDaemonReload" type="b" access="read"/></interface>
</node>''').interfaces

    def method(_bus, _sender, _path, _interface, name, parameters, invocation):
        if name == 'LoadUnit':
            assert parameters.unpack() == ('org.freedesktop.IBus.session.GNOME.service',)
            invocation.return_value(GLib.Variant('(o)', (unit,)))
        elif name == 'Reload':
            state['reload'] += 1
            invocation.return_value(None)
        else:
            raise AssertionError(name)

    def prop(_bus, _sender, _path, interface, name):
        if name == 'EnvironmentFiles':
            return GLib.Variant('a(sb)', state['files'])
        if name == 'UnsetEnvironment':
            return GLib.Variant('as', [])
        if name == 'NeedDaemonReload':
            return GLib.Variant('b', False)
        assert name == 'Environment'
        value = '/opt/public/custom:/opt/public/custom' if interface.endswith('.Service') else '/opt/public/manager'
        return GLib.Variant('as', ['IBUS_COMPONENT_PATH=' + value])

    objects = [bus.register_object(manager if i.name.endswith('.Manager') else unit,
                                  i, method, prop, None) for i in interfaces]
    desktop = Gio.Settings.new('org.gnome.desktop.input-sources')
    old_sources = desktop.get_value('sources')
    desktop.set_value('sources', GLib.Variant('a(ss)', [('xkb', 'us'), ('xkb', 'ru')]))
    shell_extensions('DisableExtension')
    connection = call('org.gnome.Mutter.RemoteDesktop', '/org/gnome/Mutter/RemoteDesktop',
                      'org.gnome.Mutter.RemoteDesktop', 'CreateSession').unpack()[0]
    call('org.gnome.Mutter.RemoteDesktop', connection, 'org.gnome.Mutter.RemoteDesktop.Session', 'Start')
    for pressed in [True, False]:
        call('org.gnome.Mutter.RemoteDesktop', connection, 'org.gnome.Mutter.RemoteDesktop.Session',
             'NotifyKeyboardKeycode', GLib.Variant('(ub)', (42, pressed)))
    call('org.gnome.Shell', '/org/gnome/Shell', 'org.freedesktop.DBus.Properties', 'Set',
         GLib.Variant('(ssv)', ('org.gnome.Shell', 'OverviewActive', GLib.Variant('b', False))))

    def settle():
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        time.sleep(0.02)

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
                        if node.name == name and (not role or node.getRoleName() == role):
                            return node
        return None

    def wait(test, description):
        end = time.monotonic() + 15
        while not test():
            if time.monotonic() > end:
                for app in pyatspi.Registry.getDesktop(0):
                    for window in app:
                        if window.name == 'Settings':
                            print(sorted({(n.getRoleName(), n.name) for n in nodes(window) if n.name}), flush=True)
                raise AssertionError(description)
            settle()

    def click(name, role='button'):
        wait(lambda: find(name, role), 'missing ' + name)
        assert find(name, role).queryAction().doAction(0)
        end = time.monotonic() + 0.3
        while time.monotonic() < end:
            settle()

    config = root / 'config/systemd/user/org.freedesktop.IBus.session.GNOME.service.d/90-snippets.conf'
    assert not config.exists(), 'use a fresh lab for setup test'
    log = (root / 'setup-ui.log').open('w')
    gui = subprocess.Popen([str(args.prefix / 'bin/snippets'), '--settings'],
                           env=dict(os.environ, GTK_IM_MODULE='wayland'), stdout=log, stderr=log)
    try:
        click('GNOME Integration', 'page tab')
        click('Prepare Integration')
        wait(lambda: find('IBus has custom or unapplied service settings. Review them before configuring Snippets; existing settings were preserved.'), 'custom service warning')
        assert not config.exists() and state['reload'] == 0
        state['files'] = []
        click('Prepare Integration')
        wait(lambda: state['reload'] == 1, 'setup did not request reload')
        before = config.read_bytes()
        paths = json.loads(before.decode().splitlines()[1][2:])
        assert paths == [str(args.prefix / 'share/ibus/component'), '/opt/public/custom', '/usr/share/ibus/component']
        wait(lambda: find('Integration is prepared. Sign out and back in, then return here and choose Enable Integration.'), 'missing honest login status')
        assert desktop.get_value('sources').unpack() == [('xkb', 'us'), ('xkb', 'ru')]
        click('Prepare Integration')
        wait(lambda: state['reload'] == 2, 'repeat preparation')
        assert config.read_bytes() == before
        click('Enable Integration')
        wait(lambda: find('Snippets input is selected and the companion is enabled. Enable Inline Expansion separately in Input & Clipboard.'), 'actual source activation')
        wait(lambda: desktop.get_value('sources').unpack() == [('xkb', 'us'), ('xkb', 'ru'), ('ibus', 'snippets')], 'preserved sources after external change')
        gi.require_version('IBus', '1.0')
        from gi.repository import IBus
        IBus.init()
        ibus = IBus.Bus.new()
        wait(lambda: ibus.get_global_engine() and ibus.get_global_engine().get_name() == 'snippets', 'actual IBus engine selection')
        click('Enable Integration')
        wait(lambda: find('Snippets input is selected and the companion is enabled. Enable Inline Expansion separately in Input & Clipboard.'), 'repeat activation')
        assert len(desktop.get_value('sources').unpack()) == 3
        print('GNOME setup UI: custom service refusal, explicit files, idempotence, real companion enablement and IBus selection with preserved US/RU sources passed', flush=True)
    finally:
        gui.terminate()
        try:
            gui.wait(timeout=8)
        except subprocess.TimeoutExpired:
            gui.kill(); gui.wait()
        desktop.set_value('sources', old_sources)
        call('org.gnome.Mutter.RemoteDesktop', connection, 'org.gnome.Mutter.RemoteDesktop.Session', 'Stop')
        for obj in objects:
            bus.unregister_object(obj)
        if config.exists():
            config.unlink()  # This fresh-lab fixture created the file.
        log.close()


if __name__ == '__main__':
    main()
