"""A fictional GNOME Shell on a private session bus: owns org.gnome.Shell and
serves the org.gnome.ScreenSaver lock state the IBus engine checks.
SetActive(b) changes it and emits ActiveChanged, as the real Shell does."""

import sys

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

XML = """
<node>
  <interface name="org.gnome.ScreenSaver">
    <method name="GetActive"><arg type="b" direction="out"/></method>
    <method name="SetActive"><arg type="b" direction="in"/></method>
    <signal name="ActiveChanged"><arg type="b"/></signal>
  </interface>
</node>
"""

active = False


def call(connection, sender, path, interface, method, parameters, invocation):
    global active
    if method == "GetActive":
        invocation.return_value(GLib.Variant("(b)", (active,)))
    elif method == "SetActive":
        active = parameters.unpack()[0]
        connection.emit_signal(
            None, path, interface, "ActiveChanged", GLib.Variant("(b)", (active,))
        )
        invocation.return_value(None)


def main():
    loop = GLib.MainLoop()
    info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]

    def acquired(connection, name):
        connection.register_object("/org/gnome/ScreenSaver", info, call, None, None)
        print("READY", flush=True)

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        "org.gnome.Shell",
        Gio.BusNameOwnerFlags.NONE,
        None,
        acquired,
        lambda *_: (print("name lost", file=sys.stderr), loop.quit()),
    )
    loop.run()


if __name__ == "__main__":
    main()
