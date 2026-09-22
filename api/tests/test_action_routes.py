from __future__ import annotations

import os
from uuid import UUID

import pytest
from pydantic import ValidationError

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault(
    "NEON_AUTH_JWKS_URL",
    "https://example.neon.tech/neondb/auth/.well-known/jwks.json",
)

from app.action_schemas import (
    ActionStatusRequest,
    PriorActionCheckRequest,
)
from app.main import app


def test_action_workflow_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "post" in paths["/decisions/{decision_id}/actions"]
    assert "get" in paths["/reviews/{review_id}/actions"]
    assert "post" in paths["/actions/{action_id}/status"]
    assert "get" in paths["/actions/{action_id}/events"]
    assert "post" in paths["/actions/{action_id}/verification"]
    assert "get" in paths["/actions/{action_id}/verifications"]
    assert "get" in paths[
        "/outlets/{outlet_id}/periods/{period_id}/prior-actions"
    ]


def test_action_mutations_require_idempotency_key() -> None:
    spec = app.openapi()
    mutations = [
        ("/decisions/{decision_id}/actions", "post"),
        ("/actions/{action_id}/status", "post"),
        ("/actions/{action_id}/verification", "post"),
    ]
    for path, method in mutations:
        operation = spec["paths"][path][method]
        header = next(
            item
            for item in operation["parameters"]
            if item["in"] == "header" and item["name"] == "Idempotency-Key"
        )
        assert header["required"] is True
        assert header["schema"]["minLength"] == 8


def test_closed_status_requires_closure_evidence() -> None:
    with pytest.raises(ValidationError):
        ActionStatusRequest(status="CLOSED")

    valid = ActionStatusRequest(
        status="CLOSED",
        closure_evidence="Signed roster and overtime report checked.",
        status_tag="follow_up_monitor",
    )
    assert valid.status == "CLOSED"


def test_prior_action_yes_no_answers_require_evidence() -> None:
    with pytest.raises(ValidationError):
        PriorActionCheckRequest(
            verification_period_id=UUID(
                "00000000-0000-0000-0000-000000000001"
            ),
            completed_answer="YES",
            driver_moved_answer="UNKNOWN",
            result_responded_answer="UNKNOWN",
            outcome="CONTINUE",
            note="Follow-up continues.",
        )


def test_close_verification_requires_closure_evidence() -> None:
    with pytest.raises(ValidationError):
        PriorActionCheckRequest(
            verification_period_id=UUID(
                "00000000-0000-0000-0000-000000000001"
            ),
            completed_answer="YES",
            completion_evidence="Roster implemented.",
            driver_moved_answer="YES",
            driver_evidence="Overtime reduced.",
            result_responded_answer="YES",
            result_evidence="Labour cost per cover improved.",
            outcome="CLOSE",
        )


def test_valid_close_verification_supports_follow_up_monitor() -> None:
    payload = PriorActionCheckRequest(
        verification_period_id=UUID(
            "00000000-0000-0000-0000-000000000001"
        ),
        completed_answer="YES",
        completion_evidence="Roster implemented.",
        driver_moved_answer="YES",
        driver_evidence="Overtime reduced from 220 to 125 hours.",
        result_responded_answer="YES",
        result_evidence="Labour cost improved and service remained stable.",
        outcome="CLOSE",
        status_tag="follow_up_monitor",
        closure_evidence="August evidence verified.",
    )
    assert payload.outcome == "CLOSE"
    assert payload.status_tag == "follow_up_monitor"


def test_reopen_requires_reason_and_cannot_claim_new_closure() -> None:
    with pytest.raises(ValidationError):
        PriorActionCheckRequest(
            verification_period_id=UUID(
                "00000000-0000-0000-0000-000000000001"
            ),
            completed_answer="UNKNOWN",
            driver_moved_answer="NO",
            driver_evidence="Overtime trigger recurred.",
            result_responded_answer="NO",
            result_evidence="Labour cost worsened again.",
            outcome="REOPEN",
            note="Prior conclusion no longer holds.",
        )

    valid = PriorActionCheckRequest(
        verification_period_id=UUID(
            "00000000-0000-0000-0000-000000000001"
        ),
        completed_answer="UNKNOWN",
        driver_moved_answer="NO",
        driver_evidence="Overtime trigger recurred.",
        result_responded_answer="NO",
        result_evidence="Labour cost worsened again.",
        outcome="REOPEN",
        reopen_reason="The monitored trigger recurred.",
    )
    assert valid.outcome == "REOPEN"


def test_waiting_on_owner_tag_only_applies_to_continuing_action() -> None:
    with pytest.raises(ValidationError):
        PriorActionCheckRequest(
            verification_period_id=UUID(
                "00000000-0000-0000-0000-000000000001"
            ),
            completed_answer="UNKNOWN",
            driver_moved_answer="UNKNOWN",
            result_responded_answer="UNKNOWN",
            outcome="CLOSE",
            status_tag="waiting_on_owner",
            closure_evidence="Closed.",
            note="Owner response pending.",
        )

    valid = PriorActionCheckRequest(
        verification_period_id=UUID(
            "00000000-0000-0000-0000-000000000001"
        ),
        completed_answer="UNKNOWN",
        driver_moved_answer="UNKNOWN",
        result_responded_answer="UNKNOWN",
        outcome="CONTINUE",
        status_tag="waiting_on_owner",
        note="Owner contract decision is still pending.",
    )
    assert valid.status_tag == "waiting_on_owner"
