"""Chromium receiver used only by the owned GNOME/IBus lab runner."""
import os
from pathlib import Path
import subprocess
import threading
import tempfile

from browser_fixture import State, server

HTML = r'''<!doctype html><meta charset="utf-8"><title>Snippets GNOME fixture</title>
<style>body{font:20px sans-serif;padding:40px}input,textarea{display:block;margin:20px;width:80%}</style>
<h2>Public GNOME integration fixture</h2>
<textarea id=plain spellcheck=false></textarea><input id=password type=password>
<input id=other spellcheck=false><script>
let seq=-1,event=0,composing=false,t=null;
const fields={1:document.querySelector('#plain'),2:document.querySelector('#password'),
              3:document.querySelector('#plain'),4:document.querySelector('#other')};
function report(){if(!t||seq<1)return;
 fetch('/result',{method:'POST',body:JSON.stringify({seq,event:++event,
  bytes:new TextEncoder().encode(t.value).length,first:t.value==='Public GNOME expansion',
  second:t.value==='ometest',literal:t.value==='\\gnometest',composing})}).catch(()=>{});
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


def run(binary, lab, settle, wait, ime="wayland"):
    from gi.repository import Gio, GLib
    root = Path(lab).absolute()
    assert os.environ["XDG_RUNTIME_DIR"] == str(root / "runtime")
    assert os.environ["IBUS_ADDRESS"].startswith(f"unix:path={root}/runtime/")
    state = State()
    http = server(state, HTML)
    thread = threading.Thread(target=http.serve_forever, daemon=True)
    thread.start()
    connection = Gio.bus_get_sync(Gio.BusType.SESSION)
    destination = "org.gnome.Mutter.RemoteDesktop"
    path = connection.call_sync(destination, "/org/gnome/Mutter/RemoteDesktop", destination,
                                "CreateSession", None, None, 0, 3000, None).unpack()[0]

    def remote(method, value=None):
        return connection.call_sync(destination, path, destination + ".Session", method,
                                    value, None, 0, 3000, None)

    def type_text(text):
        # Use stable evdev codes on the lab's explicit US layout, avoiding
        # implicit modifier/layout translation by keysym injection.
        codes = {"\\": 43, "g": 34, "n": 49, "o": 24, "m": 50,
                 "e": 18, "t": 20, "s": 31}
        for char in text:
            for pressed in (True, False):
                remote("NotifyKeyboardKeycode", GLib.Variant("(ub)", (codes[char], pressed)))
            settle(0.05)

    def advance():
        sequence = state.advance()
        wait(lambda: state.observation().get("seq") == sequence)
        settle(0.2)

    def result(name):
        return state.observation().get(name) and not state.observation().get("composing", True)

    # No remote debugging or DOM injection: only a local fixture reports its
    # own fields. The profile and every key belong to this headless lab.
    owned_profile = tempfile.TemporaryDirectory(prefix="chromium-run-", dir=root)
    profile = Path(owned_profile.name) / "profile"
    log = (root / "chromium.log").open("wb")
    browser = None
    try:
        remote("Start")
        ime_flags = (["--enable-wayland-ime", "--wayland-text-input-version=3"] if ime == "wayland"
                     else ["--gtk-version=4", "--disable-features=WaylandTextInputV3"])
        environment = dict(os.environ)
        if ime == "gtk":
            environment["GTK_IM_MODULE"] = "ibus"
        browser = subprocess.Popen([str(binary), "--ozone-platform=wayland", *ime_flags, "--no-first-run",
                                    "--no-default-browser-check", "--disable-background-networking",
                                    "--password-store=basic", "--start-maximized",
                                    f"--user-data-dir={profile}", f"http://127.0.0.1:{http.server_port}/"],
                                   env=environment, stdout=log, stderr=log)
        advance()
        settle(1)
        type_text("\\gnometest")
        wait(lambda: result("first"))
        advance()
        type_text("\\gnometest")
        wait(lambda: result("literal"))
        advance()
        type_text("\\gn")
        advance()
        type_text("ometest")
        wait(lambda: result("second"))
        print(f"Chromium Wayland/{ime} E2E: real DOM confirmed exact expansion, password pass-through "
              "and cross-field cancellation with composition finished", flush=True)
    except Exception:
        print("Chromium fixture state:", state.observation(),
              "exit:", browser.poll() if browser else None, flush=True)
        raise
    finally:
        remote("Stop")
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
        owned_profile.cleanup()
