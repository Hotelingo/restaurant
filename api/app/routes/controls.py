from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, UniqueViolation
from psycopg.types.json import Jsonb

from ..auth import AuthenticatedUser, get_current_user
from ..control_schemas import (
    AdditionalOutletRequest,
    AdditionalOutletResponse,
    AuditEvent,
    AuditLogResponse,
    MaterialityVersion,
    MaterialityWriteRequest,
    MaterialityWriteResponse,
    OutletControlsResponse,
    SettingBatchWriteRequest,
    SettingBatchWriteResponse,
    SettingWriteRequest,
    SettingWriteResponse,
)
from ..db import user_transaction

router = APIRouter(tags=["controls"])


async def _require_outlet_admin(conn, outlet_id: UUID) -> dict:
    result = await conn.execute(
        """
        select o.id as outlet_id, o.organisation_id, o.name as outlet_name,
               o.currency_code, o.timezone, o.fiscal_year_start_month
        from outlet o
        where o.id=%s
          and has_org_role(o.organisation_id, array['admin']::app_role[])
          and has_outlet_access(o.organisation_id, o.id)
        """,
        (outlet_id,),
    )
    row = await result.fetchone()
    if row is None:
        raise HTTPException(status_code=404, detail="Resource is not available")
    return row


@router.post(
    "/organisations/{organisation_id}/outlets",
    response_model=AdditionalOutletResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_additional_outlet(
    organisation_id: UUID,
    payload: AdditionalOutletRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> AdditionalOutletResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select outlet_id
                from create_outlet(%s,%s,%s,%s,%s,%s,%s,%s)
                """,
                (
                    organisation_id,
                    payload.name,
                    payload.code or "",
                    payload.currency_code,
                    payload.timezone,
                    payload.fiscal_year_start_month,
                    idempotency_key,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc
    except UniqueViolation as exc:
        raise HTTPException(
            status_code=409,
            detail="An outlet with this code already exists in the organisation.",
        ) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Outlet was not created")
    return AdditionalOutletResponse(**row)


@router.get("/outlets/{outlet_id}/controls", response_model=OutletControlsResponse)
async def get_outlet_controls(
    outlet_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> OutletControlsResponse:
    async with user_transaction(user.id) as conn:
        outlet = await _require_outlet_admin(conn, outlet_id)

        setting_result = await conn.execute(
            """
            select key, value_json
            from setting
            where outlet_id=%s
            order by key
            """,
            (outlet_id,),
        )
        settings = {row["key"]: row["value_json"] for row in await setting_result.fetchall()}

        materiality_result = await conn.execute(
            """
            select id,scope_type::text,absolute_threshold,percent_threshold,
                   source_kind::text,proposal_basis,recurrence_rule,
                   risk_override_enabled,effective_from,effective_to,approved_at
            from materiality_setting
            where outlet_id=%s
            order by scope_type, effective_from desc, created_at desc
            """,
            (outlet_id,),
        )
        materiality = [
            MaterialityVersion(**row) for row in await materiality_result.fetchall()
        ]

    return OutletControlsResponse(
        organisation_id=outlet["organisation_id"],
        outlet_id=outlet["outlet_id"],
        outlet_name=outlet["outlet_name"],
        currency_code=outlet["currency_code"].strip(),
        timezone=outlet["timezone"],
        fiscal_year_start_month=outlet["fiscal_year_start_month"],
        settings=settings,
        materiality=materiality,
    )


@router.put("/outlets/{outlet_id}/settings", response_model=SettingWriteResponse)
async def put_setting(
    outlet_id: UUID,
    payload: SettingWriteRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> SettingWriteResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select setting_id
                from put_outlet_setting(%s,%s,%s::jsonb,%s,%s)
                """,
                (
                    outlet_id,
                    payload.key,
                    Jsonb(payload.value),
                    idempotency_key,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Setting was not saved")
    return SettingWriteResponse(**row)


@router.put(
    "/outlets/{outlet_id}/settings/batch",
    response_model=SettingBatchWriteResponse,
)
async def put_settings_batch(
    outlet_id: UUID,
    payload: SettingBatchWriteRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=160),
    user: AuthenticatedUser = Depends(get_current_user),
) -> SettingBatchWriteResponse:
    setting_ids: list[UUID] = []
    try:
        async with user_transaction(user.id) as conn:
            for index, item in enumerate(payload.settings):
                result = await conn.execute(
                    """
                    select setting_id
                    from put_outlet_setting(%s,%s,%s::jsonb,%s,%s)
                    """,
                    (
                        outlet_id,
                        item.key,
                        Jsonb(item.value),
                        f"{idempotency_key}:{index}:{item.key}",
                        getattr(request.state, "correlation_id", None),
                    ),
                )
                row = await result.fetchone()
                if row is None:
                    raise HTTPException(status_code=500, detail="A setting was not saved")
                setting_ids.append(row["setting_id"])
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc

    return SettingBatchWriteResponse(setting_ids=setting_ids)


@router.post(
    "/outlets/{outlet_id}/materiality",
    response_model=MaterialityWriteResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_materiality(
    outlet_id: UUID,
    payload: MaterialityWriteRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> MaterialityWriteResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select materiality_id, source_kind::text
                from create_materiality_version(
                  %s,%s,%s,%s,%s::jsonb,%s::jsonb,%s,%s,%s,%s
                )
                """,
                (
                    outlet_id,
                    payload.scope_type,
                    payload.absolute_threshold,
                    payload.percent_threshold,
                    Jsonb(payload.proposal_basis),
                    Jsonb(payload.recurrence_rule),
                    payload.risk_override_enabled,
                    payload.effective_from,
                    idempotency_key,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc
    except CheckViolation as exc:
        raise HTTPException(status_code=422, detail=str(exc).splitlines()[0]) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Materiality version was not created")
    return MaterialityWriteResponse(**row)


@router.get(
    "/organisations/{organisation_id}/audit-log",
    response_model=AuditLogResponse,
)
async def get_audit_log(
    organisation_id: UUID,
    limit: int = Query(default=100, ge=1, le=250),
    user: AuthenticatedUser = Depends(get_current_user),
) -> AuditLogResponse:
    async with user_transaction(user.id) as conn:
        access = await conn.execute(
            "select has_full_admin_access(%s) as allowed",
            (organisation_id,),
        )
        row = await access.fetchone()
        if row is None or not row["allowed"]:
            raise HTTPException(status_code=404, detail="Resource is not available")

        result = await conn.execute(
            """
            select
              a.id,a.actor_user_id,u.name as actor_name,u.email as actor_email,
              a.outlet_id,a.action_code,a.object_type,a.object_id,
              a.correlation_id,a.occurred_at
            from audit_log a
            left join neon_auth."user" u on u.id=a.actor_user_id
            where a.organisation_id=%s
            order by a.occurred_at desc, a.id desc
            limit %s
            """,
            (organisation_id, limit),
        )
        events = [AuditEvent(**event) for event in await result.fetchall()]

    return AuditLogResponse(organisation_id=organisation_id, events=events)
