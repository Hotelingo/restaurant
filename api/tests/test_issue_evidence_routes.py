from __future__ import annotations

import os
from decimal import Decimal
from uuid import UUID

import pytest
from pydantic import ValidationError

os.environ.setdefault("DATABASE_URL", "postgresql://test:test@localhost:5432/test")
os.environ.setdefault("NEON_AUTH_BASE_URL", "https://example.neon.tech/neondb/auth")
os.environ.setdefault("NEON_AUTH_JWKS_URL", "https://example.neon.tech/neondb/auth/.well-known/jwks.json")

from app.issue_schemas import (
    DecisionCreateRequest,
    DiagnosisCreateRequest,
    DriverEvidenceCreateRequest,
    EvidenceRequestCreateRequest,
)
from app.main import app
from app.routes.issue_evidence import _driver_evidence_from_row


def test_diagnosis_evidence_routes_are_registered() -> None:
    paths = app.openapi()["paths"]
    assert "post" in paths["/issues/{issue_id}/diagnosis"]
    assert "post" in paths["/issues/{issue_id}/driver-evidence"]
    assert "post" in paths["/issues/{issue_id}/evidence-requests"]
    assert "get" in paths["/issues/{issue_id}/evidence"]
    assert "post" in paths["/evidence-requests/{evidence_request_id}/fulfill"]
    assert "post" in paths["/issues/{issue_id}/decision"]
    assert "get" in paths["/issues/{issue_id}/decisions"]


def test_all_diagnosis_evidence_mutations_require_idempotency_key() -> None:
    paths = [
        "/issues/{issue_id}/diagnosis",
        "/issues/{issue_id}/driver-evidence",
        "/issues/{issue_id}/evidence-requests",
        "/evidence-requests/{evidence_request_id}/fulfill",
        "/issues/{issue_id}/decision",
    ]
    spec = app.openapi()
    for path in paths:
        operation = spec["paths"][path]["post"]
        header = next(
            item
            for item in operation["parameters"]
            if item["in"] == "header" and item["name"] == "Idempotency-Key"
        )
        assert header["required"] is True
        assert header["schema"]["minLength"] == 8


def test_schema_distinguishes_supported_hypothesis_and_unknown() -> None:
    supported = DiagnosisCreateRequest(
        diagnosis_state="supported",
        driver_code="rate_price",
        evidence_status="validated",
        supported_summary="Rate bridge reconciled.",
    )
    hypothesis = DiagnosisCreateRequest(
        diagnosis_state="hypothesis",
        driver_code="mix",
        evidence_status="partly_supported",
        hypothesis_summary="Mix may explain part of the movement.",
    )
    unknown = DiagnosisCreateRequest(
        diagnosis_state="unknown",
        evidence_status="evidence_required",
        unknowns="Meal-period detail has not been supplied.",
    )
    assert supported.diagnosis_state == "supported"
    assert hypothesis.diagnosis_state == "hypothesis"
    assert unknown.diagnosis_state == "unknown"


def test_evidence_request_rejects_blank_minimum_field() -> None:
    with pytest.raises(ValidationError):
        EvidenceRequestCreateRequest(
            requested_dataset="Meal-period sales",
            reason="Test the mix hypothesis",
            minimum_fields=["business_date", " "],
            owner="Restaurant Manager",
            due_date="2026-08-10",
        )


def test_driver_evidence_adapter_keeps_unknown_separate_from_zero() -> None:
    row = {
        "id": UUID("00000000-0000-0000-0000-000000000001"),
        "review_issue_id": UUID("00000000-0000-0000-0000-000000000002"),
        "diagnosis_id": UUID("00000000-0000-0000-0000-000000000003"),
        "driver_code": "mix",
        "driver_name": "Mix",
        "evidence_source_type": "requested_dataset",
        "evidence_source_id": "meal-period-detail",
        "evidence_status": "evidence_required",
        "quantified_impact": None,
        "reconciliation_impact": Decimal("0.0000"),
        "note": "Evidence still required",
        "approved_by": None,
        "created_by": UUID("00000000-0000-0000-0000-000000000004"),
        "created_at": "2026-09-22T08:00:00+00:00",
    }
    evidence = _driver_evidence_from_row(row)
    assert evidence.quantified_impact is None
    assert evidence.reconciliation_impact == "0.0000"
    assert evidence.evidence_status == "evidence_required"


def test_driver_evidence_payload_preserves_decimal_not_float() -> None:
    payload = DriverEvidenceCreateRequest(
        driver_code="rate_price",
        evidence_source_type="validated_bridge",
        evidence_source_id="bridge-1",
        evidence_status="validated",
        quantified_impact=Decimal("943.1250"),
    )
    assert payload.quantified_impact == Decimal("943.1250")



def test_decision_schema_enforces_each_disposition() -> None:
    with pytest.raises(ValidationError):
        DecisionCreateRequest(
            disposition="ACT",
            decision_text="Act now",
            owner="GM",
            lever="Roster",
            verification_metric="Labour per cover",
            due_date="2026-08-15",
        )

    with pytest.raises(ValidationError):
        DecisionCreateRequest(
            disposition="INVESTIGATE",
            decision_text="Collect evidence",
            owner="Kitchen Manager",
            due_date="2026-08-10",
        )

    with pytest.raises(ValidationError):
        DecisionCreateRequest(
            disposition="MONITOR",
            decision_text="Watch it",
            cadence="weekly",
        )

    with pytest.raises(ValidationError):
        DecisionCreateRequest(
            disposition="ESCALATE",
            decision_text="Send to owner",
            owner="Finance Director",
            consequence_of_waiting="Tariff exposure continues",
            due_date="2026-08-05",
        )

    with pytest.raises(ValidationError):
        DecisionCreateRequest(
            disposition="CLOSE",
            decision_text="Explained movement",
            forecast_treatment="Return to normal",
        )


def test_valid_act_can_use_cadence_instead_of_due_date() -> None:
    payload = DecisionCreateRequest(
        disposition="ACT",
        decision_text="Rebuild the roster against expected covers",
        owner="General Manager",
        lever="Roster",
        guardrail="Protect service levels",
        verification_metric="Labour hours per cover",
        cadence="weekly",
    )
    assert payload.disposition == "ACT"
    assert payload.due_date is None
    assert payload.cadence == "weekly"


def test_valid_investigate_requires_named_evidence_request() -> None:
    payload = DecisionCreateRequest(
        disposition="INVESTIGATE",
        decision_text="Collect the requested evidence before acting",
        owner="Kitchen Manager",
        due_date="2026-08-10",
        evidence_request_id=UUID("00000000-0000-0000-0000-000000000099"),
    )
    assert payload.evidence_request_id == UUID(
        "00000000-0000-0000-0000-000000000099"
    )
