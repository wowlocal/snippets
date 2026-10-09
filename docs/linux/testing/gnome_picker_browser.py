"""Owned Chromium receiver for actual GNOME picker insertion."""
from pathlib import Path
import os
import json
import subprocess
import tempfile
import threading
from browser_fixture import State, server
from gnome_browser import HTML


def run(binary, lab, settle, wait, open_picker, chord, picker, body, capture=None):
    root = Path(lab).absolute()
    assert os.environ['XDG_RUNTIME_DIR'] == str(root / 'runtime')
    state = State()
    html = HTML.replace("t.value==='Public GNOME expansion'", "t.value===" + json.dumps(body))
    http = server(state, html)
    worker = threading.Thread(target=http.serve_forever, daemon=True)
    worker.start()
    browser = None
    log = (root / 'picker-chromium.log').open('wb')
    try:
        with tempfile.TemporaryDirectory(prefix='picker-browser-', dir=root) as profile:
            browser = subprocess.Popen([
                str(binary), '--ozone-platform=wayland', '--enable-wayland-ime',
                '--wayland-text-input-version=3', '--no-first-run', '--no-default-browser-check',
                '--disable-background-networking', '--password-store=basic', '--start-maximized',
                f'--user-data-dir={profile}', f'http://127.0.0.1:{http.server_port}/',
            ], stdout=log, stderr=log)

            def advance():
                sequence = state.advance()
                wait(lambda: state.observation().get('seq') == sequence, 'browser receiver did not acknowledge case')
                settle(0.3)

            def empty():
                value = state.observation()
                return value.get('bytes') == 0 and not value.get('composing', True)

            advance()
            settle(0.7)
            open_picker(True)
            chord(28)
            wait(lambda: state.observation().get('first') and not state.observation().get('composing', True),
                 'picker did not commit exact text into Chromium')
            print('Chromium picker: exact multiline Unicode DOM text with composition finished', flush=True)
            if capture:
                capture(body)
            advance()
            open_picker(False)
            chord(28)
            settle(0.4)
            assert empty(), 'password received text'
            chord(1)
            print('Chromium picker: password target refused', flush=True)
            advance()
            open_picker(True)
            chord(56, 15)
            wait(lambda: picker() is None, 'Alt+Tab did not leave the picker')
            advance()  # User returned to the browser, then moved to another field.
            chord(56, 15)
            wait(lambda: picker() is not None, 'Alt+Tab did not return to the picker')
            chord(28)
            settle(0.5)
            assert empty(), 'cancelled selection reached another browser field'
            print('Chromium picker: intervening focus change cancels insertion', flush=True)
    finally:
        if browser and browser.poll() is None:
            browser.terminate()
            try:
                browser.wait(timeout=8)
            except subprocess.TimeoutExpired:
                browser.kill()
                browser.wait()
        log.close()
        http.shutdown()
        http.server_close()
        worker.join(timeout=2)
