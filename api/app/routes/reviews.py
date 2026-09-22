from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, RestrictViolation

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..review_schemas import (
    ReviewCreateRequest,
    ReviewFrameRequest,
    ReviewListResponse,
    ReviewMutationResponse,
    ReviewRead,
)

router = APIRouter(prefix="/reviews", tags=["reviews"])


async def _load_review(conn, review_id: UUID) -> ReviewRead | None:
    result = await conn.execute(
        """
        select
          id,outlet_id,period_id,status::text,comparator_scenario::text,
          context_version_id,materiality_snapshot,active_calc_run_id,
          review_leader_id,started_at,frame_confirmed_at,closed_at,
          created_at,updated_at
        from review
        where id=%s
        """,
        (review_id,),
    )
    row = await result.fetchone()
    return ReviewRead(**row) if row is not None else None


@router.post("", response_model=ReviewMutationResponse)
async def create_review(
    payload: ReviewCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from create_review(%s,%s,%s,%s)",
                (
                    payload.outlet_id,
                    payload.period_id,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(status_code=500, detail="Review creation returned no result")
            review = await _load_review(conn, created["created_review_id"])
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Review context not found") from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "review-invalid", "message": str(exc).splitlines()[0]},
        ) from exc

    if review is None:
        raise HTTPException(status_code=500, detail="Created review could not be loaded")

    return ReviewMutationResponse(review=review, reused=created["reused"])


@router.post("/{review_id}/frame", response_model=ReviewMutationResponse)
async def confirm_review_frame(
    review_id: UUID,
    payload: ReviewFrameRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select *
                from frame_review(%s,%s,%s,%s::scenario_code,%s,%s)
                """,
                (
                    review_id,
                    payload.context_version_id,
                    payload.active_calc_run_id,
                    payload.comparator_scenario,
                    idempotency_key,
                    correlation_id,
                ),
            )
            framed = await result.fetchone()
            if framed is None:
                raise HTTPException(status_code=500, detail="FRAME confirmation returned no result")
            review = await _load_review(conn, framed["framed_review_id"])
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Review not found") from exc
    except RestrictViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"type": "immutable-record", "message": str(exc).splitlines()[0]},
        ) from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "frame-invalid", "message": str(exc).splitlines()[0]},
        ) from exc

    if review is None:
        raise HTTPException(status_code=500, detail="Framed review could not be loaded")

    return ReviewMutationResponse(review=review, reused=framed["reused"])


@router.get("/{review_id}", response_model=ReviewRead)
async def get_review(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewRead:
    async with user_transaction(user.id) as conn:
        review = await _load_review(conn, review_id)
    if review is None:
        raise HTTPException(status_code=404, detail="Review not found")
    return review


@router.get("", response_model=ReviewListResponse)
async def list_reviews(
    outlet_id: UUID | None = Query(default=None),
    period_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewListResponse:
    clauses: list[str] = []
    params: list[UUID] = []
    if outlet_id is not None:
        clauses.append("outlet_id=%s")
        params.append(outlet_id)
    if period_id is not None:
        clauses.append("period_id=%s")
        params.append(period_id)

    where = f"where {' and '.join(clauses)}" if clauses else ""

    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            f"""
            select
              id,outlet_id,period_id,status::text,comparator_scenario::text,
              context_version_id,materiality_snapshot,active_calc_run_id,
              review_leader_id,started_at,frame_confirmed_at,closed_at,
              created_at,updated_at
            from review
            {where}
            order by started_at desc,id desc
            """,
            params,
        )
        rows = await result.fetchall()

    return ReviewListResponse(reviews=[ReviewRead(**row) for row in rows])
