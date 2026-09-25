"""Run the calculation worker on demand instead of polling forever.

A polling worker keeps its container and the database awake around the clock.
This entry point serves a tiny private HTTP endpoint instead:

    POST /run   (header X-Worker-Token)  drain the calculation queue, then idle
    GET  /health                         liveness for the container host

The API calls POST /run right after it queues a calculation. A drain opens one
database connection, processes requests until none is claimable, then closes
the connection, so an idle worker holds no connection and sends no traffic:
the container host can sleep it and the database can scale to zero. Requests
are still claimed through the durable queue (lease, retries), so a lost or
duplicate trigger never loses or double-runs work; the queue itself is the
source of truth.

Usage:  python -m workers.trigger_server
Env:    DATABASE_URL (trusted worker credential), CALC_WORKER_TRIGGER_TOKEN,
        PORT (default 8080), CALC_WORKER_LEASE_SECONDS, CALC_WORKER_MAX_ATTEMPTS
"""

from __future__ import annotations

import hmac
import logging
import os
import socket
import sys
import threading
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("calc_worker.trigger")


class Drainer:
    """Single-flight queue drain. A trigger during a drain schedules one more pass."""

    def __init__(self, drain_once: Callable[[], int]):
        self._drain_once = drain_once
        self._lock = threading.Lock()
        self._running = False
        self._again = False

    def trigger(self) -> bool:
        """Start a drain in the background. Returns False if one was already running."""
        with self._lock:
            if self._running:
                self._again = True
                return False
            self._running = True
        threading.Thread(target=self._loop, name="calc-drain", daemon=True).start()
        return True

    def _loop(self) -> None:
        while True:
            try:
                handled = self._drain_once()
                log.info("calc_worker.drain_finished handled=%s", handled)
            except Exception:  # keep serving; the queue lease makes a retry safe
                log.exception("calc_worker.drain_failed")
            with self._lock:
                if not self._again:
                    self._running = False
                    return
                self._again = False

    @property
    def running(self) -> bool:
        with self._lock:
            return self._running


def make_drain_once(database_url: str, *, lease_seconds: int, max_attempts: int) -> Callable[[], int]:
    def drain_once() -> int:
        import psycopg
        from psycopg.rows import dict_row

        from workers.pl_worker import _worker_id, run_once

        worker_id = _worker_id()
        handled = 0
        # One connection per drain, closed afterwards so nothing keeps the
        # database or this container awake while idle.
        with psycopg.connect(database_url, row_factory=dict_row, autocommit=True) as conn:
            while run_once(
                conn,
                worker_id=worker_id,
                lease_seconds=lease_seconds,
                max_attempts=max_attempts,
            ):
                handled += 1
        return handled

    return drain_once


def make_handler(drainer: Drainer, token: str) -> type[BaseHTTPRequestHandler]:
    expected = token.encode()

    class Handler(BaseHTTPRequestHandler):
        def _reply(self, status: int, body: bytes = b"") -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if body:
                self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802 (http.server naming)
            if self.path == "/health":
                self._reply(200, b"ok")
            else:
                self._reply(404)

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/run":
                self._reply(404)
                return
            supplied = (self.headers.get("X-Worker-Token") or "").encode()
            if not hmac.compare_digest(supplied, expected):
                self._reply(401)
                return
            started = drainer.trigger()
            self._reply(202, b"started" if started else b"already running")

        def log_message(self, format: str, *args) -> None:  # quiet access log
            log.debug("calc_worker.http " + format, *args)

    return Handler


class DualStackServer(ThreadingHTTPServer):
    """Listens on IPv6 and IPv4, since private networks may use either."""

    address_family = socket.AF_INET6

    def server_bind(self) -> None:
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
        super().server_bind()


def make_server(port: int, handler: type[BaseHTTPRequestHandler]) -> ThreadingHTTPServer:
    """Dual-stack where the host supports IPv6, plain IPv4 otherwise."""
    try:
        return DualStackServer(("::", port), handler)
    except OSError:
        return ThreadingHTTPServer(("0.0.0.0", port), handler)


def main() -> int:
    # stdout: hosts such as Railway label everything on stderr as an error.
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(message)s", stream=sys.stdout)
    database_url = os.getenv("DATABASE_URL")
    token = os.getenv("CALC_WORKER_TRIGGER_TOKEN", "")
    if not database_url:
        raise SystemExit("DATABASE_URL is required")
    if len(token) < 32:
        raise SystemExit("CALC_WORKER_TRIGGER_TOKEN must be at least 32 characters")

    drainer = Drainer(make_drain_once(
        database_url,
        lease_seconds=int(os.getenv("CALC_WORKER_LEASE_SECONDS", "300")),
        max_attempts=int(os.getenv("CALC_WORKER_MAX_ATTEMPTS", "5")),
    ))
    # Work queued while the worker slept is picked up as soon as it wakes.
    drainer.trigger()

    port = int(os.getenv("PORT", "8080"))
    server = make_server(port, make_handler(drainer, token))
    log.info("calc_worker.trigger_server listening port=%s", port)
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
