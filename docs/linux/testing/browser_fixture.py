"""Fictional Chromium receiver with ordered, current DOM observations.

Only use with a disposable browser profile and an isolated Snippets library.
The controller owns State.advance(), focus checks, input and process cleanup.
"""

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


HTML = r'''<!doctype html><meta charset="utf-8">
<title>Snippets 523 Browser Fixture</title>
<style>body{background:#202432;color:#eee;font:20px sans-serif;padding:40px}
textarea{display:block;margin-top:40px;width:85%;height:230px;background:#303649;
color:white;font:20px monospace;padding:16px}</style>
<h2>Snippets · Fcitx comparison</h2><p>Isolated integration fixture</p>
<textarea autofocus spellcheck=false></textarea><script>
let seq=-1,event=0,composing=false;
const t=document.querySelector('textarea');
function report(){
  if(seq<0)return;
  fetch('/result',{method:'POST',body:JSON.stringify({seq,event:++event,
    bytes:new TextEncoder().encode(t.value).length,
    first:t.value==='fictional snippet fictional clipboard fixture',
    second:t.value==='second fictional expansion',literal:t.value==='\\nat',
    composing})}).catch(()=>{});
}
t.oninput=report;
t.oncompositionstart=()=>{composing=true;report()};
t.oncompositionend=()=>{composing=false;report()};
// compositionend can precede the final DOM edit. Re-read the field instead of
// treating an event-time snapshot as the final value. This is observation only;
// it adds no typing delay, retries or changes to the acceptance predicate.
setInterval(report,100);
let polling=false;
setInterval(async()=>{
  if(polling)return;
  polling=true;
  try{
    const s=await(await fetch('/state',{cache:'no-store'})).json();
    if(s.seq!==seq){t.value='';t.focus();seq=s.seq;report()}
  }catch(e){}finally{polling=false}
},80);
</script>'''


class State:
    def __init__(self):
        self._lock = threading.Lock()
        self._seq = 0
        self._observation = {}

    def advance(self):
        with self._lock:
            self._seq += 1
            self._observation = {}
            return self._seq

    def sequence(self):
        with self._lock:
            return self._seq

    def observation(self):
        with self._lock:
            return dict(self._observation)

    def accept(self, value):
        fields = {'seq', 'event', 'bytes', 'first', 'second', 'literal', 'composing'}
        if not isinstance(value, dict) or set(value) != fields:
            return False
        for key in ('seq', 'event', 'bytes'):
            if type(value[key]) is not int or not 0 <= value[key] <= 2**31 - 1:
                return False
        if any(type(value[key]) is not bool
               for key in ('first', 'second', 'literal', 'composing')):
            return False
        with self._lock:
            # Concurrent fetches can reach the server in reverse order.
            if (value['seq'] != self._seq or
                    value['event'] <= self._observation.get('event', -1)):
                return False
            self._observation = dict(value)
            return True


def server(state):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            if self.path == '/state':
                data = json.dumps({'seq': state.sequence()}).encode()
                mime = 'application/json'
            elif self.path == '/':
                data, mime = HTML.encode(), 'text/html; charset=utf-8'
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Type', mime)
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            try:
                size = int(self.headers.get('Content-Length', '0'))
                if self.path != '/result' or not 0 < size <= 1024:
                    raise ValueError('invalid request')
                value = json.loads(self.rfile.read(size))
            except (ValueError, UnicodeError):
                self.send_error(400)
                return
            state.accept(value)
            self.send_response(204)
            self.end_headers()

    return ThreadingHTTPServer(('127.0.0.1', 0), Handler)
