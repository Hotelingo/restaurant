"""Data Centre read models, calculation requests and outlet context versions.

Closes readiness-review finding B2 (no way to request or re-run a calculation
except a flag at commit time), gives the Data Centre a list of a period's
uploads, and lists restaurant-context versions so a review FRAME can pin one
(frame_review needs a context_version_id that no endpoint previously exposed). Writes go through the SECURITY DEFINER functions in migration 0039;
reads of import_batch/source_file rely on their existing RLS read policies.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from psycopg.errors import InsufficientPrivilege, InvalidParameterValue, NoDataFound
from pydantic import BaseModel

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction

router = APIRouter(tags=["data-centre"])


class ImportBatchSummary(BaseModel):
    batch_id: UUID
    source_file_id: UUID
    template_code: str
    scenario: str
    status: str
    period_id: UUID | None
    original_filename: str
    size_bytes: int | None
    row_count: int | None
    profile_match_tier: str | None
    uploaded_at: datetime
    committed_at: datetime | None


class ImportBatchListResponse(BaseModel):
    outlet_id: UUID
    batches: list[ImportBatchSummary]


class ContextVersionSummary(BaseModel):
    id: UUID
    version_no: int
    service_style: str | None
    effective_from: date
    effective_to: date | None
    applies_to_period: bool


class ContextVersionListResponse(BaseModel):
    outlet_id: UUID
    versions: list[ContextVersionSummary]


class CalculationRequest(BaseModel):
    module: Literal["pl", "food_cost", "revenue", "labour_other"] = "pl"


class CalculationRequestResponse(BaseModel):
    request_id: UUID
    status: str
    reused: bool
    source_batch_id: UUID


class CalculationStatus(BaseModel):
    request_id: UUID
    reason: str
    status: str
    attempts: int
    created_at: datetime
    started_at: datetime | None
    completed_at: datetime | None
    completed_run_id: UUID | None
    last_error: str | None


class CalculationStatusResponse(BaseModel):
    period_id: UUID
    requests: list[CalculationStatus]


@router.get("/outlets/{outlet_id}/imports", response_model=ImportBatchListResponse)
async def list_outlet_imports(
    outlet_id: UUID,
    period_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportBatchListResponse:
    clauses = ["b.outlet_id=%s"]
    params: list[UUID] = [outlet_id]
    if period_id is not None:
        clauses.append("b.period_id=%s")
        params.append(period_id)

    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            f"""
            select
              b.id as batch_id, b.source_file_id, b.template_code::text as template_code,
              b.scenario::text as scenario, b.status::text as status, b.period_id,
              f.original_filename, f.size_bytes, f.row_count,
              b.profile_match_tier, f.uploaded_at, b.committed_at
            from import_batch b
            join source_file f
              on f.organisation_id=b.organisation_id and f.id=b.source_file_id
            where {" and ".join(clauses)}
            order by f.uploaded_at desc, b.id desc
            limit 200
            """,
            params,
        )
        rows = await result.fetchall()

    return ImportBatchListResponse(
        outlet_id=outlet_id,
        batches=[ImportBatchSummary(**row) for row in rows],
    )


@router.get("/outlets/{outlet_id}/context-versions", response_model=ContextVersionListResponse)
async def list_context_versions(
    outlet_id: UUID,
    period_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ContextVersionListResponse:
    """Context versions for the outlet, newest first. `applies_to_period` marks
    the versions whose effective range overlaps the given period -- the same
    test frame_review applies."""
    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            """
            select
              rc.id, rc.version_no, rc.service_style, rc.effective_from, rc.effective_to,
              coalesce(
                rp.id is not null
                and rc.effective_from <= rp.period_end
                and (rc.effective_to is null or rc.effective_to >= rp.period_start),
                false
              ) as applies_to_period
            from restaurant_context rc
            left join reporting_period rp
              on rp.id=%s and rp.organisation_id=rc.organisation_id and rp.outlet_id=rc.outlet_id
            where rc.outlet_id=%s
            order by rc.version_no desc
            """,
            (period_id, outlet_id),
        )
        rows = await result.fetchall()

    return ContextVersionListResponse(
        outlet_id=outlet_id,
        versions=[ContextVersionSummary(**row) for row in rows],
    )


def _translate(exc: Exception) -> HTTPException:
    if isinstance(exc, InsufficientPrivilege):
        return HTTPException(status_code=404, detail="Reporting period not found")
    if isinstance(exc, NoDataFound):
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Commit data for this period before calculating.",
        )
    if isinstance(exc, InvalidParameterValue):
        return HTTPException(status_code=422, detail="Unsupported calculation module")
    return HTTPException(status_code=500, detail="Calculation request failed")


@router.post(
    "/periods/{period_id}/calculations",
    response_model=CalculationRequestResponse,
    status_code=status.HTTP_202_ACCEPTED,
)
async def request_calculation(
    period_id: UUID,
    payload: CalculationRequest,
    user: AuthenticatedUser = Depends(get_current_user),
) -> CalculationRequestResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select request_id, request_status, reused, source_batch_id
                from request_period_calculation(%s,%s)
                """,
                (period_id, payload.module),
            )
            row = await result.fetchone()
    except (InsufficientPrivilege, NoDataFound, InvalidParameterValue) as exc:
        raise _translate(exc) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Calculation request was not recorded")
    return CalculationRequestResponse(
        request_id=row["request_id"],
        status=row["request_status"],
        reused=row["reused"],
        source_batch_id=row["source_batch_id"],
    )


@router.get("/periods/{period_id}/calculations", response_model=CalculationStatusResponse)
async def list_calculations(
    period_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> CalculationStatusResponse:
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select request_id, reason, request_status, attempts, created_at,
                       started_at, completed_at, completed_run_id, last_error
                from list_period_calculations(%s)
                """,
                (period_id,),
            )
            rows = await result.fetchall()
    except InsufficientPrivilege as exc:
        raise _translate(exc) from exc

    return CalculationStatusResponse(
        period_id=period_id,
        requests=[
            CalculationStatus(
                request_id=r["request_id"], reason=r["reason"], status=r["request_status"],
                attempts=r["attempts"], created_at=r["created_at"], started_at=r["started_at"],
                completed_at=r["completed_at"], completed_run_id=r["completed_run_id"],
                last_error=r["last_error"],
            )
            for r in rows
        ],
    )
