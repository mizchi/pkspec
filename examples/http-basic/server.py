#!/usr/bin/env python3
"""Tiny JSON responder for the http-basic example."""
import http.server
import json

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        body = {
            "ok": True,
            "path": self.path,
            "items": [{"id": 1, "name": "first"}, {"id": 2, "name": "second"}],
        }
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 19010), H).serve_forever()
