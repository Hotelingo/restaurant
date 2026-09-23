"""Every database function the API calls must be executable by the role it runs as.

The API connects only as restaurant_app. Two Owner Pack writes were
deliberately left "server-only" and so could never be called: render and
sign-off always failed with "permission denied", invisible to CI because the
DB tests call those functions as the owner. This test reads the migrations
and the API source, so the same gap fails fast.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = sorted((ROOT / "db" / "migrations").glob("0*.sql"))
API_SOURCES = sorted((ROOT / "api" / "app").rglob("*.py"))

CALL = re.compile(r"\bfrom\s+([a-z_][a-z0-9_]*)\s*\(", re.IGNORECASE)
GRANT = re.compile(
    r"grant\s+execute\s+on\s+function\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\([^;]*?\)\s*to\s+([a-z_, ]+);",
    re.IGNORECASE | re.DOTALL,
)
SERVER_ROLE = "restaurant_pack_server"


def _grants() -> dict[str, set[str]]:
    granted: dict[str, set[str]] = {}
    for path in MIGRATIONS:
        for name, roles in GRANT.findall(path.read_text()):
            for role in roles.split(","):
                granted.setdefault(name.lower(), set()).add(role.strip().lower())
    return granted


def _sql_function_calls() -> dict[str, list[tuple[Path, int]]]:
    """`select * from fn(` style calls in API source, with their offsets."""
    defined_in_sql = {
        m.group(1).lower()
        for path in MIGRATIONS
        for m in re.finditer(r"create\s+or\s+replace\s+function\s+(?:public\.)?([a-z_][a-z0-9_]*)\s*\(", path.read_text(), re.IGNORECASE)
    }
    calls: dict[str, list[tuple[Path, int]]] = {}
    for path in API_SOURCES:
        text = path.read_text()
        for m in CALL.finditer(text):
            name = m.group(1).lower()
            if name in defined_in_sql:
                calls.setdefault(name, []).append((path, m.start()))
    return calls


def test_every_called_function_is_executable_by_the_api() -> None:
    granted = _grants()
    calls = _sql_function_calls()
    assert calls, "no SQL function calls found; the scanner is broken"
    missing = sorted(
        name for name in calls
        if not granted.get(name, set()) & {"restaurant_app", SERVER_ROLE}
    )
    assert not missing, f"API calls functions with no grant to restaurant_app or {SERVER_ROLE}: {missing}"


def test_server_only_functions_are_called_after_switching_role() -> None:
    granted = _grants()
    server_only = {name for name, roles in granted.items() if SERVER_ROLE in roles and "restaurant_app" not in roles}
    assert server_only, f"expected server-only functions granted to {SERVER_ROLE}"
    for name, sites in _sql_function_calls().items():
        if name not in server_only:
            continue
        for path, offset in sites:
            preceding = path.read_text()[max(0, offset - 600):offset]
            assert f"set local role {SERVER_ROLE}" in preceding, (
                f"{path.name} calls server-only {name}() without `set local role {SERVER_ROLE}` just before it"
            )
