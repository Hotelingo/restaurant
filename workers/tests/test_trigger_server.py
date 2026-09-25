from __future__ import annotations

import os
import threading
import unittest
import urllib.error
import urllib.request
from unittest import mock

from workers.trigger_server import Drainer, main, make_handler, make_server

TOKEN = "t" * 40


def _wait_idle(drainer: Drainer) -> None:
    for _ in range(200):
        if not drainer.running:
            return
        threading.Event().wait(0.01)
    raise AssertionError("drain did not finish")


class DrainerTests(unittest.TestCase):
    def test_trigger_during_a_drain_runs_exactly_one_more_pass(self) -> None:
        release = threading.Event()
        started = threading.Event()
        calls: list[int] = []

        def drain_once() -> int:
            calls.append(1)
            started.set()
            release.wait(2)
            return 0

        drainer = Drainer(drain_once)
        self.assertTrue(drainer.trigger())
        started.wait(2)
        # Several triggers while busy collapse into a single follow-up pass.
        self.assertFalse(drainer.trigger())
        self.assertFalse(drainer.trigger())
        release.set()
        _wait_idle(drainer)
        self.assertEqual(len(calls), 2)

    def test_a_failing_drain_does_not_stop_later_triggers(self) -> None:
        outcomes = [RuntimeError("database unavailable"), 3]

        def drain_once() -> int:
            outcome = outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

        drainer = Drainer(drain_once)
        with self.assertLogs("calc_worker.trigger", level="ERROR"):
            drainer.trigger()
            _wait_idle(drainer)
        self.assertTrue(drainer.trigger())
        _wait_idle(drainer)
        self.assertEqual(outcomes, [])


class HttpTests(unittest.TestCase):
    def setUp(self) -> None:
        self.drainer = mock.Mock()
        self.drainer.trigger.return_value = True
        self.server = make_server(0, make_handler(self.drainer, TOKEN))
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()

    def _call(self, method: str, path: str, token: str | None = None) -> int:
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", method=method)
        if token is not None:
            request.add_header("X-Worker-Token", token)
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def test_health_is_open(self) -> None:
        self.assertEqual(self._call("GET", "/health"), 200)

    def test_run_requires_the_token(self) -> None:
        self.assertEqual(self._call("POST", "/run"), 401)
        self.assertEqual(self._call("POST", "/run", "wrong-token"), 401)
        self.drainer.trigger.assert_not_called()

    def test_run_with_the_token_starts_a_drain(self) -> None:
        self.assertEqual(self._call("POST", "/run", TOKEN), 202)
        self.drainer.trigger.assert_called_once_with()

    def test_unknown_paths_are_404(self) -> None:
        self.assertEqual(self._call("GET", "/run"), 404)
        self.assertEqual(self._call("POST", "/other", TOKEN), 404)


class StartupTests(unittest.TestCase):
    def test_refuses_a_short_token(self) -> None:
        env = {"DATABASE_URL": "postgresql://x", "CALC_WORKER_TRIGGER_TOKEN": "short"}
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaises(SystemExit):
                main()

    def test_refuses_a_missing_database_url(self) -> None:
        with mock.patch.dict(os.environ, {"CALC_WORKER_TRIGGER_TOKEN": TOKEN}, clear=True):
            with self.assertRaises(SystemExit):
                main()


if __name__ == "__main__":
    unittest.main()
