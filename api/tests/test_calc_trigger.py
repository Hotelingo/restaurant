from __future__ import annotations

import asyncio
import os
import urllib.error
from contextlib import asynccontextmanager
from uuid import uuid4

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

import pytest

from app import calc_trigger
from app.auth import AuthenticatedUser
from app.config import Settings
from app.routes import data_centre
from app.routes.data_centre import CalculationRequest

URL = "http://worker.internal:8080/run"
TOKEN = "k" * 40


def _settings(**overrides) -> Settings:
    values = {
        "database_url": "postgresql://x",
        "neon_auth_base_url": "https://example.neon.tech/neondb/auth",
        "neon_auth_jwks_url": "https://example.neon.tech/neondb/auth/.well-known/jwks.json",
        "calc_worker_trigger_url": URL,
        "calc_worker_trigger_token": TOKEN,
    }
    values.update(overrides)
    return Settings(**values)


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    monkeypatch.setattr(calc_trigger, "_last_sent", 0.0)
    monkeypatch.setattr(calc_trigger, "RETRY_DELAYS_SECONDS", (0.0, 0.0, 0.0))


def test_does_nothing_when_the_worker_is_not_configured() -> None:
    async def run():
        return calc_trigger.wake_calculation_worker(
            settings=_settings(calc_worker_trigger_url=None)
        )

    assert asyncio.run(run()) is False


def test_posts_the_token_and_retries_while_the_worker_boots(monkeypatch) -> None:
    calls: list[tuple[str, str]] = []
    outcomes = [urllib.error.URLError("connection refused"), 202]

    def fake_post(url: str, token: str) -> int:
        calls.append((url, token))
        outcome = outcomes.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(calc_trigger, "_post", fake_post)
    assert asyncio.run(calc_trigger._send(URL, TOKEN)) is True
    assert calls == [(URL, TOKEN), (URL, TOKEN)]


def test_a_rejected_token_is_not_retried(monkeypatch) -> None:
    calls: list[int] = []

    def fake_post(url: str, token: str) -> int:
        calls.append(1)
        raise urllib.error.HTTPError(url, 401, "unauthorised", {}, None)

    monkeypatch.setattr(calc_trigger, "_post", fake_post)
    assert asyncio.run(calc_trigger._send(URL, TOKEN)) is False
    assert len(calls) == 1


def test_status_polls_are_rate_limited_but_new_requests_are_not(monkeypatch) -> None:
    sent: list[int] = []

    async def fake_send(url: str, token: str) -> bool:
        sent.append(1)
        return True

    monkeypatch.setattr(calc_trigger, "_send", fake_send)

    async def run():
        settings = _settings()
        results = [
            calc_trigger.wake_calculation_worker(from_poll=True, settings=settings),
            calc_trigger.wake_calculation_worker(from_poll=True, settings=settings),
            calc_trigger.wake_calculation_worker(settings=settings),
        ]
        await asyncio.gather(*calc_trigger._background)
        return results

    assert asyncio.run(run()) == [True, False, True]
    assert len(sent) == 2


@pytest.mark.parametrize(("request_status", "woken"), [("pending", True), ("completed", False)])
def test_calculate_wakes_the_worker_only_for_outstanding_work(monkeypatch, request_status, woken) -> None:
    class _Result:
        async def fetchone(self):
            return {
                "request_id": uuid4(), "request_status": request_status,
                "reused": False, "source_batch_id": uuid4(),
            }

    class _Conn:
        async def execute(self, sql, params):
            return _Result()

    @asynccontextmanager
    async def fake_transaction(_user_id):
        yield _Conn()

    wakes: list[int] = []
    monkeypatch.setattr(data_centre, "user_transaction", fake_transaction)
    monkeypatch.setattr(data_centre, "wake_calculation_worker", lambda **_: wakes.append(1))

    user = AuthenticatedUser(id=uuid4(), email=None, name=None)
    asyncio.run(data_centre.request_calculation(uuid4(), CalculationRequest(module="pl"), user))
    assert bool(wakes) is woken
