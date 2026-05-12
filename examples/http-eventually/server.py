#!/usr/bin/env python3
"""Returns 503 for ~1s, then flips to 200 — exercises eventually polling."""
import http.server
import json
import time

started = time.time()
READY_AFTER = 1.0  # seconds

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if time.time() - started < READY_AFTER:
            self.send_response(503)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ready": True}).encode())

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 19012), H).serve_forever()
