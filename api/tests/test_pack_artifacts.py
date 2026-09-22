from __future__ import annotations

from copy import deepcopy

from app.pack_artifacts import (
    PACK_RENDERER_VERSION,
    PACK_TEMPLATE_VERSION,
    artifact_sha256,
    pack_source_sha256,
    render_owner_pack_html,
)


def fixture() -> dict:
    return {
        "pack": {
            "id": "10000000-0000-0000-0000-000000000001",
            "organisation_id": "10000000-0000-0000-0000-000000000002",
            "outlet_id": "10000000-0000-0000-0000-000000000003",
            "version_no": 1,
            "review_id": "10000000-0000-0000-0000-000000000004",
            "calc_run_id": "10000000-0000-0000-0000-000000000005",
            "status": "in_review",
            "generated_at": "2026-09-22T09:00:00+00:00",
            "reconciliation_disclosure": None,
        },
        "organisation": "Example Hospitality",
        "outlet": "Café Démo 東京",
        "period": {
            "label": "July 2026",
            "start": "2026-07-01",
            "end": "2026-07-31",
        },
        "currency_code": "USD",
        "comparator_scenario": "budget",
        "management_pl": [
            {
                "code": "NET_SALES",
                "name": "Net Sales",
                "display_order": 1,
                "actual": "228500.0000",
                "comparator": "232000.0000",
                "variance": "-3500.0000",
                "unit": "currency",
                "currency_code": "USD",
            }
        ],
        "claims": [
            {
                "id": "10000000-0000-0000-0000-000000000006",
                "section_code": "headline",
                "claim_text": "Net sales movement was 3,500 adverse to budget.",
                "claim_status": "accepted",
                "evidence_status": "validated",
                "reviewed_by": "10000000-0000-0000-0000-000000000007",
                "reviewed_at": "2026-09-22T09:10:00+00:00",
                "citations": [
                    {
                        "calc_id": "PL.VAR.NET_SALES",
                        "value": "-3500.0000",
                        "unit": "currency",
                        "currency_code": "USD",
                        "calculation_status": "CALCULATED",
                        "evidence_status": "supported",
                    }
                ],
            }
        ],
        "issues": [
            {
                "id": "10000000-0000-0000-0000-000000000008",
                "title": "Net Sales",
                "ladder_code": "NET_SALES",
                "evidence_status": "validated",
                "decision_id": "10000000-0000-0000-0000-000000000009",
                "disposition": "ACT",
                "decision_text": "Adjust price architecture",
                "owner": "General Manager",
                "lever": "Price architecture",
                "guardrail": "Guest value",
                "verification_metric": "Contribution",
                "target_trigger": None,
                "due_date": "2026-08-15",
                "cadence": "weekly",
                "forecast_treatment": None,
                "action_id": "10000000-0000-0000-0000-000000000010",
                "action_status": "OPEN_ON_TRACK",
                "forecast_effect": "Verify before forecast change",
            }
        ],
    }


def test_owner_pack_html_is_byte_deterministic_and_utf8() -> None:
    snapshot = fixture()
    first = render_owner_pack_html(snapshot)
    second = render_owner_pack_html(deepcopy(snapshot))
    assert first == second
    assert artifact_sha256(first) == artifact_sha256(second)
    assert "Café Démo 東京".encode("utf-8") in first
    assert PACK_RENDERER_VERSION.encode() in first
    assert PACK_TEMPLATE_VERSION.encode() in first


def test_source_hash_ignores_workflow_status_but_detects_content_change() -> None:
    snapshot = fixture()
    original = pack_source_sha256(snapshot)

    moved = deepcopy(snapshot)
    moved["pack"]["status"] = "changes_requested"
    assert pack_source_sha256(moved) == original

    changed = deepcopy(snapshot)
    changed["claims"][0]["claim_text"] = "Updated reviewed narrative."
    assert pack_source_sha256(changed) != original


def test_rejected_claim_is_not_rendered_into_final_narrative() -> None:
    snapshot = fixture()
    snapshot["claims"][0]["claim_status"] = "rejected"
    output = render_owner_pack_html(snapshot).decode("utf-8")
    assert "Net sales movement was" not in output
    assert "No accepted narrative claims." in output
