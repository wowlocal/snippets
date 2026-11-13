"""Drives the Snippets IBus engine through a private ibus-daemon, as an
application's input context would, and checks what it commits.

Usage: driver.py APP_LOG. Prints one JSON line per observation, so the
transcripts of two engine builds can be compared, and exits non-zero when a
scenario's expectation fails. See tests/ibus-engine-live.sh.
"""

import json
import os
import sys
import time

import gi

gi.require_version("IBus", "1.0")
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib, IBus  # noqa: E402

APP_LOG = sys.argv[1]
events = []
failures = []
context = GLib.MainContext.default()


def settle(quiet=0.15, limit=2.0):
    """Runs the loop until nothing has arrived for `quiet` seconds."""
    deadline = time.monotonic() + limit
    seen = len(events)
    last = time.monotonic()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if len(events) != seen:
            seen = len(events)
            last = time.monotonic()
        elif time.monotonic() - last >= quiet:
            return
        time.sleep(0.01)


def text_of(text):
    return text.get_text() if text is not None else None


def candidates(table):
    return [text_of(table.get_candidate(i)) for i in range(table.get_number_of_candidates())]


IBus.init()
bus = IBus.Bus.new()
if not bus.is_connected():
    sys.exit("ibus-daemon is not reachable")
ic = bus.create_input_context("snippets-engine-test")
ic.connect("commit-text", lambda _, t: events.append(["commit", text_of(t)]))
ic.connect("update-preedit-text", lambda _, t, cursor, visible: events.append(["preedit", text_of(t), cursor, visible]))
ic.connect(
    "update-preedit-text-with-mode",
    lambda _, t, cursor, visible, mode: events.append(["preedit", text_of(t), cursor, visible]),
)
ic.connect("show-preedit-text", lambda _: events.append(["preedit-shown"]))
ic.connect("hide-preedit-text", lambda _: events.append(["preedit-hidden"]))
ic.connect(
    "update-lookup-table",
    lambda _, table, visible: events.append(["table", candidates(table), table.get_cursor_pos(), visible]),
)
ic.connect("show-lookup-table", lambda _: events.append(["table-shown"]))
ic.connect("hide-lookup-table", lambda _: events.append(["table-hidden"]))
ic.set_capabilities(
    IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS | IBus.Capabilite.LOOKUP_TABLE
)
# IBus 1.5 uses one global engine, as GNOME's input sources do. Selecting it
# makes the daemon start the engine from its component.
if not bus.set_global_engine("snippets"):
    sys.exit("the snippets engine could not be selected")
ic.focus_in()
for _ in range(100):
    engine = ic.get_engine()
    if engine is not None and engine.get_name() == "snippets":
        break
    time.sleep(0.05)
else:
    sys.exit("the input context did not get the snippets engine")
settle()

shell = Gio.bus_get_sync(Gio.BusType.SESSION, None)


def set_locked(value):
    shell.call_sync(
        "org.gnome.Shell", "/org/gnome/ScreenSaver", "org.gnome.ScreenSaver", "SetActive",
        GLib.Variant("(b)", (value,)), None, Gio.DBusCallFlags.NONE, 1000, None,
    )


def app_log():
    try:
        with open(APP_LOG, encoding="utf-8") as source:
            lines = source.read().splitlines()
    except FileNotFoundError:
        lines = []
    open(APP_LOG, "w").close()
    return lines


NAMES = {"\\": "backslash", " ": "space"}


def keyval(key):
    return IBus.keyval_from_name(NAMES.get(key, key))


def press(key, state=0, wait=True):
    value = keyval(key)
    handled = ic.process_key_event(value, 0, state)
    released = ic.process_key_event(value, 0, state | IBus.ModifierType.RELEASE_MASK)
    events.append(["key", key, state, handled, released])
    if wait:
        settle()


def typing(text):
    for key in text:
        press(key)


def scenario(name, purpose=IBus.InputPurpose.FREE_FORM, hints=0):
    def decorate(body):
        ic.focus_out()
        settle()
        ic.focus_in()
        ic.set_content_type(purpose, hints)
        settle()
        app_log()
        events.clear()
        body()
        settle(limit=3.0)
        commits = [e[1] for e in events if e[0] == "commit"]
        for line in app_log():
            events.append(["app", line])
        for event in events:
            print(json.dumps([name] + event, ensure_ascii=False))
        expected = getattr(body, "expected", None)
        if expected is not None and commits != expected:
            failures.append(f"{name}: committed {commits!r}, expected {expected!r}")
        if getattr(body, "app_untouched", False) and any(e[0] == "app" for e in events):
            failures.append(f"{name}: the app was asked for something")
        return body

    return decorate


def expect(*commits):
    def decorate(body):
        body.expected = list(commits)
        return body

    return decorate


CONTROL = IBus.ModifierType.CONTROL_MASK


@scenario("expand-with-return")
@expect("Hello, world!")
def _():
    typing("\\hel")
    press("Return")


@scenario("escape-keeps-what-was-typed")
@expect("\\he")
def _():
    typing("\\he")
    press("Escape")


@scenario("password-field-passes-through", purpose=IBus.InputPurpose.PASSWORD)
@expect()
def _():
    typing("\\he")


@scenario("hidden-text-hint-passes-through", hints=1 << 12)
@expect()
def _():
    typing("\\he")


@scenario("arrow-then-tab-picks-second-row")
@expect("Ξυλόφωνο")
def _():
    typing("\\x")
    press("Down")
    press("Tab")


@scenario("control-n-p-navigation")
@expect("Ξυλόφωνο")
def _():
    typing("\\x")
    press("n", CONTROL)
    press("n", CONTROL)
    press("p", CONTROL)
    press("Return")


@scenario("space-ends-the-query-literally")
@expect("\\he ")
def _():
    typing("\\he ")


@scenario("second-backslash-is-literal")
@expect("\\\\")
def _():
    typing("\\\\")


@scenario("malformed-rows-become-literal")
@expect("\\b")
def _():
    typing("\\b")
    press("a")


@scenario("backspace-to-nothing-clears")
@expect()
def _():
    typing("\\he")
    for _ in range(3):
        press("BackSpace")
    press("BackSpace")


@scenario("backspace-then-retype")
@expect("How can I help?")
def _():
    typing("\\hex")
    press("BackSpace")
    typing("lp")
    press("Return")


@scenario("return-while-pending-accepts-the-first-row")
@expect("Slow and steady")
def _():
    press("\\")
    press("s", wait=False)
    press("Return", wait=False)
    settle(limit=3.0)


@scenario("down-while-pending-moves-once-rows-arrive")
@expect("Hang in there")
def _():
    press("\\")
    press("s", wait=False)
    press("Down", wait=False)
    settle(limit=3.0)
    press("Return")


@scenario("no-match-return-is-literal")
@expect("\\zz\n")
def _():
    typing("\\zz")
    press("Return")


@scenario("focus-loss-discards-the-composition")
@expect()
def _():
    typing("\\he")
    ic.focus_out()
    settle()


@scenario("content-type-change-discards-the-composition")
@expect()
def _():
    typing("\\he")
    ic.set_content_type(IBus.InputPurpose.EMAIL, 0)
    settle()


@scenario("locked-screen-refuses-replies")
@expect()
def _():
    set_locked(True)
    try:
        typing("\\he")
        press("Return")
    finally:
        set_locked(False)
        settle()


@scenario("locking-clears-an-open-composition")
@expect()
def _():
    typing("\\he")
    set_locked(True)
    settle()
    set_locked(False)
    settle()


@scenario("control-chord-ends-literally")
@expect("\\he")
def _():
    typing("\\he")
    press("a", CONTROL)


if os.environ.get("SNIPPETS_IBUS_TEST_COMPOSE") == "1":

    def app_untouched(body):
        body.app_untouched = True
        return body

    # A backslash inside a Compose sequence never opens a query.
    @scenario("dead-key-composes-without-a-query")
    @expect("é")
    @app_untouched
    def _():
        press("dead_acute")
        press("e")
        press("Multi_key")
        press("\\")
        press("Escape")


ic.focus_out()
settle()
for failure in failures:
    print("FAIL " + failure, file=sys.stderr)
sys.exit(1 if failures else 0)
