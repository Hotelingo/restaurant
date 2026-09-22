from __future__ import annotations

from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import (
    CheckViolation,
    InsufficientPrivilege,
    InvalidParameterValue,
    NoDataFound,
    UniqueViolation,
)

from ..action_schemas import (
    ActionCreateRequest,
    ActionEventListResponse,
    ActionEventRead,
    ActionListResponse,
    ActionMutationResponse,
    ActionRead,
    ActionStatusRequest,
    PriorActionCheckListResponse,
    PriorActionCheckMutationResponse,
    PriorActionCheckRead,
    PriorActionCheckRequest,
    PriorActionItem,
    PriorActionWorkspaceResponse,
)
from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction

router = APIRouter(tags=["actions"])


def _action_from_row(row) -> ActionRead:
    return ActionRead(
        **{
            **row,
            "status": str(row["status"]),
        }
    )


def _event_from_row(row) -> ActionEventRead:
    return ActionEventRead(
        **{
            **row,
            "from_status": (
                str(row["from_status"]) if row["from_status"] is not None else None
            ),
            "to_status": (
                str(row["to_status"]) if row["to_status"] is not None else None
            ),
        }
    )


def _verification_from_row(row) -> PriorActionCheckRead:
    return PriorActionCheckRead(
        **{
            **row,
            "completed_answer": str(row["completed_answer"]),
            "driver_moved_answer": str(row["driver_moved_answer"]),
            "result_responded_answer": str(row["result_responded_answer"]),
            "outcome": str(row["outcome"]),
            "action_status_before": str(row["action_status_before"]),
            "action_status_after": str(row["action_status_after"]),
        }
    )


async def _load_action(conn, action_id: UUID) -> ActionRead | None:
    result = await conn.execute(
        """
        select
          id,review_id,review_issue_id,decision_id,
          owner,owner_user_id,lever,guardrail,metric,target_trigger,
          due_date,cadence,forecast_effect,status::text as status,
          status_tag,closure_evidence,created_by,created_at,updated_at
        from action
        where id=%s
        """,
        (action_id,),
    )
    row = await result.fetchone()
    return _action_from_row(row) if row is not None else None


async def _load_verification(
    conn,
    verification_id: UUID,
) -> PriorActionCheckRead | None:
    result = await conn.execute(
        """
        select
          id,action_id,verification_period_id,
          completed_answer::text as completed_answer,completion_evidence,
          driver_moved_answer::text as driver_moved_answer,driver_evidence,
          result_responded_answer::text as result_responded_answer,result_evidence,
          outcome::text as outcome,
          action_status_before::text as action_status_before,
          action_status_after::text as action_status_after,
          status_tag,closure_evidence,reopen_reason,note,
          created_by,created_at
        from prior_action_check
        where id=%s
        """,
        (verification_id,),
    )
    row = await result.fetchone()
    return _verification_from_row(row) if row is not None else None


def _translate_action_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (InsufficientPrivilege, NoDataFound)):
        return HTTPException(status_code=404, detail="Action context not found")
    if isinstance(exc, UniqueViolation):
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "verification-exists",
                "message": "This action already has an immutable verification for the selected period.",
            },
        )
    if isinstance(exc, (CheckViolation, InvalidParameterValue)):
        return HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "type": "action-invalid",
                "message": str(exc).splitlines()[0],
            },
        )
    return HTTPException(status_code=500, detail="Action operation failed")


@router.post(
    "/decisions/{decision_id}/actions",
    response_model=ActionMutationResponse,
)
async def create_action(
    decision_id: UUID,
    payload: ActionCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ActionMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from create_action_from_decision(
                  %s,%s,%s,%s,%s,%s
                )
                """,
                (
                    decision_id,
                    payload.owner,
                    payload.owner_user_id,
                    payload.forecast_effect,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(
                    status_code=500,
                    detail="Action creation returned no result",
                )
            action = await _load_action(conn, created["action_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        UniqueViolation,
    ) as exc:
        raise _translate_action_error(exc) from exc

    if action is None:
        raise HTTPException(status_code=500, detail="Created action could not be loaded")
    return ActionMutationResponse(action=action, reused=created["reused"])


@router.get(
    "/reviews/{review_id}/actions",
    response_model=ActionListResponse,
)
async def list_review_actions(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ActionListResponse:
    async with user_transaction(user.id) as conn:
        review_result = await conn.execute(
            "select id from review where id=%s",
            (review_id,),
        )
        if await review_result.fetchone() is None:
            raise HTTPException(status_code=404, detail="Review not found")

        result = await conn.execute(
            """
            select
              id,review_id,review_issue_id,decision_id,
              owner,owner_user_id,lever,guardrail,metric,target_trigger,
              due_date,cadence,forecast_effect,status::text as status,
              status_tag,closure_evidence,created_by,created_at,updated_at
            from action
            where review_id=%s
            order by created_at,id
            """,
            (review_id,),
        )
        rows = await result.fetchall()

    return ActionListResponse(actions=[_action_from_row(row) for row in rows])


@router.post(
    "/actions/{action_id}/status",
    response_model=ActionMutationResponse,
)
async def set_action_status(
    action_id: UUID,
    payload: ActionStatusRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ActionMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from transition_action_status(
                  %s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    action_id,
                    payload.status,
                    payload.status_tag,
                    payload.closure_evidence,
                    payload.note,
                    idempotency_key,
                    correlation_id,
                ),
            )
            changed = await result.fetchone()
            if changed is None:
                raise HTTPException(
                    status_code=500,
                    detail="Action status operation returned no result",
                )
            action = await _load_action(conn, changed["action_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        UniqueViolation,
    ) as exc:
        raise _translate_action_error(exc) from exc

    if action is None:
        raise HTTPException(status_code=500, detail="Updated action could not be loaded")
    return ActionMutationResponse(action=action, reused=changed["reused"])


@router.get(
    "/actions/{action_id}/events",
    response_model=ActionEventListResponse,
)
async def list_action_events(
    action_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ActionEventListResponse:
    async with user_transaction(user.id) as conn:
        if await _load_action(conn, action_id) is None:
            raise HTTPException(status_code=404, detail="Action not found")
        result = await conn.execute(
            """
            select
              id,action_id,event_type,
              from_status::text as from_status,
              to_status::text as to_status,
              status_tag,note,evidence,created_by,created_at
            from action_event
            where action_id=%s
            order by created_at,id
            """,
            (action_id,),
        )
        rows = await result.fetchall()

    return ActionEventListResponse(events=[_event_from_row(row) for row in rows])


@router.post(
    "/actions/{action_id}/verification",
    response_model=PriorActionCheckMutationResponse,
)
async def verify_prior_action(
    action_id: UUID,
    payload: PriorActionCheckRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PriorActionCheckMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from record_prior_action_check(
                  %s,%s,%s,%s,%s,%s,%s,%s,
                  %s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    action_id,
                    payload.verification_period_id,
                    payload.completed_answer,
                    payload.completion_evidence,
                    payload.driver_moved_answer,
                    payload.driver_evidence,
                    payload.result_responded_answer,
                    payload.result_evidence,
                    payload.outcome,
                    payload.status_tag,
                    payload.closure_evidence,
                    payload.reopen_reason,
                    payload.note,
                    idempotency_key,
                    correlation_id,
                ),
            )
            recorded = await result.fetchone()
            if recorded is None:
                raise HTTPException(
                    status_code=500,
                    detail="Prior-action verification returned no result",
                )

            verification = await _load_verification(
                conn,
                recorded["prior_action_check_id"],
            )
            action = await _load_action(conn, action_id)
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        UniqueViolation,
    ) as exc:
        raise _translate_action_error(exc) from exc

    if verification is None or action is None:
        raise HTTPException(
            status_code=500,
            detail="Recorded verification could not be loaded",
        )

    return PriorActionCheckMutationResponse(
        verification=verification,
        action=action,
        reused=recorded["reused"],
    )


@router.get(
    "/actions/{action_id}/verifications",
    response_model=PriorActionCheckListResponse,
)
async def list_action_verifications(
    action_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> PriorActionCheckListResponse:
    async with user_transaction(user.id) as conn:
        if await _load_action(conn, action_id) is None:
            raise HTTPException(status_code=404, detail="Action not found")

        result = await conn.execute(
            """
            select
              id,action_id,verification_period_id,
              completed_answer::text as completed_answer,completion_evidence,
              driver_moved_answer::text as driver_moved_answer,driver_evidence,
              result_responded_answer::text as result_responded_answer,result_evidence,
              outcome::text as outcome,
              action_status_before::text as action_status_before,
              action_status_after::text as action_status_after,
              status_tag,closure_evidence,reopen_reason,note,
              created_by,created_at
            from prior_action_check
            where action_id=%s
            order by created_at,id
            """,
            (action_id,),
        )
        rows = await result.fetchall()

    return PriorActionCheckListResponse(
        verifications=[_verification_from_row(row) for row in rows]
    )


@router.get(
    "/outlets/{outlet_id}/periods/{period_id}/prior-actions",
    response_model=PriorActionWorkspaceResponse,
)
async def prior_action_workspace(
    outlet_id: UUID,
    period_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> PriorActionWorkspaceResponse:
    """SC13 next-period read model.

    Resolve the immediately preceding reporting period for the outlet and show
    its action register together with any verification already recorded against
    the requested current period.
    """
    async with user_transaction(user.id) as conn:
        current_result = await conn.execute(
            """
            select organisation_id,outlet_id,id,period_start
            from reporting_period
            where id=%s
              and outlet_id=%s
              and has_org_access(organisation_id)
              and has_outlet_access(organisation_id,outlet_id)
            """,
            (period_id, outlet_id),
        )
        current = await current_result.fetchone()
        if current is None:
            raise HTTPException(status_code=404, detail="Reporting period not found")

        previous_result = await conn.execute(
            """
            select id
            from reporting_period
            where organisation_id=%s
              and outlet_id=%s
              and period_end < %s
            order by period_end desc,id desc
            limit 1
            """,
            (
                current["organisation_id"],
                current["outlet_id"],
                current["period_start"],
            ),
        )
        previous = await previous_result.fetchone()
        if previous is None:
            return PriorActionWorkspaceResponse(
                outlet_id=outlet_id,
                verification_period_id=period_id,
                source_period_id=None,
                prior_actions=[],
            )

        action_result = await conn.execute(
            """
            select
              a.id,a.review_id,a.review_issue_id,a.decision_id,
              a.owner,a.owner_user_id,a.lever,a.guardrail,a.metric,
              a.target_trigger,a.due_date,a.cadence,a.forecast_effect,
              a.status::text as status,a.status_tag,a.closure_evidence,
              a.created_by,a.created_at,a.updated_at
            from action a
            join review rv
              on rv.organisation_id=a.organisation_id
             and rv.outlet_id=a.outlet_id
             and rv.id=a.review_id
            where rv.period_id=%s
            order by a.created_at,a.id
            """,
            (previous["id"],),
        )
        action_rows = await action_result.fetchall()

        items: list[PriorActionItem] = []
        for row in action_rows:
            check_result = await conn.execute(
                """
                select
                  id,action_id,verification_period_id,
                  completed_answer::text as completed_answer,completion_evidence,
                  driver_moved_answer::text as driver_moved_answer,driver_evidence,
                  result_responded_answer::text as result_responded_answer,result_evidence,
                  outcome::text as outcome,
                  action_status_before::text as action_status_before,
                  action_status_after::text as action_status_after,
                  status_tag,closure_evidence,reopen_reason,note,
                  created_by,created_at
                from prior_action_check
                where action_id=%s and verification_period_id=%s
                """,
                (row["id"], period_id),
            )
            check = await check_result.fetchone()
            items.append(
                PriorActionItem(
                    action=_action_from_row(row),
                    verification=(
                        _verification_from_row(check) if check is not None else None
                    ),
                )
            )

    return PriorActionWorkspaceResponse(
        outlet_id=outlet_id,
        verification_period_id=period_id,
        source_period_id=previous["id"],
        prior_actions=items,
    )
