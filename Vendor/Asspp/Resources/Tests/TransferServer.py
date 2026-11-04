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
        if self.path == "/parallel":
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAYLOAD) * 4))
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("ETag", '\"parallel-fixture\"')
            self.end_headers()
            return
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
        payload = PAYLOAD * 4 if self.path == "/parallel" else PAYLOAD
        start = int(request_range.removeprefix("bytes=").split("-")[0]) if request_range else 0
        end_text = request_range.split("-")[-1] if request_range else ""
        end = int(end_text) if end_text else len(payload)-1
        self.send_response(206 if request_range else 200)
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("ETag", '"parallel-fixture"' if self.path == "/parallel" else '"transfer-fixture"')
        self.send_header("Last-Modified", "Mon, 02 Nov 2026 00:00:00 GMT")
        if request_range:
            self.send_header("Content-Range", f"bytes {start}-{end}/{len(payload)}")
        self.end_headers()
        try:
            for offset in range(start, end + 1, 65536):
                self.wfile.write(payload[offset:min(offset + 65536, end + 1)])
                self.wfile.flush()
                time.sleep(0.008)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
