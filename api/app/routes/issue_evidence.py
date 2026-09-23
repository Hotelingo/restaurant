from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, NoDataFound
from psycopg.types.json import Jsonb

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..issue_schemas import (
    DecisionCreateRequest,
    DecisionMutationResponse,
    DecisionRead,
    DiagnosisCreateRequest,
    DiagnosisMutationResponse,
    DiagnosisRead,
    DriverEvidenceCreateRequest,
    DriverEvidenceMutationResponse,
    DriverEvidenceRead,
    EvidenceRequestCreateRequest,
    EvidenceRequestFulfillRequest,
    EvidenceRequestMutationResponse,
    EvidenceRequestRead,
    IssueDecisionWorkspaceResponse,
    IssueEvidenceWorkspaceResponse,
)

router = APIRouter(tags=["issue-evidence"])


def _decimal_text(value: Decimal | None) -> str | None:
    return format(value, "f") if value is not None else None


def _decision_from_row(row) -> DecisionRead:
    return DecisionRead(**row)


def _diagnosis_from_row(row) -> DiagnosisRead:
    return DiagnosisRead(**row)


def _driver_evidence_from_row(row) -> DriverEvidenceRead:
    return DriverEvidenceRead(
        **{
            **row,
            "quantified_impact": _decimal_text(row["quantified_impact"]),
            "reconciliation_impact": _decimal_text(row["reconciliation_impact"]) or "0",
        }
    )


def _evidence_request_from_row(row) -> EvidenceRequestRead:
    return EvidenceRequestRead(
        **{
            **row,
            "minimum_fields": list(row["minimum_fields"] or []),
        }
    )


async def _load_decision(conn, decision_id: UUID) -> DecisionRead | None:
    result = await conn.execute(
        """
        select
          id,review_issue_id,version_no,disposition::text as disposition,
          diagnosis_id,decision_text,owner,lever,guardrail,
          verification_metric,target_trigger,due_date,cadence,
          evidence_request_id,decision_required,consequence_of_waiting,
          forecast_treatment,closure_evidence,supersedes_decision_id,
          decided_by,decided_at
        from decision
        where id=%s
        """,
        (decision_id,),
    )
    row = await result.fetchone()
    return _decision_from_row(row) if row else None


async def _load_diagnosis(conn, diagnosis_id: UUID) -> DiagnosisRead | None:
    result = await conn.execute(
        """
        select
          d.id,d.review_issue_id,d.version_no,d.diagnosis_state,
          dt.code as driver_code,dt.name as driver_name,
          d.supported_summary,d.hypothesis_summary,d.unknowns,
          d.evidence_status,d.diagnostic_status,d.supersedes_diagnosis_id,
          d.created_by,d.created_at
        from diagnosis d
        left join driver_taxonomy dt on dt.id=d.driver_taxonomy_id
        where d.id=%s
        """,
        (diagnosis_id,),
    )
    row = await result.fetchone()
    return _diagnosis_from_row(row) if row else None


async def _load_driver_evidence(conn, evidence_id: UUID) -> DriverEvidenceRead | None:
    result = await conn.execute(
        """
        select
          de.id,de.review_issue_id,de.diagnosis_id,
          dt.code as driver_code,dt.name as driver_name,
          de.evidence_source_type,de.evidence_source_id,de.evidence_status,
          de.quantified_impact,de.reconciliation_impact,de.note,
          de.approved_by,de.created_by,de.created_at
        from driver_evidence de
        join driver_taxonomy dt on dt.id=de.driver_taxonomy_id
        where de.id=%s
        """,
        (evidence_id,),
    )
    row = await result.fetchone()
    return _driver_evidence_from_row(row) if row else None


async def _load_evidence_request(conn, request_id: UUID) -> EvidenceRequestRead | None:
    result = await conn.execute(
        """
        select
          id,review_issue_id,requested_dataset,reason,minimum_fields,
          owner,due_date,status,fulfilled_batch_id,fulfilled_at,
          created_by,created_at,updated_at
        from evidence_request
        where id=%s
        """,
        (request_id,),
    )
    row = await result.fetchone()
    return _evidence_request_from_row(row) if row else None


def _translate_db_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (InsufficientPrivilege, NoDataFound)):
        return HTTPException(status_code=404, detail="Issue or evidence request not found")
    if isinstance(exc, CheckViolation):
        return HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "type": "diagnosis-evidence-invalid",
                "message": str(exc).splitlines()[0],
            },
        )
    return HTTPException(status_code=500, detail="Diagnosis/evidence operation failed")


@router.post(
    "/issues/{issue_id}/diagnosis",
    response_model=DiagnosisMutationResponse,
)
async def record_diagnosis(
    issue_id: UUID,
    payload: DiagnosisCreateRequest,
    request: Request,
    idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> DiagnosisMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from record_issue_diagnosis(
                  %s,%s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    issue_id,
                    payload.diagnosis_state,
                    payload.driver_code,
                    payload.evidence_status,
                    payload.supported_summary,
                    payload.hypothesis_summary,
                    payload.unknowns,
                    idempotency_key,
                    correlation_id,
                ),
            )
            recorded = await result.fetchone()
            if recorded is None:
                raise HTTPException(status_code=500, detail="Diagnosis operation returned no result")
            diagnosis = await _load_diagnosis(conn, recorded["diagnosis_id"])
    except (CheckViolation, InsufficientPrivilege, NoDataFound) as exc:
        raise _translate_db_error(exc) from exc

    if diagnosis is None:
        raise HTTPException(status_code=500, detail="Recorded diagnosis could not be loaded")
    return DiagnosisMutationResponse(diagnosis=diagnosis, reused=recorded["reused"])


@router.post(
    "/issues/{issue_id}/driver-evidence",
    response_model=DriverEvidenceMutationResponse,
)
async def add_evidence(
    issue_id: UUID,
    payload: DriverEvidenceCreateRequest,
    request: Request,
    idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> DriverEvidenceMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from add_driver_evidence(
                  %s,%s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    issue_id,
                    payload.driver_code,
                    payload.evidence_source_type,
                    payload.evidence_source_id,
                    payload.evidence_status,
                    payload.quantified_impact,
                    payload.note,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(status_code=500, detail="Evidence operation returned no result")
            evidence = await _load_driver_evidence(conn, created["evidence_id"])
    except (CheckViolation, InsufficientPrivilege, NoDataFound) as exc:
        raise _translate_db_error(exc) from exc

    if evidence is None:
        raise HTTPException(status_code=500, detail="Created evidence could not be loaded")
    return DriverEvidenceMutationResponse(evidence=evidence, reused=created["reused"])


@router.post(
    "/issues/{issue_id}/evidence-requests",
    response_model=EvidenceRequestMutationResponse,
)
async def create_request(
    issue_id: UUID,
    payload: EvidenceRequestCreateRequest,
    request: Request,
    idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> EvidenceRequestMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from create_evidence_request(
                  %s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    issue_id,
                    payload.requested_dataset,
                    payload.reason,
                    Jsonb(payload.minimum_fields),
                    payload.owner,
                    payload.due_date,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(status_code=500, detail="Evidence request returned no result")
            evidence_request = await _load_evidence_request(
                conn, created["evidence_request_id"]
            )
    except (CheckViolation, InsufficientPrivilege, NoDataFound) as exc:
        raise _translate_db_error(exc) from exc

    if evidence_request is None:
        raise HTTPException(status_code=500, detail="Evidence request could not be loaded")
    return EvidenceRequestMutationResponse(
        evidence_request=evidence_request,
        reused=created["reused"],
    )


@router.post(
    "/evidence-requests/{evidence_request_id}/fulfill",
    response_model=EvidenceRequestMutationResponse,
)
async def fulfill_request(
    evidence_request_id: UUID,
    payload: EvidenceRequestFulfillRequest,
    request: Request,
    idempotency_key: str = Header(..., alias="Idempotency-Key", min_length=8, max_length=200),
    user: AuthenticatedUser = Depends(get_current_user),
) -> EvidenceRequestMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)
    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from fulfill_evidence_request(%s,%s,%s,%s)",
                (
                    evidence_request_id,
                    payload.batch_id,
                    idempotency_key,
                    correlation_id,
                ),
            )
            fulfilled = await result.fetchone()
            if fulfilled is None:
                raise HTTPException(status_code=500, detail="Evidence fulfillment returned no result")
            evidence_request = await _load_evidence_request(
                conn, fulfilled["evidence_request_id"]
            )
    except (CheckViolation, InsufficientPrivilege, NoDataFound) as exc:
        raise _translate_db_error(exc) from exc

    if evidence_request is None:
        raise HTTPException(status_code=500, detail="Evidence request could not be loaded")
    return EvidenceRequestMutationResponse(
        evidence_request=evidence_request,
        reused=fulfilled["reused"],
    )


@router.get(
    "/issues/{issue_id}/evidence",
    response_model=IssueEvidenceWorkspaceResponse,
)
async def get_issue_evidence(
    issue_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> IssueEvidenceWorkspaceResponse:
    async with user_transaction(user.id) as conn:
        issue_result = await conn.execute(
            """
            select id,title,evidence_status
            from review_issue
            where id=%s
            """,
            (issue_id,),
        )
        issue = await issue_result.fetchone()
        if issue is None:
            raise HTTPException(status_code=404, detail="Issue not found")

        diagnosis_result = await conn.execute(
            """
            select
              d.id,d.review_issue_id,d.version_no,d.diagnosis_state,
              dt.code as driver_code,dt.name as driver_name,
              d.supported_summary,d.hypothesis_summary,d.unknowns,
              d.evidence_status,d.diagnostic_status,d.supersedes_diagnosis_id,
              d.created_by,d.created_at
            from diagnosis d
            left join driver_taxonomy dt on dt.id=d.driver_taxonomy_id
            where d.review_issue_id=%s
            order by d.version_no desc
            """,
            (issue_id,),
        )
        diagnosis_rows = await diagnosis_result.fetchall()

        evidence_result = await conn.execute(
            """
            select
              de.id,de.review_issue_id,de.diagnosis_id,
              dt.code as driver_code,dt.name as driver_name,
              de.evidence_source_type,de.evidence_source_id,de.evidence_status,
              de.quantified_impact,de.reconciliation_impact,de.note,
              de.approved_by,de.created_by,de.created_at
            from driver_evidence de
            join driver_taxonomy dt on dt.id=de.driver_taxonomy_id
            where de.review_issue_id=%s
            order by de.created_at,de.id
            """,
            (issue_id,),
        )
        evidence_rows = await evidence_result.fetchall()

        request_result = await conn.execute(
            """
            select
              id,review_issue_id,requested_dataset,reason,minimum_fields,
              owner,due_date,status,fulfilled_batch_id,fulfilled_at,
              created_by,created_at,updated_at
            from evidence_request
            where review_issue_id=%s
            order by created_at,id
            """,
            (issue_id,),
        )
        request_rows = await request_result.fetchall()

    history = [_diagnosis_from_row(row) for row in diagnosis_rows]
    return IssueEvidenceWorkspaceResponse(
        issue_id=issue["id"],
        issue_title=issue["title"],
        issue_evidence_status=issue["evidence_status"],
        latest_diagnosis=history[0] if history else None,
        diagnosis_history=history,
        driver_evidence=[
            _driver_evidence_from_row(row) for row in evidence_rows
        ],
        evidence_requests=[
            _evidence_request_from_row(row) for row in request_rows
        ],
    )



@router.post(
    "/issues/{issue_id}/decision",
    response_model=DecisionMutationResponse,
)
async def record_decision(
    issue_id: UUID,
    payload: DecisionCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> DecisionMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from record_issue_decision(
                  %s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    issue_id,
                    payload.disposition,
                    payload.decision_text,
                    payload.owner,
                    payload.lever,
                    payload.guardrail,
                    payload.verification_metric,
                    payload.target_trigger,
                    payload.due_date,
                    payload.cadence,
                    payload.evidence_request_id,
                    payload.decision_required,
                    payload.consequence_of_waiting,
                    payload.forecast_treatment,
                    payload.closure_evidence,
                    idempotency_key,
                    correlation_id,
                ),
            )
            recorded = await result.fetchone()
            if recorded is None:
                raise HTTPException(
                    status_code=500,
                    detail="Decision operation returned no result",
                )
            decision = await _load_decision(conn, recorded["decision_id"])
    except (CheckViolation, InsufficientPrivilege, NoDataFound) as exc:
        if isinstance(exc, (InsufficientPrivilege, NoDataFound)):
            raise HTTPException(status_code=404, detail="Review issue not found") from exc
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={
                "type": "decision-invalid",
                "message": str(exc).splitlines()[0],
            },
        ) from exc

    if decision is None:
        raise HTTPException(
            status_code=500,
            detail="Recorded decision could not be loaded",
        )
    return DecisionMutationResponse(
        decision=decision,
        reused=recorded["reused"],
    )


@router.get(
    "/issues/{issue_id}/decisions",
    response_model=IssueDecisionWorkspaceResponse,
)
async def get_issue_decisions(
    issue_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> IssueDecisionWorkspaceResponse:
    async with user_transaction(user.id) as conn:
        issue_result = await conn.execute(
            """
            select id,title,evidence_status,active_decision_id
            from review_issue
            where id=%s
            """,
            (issue_id,),
        )
        issue = await issue_result.fetchone()
        if issue is None:
            raise HTTPException(status_code=404, detail="Issue not found")

        history_result = await conn.execute(
            """
            select
              id,review_issue_id,version_no,disposition::text as disposition,
              diagnosis_id,decision_text,owner,lever,guardrail,
              verification_metric,target_trigger,due_date,cadence,
              evidence_request_id,decision_required,consequence_of_waiting,
              forecast_treatment,closure_evidence,supersedes_decision_id,
              decided_by,decided_at
            from decision
            where review_issue_id=%s
            order by version_no desc
            """,
            (issue_id,),
        )
        rows = await history_result.fetchall()

    history = [_decision_from_row(row) for row in rows]
    active = next(
        (
            decision
            for decision in history
            if decision.id == issue["active_decision_id"]
        ),
        None,
    )
    return IssueDecisionWorkspaceResponse(
        issue_id=issue["id"],
        issue_title=issue["title"],
        issue_evidence_status=issue["evidence_status"],
        active_decision=active,
        decision_history=history,
    )
