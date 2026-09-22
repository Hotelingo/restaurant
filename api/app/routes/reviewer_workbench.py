from __future__ import annotations

from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import (
    CheckViolation,
    InsufficientPrivilege,
    InvalidParameterValue,
    RestrictViolation,
)

from packages.review_gate import (
    ActDecisionGateInput,
    ClaimGateInput,
    ReviewGateInput,
    evaluate_review_gate,
)

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..reviewer_schemas import (
    PackHistoryVersionRead,
    PackSignoffRequest,
    PackSignoffResponse,
    PackSubmitResponse,
    ReconciliationDisclosureRequest,
    ReconciliationDisclosureResponse,
    ReviewCommentCreateRequest,
    ReviewCommentMutationResponse,
    ReviewCommentRead,
    ReviewCommentResolveRequest,
    ReviewGateOutcomeRead,
    ReviewGateResponse,
    ReviewPackHistoryResponse,
    SignoffRead,
)

router = APIRouter(tags=["reviewer-workbench"])


def _translate_workbench_error(exc: Exception) -> HTTPException:
    message = str(exc).splitlines()[0]
    if isinstance(exc, InsufficientPrivilege):
        return HTTPException(status_code=404, detail="Review or pack context not found")
    if isinstance(exc, RestrictViolation):
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={"type": "immutable-record", "message": message},
        )
    if isinstance(exc, (CheckViolation, InvalidParameterValue)):
        return HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "review-workbench-invalid", "message": message},
        )
    return HTTPException(status_code=500, detail="Reviewer workbench operation failed")


async def _load_comment(conn, comment_id: UUID) -> ReviewCommentRead | None:
    result = await conn.execute(
        """
        select
          id,review_id,parent_comment_id,body,author_user_id,
          author_role::text as author_role,resolution_status,
          resolution_note,resolved_by,resolved_at,created_at
        from review_comment
        where id=%s
        """,
        (comment_id,),
    )
    row = await result.fetchone()
    return ReviewCommentRead(**row) if row is not None else None


async def _load_signoff(conn, signoff_id: UUID) -> SignoffRead | None:
    result = await conn.execute(
        """
        select
          id,review_id,pack_version_id,calc_run_id,
          reviewer_user_id,reviewer_role::text as reviewer_role,
          decision::text as decision,caveat,
          scope_reviewed,scope_not_reviewed,gate_snapshot,created_at
        from signoff
        where id=%s
        """,
        (signoff_id,),
    )
    row = await result.fetchone()
    return SignoffRead(**row) if row is not None else None


async def _load_pack_gate_context(conn, pack_id: UUID) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          p.id,p.organisation_id,p.outlet_id,p.review_id,p.calc_run_id,
          p.status::text as status,p.reconciliation_disclosure
        from pack_version p
        where p.id=%s
        """,
        (pack_id,),
    )
    return await result.fetchone()


async def _latest_pack_for_review(conn, review_id: UUID) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          p.id,p.organisation_id,p.outlet_id,p.review_id,p.calc_run_id,
          p.status::text as status,p.reconciliation_disclosure
        from pack_version p
        where p.review_id=%s
        order by p.version_no desc,p.created_at desc,p.id desc
        limit 1
        """,
        (review_id,),
    )
    return await result.fetchone()


async def _reconciliation_failed(conn, *, calc_run_id: UUID) -> bool:
    result = await conn.execute(
        """
        with actual_batch as (
          select i.batch_id
          from calc_run_input i
          where i.run_id=%s
            and i.input_role='actual'
          order by i.created_at,i.id
          limit 1
        ),
        accounting as (
          select ll.code as line_code,sum(ff.amount) as amount
          from actual_batch ab
          join financial_fact ff on ff.batch_id=ab.batch_id
          join ladder_line ll on ll.id=ff.ladder_line_id
          where not ll.is_calculated
          group by ll.code
        ),
        management as (
          select
            cr.grain_key->>'ladder_code' as line_code,
            cr.value_numeric,
            cr.calculation_status
          from calc_result cr
          where cr.run_id=%s
            and cr.grain_type='management_pl'
            and cr.grain_key->>'scenario'='actual'
        )
        select
          not exists(select 1 from accounting)
          or exists(
            select 1
            from accounting a
            left join management m using(line_code)
            where m.line_code is null
               or m.calculation_status<>'CALCULATED'
               or m.value_numeric is distinct from a.amount
          ) as failed
        """,
        (calc_run_id, calc_run_id),
    )
    row = await result.fetchone()
    return bool(row["failed"]) if row is not None else True


async def _claim_gate_inputs(conn, pack_id: UUID) -> tuple[ClaimGateInput, ...]:
    result = await conn.execute(
        """
        select id,claim_status::text as claim_status,review_check_snapshot
        from claim
        where pack_version_id=%s
        order by created_at,id
        """,
        (pack_id,),
    )
    rows = await result.fetchall()
    claims: list[ClaimGateInput] = []

    for row in rows:
        claim_status = row["claim_status"]
        if claim_status == "rejected":
            claims.append(
                ClaimGateInput(
                    claim_id=row["id"],
                    decision_status="rejected",
                    number_match=True,
                    citation_present=True,
                    status_echo=True,
                    direction=True,
                    banned_wording_clear=True,
                    scope=True,
                )
            )
            continue

        snapshot = row["review_check_snapshot"]
        if snapshot is None:
            check_result = await conn.execute(
                "select claim_check(%s) as check_result",
                (row["id"],),
            )
            check_row = await check_result.fetchone()
            snapshot = check_row["check_result"] if check_row is not None else {}

        accepted = claim_status == "accepted"
        claims.append(
            ClaimGateInput(
                claim_id=row["id"],
                decision_status=claim_status,
                number_match=bool(snapshot.get("number_match", False)),
                citation_present=bool(snapshot.get("citation_present", False)),
                status_echo=(
                    accepted
                    and snapshot.get("status_echo") in (
                        "confirmed_by_reviewer",
                        "manual_review_required",
                    )
                ),
                direction=(
                    accepted
                    and snapshot.get("direction") in (
                        "confirmed_by_reviewer",
                        "manual_review_required",
                    )
                ),
                banned_wording_clear=not bool(
                    snapshot.get("banned_wording", True)
                ),
                scope=(
                    accepted
                    and snapshot.get("scope") in (
                        "confirmed_by_reviewer",
                        "manual_review_required",
                    )
                ),
            )
        )

    return tuple(claims)


async def _act_gate_inputs(conn, review_id: UUID) -> tuple[ActDecisionGateInput, ...]:
    result = await conn.execute(
        """
        select
          d.id,d.owner,d.lever,d.guardrail,d.verification_metric,
          d.due_date,d.cadence
        from review_issue ri
        join decision d on d.id=ri.active_decision_id
        where ri.review_id=%s
          and ri.issue_status<>'removed'
          and d.disposition='ACT'
        order by ri.shortlist_order,ri.id
        """,
        (review_id,),
    )
    rows = await result.fetchall()
    return tuple(
        ActDecisionGateInput(
            decision_id=row["id"],
            owner_present=bool(row["owner"] and row["owner"].strip()),
            lever_present=bool(row["lever"] and row["lever"].strip()),
            guardrail_present=bool(row["guardrail"] and row["guardrail"].strip()),
            metric_present=bool(
                row["verification_metric"] and row["verification_metric"].strip()
            ),
            due_date_present=row["due_date"] is not None,
            cadence_present=bool(row["cadence"] and row["cadence"].strip()),
        )
        for row in rows
    )


async def _evaluate_pack_gate(
    conn,
    *,
    pack: dict[str, Any],
    signer_user_id: UUID,
):
    reconciliation_failed = await _reconciliation_failed(
        conn,
        calc_run_id=pack["calc_run_id"],
    )
    claims = await _claim_gate_inputs(conn, pack["id"])
    act_decisions = await _act_gate_inputs(conn, pack["review_id"])

    comments_result = await conn.execute(
        """
        select count(*)::integer as unresolved_count
        from review_comment
        where review_id=%s and resolution_status='open'
        """,
        (pack["review_id"],),
    )
    comments_row = await comments_result.fetchone()
    unresolved_comments = (
        comments_row["unresolved_count"] if comments_row is not None else 0
    )

    role_result = await conn.execute(
        """
        select has_org_role(
          %s,array['reviewer']::app_role[]
        ) as is_reviewer
        """,
        (pack["organisation_id"],),
    )
    role_row = await role_result.fetchone()

    decision_result = await conn.execute(
        """
        select distinct d.decided_by
        from review_issue ri
        join decision d on d.id=ri.active_decision_id
        where ri.review_id=%s
          and ri.issue_status<>'removed'
        """,
        (pack["review_id"],),
    )
    decision_makers = tuple(
        row["decided_by"] for row in await decision_result.fetchall()
    )

    return evaluate_review_gate(
        ReviewGateInput(
            reconciliation_failed=reconciliation_failed,
            pack_stamped_not_reconciled=bool(pack["reconciliation_disclosure"]),
            claims=claims,
            act_decisions=act_decisions,
            unresolved_comment_count=unresolved_comments,
            signer_user_id=signer_user_id,
            signer_is_reviewer=bool(
                role_row["is_reviewer"] if role_row is not None else False
            ),
            decision_maker_user_ids=decision_makers,
        )
    )


def _gate_outcome_payload(outcome) -> ReviewGateOutcomeRead:
    return ReviewGateOutcomeRead(
        code=str(outcome.code),
        passed=outcome.passed,
        message=outcome.message,
        remediation=outcome.remediation,
        subject_ids=list(outcome.subject_ids),
    )


def _gate_response(
    *,
    review_id: UUID,
    pack_id: UUID,
    result,
) -> ReviewGateResponse:
    outcomes = [_gate_outcome_payload(item) for item in result.outcomes]
    failures = [item for item in outcomes if not item.passed]
    return ReviewGateResponse(
        review_id=review_id,
        pack_version_id=pack_id,
        passed=result.passed,
        outcomes=outcomes,
        failures=failures,
    )


def _gate_snapshot(response: ReviewGateResponse) -> dict[str, Any]:
    return {
        "passed": response.passed,
        "review_id": str(response.review_id),
        "pack_version_id": str(response.pack_version_id),
        "outcomes": [
            {
                "code": item.code,
                "passed": item.passed,
                "message": item.message,
                "remediation": item.remediation,
                "subject_ids": [str(value) for value in item.subject_ids],
            }
            for item in response.outcomes
        ],
        "failures": [
            {
                "code": item.code,
                "message": item.message,
                "remediation": item.remediation,
                "subject_ids": [str(value) for value in item.subject_ids],
            }
            for item in response.failures
        ],
    }


@router.get(
    "/reviews/{review_id}/gates",
    response_model=ReviewGateResponse,
)
async def get_review_gates(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewGateResponse:
    async with user_transaction(user.id) as conn:
        pack = await _latest_pack_for_review(conn, review_id)
        if pack is None:
            raise HTTPException(status_code=404, detail="Owner Pack not found")
        result = await _evaluate_pack_gate(
            conn,
            pack=pack,
            signer_user_id=user.id,
        )
    return _gate_response(review_id=review_id, pack_id=pack["id"], result=result)


@router.get(
    "/reviews/{review_id}/comments",
    response_model=list[ReviewCommentRead],
)
async def list_review_comments(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> list[ReviewCommentRead]:
    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            """
            select
              id,review_id,parent_comment_id,body,author_user_id,
              author_role::text as author_role,resolution_status,
              resolution_note,resolved_by,resolved_at,created_at
            from review_comment
            where review_id=%s
            order by created_at,id
            """,
            (review_id,),
        )
        rows = await result.fetchall()
    return [ReviewCommentRead(**row) for row in rows]


@router.post(
    "/reviews/{review_id}/comments",
    response_model=ReviewCommentMutationResponse,
)
async def create_review_comment(
    review_id: UUID,
    payload: ReviewCommentCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewCommentMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from create_review_comment(%s,%s,%s,%s,%s)",
                (
                    review_id,
                    payload.parent_comment_id,
                    payload.body,
                    idempotency_key,
                    correlation_id,
                ),
            )
            row = await result.fetchone()
            if row is None:
                raise HTTPException(status_code=500, detail="Comment creation returned no result")
            comment = await _load_comment(conn, row["comment_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        RestrictViolation,
    ) as exc:
        raise _translate_workbench_error(exc) from exc

    if comment is None:
        raise HTTPException(status_code=500, detail="Created comment could not be loaded")
    return ReviewCommentMutationResponse(comment=comment, reused=row["reused"])


@router.post(
    "/reviews/{review_id}/comments/{comment_id}/resolve",
    response_model=ReviewCommentMutationResponse,
)
async def resolve_review_comment(
    review_id: UUID,
    comment_id: UUID,
    payload: ReviewCommentResolveRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewCommentMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    async with user_transaction(user.id) as conn:
        before = await _load_comment(conn, comment_id)
        if before is None or before.review_id != review_id:
            raise HTTPException(status_code=404, detail="Review comment not found")

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from resolve_review_comment(%s,%s,%s,%s)",
                (
                    comment_id,
                    payload.resolution_note,
                    idempotency_key,
                    correlation_id,
                ),
            )
            row = await result.fetchone()
            if row is None:
                raise HTTPException(status_code=500, detail="Comment resolution returned no result")
            comment = await _load_comment(conn, row["comment_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        RestrictViolation,
    ) as exc:
        raise _translate_workbench_error(exc) from exc

    if comment is None:
        raise HTTPException(status_code=500, detail="Resolved comment could not be loaded")
    return ReviewCommentMutationResponse(comment=comment, reused=row["reused"])


@router.post(
    "/packs/{pack_id}/submit",
    response_model=PackSubmitResponse,
)
async def submit_pack(
    pack_id: UUID,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackSubmitResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from submit_pack_for_review(%s,%s,%s)",
                (pack_id, idempotency_key, correlation_id),
            )
            row = await result.fetchone()
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        RestrictViolation,
    ) as exc:
        raise _translate_workbench_error(exc) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Pack submission returned no result")
    return PackSubmitResponse(
        pack_version_id=row["pack_version_id"],
        status=str(row["pack_status"]),
        reused=row["reused"],
    )


@router.post(
    "/packs/{pack_id}/reconciliation-disclosure",
    response_model=ReconciliationDisclosureResponse,
)
async def disclose_not_reconciled(
    pack_id: UUID,
    payload: ReconciliationDisclosureRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReconciliationDisclosureResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from set_pack_reconciliation_disclosure(%s,%s,%s,%s)",
                (pack_id, payload.reason, idempotency_key, correlation_id),
            )
            row = await result.fetchone()
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        RestrictViolation,
    ) as exc:
        raise _translate_workbench_error(exc) from exc

    if row is None:
        raise HTTPException(status_code=500, detail="Disclosure returned no result")
    return ReconciliationDisclosureResponse(
        pack_version_id=row["pack_version_id"],
        reconciliation_disclosure=row["reconciliation_disclosure"],
        reused=row["reused"],
    )


@router.post(
    "/packs/{pack_id}/signoff",
    response_model=PackSignoffResponse,
)
async def record_signoff(
    pack_id: UUID,
    payload: PackSignoffRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackSignoffResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    async with user_transaction(user.id) as conn:
        pack = await _load_pack_gate_context(conn, pack_id)
        if pack is None:
            raise HTTPException(status_code=404, detail="Owner Pack not found")
        gate_result = await _evaluate_pack_gate(
            conn,
            pack=pack,
            signer_user_id=user.id,
        )
        gate_response = _gate_response(
            review_id=pack["review_id"],
            pack_id=pack_id,
            result=gate_result,
        )

    if payload.decision == "signed" and not gate_response.passed:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "gate-failed",
                "message": "Review gate conditions are not satisfied.",
                "failures": [
                    item.model_dump(mode="json") for item in gate_response.failures
                ],
            },
        )

    snapshot = _gate_snapshot(gate_response)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from record_pack_signoff(
                  %s,%s,%s,%s,%s,%s::jsonb,%s,%s
                )
                """,
                (
                    pack_id,
                    payload.decision,
                    payload.caveat,
                    payload.scope_reviewed,
                    payload.scope_not_reviewed,
                    snapshot,
                    idempotency_key,
                    correlation_id,
                ),
            )
            row = await result.fetchone()
            if row is None:
                raise HTTPException(status_code=500, detail="Sign-off returned no result")
            signoff = await _load_signoff(conn, row["signoff_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        RestrictViolation,
    ) as exc:
        raise _translate_workbench_error(exc) from exc

    if signoff is None:
        raise HTTPException(status_code=500, detail="Sign-off could not be loaded")
    return PackSignoffResponse(
        signoff=signoff,
        pack_status=str(row["pack_status"]),
        reused=row["reused"],
    )


@router.get(
    "/reviews/{review_id}/history",
    response_model=ReviewPackHistoryResponse,
)
async def get_review_pack_history(
    review_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReviewPackHistoryResponse:
    async with user_transaction(user.id) as conn:
        pack_result = await conn.execute(
            """
            select
              id,version_no,calc_run_id,status::text as status,
              supersedes_pack_version_id,generated_at,
              artifact_sha256,created_at
            from pack_version
            where review_id=%s
            order by version_no,id
            """,
            (review_id,),
        )
        pack_rows = await pack_result.fetchall()

        versions: list[PackHistoryVersionRead] = []
        for pack in pack_rows:
            signoff_result = await conn.execute(
                """
                select
                  id,review_id,pack_version_id,calc_run_id,
                  reviewer_user_id,reviewer_role::text as reviewer_role,
                  decision::text as decision,caveat,
                  scope_reviewed,scope_not_reviewed,gate_snapshot,created_at
                from signoff
                where pack_version_id=%s
                order by created_at,id
                """,
                (pack["id"],),
            )
            signoffs = [
                SignoffRead(**row) for row in await signoff_result.fetchall()
            ]
            versions.append(
                PackHistoryVersionRead(
                    **pack,
                    signoffs=signoffs,
                )
            )

    return ReviewPackHistoryResponse(review_id=review_id, versions=versions)
