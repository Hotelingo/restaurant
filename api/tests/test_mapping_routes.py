from __future__ import annotations

import asyncio
import os
from contextlib import asynccontextmanager
from types import SimpleNamespace
from uuid import UUID, uuid4

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

import pytest
from fastapi import HTTPException
from psycopg.errors import CheckViolation, InsufficientPrivilege

from app.auth import AuthenticatedUser
from app.main import app
from app.routes import import_workflow, mappings
from app.routes.import_workflow import MappingConfirmRequest
from app.routes.mappings import (
    MappingProfileSummary,
    MappingRevisionRequest,
)

USER = AuthenticatedUser(id=uuid4(), email=None, name=None)


class _Result:
    def __init__(self, rows):
        self._rows = rows

    async def fetchone(self):
        return self._rows[0] if self._rows else None

    async def fetchall(self):
        return self._rows


class _Conn:
    """Answers each execute() with the next scripted result and records calls."""

    def __init__(self, *results):
        self._results = list(results)
        self.calls: list[tuple[str, tuple]] = []

    async def execute(self, sql, params=()):
        self.calls.append((sql, params))
        outcome = self._results.pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return _Result(outcome)


def _patch_transaction(monkeypatch, module, conn) -> None:
    @asynccontextmanager
    async def fake_transaction(_user_id):
        yield conn

    monkeypatch.setattr(module, "user_transaction", fake_transaction)


def _request():
    return SimpleNamespace(state=SimpleNamespace(correlation_id="corr-test"))


def test_mapping_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "get" in paths["/outlets/{outlet_id}/mapping-profiles"]
    assert "get" in paths["/mapping-profiles/{source_profile_id}"]
    assert "post" in paths["/mapping-profiles/versions/{profile_version_id}/revisions"]


def test_revision_requires_idempotency_key() -> None:
    operation = app.openapi()["paths"]["/mapping-profiles/versions/{profile_version_id}/revisions"]["post"]
    header = next(
        item for item in operation["parameters"]
        if item["in"] == "header" and item["name"] == "Idempotency-Key"
    )
    assert header["required"] is True
    assert header["schema"]["minLength"] == 8


def test_revision_accepts_only_editable_value_fields() -> None:
    MappingRevisionRequest(value_changes=[
        {"field_name": "product_group", "source_value": "Wine", "canonical_value": "beverage"}
    ])
    with pytest.raises(ValueError):
        MappingRevisionRequest(value_changes=[
            {"field_name": "account_name", "source_value": "x", "canonical_value": "y"}
        ])


def test_profile_list_query_returns_exactly_the_summary_fields(monkeypatch) -> None:
    from test_import_workflow_routes import _select_output_names

    outlet_id = uuid4()
    conn = _Conn([{"id": outlet_id, "can_edit": True}], [])
    _patch_transaction(monkeypatch, mappings, conn)

    response = asyncio.run(mappings.list_mapping_profiles(outlet_id, USER))

    assert response.can_edit is True
    assert response.profiles == []
    assert _select_output_names(conn.calls[1][0]) == set(MappingProfileSummary.model_fields)
    assert conn.calls[1][1] == (outlet_id,)


def test_unknown_outlet_is_404(monkeypatch) -> None:
    _patch_transaction(monkeypatch, mappings, _Conn([]))
    with pytest.raises(HTTPException) as err:
        asyncio.run(mappings.list_mapping_profiles(uuid4(), USER))
    assert err.value.status_code == 404


def test_revision_passes_changes_to_the_database_function(monkeypatch) -> None:
    version_id, new_id, profile_id = uuid4(), uuid4(), uuid4()
    conn = _Conn(
        [{"revised_profile_version_id": new_id, "revised_version_no": 3, "reused": False}],
        [{"source_profile_id": profile_id}],
    )
    _patch_transaction(monkeypatch, mappings, conn)
    payload = MappingRevisionRequest(account_changes=[
        {"source_identity_key": "code:5000", "ladder_line_code": "OTHER_DIRECT_OPERATING"}
    ])

    response = asyncio.run(mappings.revise_mapping_profile(
        version_id, payload, _request(), "revision-key-1", USER
    ))

    assert (response.profile_version_id, response.version_no) == (new_id, 3)
    assert response.source_profile_id == profile_id
    sql, params = conn.calls[0]
    assert "revise_profile_mappings" in sql
    assert params[0] == version_id
    assert params[1] == "revision-key-1"
    assert params[2].obj == [
        {"source_identity_key": "code:5000", "ladder_line_code": "OTHER_DIRECT_OPERATING"}
    ]
    assert params[3].obj == []
    assert params[4] == "corr-test"
    # The profile lookup must be its own statement: the calling statement
    # cannot see the version row the function just inserted.
    assert "revise_profile_mappings" not in conn.calls[1][0]
    assert conn.calls[1][1] == (new_id,)


@pytest.mark.parametrize(
    ("error", "status_code"),
    [
        (CheckViolation("this mapping has changed since it was opened; reload and try again"), 422),
        (InsufficientPrivilege("mapping version is not available"), 404),
    ],
)
def test_revision_errors_map_to_http(monkeypatch, error, status_code) -> None:
    _patch_transaction(monkeypatch, mappings, _Conn(error))
    with pytest.raises(HTTPException) as err:
        asyncio.run(mappings.revise_mapping_profile(
            uuid4(), MappingRevisionRequest(), _request(), "revision-key-2", USER
        ))
    assert err.value.status_code == status_code
    if status_code == 422:
        assert "reload" in err.value.detail["message"]


def test_confirm_builds_on_the_active_version_after_a_revision(monkeypatch) -> None:
    # The batch was read against an older version; the layout was revised
    # since. Confirming must clone the active version, not the stale one.
    batch_id, active_id, new_id = uuid4(), uuid4(), uuid4()
    conn = _Conn(
        [{"template_code": "T1"}],
        [{"active_profile_version_id": active_id}],
        [{
            "confirmed_profile_version_id": new_id,
            "confirmed_version_no": 4,
            "confirmed_batch_status": "validating",
            "reused": False,
        }],
    )
    _patch_transaction(monkeypatch, import_workflow, conn)

    asyncio.run(import_workflow.confirm_import_mapping(
        batch_id, MappingConfirmRequest(), _request(), "confirm-key-1", USER
    ))

    confirm_sql, confirm_params = conn.calls[2]
    assert "confirm_financial_mapping" in confirm_sql
    assert confirm_params[3] == active_id


def test_confirm_keeps_an_explicit_base_version(monkeypatch) -> None:
    explicit = UUID("00000000-0000-0000-0000-00000000000a")
    conn = _Conn(
        [{"template_code": "T1"}],
        [{
            "confirmed_profile_version_id": uuid4(),
            "confirmed_version_no": 2,
            "confirmed_batch_status": "validating",
            "reused": False,
        }],
    )
    _patch_transaction(monkeypatch, import_workflow, conn)

    asyncio.run(import_workflow.confirm_import_mapping(
        uuid4(), MappingConfirmRequest(base_profile_version_id=explicit),
        _request(), "confirm-key-2", USER,
    ))

    assert len(conn.calls) == 2
    assert conn.calls[1][1][3] == explicit


def test_profile_matching_considers_only_active_versions() -> None:
    import inspect

    source = inspect.getsource(import_workflow.parse_import_batch)
    assert "sp.active_profile_version_id=pv.id" in source
