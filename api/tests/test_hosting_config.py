from __future__ import annotations

import os

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

import importlib

from fastapi.testclient import TestClient


def _client(monkeypatch, **env: str) -> TestClient:
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    import app.config as config
    import app.main as main

    config.get_settings.cache_clear()
    importlib.reload(main)
    return TestClient(main.app)  # not a context manager: lifespan (DB pool) does not start


def _preflight(client: TestClient, origin: str):
    return client.options(
        "/auth/context",
        headers={"Origin": origin, "Access-Control-Request-Method": "GET"},
    )


def test_listed_origin_is_allowed(monkeypatch) -> None:
    client = _client(monkeypatch, CORS_ORIGINS="https://app.example.com")
    response = _preflight(client, "https://app.example.com")
    assert response.headers.get("access-control-allow-origin") == "https://app.example.com"


def test_preview_origins_match_the_regex_and_nothing_else(monkeypatch) -> None:
    client = _client(
        monkeypatch,
        CORS_ORIGINS="https://app.example.com",
        CORS_ORIGIN_REGEX=r"https://restaurant-[a-z0-9-]+-hotelingo\.vercel\.app",
    )
    allowed = _preflight(client, "https://restaurant-git-feature-x-hotelingo.vercel.app")
    assert allowed.headers.get("access-control-allow-origin") == "https://restaurant-git-feature-x-hotelingo.vercel.app"
    for origin in (
        "https://evil.example.com",
        "https://restaurant-x-hotelingo.vercel.app.evil.com",
        "http://restaurant-x-hotelingo.vercel.app",
    ):
        assert "access-control-allow-origin" not in _preflight(client, origin).headers, origin


def test_liveness_does_not_need_the_database(monkeypatch) -> None:
    client = _client(monkeypatch)
    assert client.get("/health").json() == {"status": "ok"}


def test_readiness_reports_503_without_a_database(monkeypatch) -> None:
    client = _client(monkeypatch)
    response = client.get("/health/ready")
    assert response.status_code == 503
    assert response.json()["database"] == "unreachable"
