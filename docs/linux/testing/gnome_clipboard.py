"""Actual global Capture action from a GTK clipboard owner in the private lab."""
def nodes(node, depth=0):
    if depth > 48:
        return
    yield node
    for child in node:
        yield from nodes(child, depth + 1)

def main_window(pyatspi):
    for app in pyatspi.Registry.getDesktop(0):
        for candidate in app:
            if candidate.name == 'Snippets' and candidate.getState().contains(pyatspi.STATE_ACTIVE):
                return candidate
    return None

def editor_contains(pyatspi, value):
    candidate = main_window(pyatspi)
    if not candidate:
        return False
    for node in nodes(candidate):
        try:
            text = node.queryText()
            if text.getText(0, text.characterCount) == value:
                return True
        except NotImplementedError:
            pass
    return False


def capture_browser(pyatspi, settle, wait, chord, body):
    chord(29, 30)  # Select the real textarea text.
    chord(29, 46)  # Chromium owns the selection through its native copy path.
    settle(0.2)
    chord(125, 56, 46)
    wait(lambda: editor_contains(pyatspi, body), 'Chromium clipboard did not reach the exact draft')
    chord(125, 35)  # Minimize the owned library window and return to Chromium.
    settle(0.3)
    print('Chromium Capture: physical Copy and Capture produce exact multiline Unicode draft', flush=True)


def run(Gtk, Gdk, GObject, GLib, pyatspi, window, plain, password, settle, wait, chord):
    clipboard = window.get_display().get_clipboard()
    expected = 'Public capture\nПривет — ✓'

    def capture(body, private=False, hidden=False):
        provider = Gdk.ContentProvider.new_for_value(GObject.Value(GObject.TYPE_STRING, body))
        if private:
            provider = Gdk.ContentProvider.new_union([
                provider, Gdk.ContentProvider.new_for_bytes('application/x-keepassxc', GLib.Bytes.new(b'1'))])
        window.present()
        (password if hidden else plain).grab_focus()
        settle(0.1)
        if not window.is_active():
            chord(56, 15)  # Switch between the two owned windows as a user would.
        wait(window.is_active, 'capture receiver focus')
        chord(42)  # Wayland selection ownership needs an input serial from this client.
        assert clipboard.set_content(provider)
        settle(0.25)
        chord(125, 56, 46)  # The actual registered Capture clipboard text shortcut.
        wait(lambda: main_window(pyatspi) is not None, 'Capture did not present the library')
        settle(0.2)

    capture(expected)
    wait(lambda: editor_contains(pyatspi, expected), 'Capture did not create an exact Unicode/multiline draft')
    for body, private, hidden in [('Public sensitive marker', True, False),
                                   ('Public password marker', False, True),
                                   ('x' * (256 * 1024 + 1), False, False),
                                   ('', False, False)]:
        capture(body, private, hidden)
        assert editor_contains(pyatspi, expected), 'rejected capture changed the existing draft'
        assert not editor_contains(pyatspi, body) if body else True
    observed = []
    window.present(); plain.grab_focus(); settle(0.1)
    if not window.is_active():
        chord(56, 15)
    wait(window.is_active, 'clipboard verification focus')
    clipboard.read_text_async(None, lambda obj, result: observed.append(obj.read_text_finish(result)))
    wait(lambda: bool(observed), 'clipboard verification')
    assert observed == [''], 'Capture wrote into the clipboard'
    print('GTK Capture: actual shortcut creates exact Unicode draft; sensitive hints, password focus, oversized and empty selections refused; clipboard unchanged', flush=True)
