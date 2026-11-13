#!/usr/bin/env python3
"""
Lightweight HTTP Health Check & Telemetry Server for Render.com
Answers Render's port health checks on $PORT and provides live status & logs.
"""
import os
import sys
import time
import json
from http.server import HTTPServer, BaseHTTPRequestHandler

PORT = int(os.environ.get("PORT", 10000))
START_TIME = time.time()

class HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/", "/health", "/healthz"):
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            data = {
                "status": "healthy",
                "service": "render-relay",
                "uptime_seconds": int(time.time() - START_TIME),
                "timestamp": int(time.time())
            }
            self.wfile.write(json.dumps(data).encode("utf-8"))
        elif self.path == "/logs":
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            log_content = ""
            if os.path.exists("/tmp/tailscaled.log"):
                try:
                    with open("/tmp/tailscaled.log", "r") as f:
                        lines = f.readlines()
                        log_content = "".join(lines[-100:])
                except Exception as e:
                    log_content = f"Error reading log: {e}\n"
            banner = f"=== RENDER CLOUD RELAY LOGS (Uptime: {int(time.time() - START_TIME)}s) ===\n"
            self.wfile.write((banner + log_content).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        # Clean logging
        sys.stderr.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.address_string()} - {format % args}\n")

def run():
    server = HTTPServer(("0.0.0.0", PORT), HealthHandler)
    print(f"Health server listening on 0.0.0.0:{PORT}")
    sys.stdout.flush()
    server.serve_forever()

if __name__ == "__main__":
    run()
