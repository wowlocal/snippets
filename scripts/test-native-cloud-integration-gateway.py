#!/usr/bin/env python3
"""Private development gateway exposing only the native Snippets API, never mail/admin UI."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from http.client import HTTPConnection
from pathlib import Path
from threading import BoundedSemaphore, Lock
import argparse
import ipaddress
import re
import urllib.parse
import json

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--origin-file', required=True, type=Path)
parser.add_argument('--chaos-file', required=True, type=Path)
parser.add_argument('--state-file', required=True, type=Path)
parser.add_argument('--port', type=int, default=8787)
parser.add_argument('--api-port', type=int, default=8087)
ARGS = parser.parse_args()
ORIGIN = ARGS.origin_file.read_text().strip()
HOST = ORIGIN.removeprefix('https://')
SLOTS = BoundedSemaphore(32)
MAX_BODY = 16 * 1024 * 1024

class Chaos:
    def __init__(self):
        self.lock = Lock()
        self.generation = None
        self.matched = 0
        self.triggered = 0
        self.upstream = 0

    def select(self, method, path):
        with self.lock:
            if not ARGS.chaos_file.exists(): return None
            raw = ARGS.chaos_file.read_bytes()
            if len(raw) > 4096: raise ValueError('invalid chaos plan')
            plan = json.loads(raw)
            if plan.get('generation') != self.generation:
                self.generation = plan.get('generation')
                self.matched = self.triggered = self.upstream = 0
            if plan.get('kind') == 'disabled': return None
            space = plan.get('spaceID', '')
            if not re.fullmatch(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', space):
                raise ValueError('invalid chaos scope')
            parsed = urllib.parse.urlsplit(path)
            prefix = '/v2/spaces/' + space
            kind = plan.get('kind')
            matching = ((kind == 'lost_ack' and method == 'POST' and parsed.path == prefix + '/records/batch') or
                        (kind == 'truncate' and method == 'GET' and parsed.path == prefix + '/changes') or
                        (kind == 'stale_cursor' and method == 'GET' and parsed.path == prefix + '/changes' and
                         bool(urllib.parse.parse_qs(parsed.query).get('cursor'))))
            if not matching: return None
            self.matched += 1
            selected = self.matched == 1
            if selected: self.triggered += 1
            self.persist()
            return kind if selected else None

    def did_forward(self):
        with self.lock:
            self.upstream += 1
            self.persist()

    def persist(self):
        value = {'generation': self.generation, 'matched': self.matched,
                 'triggered': self.triggered, 'upstreamAttempts': self.upstream}
        temporary = ARGS.state_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(value))
        temporary.chmod(0o600)
        temporary.replace(ARGS.state_file)

CHAOS = Chaos()

class Gateway(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reject(self, status):
        body = json.dumps({'code': 'gateway_unavailable' if status >= 500 else 'invalid_request'}).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/problem+json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)
        self.close_connection = True

    def handle_request(self):
        self.connection.settimeout(30)
        path = self.path.split('?', 1)[0]
        if not (path.startswith('/v2/') or path in ('/.well-known/snippets-sync', '/health/live', '/health/ready')):
            self.reject(404)
            return
        if self.headers.get('Transfer-Encoding'):
            self.reject(400)
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
        except ValueError:
            self.reject(400)
            return
        if length < 0 or length > MAX_BODY:
            self.reject(413)
            return
        # This development listener is loopback-only behind cloudflared. Cloudflare
        # overwrites CF-Connecting-IP at the public edge. Never forward a caller's
        # X-Snippets-Client-IP or trust a comma-separated forwarding chain.
        try:
            peer = ipaddress.ip_address(self.client_address[0])
            forwarded = self.headers.get_all('CF-Connecting-IP', [])
            client_ip = peer
            if peer.is_loopback and forwarded:
                if len(forwarded) != 1 or len(forwarded[0]) > 64 or '%' in forwarded[0]:
                    raise ValueError('invalid client address')
                client_ip = ipaddress.ip_address(forwarded[0])
            client_ip = getattr(client_ip, 'ipv4_mapped', None) or client_ip
        except ValueError:
            self.reject(400)
            return
        if not SLOTS.acquire(blocking=False):
            self.reject(503)
            return
        connection = HTTPConnection('127.0.0.1', ARGS.api_port, timeout=30)
        try:
            skip = {'host', 'connection', 'transfer-encoding', 'proxy-authorization', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'x-snippets-client-ip', 'cf-connecting-ip'}
            headers = {key: value for key, value in self.headers.items() if key.lower() not in skip}
            headers['Host'] = HOST
            headers['X-Snippets-Client-IP'] = str(client_ip)
            action = CHAOS.select(self.command, self.path)
            upstream_path = self.path
            if action == 'stale_cursor':
                parsed = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parsed.query)
                query['cursor'] = ['invalid-native-integration-cursor']
                upstream_path = parsed.path + '?' + urllib.parse.urlencode(query, doseq=True)
            if action: CHAOS.did_forward()
            connection.request(self.command, upstream_path, body=self.rfile.read(length) if length else None, headers=headers)
            response = connection.getresponse()
            body = response.read(64 * 1024 * 1024 + 1)
            if len(body) > 64 * 1024 * 1024:
                self.reject(502)
                return
            if action == 'lost_ack':
                self.send_response(503)
                body = b'{"code":"dependency_unavailable"}'
                self.send_header('Content-Type', 'application/problem+json')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.end_headers()
                self.wfile.write(body)
                return
            if action == 'truncate': body = body[:17]
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in {'connection', 'transfer-encoding', 'content-length'}:
                    self.send_header(key, value)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            if self.command != 'HEAD':
                self.wfile.write(body)
        except (ConnectionError, OSError, ValueError):
            self.close_connection = True
            try:
                self.reject(502)
            except (ConnectionError, OSError):
                pass
        finally:
            connection.close()
            SLOTS.release()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_request

ThreadingHTTPServer(('127.0.0.1', ARGS.port), Gateway).serve_forever()
