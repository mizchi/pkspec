#!/usr/bin/env python3
"""Counter server — returns a different value each call so cassettes vs. live show clearly."""
import http.server
import json

count = {"n": 0}

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        count["n"] += 1
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"call": count["n"]}).encode())

    def log_message(self, *a):
        pass

http.server.HTTPServer(("127.0.0.1", 19011), H).serve_forever()
