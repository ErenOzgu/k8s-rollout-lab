"""The service and the load generator, without Kubernetes.

These run in a second. They check the behaviour the cluster tests lean on: readiness goes away on SIGTERM,
the service keeps answering while it drains, and a slow or broken release looks the way the manifests expect.
"""

from __future__ import annotations

import contextlib
import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

APP = Path(__file__).resolve().parent.parent / "app"


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def get(port: int, path: str = "/") -> tuple[int, str]:
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=2) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


class Service:
    """The server as a child process, so that signals are real."""

    def __init__(self, **env: str) -> None:
        self.port = free_port()
        self.output: str | None = None
        self.proc = subprocess.Popen(
            [sys.executable, str(APP / "server.py")],
            env={**os.environ, "PORT": str(self.port), "HOSTNAME": "pod-a", **env},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )

    def wait_listening(self, timeout: float = 5.0) -> float:
        start = time.monotonic()
        while time.monotonic() - start < timeout:
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.2).close()
                return time.monotonic() - start
            except OSError:
                time.sleep(0.02)
        raise AssertionError("the service never started listening")

    def stop(self) -> str:
        """Kill it if it is still running, and return everything it printed. Safe to call twice."""
        if self.output is None:
            if self.proc.poll() is None:
                self.proc.kill()
            self.output, _ = self.proc.communicate()
        return self.output

    def __enter__(self) -> Service:
        return self

    def __exit__(self, *exc: object) -> None:
        self.stop()


class TestService(unittest.TestCase):
    def test_root_reports_version_and_pod(self) -> None:
        with Service(VERSION="1.2.3") as svc:
            svc.wait_listening()
            code, body = get(svc.port)
            self.assertEqual(code, 200)
            self.assertEqual(json.loads(body), {"version": "1.2.3", "pod": "pod-a"})

    def test_healthy_and_ready_by_default(self) -> None:
        with Service() as svc:
            svc.wait_listening()
            self.assertEqual(get(svc.port, "/healthz")[0], 200)
            self.assertEqual(get(svc.port, "/readyz")[0], 200)

    def test_unknown_path_is_404(self) -> None:
        with Service() as svc:
            svc.wait_listening()
            self.assertEqual(get(svc.port, "/nope")[0], 404)

    def test_a_release_that_never_becomes_ready(self) -> None:
        with Service(FAIL_READY="1") as svc:
            svc.wait_listening()
            self.assertEqual(get(svc.port, "/healthz")[0], 200, "alive, so it is not restarted")
            self.assertEqual(get(svc.port, "/readyz")[0], 503)
            self.assertEqual(get(svc.port, "/")[0], 200, "it answers if something sends it traffic")

    def test_a_slow_start_does_not_listen_until_the_delay_is_over(self) -> None:
        with Service(START_DELAY="0.6") as svc:
            with self.assertRaises(OSError):
                socket.create_connection(("127.0.0.1", svc.port), timeout=0.2).close()
            waited = svc.wait_listening()
            self.assertGreater(waited, 0.2)
            self.assertEqual(get(svc.port, "/readyz")[0], 200)

    def test_sigterm_turns_readiness_off_but_keeps_serving_while_draining(self) -> None:
        with Service(DRAIN_SECONDS="1.0") as svc:
            svc.wait_listening()
            self.assertEqual(get(svc.port, "/readyz")[0], 200)
            svc.proc.send_signal(signal.SIGTERM)
            time.sleep(0.3)
            self.assertEqual(get(svc.port, "/readyz")[0], 503, "no new traffic should be sent")
            self.assertEqual(get(svc.port, "/")[0], 200, "traffic already on its way is still answered")
            self.assertEqual(get(svc.port, "/healthz")[0], 200, "draining is not a reason to restart")

    def test_exits_cleanly_after_the_drain_time_and_not_before(self) -> None:
        with Service(DRAIN_SECONDS="0.8") as svc:
            svc.wait_listening()
            sent = time.monotonic()
            svc.proc.send_signal(signal.SIGTERM)
            time.sleep(0.4)
            self.assertIsNone(svc.proc.poll(), "it left before the drain time was over")
            self.assertEqual(svc.proc.wait(timeout=5), 0)
            self.assertGreaterEqual(time.monotonic() - sent, 0.8)
            out = svc.stop()
            self.assertIn("SIGTERM", out)
            self.assertIn("stopped", out)

    def test_slow_answers_after_the_delay(self) -> None:
        with Service() as svc:
            svc.wait_listening()
            start = time.monotonic()
            self.assertEqual(get(svc.port, "/slow?ms=400")[0], 200)
            self.assertGreaterEqual(time.monotonic() - start, 0.4)

    def test_slow_refuses_a_missing_or_silly_delay(self) -> None:
        with Service() as svc:
            svc.wait_listening()
            for path in ("/slow", "/slow?ms=abc", "/slow?ms=-1", "/slow?ms=3600000"):
                self.assertEqual(get(svc.port, path)[0], 400, path)

    def test_a_request_still_running_when_sigterm_arrives_is_finished(self) -> None:
        # The request outlasts the drain (0.5 s). Without waiting for it, the process exits at 0.5 s and the
        # client gets a reset instead of a 200.
        with Service(DRAIN_SECONDS="0.5", FINISH_SECONDS="5") as svc:
            svc.wait_listening()
            result: list[tuple[int, str]] = []
            client = threading.Thread(target=lambda: result.append(get(svc.port, "/slow?ms=1800")))
            client.start()
            time.sleep(0.3)  # the request is running now
            svc.proc.send_signal(signal.SIGTERM)
            client.join(timeout=10)
            self.assertEqual(result, [(200, "slow ok\n")])
            self.assertEqual(svc.proc.wait(timeout=5), 0)
            self.assertIn("waiting up to 5s for 1 running request", svc.stop())

    def test_a_request_that_outlasts_finish_seconds_does_not_hold_the_pod_for_ever(self) -> None:
        with Service(DRAIN_SECONDS="0.2", FINISH_SECONDS="0.6") as svc:
            svc.wait_listening()

            def abandoned() -> None:
                with contextlib.suppress(OSError, http.client.HTTPException):
                    get(svc.port, "/slow?ms=8000")

            client = threading.Thread(target=abandoned, daemon=True)
            client.start()
            time.sleep(0.3)
            sent = time.monotonic()
            svc.proc.send_signal(signal.SIGTERM)
            self.assertEqual(svc.proc.wait(timeout=5), 0)
            self.assertLess(time.monotonic() - sent, 3)


class TestLoadgen(unittest.TestCase):
    def run_loadgen(self, port: int, seconds: float) -> list[list[str]]:
        proc = subprocess.Popen(
            [sys.executable, str(APP / "loadgen.py"), f"http://127.0.0.1:{port}/", "0.02"],
            stdout=subprocess.PIPE,
            text=True,
        )
        time.sleep(seconds)
        proc.send_signal(signal.SIGTERM)
        out, _ = proc.communicate(timeout=5)
        self.assertEqual(proc.returncode, 0)
        return [line.split() for line in out.splitlines()]

    def test_counts_successes_with_the_version_that_answered(self) -> None:
        with Service(VERSION="9.9.9") as svc:
            svc.wait_listening()
            lines = self.run_loadgen(svc.port, 0.5)
        self.assertGreater(len(lines), 5)
        self.assertTrue(all(len(line) == 3 for line in lines))
        self.assertEqual({line[1] for line in lines}, {"200"})
        self.assertEqual({line[2] for line in lines}, {"9.9.9"})

    def test_a_refused_connection_is_a_failed_request(self) -> None:
        lines = self.run_loadgen(free_port(), 0.4)
        self.assertGreater(len(lines), 3)
        self.assertEqual({line[1] for line in lines}, {"ERR"})

    def test_a_status_other_than_200_is_recorded_as_it_is(self) -> None:
        with Service() as svc:
            svc.wait_listening()
            proc = subprocess.Popen(
                [sys.executable, str(APP / "loadgen.py"), f"http://127.0.0.1:{svc.port}/nope", "0.02"],
                stdout=subprocess.PIPE,
                text=True,
            )
            time.sleep(0.3)
            proc.send_signal(signal.SIGTERM)
            out, _ = proc.communicate(timeout=5)
        self.assertEqual({line.split()[1] for line in out.splitlines()}, {"404"})


if __name__ == "__main__":
    unittest.main()
