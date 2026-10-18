"""A small HTTP service that behaves like a well-run one during a rollout.

It does three things a deployment depends on:

* /readyz says whether to send traffic. It turns 503 as soon as SIGTERM arrives.
* After SIGTERM it keeps serving for DRAIN_SECONDS, because the endpoint list takes a moment to
  reach every node; requests still on their way must not meet a closed port.
* START_DELAY and FAIL_READY make slow and broken releases on demand, for the tests.

Standard library only.
"""

from __future__ import annotations

import json
import os
import signal
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class State:
    """What the handlers need to know. One per server, so tests can run several."""

    def __init__(self, version: str, fail_ready: bool, pod: str) -> None:
        self.version = version
        self.fail_ready = fail_ready
        self.pod = pod
        self.draining = threading.Event()

    @property
    def ready(self) -> bool:
        return not self.fail_ready and not self.draining.is_set()


def make_handler(state: State) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def _send(self, code: int, body: bytes, content_type: str = "text/plain") -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/healthz":
                self._send(200, b"ok\n")
            elif self.path == "/readyz":
                if state.ready:
                    self._send(200, b"ready\n")
                else:
                    self._send(503, b"not ready\n")
            elif self.path == "/":
                body = json.dumps({"version": state.version, "pod": state.pod}).encode() + b"\n"
                self._send(200, body, "application/json")
            else:
                self._send(404, b"not found\n")

        def log_message(self, format: str, *args: object) -> None:
            pass  # one line per request would bury the lifecycle lines below

    return Handler


def log(message: str) -> None:
    print(f"{time.strftime('%H:%M:%S')} {message}", flush=True)


def serve(
    port: int,
    version: str,
    start_delay: float,
    drain_seconds: float,
    fail_ready: bool,
    pod: str,
    *,
    install_signals: bool = True,
) -> int:
    state = State(version, fail_ready, pod)
    if start_delay > 0:
        log(f"starting slowly: not listening for {start_delay:g}s")
        time.sleep(start_delay)
    server = ThreadingHTTPServer(("0.0.0.0", port), make_handler(state))
    server.daemon_threads = True

    def drain() -> None:
        state.draining.set()
        log(f"SIGTERM: not ready any more, still serving for {drain_seconds:g}s")
        time.sleep(drain_seconds)
        server.shutdown()

    if install_signals:
        # shutdown() waits for serve_forever(), which runs on this thread: call it from another.
        signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=drain, daemon=True).start())
    log(f"version {version} listening on :{port}" + (" (never ready)" if fail_ready else ""))
    try:
        server.serve_forever(poll_interval=0.1)
    finally:
        server.server_close()
    log("stopped")
    return 0


def main() -> int:
    return serve(
        port=int(os.environ.get("PORT", "8080")),
        version=os.environ.get("VERSION", "dev"),
        start_delay=float(os.environ.get("START_DELAY", "0")),
        drain_seconds=float(os.environ.get("DRAIN_SECONDS", "5")),
        fail_ready=os.environ.get("FAIL_READY", "") == "1",
        pod=os.environ.get("HOSTNAME") or socket.gethostname(),
    )


if __name__ == "__main__":
    sys.exit(main())
