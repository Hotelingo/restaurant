from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, model_validator

MemberRole = Literal["admin", "editor", "viewer", "reviewer"]
ScopeMode = Literal["all_outlets", "selected_outlets"]


class InvitationCreateRequest(BaseModel):
    email: EmailStr
    role: MemberRole
    scope_mode: ScopeMode = "all_outlets"
    outlet_ids: list[UUID] = Field(default_factory=list, max_length=100)
    expires_in_hours: int = Field(default=72, ge=1, le=168)

    @model_validator(mode="after")
    def validate_scope(self):
        if self.scope_mode == "selected_outlets" and not self.outlet_ids:
            raise ValueError("Selected-outlet invitations require at least one outlet")
        if self.scope_mode == "all_outlets" and self.outlet_ids:
            raise ValueError("All-outlets invitations cannot include selected outlet IDs")
        if len(set(self.outlet_ids)) != len(self.outlet_ids):
            raise ValueError("Selected outlet IDs must be unique")
        return self


class InvitationCreateResponse(BaseModel):
    invitation_id: UUID
    token: str
    accept_path: str
    expires_at: datetime


class InvitationPreviewResponse(BaseModel):
    invitation_id: UUID
    organisation_name: str
    role: str
    scope_mode: str
    outlet_names: list[str]
    inviter_name: str | None
    expires_at: datetime
    status: str


class InvitationDecisionResponse(BaseModel):
    organisation_id: UUID | None = None
    membership_id: UUID | None = None
    invitation_id: UUID | None = None


class MembershipActiveRequest(BaseModel):
    active: bool


class MembershipActiveResponse(BaseModel):
    membership_id: UUID
    active: bool


class MemberRow(BaseModel):
    membership_id: UUID
    user_id: UUID
    display_name: str | None
    email: str | None
    role: str
    scope_mode: str
    outlet_ids: list[UUID]
    outlet_names: list[str]
    active: bool


class InvitationRow(BaseModel):
    invitation_id: UUID
    email: str
    role: str
    scope_mode: str
    outlet_ids: list[UUID]
    outlet_names: list[str]
    status: str
    expires_at: datetime
    created_at: datetime


class OrganisationOutletRow(BaseModel):
    id: UUID
    name: str
    code: str | None


class MembersResponse(BaseModel):
    organisation_id: UUID
    organisation_name: str
    outlets: list[OrganisationOutletRow]
    members: list[MemberRow]
    invitations: list[InvitationRow]
