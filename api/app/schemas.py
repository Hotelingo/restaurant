from __future__ import annotations

from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, field_validator


class OutletContext(BaseModel):
    id: UUID
    name: str
    code: str | None
    currency_code: str
    timezone: str
    roles: list[str]


class OrganisationContext(BaseModel):
    id: UUID
    name: str
    slug: str
    roles: list[str]
    outlets: list[OutletContext]


class AuthContextResponse(BaseModel):
    user_id: UUID
    organisations: list[OrganisationContext]


class BootstrapRequest(BaseModel):
    organisation_name: str = Field(min_length=1, max_length=200)
    organisation_slug: str = Field(pattern=r"^[a-z0-9]+(?:-[a-z0-9]+)*$", max_length=80)
    outlet_name: str = Field(min_length=1, max_length=200)
    outlet_code: str | None = Field(default=None, max_length=40)
    currency_code: str = Field(min_length=3, max_length=3)
    timezone: str = Field(min_length=1, max_length=100)
    fiscal_year_start_month: int = Field(ge=1, le=12)

    @field_validator("currency_code")
    @classmethod
    def normalize_currency(cls, value: str) -> str:
        return value.upper()


class BootstrapResponse(BaseModel):
    organisation_id: UUID
    outlet_id: UUID
    role: Literal["admin"] = "admin"
