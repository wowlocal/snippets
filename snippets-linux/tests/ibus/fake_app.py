"""A stand-in for the Snippets app's IBus bridge (`src/inline_bridge.rs`).

Run as `snippets fake_app.py RUNTIME_DIR LOG`, from an interpreter copied to the
name `snippets` beside the engine: the engine accepts only a peer whose
executable is that file. Serves SNI3 frames on RUNTIME_DIR/snippets-ibus.sock
from a fictional catalog and logs every request, so a run can be compared.

Queries starting with `b` get a malformed row reply; queries starting with `s`
are answered after 200 ms, so keys can arrive while a request is pending. The
app hangs up, as when it quits or expansion is turned off: one second after
answering a query starting with `q` (no request is pending then), right after
answering one starting with `j`, and 300 ms after a query starting with `k`,
unanswered (keys typed meanwhile wait for it). While RUNTIME_DIR/refuse-engine
exists, it closes every new connection unread, as it refuses an engine left
running from an earlier installation.
"""

import os
import socket
import struct
import sys
import threading
import time

CATALOG = [
    # name, keyword, expansion
    ("Hello", "hello", "Hello, world!"),
    ("Help", "help", "How can I help?"),
    ("Slow", "slow", "Slow and steady"),
    ("Sloth", "sloth", "Hang in there"),
    ("Xenon", "xenon", "Xe"),
    ("Xylophone", "xylo", "Ξυλόφωνο"),
]
PALETTE = bytes([1]) + bytes([43, 43, 43, 245, 245, 245, 0, 122, 255])


def identity(index):
    return bytes([0x5E] * 15 + [index + 1])


def field(text, query):
    data = text.encode()
    matches = b""
    count = 0
    if query and text.lower().startswith(query.lower()):
        end = len(query.encode())
        matches = struct.pack("<HH", 0, end)
        count = 1
    return struct.pack("<H", len(data)) + data + bytes([count]) + matches


def rows(entries, query):
    body = bytes([len(entries)]) + PALETTE
    for index, (name, keyword, _) in entries:
        body += identity(index) + field(name, query) + field(keyword, query)
        # One shown tag of two.
        body += bytes([1]) + struct.pack("<H", 2) + bytes([4]) + b"demo"
    return body


def frame(kind, payload):
    return b"SNI3" + bytes([kind]) + struct.pack("<I", len(payload)) + payload


def read_exact(conn, size):
    data = b""
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError
        data += chunk
    return data


class Log:
    def __init__(self, path):
        self.lock = threading.Lock()
        self.path = path
        self.connections = 0

    def connection(self):
        with self.lock:
            self.connections += 1
            return self.connections

    def write(self, line):
        with self.lock, open(self.path, "a", encoding="utf-8") as out:
            out.write(line + "\n")


def serve(conn, log, refuse):
    number = log.connection()
    shown = []
    try:
        if os.path.exists(refuse):
            log.write(f"app {number} refused")
            return
        while True:
            header = read_exact(conn, 9)
            if header[:4] != b"SNI3":
                log.write(f"app {number} bad-magic")
                return
            kind = header[4]
            (length,) = struct.unpack("<I", header[5:9])
            payload = read_exact(conn, length)
            if kind == 1:
                query = payload.decode()
                log.write(f"app {number} query {query!r}")
                if query.startswith("k"):
                    time.sleep(0.3)
                    log.write(f"app {number} hang-up")
                    return
                if query.startswith("s"):
                    time.sleep(0.2)
                if query.startswith("b"):
                    conn.sendall(frame(1, bytes([1]) + PALETTE + b"\x00"))
                    continue
                shown = [
                    (index, entry)
                    for index, entry in enumerate(CATALOG)
                    if entry[1].startswith(query)
                ][:8]
                conn.sendall(frame(1, rows([(i, e) for i, e in shown], query)))
                if query.startswith("q"):
                    time.sleep(1.0)
                if query.startswith(("q", "j")):
                    log.write(f"app {number} hang-up")
                    return
            elif kind == 2:
                index = payload[0] if payload else 255
                log.write(f"app {number} select {index}")
                if index < len(shown):
                    conn.sendall(frame(2, shown[index][1][2].encode()))
                else:
                    return
            elif kind == 3:
                log.write(f"app {number} used")
            else:
                log.write(f"app {number} kind {kind}")
                return
    except (EOFError, ConnectionError):
        pass
    finally:
        conn.close()


def main():
    runtime, log_path = sys.argv[1], sys.argv[2]
    path = os.path.join(runtime, "snippets-ibus.sock")
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o177)
    server.bind(path)
    os.umask(old)
    os.chmod(path, 0o600)
    server.listen(8)
    log = Log(log_path)
    refuse = os.path.join(runtime, "refuse-engine")
    print("READY", flush=True)
    while True:
        conn, _ = server.accept()
        threading.Thread(target=serve, args=(conn, log, refuse), daemon=True).start()


if __name__ == "__main__":
    main()
