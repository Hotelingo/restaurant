from __future__ import annotations

from decimal import Decimal
from uuid import UUID

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import (
    CheckViolation,
    InsufficientPrivilege,
    InvalidParameterValue,
    NoDataFound,
    RestrictViolation,
    UniqueViolation,
)

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..pack_schemas import (
    ClaimCheckRead,
    ClaimCitationRead,
    PackArtifactUrlResponse,
    PackClaimCreateRequest,
    PackClaimEditRequest,
    PackClaimMutationResponse,
    PackClaimRead,
    PackClaimReviewResponse,
    PackMutationResponse,
    PackReadResponse,
    PackVersionRead,
)
from ..storage import StorageConfigurationError, get_object_storage

router = APIRouter(tags=["packs"])


def _decimal_text(value: Decimal | None) -> str | None:
    return format(value, "f") if value is not None else None


def _pack_from_row(row) -> PackVersionRead:
    return PackVersionRead(
        **{
            **row,
            "status": str(row["status"]),
        }
    )


def _check_from_json(payload: dict) -> ClaimCheckRead:
    return ClaimCheckRead(**payload)


async def _load_pack(conn, pack_id: UUID) -> PackVersionRead | None:
    result = await conn.execute(
        """
        select
          id,review_id,version_no,calc_run_id,status::text as status,
          supersedes_pack_version_id,reconciliation_disclosure,generated_at,
          artifact_bucket,artifact_path,artifact_sha256,
          renderer_version,template_version,
          created_by,created_at,updated_at
        from pack_version
        where id=%s
        """,
        (pack_id,),
    )
    row = await result.fetchone()
    return _pack_from_row(row) if row is not None else None


async def _load_claim(conn, claim_id: UUID) -> PackClaimRead | None:
    result = await conn.execute(
        """
        select
          id,pack_version_id,section_code,claim_text,
          claim_status::text as claim_status,evidence_status,
          edited_by,edited_at,reviewed_by,reviewed_at,
          review_check_snapshot,created_by,created_at
        from claim
        where id=%s
        """,
        (claim_id,),
    )
    row = await result.fetchone()
    if row is None:
        return None

    citations_result = await conn.execute(
        """
        select
          cc.id,cc.calc_result_id,
          cr.calc_id,cr.grain_type,cr.grain_key,
          cr.value_numeric,cr.value_text,cr.unit,
          btrim(cr.currency_code) as currency_code,
          cr.calculation_status,cr.evidence_status,
          cc.citation_role
        from claim_citation cc
        join calc_result cr
          on cr.organisation_id=cc.organisation_id
         and cr.outlet_id=cc.outlet_id
         and cr.run_id=cc.calc_run_id
         and cr.id=cc.calc_result_id
        where cc.claim_id=%s
        order by cc.created_at,cc.id
        """,
        (claim_id,),
    )
    citation_rows = await citations_result.fetchall()

    check_payload = row["review_check_snapshot"]
    if check_payload is None:
        check_result = await conn.execute(
            "select claim_check(%s) as check_result",
            (claim_id,),
        )
        check_row = await check_result.fetchone()
        check_payload = (
            check_row["check_result"] if check_row is not None else None
        )

    citations = [
        ClaimCitationRead(
            **{
                **citation,
                "value_numeric": _decimal_text(citation["value_numeric"]),
            }
        )
        for citation in citation_rows
    ]

    return PackClaimRead(
        **row,
        citations=citations,
        check=(
            _check_from_json(check_payload)
            if check_payload is not None
            else None
        ),
    )


def _translate_pack_error(exc: Exception) -> HTTPException:
    if isinstance(exc, (InsufficientPrivilege, NoDataFound)):
        return HTTPException(status_code=404, detail="Pack context not found")

    if isinstance(exc, RestrictViolation):
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "immutable-record",
                "message": str(exc).splitlines()[0],
            },
        )

    if isinstance(exc, UniqueViolation):
        return HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "pack-conflict",
                "message": str(exc).splitlines()[0],
            },
        )

    if isinstance(exc, (CheckViolation, InvalidParameterValue)):
        message = str(exc).splitlines()[0]
        problem_type = (
            "claim-check-failed"
            if "claimCheck" in message
            else "pack-invalid"
        )
        return HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": problem_type, "message": message},
        )

    return HTTPException(status_code=500, detail="Pack operation failed")


@router.post(
    "/reviews/{review_id}/packs",
    response_model=PackMutationResponse,
)
async def create_pack(
    review_id: UUID,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from create_pack_version(%s,%s,%s)",
                (review_id, idempotency_key, correlation_id),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(
                    status_code=500,
                    detail="Pack creation returned no result",
                )
            pack = await _load_pack(conn, created["pack_version_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        RestrictViolation,
        UniqueViolation,
    ) as exc:
        raise _translate_pack_error(exc) from exc

    if pack is None:
        raise HTTPException(status_code=500, detail="Created pack could not be loaded")

    return PackMutationResponse(pack=pack, reused=created["reused"])


@router.get(
    "/packs/{pack_id}",
    response_model=PackReadResponse,
)
async def get_pack(
    pack_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackReadResponse:
    async with user_transaction(user.id) as conn:
        pack = await _load_pack(conn, pack_id)
        if pack is None:
            raise HTTPException(status_code=404, detail="Pack not found")

        result = await conn.execute(
            """
            select id
            from claim
            where pack_version_id=%s
            order by created_at,id
            """,
            (pack_id,),
        )
        ids = [row["id"] for row in await result.fetchall()]
        claims = []
        for claim_id in ids:
            claim = await _load_claim(conn, claim_id)
            if claim is not None:
                claims.append(claim)

    return PackReadResponse(pack=pack, claims=claims)


@router.get(
    "/packs/{pack_id}/claims",
    response_model=list[PackClaimRead],
)
async def list_pack_claims(
    pack_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> list[PackClaimRead]:
    async with user_transaction(user.id) as conn:
        if await _load_pack(conn, pack_id) is None:
            raise HTTPException(status_code=404, detail="Pack not found")

        result = await conn.execute(
            """
            select id
            from claim
            where pack_version_id=%s
            order by created_at,id
            """,
            (pack_id,),
        )
        ids = [row["id"] for row in await result.fetchall()]
        claims: list[PackClaimRead] = []
        for claim_id in ids:
            claim = await _load_claim(conn, claim_id)
            if claim is not None:
                claims.append(claim)

    return claims


@router.post(
    "/packs/{pack_id}/claims",
    response_model=PackClaimMutationResponse,
)
async def create_claim(
    pack_id: UUID,
    payload: PackClaimCreateRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackClaimMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                """
                select * from create_pack_claim(
                  %s,%s,%s,%s,%s,%s,%s
                )
                """,
                (
                    pack_id,
                    payload.section_code,
                    payload.claim_text,
                    payload.evidence_status,
                    payload.calc_result_ids,
                    idempotency_key,
                    correlation_id,
                ),
            )
            created = await result.fetchone()
            if created is None:
                raise HTTPException(
                    status_code=500,
                    detail="Claim creation returned no result",
                )
            claim = await _load_claim(conn, created["claim_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        RestrictViolation,
        UniqueViolation,
    ) as exc:
        raise _translate_pack_error(exc) from exc

    if claim is None:
        raise HTTPException(status_code=500, detail="Created claim could not be loaded")

    return PackClaimMutationResponse(claim=claim, reused=created["reused"])


@router.post(
    "/packs/{pack_id}/claims/{claim_id}/edit",
    response_model=PackClaimMutationResponse,
)
async def edit_claim(
    pack_id: UUID,
    claim_id: UUID,
    payload: PackClaimEditRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackClaimMutationResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    async with user_transaction(user.id) as conn:
        claim_before = await _load_claim(conn, claim_id)
        if claim_before is None or claim_before.pack_version_id != pack_id:
            raise HTTPException(status_code=404, detail="Claim not found")

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from edit_pack_claim(%s,%s,%s,%s)",
                (
                    claim_id,
                    payload.claim_text,
                    idempotency_key,
                    correlation_id,
                ),
            )
            edited = await result.fetchone()
            if edited is None:
                raise HTTPException(
                    status_code=500,
                    detail="Claim edit returned no result",
                )
            claim = await _load_claim(conn, edited["claim_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        RestrictViolation,
        UniqueViolation,
    ) as exc:
        raise _translate_pack_error(exc) from exc

    if claim is None:
        raise HTTPException(status_code=500, detail="Edited claim could not be loaded")

    return PackClaimMutationResponse(claim=claim, reused=edited["reused"])


@router.get(
    "/packs/{pack_id}/claims/{claim_id}/check",
    response_model=ClaimCheckRead,
)
async def check_claim(
    pack_id: UUID,
    claim_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ClaimCheckRead:
    async with user_transaction(user.id) as conn:
        claim = await _load_claim(conn, claim_id)
        if claim is None or claim.pack_version_id != pack_id:
            raise HTTPException(status_code=404, detail="Claim not found")
        if claim.check is None:
            raise HTTPException(status_code=500, detail="Claim check returned no result")
        return claim.check


async def _review_claim(
    *,
    pack_id: UUID,
    claim_id: UUID,
    decision: str,
    request: Request,
    idempotency_key: str,
    user: AuthenticatedUser,
) -> PackClaimReviewResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    async with user_transaction(user.id) as conn:
        before = await _load_claim(conn, claim_id)
        if before is None or before.pack_version_id != pack_id:
            raise HTTPException(status_code=404, detail="Claim not found")

    try:
        async with user_transaction(user.id) as conn:
            result = await conn.execute(
                "select * from review_pack_claim(%s,%s,%s,%s)",
                (
                    claim_id,
                    decision,
                    idempotency_key,
                    correlation_id,
                ),
            )
            reviewed = await result.fetchone()
            if reviewed is None:
                raise HTTPException(
                    status_code=500,
                    detail="Claim review returned no result",
                )
            claim = await _load_claim(conn, reviewed["claim_id"])
    except (
        CheckViolation,
        InsufficientPrivilege,
        InvalidParameterValue,
        NoDataFound,
        RestrictViolation,
        UniqueViolation,
    ) as exc:
        raise _translate_pack_error(exc) from exc

    if claim is None:
        raise HTTPException(status_code=500, detail="Reviewed claim could not be loaded")

    return PackClaimReviewResponse(
        claim=claim,
        check=_check_from_json(reviewed["check_result"]),
        reused=reviewed["reused"],
    )


@router.post(
    "/packs/{pack_id}/claims/{claim_id}/accept",
    response_model=PackClaimReviewResponse,
)
async def accept_claim(
    pack_id: UUID,
    claim_id: UUID,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackClaimReviewResponse:
    return await _review_claim(
        pack_id=pack_id,
        claim_id=claim_id,
        decision="accept",
        request=request,
        idempotency_key=idempotency_key,
        user=user,
    )


@router.post(
    "/packs/{pack_id}/claims/{claim_id}/reject",
    response_model=PackClaimReviewResponse,
)
async def reject_claim(
    pack_id: UUID,
    claim_id: UUID,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackClaimReviewResponse:
    return await _review_claim(
        pack_id=pack_id,
        claim_id=claim_id,
        decision="reject",
        request=request,
        idempotency_key=idempotency_key,
        user=user,
    )


@router.get(
    "/packs/{pack_id}/artifact-url",
    response_model=PackArtifactUrlResponse,
)
async def get_pack_artifact_url(
    pack_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> PackArtifactUrlResponse:
    async with user_transaction(user.id) as conn:
        pack = await _load_pack(conn, pack_id)

    if pack is None:
        raise HTTPException(status_code=404, detail="Pack not found")
    if (
        pack.status != "signed"
        or not pack.artifact_path
        or not pack.artifact_bucket
        or not pack.artifact_sha256
    ):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "pack-artifact-unavailable",
                "message": "A signed Owner Pack artefact is not available yet.",
            },
        )

    try:
        storage = get_object_storage()
        if pack.artifact_bucket != storage.bucket:
            raise StorageConfigurationError(
                "Pack artefact bucket does not match configured private bucket."
            )
        url = await storage.presign_download(
            pack.artifact_path,
            expires_seconds=300,
        )
    except StorageConfigurationError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"type": "storage-unavailable", "message": str(exc)},
        ) from exc
    except (BotoCoreError, ClientError) as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={
                "type": "storage-read-failed",
                "message": "Could not create a signed Owner Pack download URL.",
            },
        ) from exc

    return PackArtifactUrlResponse(
        url=url,
        expires_in_seconds=300,
        artifact_sha256=pack.artifact_sha256,
    )
