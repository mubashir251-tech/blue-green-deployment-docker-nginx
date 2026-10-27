import json
import os
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ENVIRONMENT = os.getenv("APP_ENV", "blue")
VERSION = os.getenv("APP_VERSION", "1.0")
START_TIME = time.time()


class AppHandler(BaseHTTPRequestHandler):
    def send_json(self, status_code, data):
        body = json.dumps(data).encode("utf-8")
        self.send_response(status_code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.send_json(200, {
                "version": ENVIRONMENT,
                "app_version": VERSION,
                "environment": ENVIRONMENT,
                "timestamp": datetime.now(timezone.utc).isoformat()
            })
        elif self.path == "/health":
            self.send_json(200, {
                "status": "healthy",
                "environment": ENVIRONMENT,
                "uptime": round(time.time() - START_TIME, 2)
            })
        else:
            self.send_json(404, {"error": "Not found"})

    def log_message(self, format_string, *args):
        print(f"[{ENVIRONMENT}] {self.address_string()} - {format_string % args}")


server = ThreadingHTTPServer(("0.0.0.0", 3000), AppHandler)
print(f"Starting {ENVIRONMENT} environment, version {VERSION}, on port 3000")
server.serve_forever()
