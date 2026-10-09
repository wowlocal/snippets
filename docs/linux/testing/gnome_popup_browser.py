"""Real Chromium candidate-panel receiver for gnome_popup.py's owned lab."""
import os
from pathlib import Path
import subprocess
import tempfile
import threading

from browser_fixture import State, server


HTML = r'''<!doctype html><meta charset="utf-8"><title>Public GNOME candidate browser</title>
<style>body{font:20px sans-serif;padding:40px}input,textarea{display:block;margin:20px;width:80%}</style>
<h2>Snippets — native GNOME candidate panel</h2>
<textarea id=plain spellcheck=false></textarea><input id=other spellcheck=false>
<input id=password type=password><script>
let seq=-1,event=0,composing=false,t=null;
const fields={1:document.querySelector('#plain'),2:document.querySelector('#plain'),
  3:document.querySelector('#plain'),4:document.querySelector('#other'),
  5:document.querySelector('#password')};
function report(){if(!t||seq<1)return;
 fetch('/result',{method:'POST',body:JSON.stringify({seq,event:++event,
  bytes:new TextEncoder().encode(t.value).length,first:t.value==='Alpha body ✓',
  second:t.value==='Beta body ✓',literal:t.value===(seq===4?'alpha':'\\panel'),composing})}).catch(()=>{});
}
for(const e of new Set(Object.values(fields))){
 e.oninput=report;e.oncompositionstart=()=>{composing=true;report()};
 e.oncompositionend=()=>{composing=false;report()};
}
setInterval(report,100);
let polling=false;
setInterval(async()=>{if(polling)return;polling=true;try{
 const s=await(await fetch('/state',{cache:'no-store'})).json();
 if(s.seq!==seq&&fields[s.seq]){t=fields[s.seq];t.value='';t.focus();seq=s.seq;report()}
}catch(e){}finally{polling=false}},80);
</script>'''


def run(binary, root, settle, wait, key, type_text, wait_candidates, wait_hidden, screenshot):
    from gi.repository import IBus
    assert os.environ['XDG_RUNTIME_DIR'] == str(root / 'runtime')
    state = State()
    http = server(state, HTML)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    profile = tempfile.TemporaryDirectory(prefix='popup-chromium-', dir=root)
    browser = None
    log = (root / 'popup-chromium.log').open('w')

    def advance():
        seq = state.advance()
        wait(lambda: state.observation().get('seq') == seq, 'browser field acknowledgment')
        settle(0.2)

    def result(name):
        value = state.observation()
        return value.get(name) and not value.get('composing', True)

    try:
        browser = subprocess.Popen([
            str(binary), '--ozone-platform=wayland', '--enable-wayland-ime',
            '--wayland-text-input-version=3', '--no-first-run', '--no-default-browser-check',
            '--disable-background-networking', '--password-store=basic', '--start-maximized',
            f'--user-data-dir={Path(profile.name) / "profile"}',
            f'http://127.0.0.1:{http.server_port}/'], stdout=log, stderr=log)
        advance()
        settle(0.7)
        type_text('\\panel')
        order = wait_candidates()
        screenshot('chromium_candidates')
        key(IBus.KEY_Down)
        key(IBus.KEY_Return)
        expected = 'first' if order[1].startswith('Public Alpha\n') else 'second'
        wait(lambda: result(expected), 'browser selected body and ended composition')
        wait_hidden()
        advance()
        type_text('\\panel')
        wait_candidates()
        key(IBus.KEY_Escape)
        wait(lambda: result('literal'), 'browser literal Escape')
        wait_hidden()
        advance()
        type_text('\\panel')
        wait_candidates()
        advance()
        wait_hidden()
        type_text('alpha')
        wait(lambda: result('literal'), 'browser cross-field cancellation')
        advance()
        type_text('\\panel')
        wait(lambda: result('literal'), 'browser password pass-through')
        wait_hidden()
        print('PASS: Chromium native GNOME candidate rows, Down/Enter exact DOM, Escape, focus cancellation and password suppression', flush=True)
    except Exception:
        print('Browser observation:', state.observation(), flush=True)
        raise
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
        thread.join(timeout=2)
        profile.cleanup()
