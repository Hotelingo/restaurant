from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import CheckViolation, ExclusionViolation, InsufficientPrivilege
from psycopg.types.json import Jsonb

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..setup_schemas import (
    ContextVersionRequest,
    ContextVersionResponse,
    ReportingPeriodRequest,
    ReportingPeriodResponse,
    SetupSummaryPeriod,
    SetupSummaryResponse,
)

router = APIRouter(prefix="/outlets", tags=["setup"])


def _clean_list(values: list[str]) -> list[str]:
    return [value.strip() for value in values if value.strip()]


@router.post(
    "/{outlet_id}/context",
    response_model=ContextVersionResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_context_version(
    outlet_id: UUID,
    payload: ContextVersionRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ContextVersionResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select context_id, version_no
                from create_restaurant_context_version(
                  %s,%s,%s::jsonb,%s::jsonb,%s::jsonb,%s::jsonb,
                  %s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    outlet_id,
                    payload.service_style or "",
                    Jsonb({"seats": payload.seats} if payload.seats is not None else {}),
                    Jsonb(_clean_list(payload.meal_periods)),
                    Jsonb(_clean_list(payload.business_formats)),
                    Jsonb(_clean_list(payload.customer_sources)),
                    payload.recipe_costing_status or "",
                    payload.labour_recording_basis or "",
                    payload.source_tracking_quality or "",
                    payload.evidence_maturity or "",
                    payload.effective_from,
                    idempotency_key,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Context version was not created")

    return ContextVersionResponse(**row)


@router.post(
    "/{outlet_id}/periods",
    response_model=ReportingPeriodResponse,
    status_code=status.HTTP_201_CREATED,
)
async def create_period(
    outlet_id: UUID,
    payload: ReportingPeriodRequest,
    request: Request,
    idempotency_key: str = Header(alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReportingPeriodResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select period_id
                from create_reporting_period(%s,%s,%s,%s,%s,%s)
                """,
                (
                    outlet_id,
                    payload.period_start,
                    payload.period_end,
                    payload.label,
                    idempotency_key,
                    getattr(request.state, "correlation_id", None),
                ),
            )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Resource is not available") from exc
    except ExclusionViolation as exc:
        raise HTTPException(
            status_code=409,
            detail="This reporting period overlaps an existing period.",
        ) from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=422,
            detail="Reporting-period dates are not valid.",
        ) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Reporting period was not created")

    return ReportingPeriodResponse(**row)


@router.get("/{outlet_id}/setup-summary", response_model=SetupSummaryResponse)
async def setup_summary(
    outlet_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> SetupSummaryResponse:
    async with user_transaction(user.id) as conn:
        outlet_result = await conn.execute(
            """
            select
              org.id as organisation_id,
              org.name as organisation_name,
              o.id as outlet_id,
              o.name as outlet_name,
              o.code as outlet_code,
              o.currency_code,
              o.timezone
            from outlet o
            join organisation org on org.id=o.organisation_id
            where o.id=%s
            """,
            (outlet_id,),
        )
        outlet = await outlet_result.fetchone()
        if outlet is None:
            raise HTTPException(status_code=404, detail="Resource is not available")

        context_result = await conn.execute(
            """
            select max(version_no)::int as latest_context_version
            from restaurant_context
            where outlet_id=%s
            """,
            (outlet_id,),
        )
        context = await context_result.fetchone()

        periods_result = await conn.execute(
            """
            select id,label,period_start,period_end,close_status
            from reporting_period
            where outlet_id=%s
            order by period_start desc, period_end desc
            """,
            (outlet_id,),
        )
        periods = await periods_result.fetchall()

    return SetupSummaryResponse(
        organisation_id=outlet["organisation_id"],
        organisation_name=outlet["organisation_name"],
        outlet_id=outlet["outlet_id"],
        outlet_name=outlet["outlet_name"],
        outlet_code=outlet["outlet_code"],
        currency_code=outlet["currency_code"].strip(),
        timezone=outlet["timezone"],
        latest_context_version=(context or {}).get("latest_context_version"),
        periods=[SetupSummaryPeriod(**row) for row in periods],
    )
