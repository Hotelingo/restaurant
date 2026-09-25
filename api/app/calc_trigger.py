"""Wake the on-demand calculation worker (workers/trigger_server.py).

The queue in the database is the source of truth; this is only a nudge so an
idle worker does not have to poll. It is fire-and-forget: the user's request
never waits for it and never fails because of it. A sleeping worker's first
request can fail while it boots, so a few retries are made in the background.
Status polls call it too (rate-limited), so a nudge lost during a cold boot
is repaired by the next poll.
"""

from __future__ import annotations

import asyncio
import logging
import time
import urllib.error
import urllib.request

from .config import Settings, get_settings

log = logging.getLogger("calc_trigger")

RETRY_DELAYS_SECONDS = (0.0, 3.0, 8.0)
POLL_MIN_INTERVAL_SECONDS = 15.0

_background: set[asyncio.Task] = set()
_last_sent = 0.0


def _post(url: str, token: str) -> int:
    request = urllib.request.Request(
        url, method="POST", data=b"", headers={"X-Worker-Token": token}
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        return response.status


async def _send(url: str, token: str) -> bool:
    for delay in RETRY_DELAYS_SECONDS:
        if delay:
            await asyncio.sleep(delay)
        try:
            status = await asyncio.to_thread(_post, url, token)
            if 200 <= status < 300:
                return True
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403, 404):
                log.error("calc_trigger.rejected status=%s", exc.code)
                return False
        except (urllib.error.URLError, OSError, TimeoutError):
            pass
    log.warning("calc_trigger.unreachable")
    return False


def wake_calculation_worker(*, from_poll: bool = False, settings: Settings | None = None) -> bool:
    """Schedule a background nudge. Returns True if one was scheduled."""
    global _last_sent
    settings = settings or get_settings()
    url, token = settings.calc_worker_trigger_url, settings.calc_worker_trigger_token
    if not url or not token:
        return False
    now = time.monotonic()
    if from_poll and now - _last_sent < POLL_MIN_INTERVAL_SECONDS:
        return False
    _last_sent = now
    task = asyncio.get_running_loop().create_task(_send(url, token))
    _background.add(task)
    task.add_done_callback(_background.discard)
    return True
