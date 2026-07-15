#!/usr/bin/env python3
"""Simple HTTP service for systemd exercise.

Handles SIGTERM gracefully — demonstrates proper signal handling
for PID 1 / container init process.
"""

import http.server
import os
import signal
import sys

PORT = int(os.environ.get("APP_PORT", "8080"))
running = True


def handle_sigterm(_signum, _frame):
    global running
    print("Received SIGTERM, shutting down gracefully...", flush=True)
    running = False


signal.signal(signal.SIGTERM, handle_sigterm)
signal.signal(signal.SIGINT, handle_sigterm)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(f"Hello from PID={os.getpid()}\n".encode())

    def log_message(self, format, *args):
        print(f"[{self.client_address[0]}] {format % args}", flush=True)


def main():
    print(f"Starting server on :{PORT} (PID={os.getpid()})", flush=True)
    print(f"APP_ENV={os.environ.get('APP_ENV', 'not set')}", flush=True)

    server = http.server.HTTPServer(("0.0.0.0", PORT), Handler)

    # Serve until stopped
    while running:
        server.handle_request()

    print("Server stopped.", flush=True)
    sys.exit(0)


if __name__ == "__main__":
    main()
