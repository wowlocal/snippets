#!/usr/bin/env python3
"""Exercise the real Linux installer with built artifacts and disposable prefixes."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target-dir', required=True, type=Path)
    parser.add_argument('--desktop', choices=('gnome', 'hyprland'), default='gnome')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    target = args.target_dir.resolve()
    spec = importlib.util.spec_from_file_location('metadata', repo / 'scripts/linux-install-metadata.py')
    metadata = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(metadata)
    import gi
    gi.require_version('Gio', '2.0')
    from gi.repository import Gio, GLib

    with tempfile.TemporaryDirectory(prefix='snippets-install-check-') as directory:
        root = Path(directory)
        # All metacharacters remain ordinary path characters, even when the
        # desktop entry is launched by GLib rather than our own parser.
        prefix = root / '''Public space ' " $ ` % \\ & (test)'''
        env = dict(os.environ, CARGO_TARGET_DIR=str(target),
                   SNIPPETS_SUPPORT_DIR=str(root / 'library'),
                   XDG_CONFIG_HOME=str(root / 'config'))
        command = ['bash', str(repo / 'scripts/install-linux.sh'), '--no-build',
                   '--prefix', str(prefix), '--desktop', args.desktop]
        subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
        destination = prefix / 'share/snippets-linux'
        names = ['snippets', 'snippets-cli', 'snippets-owner-auth']
        if args.desktop == 'gnome':
            names.append('snippets-ibus')
        for name in names:
            installed = destination / name
            assert installed.is_file() and not installed.is_symlink()
            assert installed.stat().st_nlink == 1
            assert installed.stat().st_mode & 0o777 == 0o755
            assert hashlib.sha256(installed.read_bytes()).digest() == hashlib.sha256(
                (target / 'release' / name).read_bytes()).digest()
        for name in ('snippets', 'snippets-cli'):
            assert (prefix / 'bin' / name).resolve() == destination / name
        entry = prefix / 'share/applications/com.khm.snippets.linux.desktop'
        subprocess.run(['desktop-file-validate', str(entry)], check=True)
        if args.desktop == 'gnome':
            assert not (prefix / 'share/fcitx5').exists()
            assert not (destination / 'libsnippets-fcitx.so').exists()
            xml = prefix / 'share/ibus/component/snippets.xml'
            component = ET.parse(xml).getroot()
            assert shlex.split(component.findtext('exec')) == [str(destination / 'snippets-ibus'), '--ibus']
            gi.require_version('IBus', '1.0')
            from gi.repository import IBus
            actual = IBus.Component.new_from_file(str(xml))
            assert actual and actual.get_name() == 'org.freedesktop.IBus.Snippets'
            assert GLib.shell_parse_argv(actual.get_exec())[1] == [str(destination / 'snippets-ibus'), '--ibus']
            assert actual.get_engines()[0].get_name() == 'snippets'
            extension = prefix / 'share/gnome-shell/extensions/snippets@wowlocal.github.io'
            assert json.loads((extension / 'metadata.json').read_text())['shell-version'] == ['50']
            assert (extension / 'extension.js').read_bytes() == (
                repo / 'snippets-linux/gnome/snippets@wowlocal.github.io/extension.js').read_bytes()
        else:
            assert not (prefix / 'share/ibus').exists()
            assert not (prefix / 'share/gnome-shell').exists()
            assert (prefix / 'share/fcitx5/addon/snippets.conf').is_file()

        # Reinstallation must replace files atomically without modifying data or
        # opt-in preferences. No GUI, input service, or live library is started.
        subprocess.run(command, env=env, check=True, stdout=subprocess.DEVNULL)
        assert not (root / 'library').exists() and not (root / 'config').exists()
        receipt = root / 'argv.json'
        destination.joinpath('snippets').write_text(
            '#!/usr/bin/python3\nimport json,sys\nfrom pathlib import Path\n'
            f'Path({str(receipt)!r}).write_text(json.dumps(sys.argv))\n')
        destination.joinpath('snippets').chmod(0o755)
        launch_entry = root / 'launch.desktop'
        launch_entry.write_text(entry.read_text().replace('StartupNotify=true', 'StartupNotify=false'))
        app = Gio.DesktopAppInfo.new_from_filename(str(launch_entry))
        assert app
        for action, expected in [(None, []), ('Picker', ['--picker']), ('Settings', ['--settings'])]:
            receipt.unlink(missing_ok=True)
            if action:
                app.launch_action(action, None)
            else:
                assert app.launch([], None)
            deadline = time.monotonic() + 5
            while not receipt.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            # Atomicity is unnecessary for the fictional receipt; wait until
            # the short-lived child has written its complete JSON.
            time.sleep(0.05)
            assert json.loads(receipt.read_text()) == [str(destination / 'snippets'), *expected]
        for invalid in ('relative', '/tmp/bad\npath', '/tmp/bad=path'):
            try:
                metadata.desktop_argument(Path(invalid))
            except ValueError:
                continue
            raise AssertionError('invalid desktop path accepted')
        if args.desktop == 'gnome':
            incomplete = root / 'incomplete/release'
            incomplete.mkdir(parents=True)
            for name in ('snippets', 'snippets-cli', 'snippets-owner-auth'):
                (incomplete / name).write_text('not executed')
                (incomplete / name).chmod(0o755)
            refused = root / 'refused-prefix'
            missing = subprocess.run(command[:-4] + ['--prefix', str(refused), '--desktop', 'gnome'],
                                     env=dict(env, CARGO_TARGET_DIR=str(incomplete.parent)),
                                     capture_output=True, text=True)
            assert missing.returncode != 0 and not refused.exists()
            assert 'Release executables are missing or linked' in missing.stderr
        print(f'{args.desktop} installer: real artifacts, isolated reinstall, metadata parsers and GLib desktop launch passed')


if __name__ == '__main__':
    main()
