#!/usr/bin/env python3
"""Disposable smart-HTTP git server for Snippets integration tests.

Serves the bare repositories under --root through the real `git http-backend` CGI,
requires one HTTP Basic credential, and binds to loopback only. It prints
`READY <port>` once listening. Not for anything but tests.
"""

import argparse
import base64
import hmac
import http.server
import os
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="directory containing bare repositories")
    parser.add_argument("--username", required=True)
    parser.add_argument("--token-file", required=True, help="file holding the access token")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--log", help="append one line per request to this file")
    arguments = parser.parse_args()

    with open(arguments.token_file, encoding="utf-8") as handle:
        token = handle.read().strip()
    expected = "Basic " + base64.b64encode(f"{arguments.username}:{token}".encode()).decode()
    root = os.path.realpath(arguments.root)
    home = os.path.join(root, ".home")
    os.makedirs(home, mode=0o700, exist_ok=True)

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):  # noqa: A002 - BaseHTTPRequestHandler API
            if arguments.log:
                with open(arguments.log, "a", encoding="utf-8") as log:
                    log.write(f"{self.command} {self.path.split('?')[0]} {args[1] if len(args) > 1 else ''}\n")

        def do_GET(self):
            self.handle_git()

        def do_POST(self):
            self.handle_git()

        def handle_git(self):
            authorization = self.headers.get("Authorization", "")
            if not hmac.compare_digest(authorization, expected):
                self.respond(401, {"WWW-Authenticate": 'Basic realm="snippets-test"',
                                   "Content-Type": "text/plain"}, b"unauthorized")
                return
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            path, _, query = self.path.partition("?")
            environment = {
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "HOME": home,
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_PROJECT_ROOT": root,
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": path,
                "QUERY_STRING": query,
                "REQUEST_METHOD": self.command,
                "REMOTE_USER": arguments.username,
                "REMOTE_ADDR": "127.0.0.1",
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(len(body)),
            }
            if "DEVELOPER_DIR" in os.environ:
                environment["DEVELOPER_DIR"] = os.environ["DEVELOPER_DIR"]
            result = subprocess.run(
                ["/usr/bin/git", "http-backend"], input=body, env=environment,
                capture_output=True, check=False)
            raw = result.stdout
            separator = raw.find(b"\r\n\r\n")
            skip = 4
            if separator < 0:
                separator = raw.find(b"\n\n")
                skip = 2
            if separator < 0:
                self.respond(500, {"Content-Type": "text/plain"}, b"backend failed")
                return
            status = 200
            headers = {}
            for line in raw[:separator].decode("latin-1").splitlines():
                name, _, value = line.partition(":")
                if name.lower() == "status":
                    status = int(value.strip()[:3])
                elif name:
                    headers[name] = value.strip()
            self.respond(status, headers, raw[separator + skip:])

        def respond(self, status, headers, body):
            self.send_response(status)
            for name, value in headers.items():
                if name.lower() not in ("content-length", "transfer-encoding"):
                    self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    print(f"READY {server.server_address[1]}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
