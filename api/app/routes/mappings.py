"""Mappings page: view saved source mappings and revise them for future uploads.

Reads rely on the RLS read policies of the mapping tables (migration 0011).
The only write is ``revise_profile_mappings`` (migration 0041), a SECURITY
DEFINER function that clones the active approved version with the requested
changes into a new approved version. Approved versions are never edited, so
months already committed keep the mapping they were read with.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, InvalidParameterValue
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction

router = APIRouter(tags=["mappings"])

EDITOR_ROLES = "array['admin','editor','setup_analyst']::app_role[]"


class MappingVersionSummary(BaseModel):
    id: UUID
    version_no: int
    approved_at: datetime | None
    is_active: bool


class MappingProfileSummary(BaseModel):
    source_profile_id: UUID
    template_code: str
    source_label: str
    active_version_id: UUID | None
    active_version_no: int | None
    active_approved_at: datetime | None
    version_count: int
    account_count: int
    value_count: int
    item_count: int


class MappingProfileListResponse(BaseModel):
    outlet_id: UUID
    can_edit: bool
    profiles: list[MappingProfileSummary]


class AccountMappingView(BaseModel):
    source_identity_key: str
    source_account_code: str | None
    source_account_name: str
    ladder_line_code: str
    mapping_basis: str


class ValueMappingView(BaseModel):
    field_name: str
    source_value: str
    canonical_value: str


class ItemMappingView(BaseModel):
    source_item_code: str | None
    source_item_name: str
    canonical_item_key: str


class ColumnMappingView(BaseModel):
    source_column: str
    canonical_field: str


class MappingProfileDetailResponse(BaseModel):
    source_profile_id: UUID
    outlet_id: UUID
    template_code: str
    source_label: str
    active_version_id: UUID | None
    version_id: UUID
    version_no: int
    approved_at: datetime | None
    supersedes_version_id: UUID | None
    is_active: bool
    can_edit: bool
    versions: list[MappingVersionSummary]
    accounts: list[AccountMappingView]
    values: list[ValueMappingView]
    items: list[ItemMappingView]
    columns: list[ColumnMappingView]


class AccountMappingChange(BaseModel):
    source_identity_key: str = Field(min_length=1, max_length=600)
    ladder_line_code: str = Field(min_length=1, max_length=80)


class ValueMappingChange(BaseModel):
    field_name: Literal["management_line", "product_group", "labour_activity_basis"]
    source_value: str = Field(min_length=1, max_length=600)
    canonical_value: str = Field(min_length=1, max_length=120)


class MappingRevisionRequest(BaseModel):
    account_changes: list[AccountMappingChange] = Field(default_factory=list, max_length=10000)
    value_changes: list[ValueMappingChange] = Field(default_factory=list, max_length=1000)


class MappingRevisionResponse(BaseModel):
    source_profile_id: UUID
    profile_version_id: UUID
    version_no: int
    reused: bool


@router.get(
    "/outlets/{outlet_id}/mapping-profiles",
    response_model=MappingProfileListResponse,
)
async def list_mapping_profiles(
    outlet_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> MappingProfileListResponse:
    async with user_transaction(user.id) as conn:
        outlet_result = await conn.execute(
            f"""
            select o.id, has_org_role(o.organisation_id, {EDITOR_ROLES}) as can_edit
            from outlet o
            where o.id=%s
            """,
            (outlet_id,),
        )
        outlet = await outlet_result.fetchone()
        if outlet is None:
            raise HTTPException(status_code=404, detail="Outlet not found")

        result = await conn.execute(
            """
            select
              sp.id as source_profile_id,
              sp.template_code,
              sp.source_label,
              sp.active_profile_version_id as active_version_id,
              av.version_no as active_version_no,
              av.approved_at as active_approved_at,
              (select count(*) from profile_version pv
                where pv.source_profile_id=sp.id and pv.status='approved') as version_count,
              (select count(*) from account_mapping am
                where am.profile_version_id=sp.active_profile_version_id) as account_count,
              (select count(*) from value_mapping vm
                where vm.profile_version_id=sp.active_profile_version_id) as value_count,
              (select count(*) from item_mapping im
                where im.profile_version_id=sp.active_profile_version_id) as item_count
            from source_profile sp
            left join profile_version av on av.id=sp.active_profile_version_id
            where sp.outlet_id=%s
            order by sp.template_code, sp.source_label
            """,
            (outlet_id,),
        )
        rows = await result.fetchall()

    return MappingProfileListResponse(
        outlet_id=outlet_id,
        can_edit=bool(outlet["can_edit"]),
        profiles=[MappingProfileSummary(**row) for row in rows],
    )


@router.get(
    "/mapping-profiles/{source_profile_id}",
    response_model=MappingProfileDetailResponse,
)
async def get_mapping_profile(
    source_profile_id: UUID,
    version_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> MappingProfileDetailResponse:
    async with user_transaction(user.id) as conn:
        profile_result = await conn.execute(
            f"""
            select
              sp.id, sp.outlet_id, sp.template_code, sp.source_label,
              sp.active_profile_version_id,
              has_org_role(sp.organisation_id, {EDITOR_ROLES}) as can_edit
            from source_profile sp
            where sp.id=%s
            """,
            (source_profile_id,),
        )
        profile = await profile_result.fetchone()
        if profile is None:
            raise HTTPException(status_code=404, detail="Mapping not found")

        versions_result = await conn.execute(
            """
            select id, version_no, approved_at
            from profile_version
            where source_profile_id=%s and status='approved'
            order by version_no desc
            """,
            (source_profile_id,),
        )
        versions = await versions_result.fetchall()
        if not versions:
            raise HTTPException(status_code=404, detail="Mapping has no approved version")

        selected_id = version_id or profile["active_profile_version_id"] or versions[0]["id"]
        selected = next((v for v in versions if v["id"] == selected_id), None)
        if selected is None:
            raise HTTPException(status_code=404, detail="Mapping version not found")

        supersedes_result = await conn.execute(
            "select supersedes_profile_version_id from profile_version where id=%s",
            (selected_id,),
        )
        supersedes = await supersedes_result.fetchone()

        accounts_result = await conn.execute(
            """
            select
              am.source_identity_key, am.source_account_code, am.source_account_name,
              ll.code as ladder_line_code, am.mapping_basis
            from account_mapping am
            join ladder_line ll on ll.id=am.ladder_line_id
            where am.profile_version_id=%s
            order by am.source_account_code nulls last, am.source_account_name
            """,
            (selected_id,),
        )
        values_result = await conn.execute(
            """
            select field_name, source_value, canonical_value
            from value_mapping
            where profile_version_id=%s
            order by field_name, source_value
            """,
            (selected_id,),
        )
        items_result = await conn.execute(
            """
            select source_item_code, source_item_name, canonical_item_key
            from item_mapping
            where profile_version_id=%s
            order by source_item_code nulls last, source_item_name
            """,
            (selected_id,),
        )
        columns_result = await conn.execute(
            """
            select source_column, canonical_field
            from column_mapping
            where profile_version_id=%s
            order by source_column
            """,
            (selected_id,),
        )
        accounts = await accounts_result.fetchall()
        values = await values_result.fetchall()
        items = await items_result.fetchall()
        columns = await columns_result.fetchall()

    active_id = profile["active_profile_version_id"]
    return MappingProfileDetailResponse(
        source_profile_id=profile["id"],
        outlet_id=profile["outlet_id"],
        template_code=profile["template_code"],
        source_label=profile["source_label"],
        active_version_id=active_id,
        version_id=selected["id"],
        version_no=selected["version_no"],
        approved_at=selected["approved_at"],
        supersedes_version_id=supersedes["supersedes_profile_version_id"] if supersedes else None,
        is_active=selected["id"] == active_id,
        can_edit=bool(profile["can_edit"]),
        versions=[
            MappingVersionSummary(
                id=v["id"],
                version_no=v["version_no"],
                approved_at=v["approved_at"],
                is_active=v["id"] == active_id,
            )
            for v in versions
        ],
        accounts=[AccountMappingView(**row) for row in accounts],
        values=[ValueMappingView(**row) for row in values],
        items=[ItemMappingView(**row) for row in items],
        columns=[ColumnMappingView(**row) for row in columns],
    )


@router.post(
    "/mapping-profiles/versions/{profile_version_id}/revisions",
    response_model=MappingRevisionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def revise_mapping_profile(
    profile_version_id: UUID,
    payload: MappingRevisionRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> MappingRevisionResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select revised_profile_version_id, revised_version_no, reused
                from revise_profile_mappings(%s,%s,%s::jsonb,%s::jsonb,%s)
                """,
                (
                    profile_version_id,
                    idempotency_key,
                    Jsonb([c.model_dump(mode="json") for c in payload.account_changes]),
                    Jsonb([c.model_dump(mode="json") for c in payload.value_changes]),
                    correlation_id,
                ),
            )
            row = await result.fetchone()
            profile_row = None
            if row is not None:
                # A separate statement: rows the function inserted are not
                # visible to the statement that called it.
                profile_result = await conn.execute(
                    "select source_profile_id from profile_version where id=%s",
                    (row["revised_profile_version_id"],),
                )
                profile_row = await profile_result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Mapping not found") from exc
    except (CheckViolation, InvalidParameterValue) as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "mapping-revision-invalid", "message": str(exc).splitlines()[0]},
        ) from exc

    if row is None or profile_row is None:
        raise HTTPException(status_code=500, detail="Mapping revision returned no result")

    return MappingRevisionResponse(
        source_profile_id=profile_row["source_profile_id"],
        profile_version_id=row["revised_profile_version_id"],
        version_no=row["revised_version_no"],
        reused=row["reused"],
    )
