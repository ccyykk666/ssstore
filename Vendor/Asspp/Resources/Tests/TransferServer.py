"""Loopback CDN fixture for byte integrity, native resume, and HTTP errors."""
import collections
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
import time
import json

PAYLOAD = bytes(range(256)) * 32768
requests = collections.defaultdict(list)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_HEAD(self):
        requests[self.path].append("HEAD")
        self.send_response(405)
        self.end_headers()

    def do_GET(self):
        if self.path == "/stats":
            body = json.dumps(requests).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        request_range = self.headers.get("Range", "")
        requests[self.path].append(request_range or "GET")
        if self.path == "/denied":
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        start = int(request_range.removeprefix("bytes=").split("-")[0]) if request_range else 0
        self.send_response(206 if request_range else 200)
        self.send_header("Content-Length", str(len(PAYLOAD) - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"transfer-fixture"')
        self.send_header("Last-Modified", "Mon, 02 Nov 2026 00:00:00 GMT")
        if request_range:
            self.send_header("Content-Range", f"bytes {start}-{len(PAYLOAD)-1}/{len(PAYLOAD)}")
        self.end_headers()
        try:
            for offset in range(start, len(PAYLOAD), 65536):
                self.wfile.write(PAYLOAD[offset:offset + 65536])
                self.wfile.flush()
                time.sleep(0.008)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
