#!/usr/bin/env python3
"""An owned, headless GNOME/IBus session; never reconfigure the user's session.

Run in the Ubuntu guest. environment.json is for child test commands only.
Terminate this supervisor to clean up its process groups. All desktop preferences,
runtime sockets, application data and logs stay inside the supplied directory.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import time
from xml.sax.saxutils import escape


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--extension", type=Path, help="stage the Snippets companion in this lab only")
    args = parser.parse_args()
    root = args.directory.absolute()
    root.mkdir(mode=0o700, parents=True, exist_ok=False)
    children = []
    logs = []
    stopping = False

    def stop(_signum, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    env = os.environ.copy()
    for key in ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS",
                "DBUS_STARTER_ADDRESS", "DBUS_STARTER_BUS_TYPE",
                "HYPRLAND_INSTANCE_SIGNATURE", "SESSION_MANAGER", "IBUS_ADDRESS"):
        env.pop(key, None)
    for key, folder in [("XDG_RUNTIME_DIR", "runtime"), ("XDG_CONFIG_HOME", "config"),
                        ("XDG_CACHE_HOME", "cache"), ("XDG_DATA_HOME", "data"),
                        ("XDG_STATE_HOME", "state"), ("SNIPPETS_SUPPORT_DIR", "library")]:
        path = root / folder
        path.mkdir(mode=0o700)
        env[key] = str(path)
    env.update(XDG_CURRENT_DESKTOP="GNOME", XDG_SESSION_TYPE="wayland",
               GSETTINGS_BACKEND="keyfile", GNOME_SHELL_SESSION_MODE="user",
               WAYLAND_DISPLAY="snippets-lab",
               IBUS_ADDRESS=f"unix:path={root}/runtime/ibus-bus")
    if args.extension:
        metadata = json.loads((args.extension / "metadata.json").read_text())
        assert metadata["uuid"] == "snippets@wowlocal.github.io"
        destination = root / "data/gnome-shell/extensions" / metadata["uuid"]
        destination.mkdir(parents=True)
        for name in ("metadata.json", "extension.js"):
            shutil.copy2(args.extension / name, destination / name)
    components = root / "data/ibus/component"
    components.mkdir(parents=True)
    env["IBUS_COMPONENT_PATH"] = f"{components}:/usr/share/ibus/component"
    # The test runner supplies this owned symlink while a fixture is running.
    executable = escape(str(root / "engine-current/snippets-ibus"))
    (components / "snippets.xml").write_text(f'''<component>
<name>org.freedesktop.IBus.Snippets</name><description>Snippets lab</description>
<exec>{executable} --ibus</exec><version>0.1.0</version><license>MIT</license>
<author>Snippets</author><homepage></homepage><textdomain></textdomain>
<engines><engine><name>snippets</name><longname>Snippets</longname>
<description>Snippets lab</description><language>en</language><license>MIT</license>
<author>Snippets</author><layout>default</layout><icon></icon></engine></engines>
</component>''')

    def spawn(name, command, stdout=None):
        log = (root / f"{name}.log").open("wb")
        logs.append(log)
        child = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                 stdout=stdout if stdout is not None else log,
                                 stderr=log, start_new_session=True)
        children.append(child)
        return child

    def call(destination, path, method, *arguments):
        return subprocess.run(["gdbus", "call", "--session", "--dest", destination,
                               "--object-path", path, "--method", method, *arguments],
                              env=env, capture_output=True, timeout=3)

    try:
        bus = spawn("bus", ["dbus-daemon", "--session", "--nofork", "--print-address=1"],
                    subprocess.PIPE)
        address = bus.stdout.readline().decode().strip()
        if not address.startswith("unix:"):
            raise RuntimeError("private D-Bus did not publish an address")
        env["DBUS_SESSION_BUS_ADDRESS"] = address
        bus.stdout.close()
        # This engine bus belongs only to the lab. Never use --replace.
        spawn("ibus", ["ibus-daemon", "--single", "--emoji-extension=disable",
                       "--address", env["IBUS_ADDRESS"], "--cache=none"])
        for schema, key, value in [
            ("org.gnome.desktop.session", "idle-delay", "uint32 0"),
            ("org.gnome.desktop.screensaver", "lock-enabled", "false"),
            ("org.gnome.desktop.interface", "enable-animations", "false"),
            ("org.gnome.desktop.input-sources", "sources", "[('xkb', 'us')]"),
        ]:
            subprocess.run(["gsettings", "set", schema, key, value], env=env, check=True)
        if args.extension:
            subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions",
                            "['snippets@wowlocal.github.io']"], env=env, check=True)
        spawn("shell", ["gnome-shell", "--headless", "--no-x11",
                        "--virtual-monitor", "1280x800", "--wayland-display", "snippets-lab"])
        env["WAYLAND_DISPLAY"] = "snippets-lab"
        deadline = time.monotonic() + 40
        while not stopping:
            if any(child.poll() is not None for child in children):
                raise RuntimeError("a lab service exited; inspect the owned log directory")
            reply = call("org.gnome.Shell", "/org/gnome/ScreenSaver",
                         "org.gnome.ScreenSaver.GetActive")
            if reply.returncode == 0 and reply.stdout.strip() == b"(false,)":
                break
            if time.monotonic() > deadline:
                raise RuntimeError("headless GNOME did not become ready")
            time.sleep(0.1)
        if stopping:
            return
        (root / "environment.json").write_text(json.dumps({
            key: value for key, value in env.items()
            if key.startswith("XDG_") or key in {
                "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "IBUS_ADDRESS",
                "IBUS_COMPONENT_PATH",
                "GSETTINGS_BACKEND", "GNOME_SHELL_SESSION_MODE", "SNIPPETS_SUPPORT_DIR"
            }
        }, indent=2) + "\n")
        print(f"GNOME lab ready: {root}", flush=True)
        while not stopping:
            if any(child.poll() is not None for child in children):
                raise RuntimeError("a lab service exited")
            time.sleep(0.2)
    finally:
        (root / "environment.json").unlink(missing_ok=True)
        for child in reversed(children):
            # Descendants inherit the owned process group even if their parent
            # has exited. This never targets the user's desktop processes.
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        for child in children:
            try:
                child.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        for log in logs:
            log.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
