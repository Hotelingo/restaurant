from uuid import UUID

import pytest
from pydantic import ValidationError

from app.member_schemas import InvitationCreateRequest


def test_selected_scope_requires_an_outlet():
    with pytest.raises(ValidationError):
        InvitationCreateRequest(
            email="viewer@example.com",
            role="viewer",
            scope_mode="selected_outlets",
            outlet_ids=[],
        )


def test_all_outlets_rejects_selected_ids():
    with pytest.raises(ValidationError):
        InvitationCreateRequest(
            email="viewer@example.com",
            role="viewer",
            scope_mode="all_outlets",
            outlet_ids=[UUID("40000000-0000-0000-0000-000000000001")],
        )


def test_setup_analyst_is_not_a_customer_member_role():
    with pytest.raises(ValidationError):
        InvitationCreateRequest(
            email="staff@example.com",
            role="setup_analyst",
            scope_mode="all_outlets",
        )


def test_valid_selected_scope():
    payload = InvitationCreateRequest(
        email="Editor@Example.COM",
        role="editor",
        scope_mode="selected_outlets",
        outlet_ids=[UUID("40000000-0000-0000-0000-000000000001")],
    )
    assert payload.role == "editor"
    assert len(payload.outlet_ids) == 1
