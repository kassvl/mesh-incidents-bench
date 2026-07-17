#!/usr/bin/env python3
"""Serializing proxy for rate-limited LLM API keys.

Mistral's experiment tier allows 4 requests per minute; agentic tools like
HolmesGPT burst far past that and die on 429s mid-investigation. This proxy
forwards requests to api.mistral.ai one at a time with a minimum spacing,
so the tool runs slower instead of crashing.

Usage:
    python3 mistral-throttle.py [port] [min_interval_seconds]
Then point the client at it, e.g. MISTRAL_API_BASE=http://127.0.0.1:8787/v1
"""
import http.client
import http.server
import sys
import threading
import time

UPSTREAM = "api.mistral.ai"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8787
MIN_INTERVAL = float(sys.argv[2]) if len(sys.argv) > 2 else 16.0

lock = threading.Lock()
last_request = [0.0]

HOP_HEADERS = {"connection", "keep-alive", "transfer-encoding", "host",
               "proxy-authenticate", "proxy-authorization", "te", "trailers", "upgrade"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        self.forward()

    def do_GET(self):
        self.forward()

    def forward(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with lock:
            wait = MIN_INTERVAL - (time.time() - last_request[0])
            if wait > 0:
                time.sleep(wait)
            last_request[0] = time.time()
            conn = http.client.HTTPSConnection(UPSTREAM, timeout=120)
            headers = {k: v for k, v in self.headers.items()
                       if k.lower() not in HOP_HEADERS}
            headers["Host"] = UPSTREAM
            conn.request(self.command, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()
            payload = resp.read()
            conn.close()
        self.send_response(resp.status)
        for k, v in resp.getheaders():
            if k.lower() not in HOP_HEADERS and k.lower() != "content-length":
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        sys.stderr.write("throttle: %s\n" % (fmt % args))


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    sys.stderr.write(f"throttle: forwarding to {UPSTREAM} on :{PORT}, "
                     f"min {MIN_INTERVAL}s between requests\n")
    server.serve_forever()
