"""Send requests to a URL at a steady rate and print one line per request.

    python loadgen.py http://rollout-app [interval_seconds]

Each line is "<epoch milliseconds> <status or ERR> <version>". A new connection is used for every
request, so each one is balanced across the pods like a new client would be. Stops on SIGTERM.
"""

from __future__ import annotations

import json
import signal
import sys
import time
import urllib.error
import urllib.request

running = True


def stop(*_: object) -> None:
    global running
    running = False


def one(url: str, timeout: float) -> tuple[str, str]:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            body = json.loads(response.read())
            return str(response.status), str(body.get("version", "?"))
    except urllib.error.HTTPError as error:
        return str(error.code), "-"
    except Exception:  # connection refused, reset, timeout: all count as a failed request
        return "ERR", "-"


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    url = argv[1]
    interval = float(argv[2]) if len(argv) > 2 else 0.05
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    while running:
        started = time.monotonic()
        status, version = one(url, timeout=2.0)
        print(f"{int(time.time() * 1000)} {status} {version}", flush=True)
        time.sleep(max(0.0, interval - (time.monotonic() - started)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
