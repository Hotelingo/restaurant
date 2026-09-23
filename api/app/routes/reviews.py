from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Query, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, RestrictViolation

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..review_schemas import (
    ReviewCreateRequest,
    ReviewFrameRequest,
    ReviewIssueCreateRequest,
    ReviewIssueListResponse,
    ReviewIssueMutationResponse,
    ReviewIssueOrderRequest,
    ReviewIssueOrderResponse,
    ReviewIssueRead,
    ReviewListResponse,
    ReviewMutationResponse,
    ReviewRead,
)

router = APIRouter(prefix="/reviews", tags=["reviews"])


def _shortlist_guidance(count: int) -> str:
    if count < 3:
        return "below_expected"
    if count <= 5:
        return "expected_range"
    if count == 6:
        return "six_with_reason"
    return "above_expected_warning"


def _issue_from_row(row) -> ReviewIssueRead:
    movement_amount = format(row["movement_amount"], "f")
    movement_rate = (
        format(row["movement_rate"], "f")
        if row["movement_rate"] is not None
        else None
    )
    return ReviewIssueRead(
        **{
            **row,
            "movement_amount": movement_amount,
            "movement_rate": movement_rate,
            "materiality_rules": list(row["materiality_rules"] or []),
        }
    )


async def _load_issue(conn, issue_id: UUID) -> ReviewIssueRead | None:
    result = await conn.execute(
        """
        select
          id,review_id,source_calc_run_id,source_calc_result_id,
          title,movement_amount,movement_rate,ladder_code,module,
          materiality_reason,materiality_rules,shortlist_order,
          selection_reason,evidence_status,issue_status,created_by,
          created_at,updated_at
        from review_issue
        where id=%s
        """,
        (issue_id,),
    )
    row = await result.fetchone()
    return _issue_from_row(row) if row is not None else None


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



@router.post(
    "/{review_id}/issues",
    response_model=ReviewIssueMutationResponse,
)
async def add_review_issue(
    review_id: UUID,
    payload: ReviewIssueCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewIssueMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from add_review_issue(%s,%s,%s,%s,%s,%s)",
                (
                    review_id,
                    payload.source_calc_result_id,
                    payload.title,
                    payload.selection_reason,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(status_code=500, detail="Shortlist mutation returned no result")
            issue = await _load_issue(conn, created["created_issue_id"])
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Review not found") from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "shortlist-invalid", "message": str(exc).splitlines()[0]},
        ) from exc

    if issue is None:
        raise HTTPException(status_code=500, detail="Shortlisted issue could not be loaded")

    return ReviewIssueMutationResponse(
        issue=issue,
        shortlist_count=created["shortlist_count"],
        shortlist_guidance=created["shortlist_guidance"],
        reused=created["reused"],
    )


@router.get(
    "/{review_id}/issues",
    response_model=ReviewIssueListResponse,
)
async def list_review_issues(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewIssueListResponse:
    async with user_transaction(user.id) as conn:
        review = await _load_review(conn, review_id)
        if review is None:
            raise HTTPException(status_code=404, detail="Review not found")
        result = await conn.execute(
            """
            select
              id,review_id,source_calc_run_id,source_calc_result_id,
              title,movement_amount,movement_rate,ladder_code,module,
              materiality_reason,materiality_rules,shortlist_order,
              selection_reason,evidence_status,issue_status,created_by,
              created_at,updated_at
            from review_issue
            where review_id=%s and issue_status<>'removed'
            order by shortlist_order,id
            """,
            (review_id,),
        )
        rows = await result.fetchall()

    issues = [_issue_from_row(row) for row in rows]
    return ReviewIssueListResponse(
        issues=issues,
        shortlist_count=len(issues),
        shortlist_guidance=_shortlist_guidance(len(issues)),
    )


@router.put(
    "/{review_id}/issues/order",
    response_model=ReviewIssueOrderResponse,
)
async def reorder_review_issues(
    review_id: UUID,
    payload: ReviewIssueOrderRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewIssueOrderResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from reorder_review_issues(%s,%s,%s,%s)",
                (
                    review_id,
                    payload.issue_ids,
                    idempotency_key,
                    correlation_id,
                ),
            )
            reordered = await result.fetchone()
            if reordered is None:
                raise HTTPException(status_code=500, detail="Shortlist reorder returned no result")
            issues_result = await conn.execute(
                """
                select
                  id,review_id,source_calc_run_id,source_calc_result_id,
                  title,movement_amount,movement_rate,ladder_code,module,
                  materiality_reason,materiality_rules,shortlist_order,
                  selection_reason,evidence_status,issue_status,created_by,
                  created_at,updated_at
                from review_issue
                where review_id=%s and issue_status<>'removed'
                order by shortlist_order,id
                """,
                (review_id,),
            )
            issue_rows = await issues_result.fetchall()
    except InsufficientPrivilege as exc:
        raise HTTPException(status_code=404, detail="Review not found") from exc
    except CheckViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "shortlist-order-invalid", "message": str(exc).splitlines()[0]},
        ) from exc

    return ReviewIssueOrderResponse(
        issues=[_issue_from_row(row) for row in issue_rows],
        reordered_count=reordered["reordered_count"],
        reused=reordered["reused"],
    )
