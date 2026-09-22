from __future__ import annotations

from datetime import datetime, timezone
import json
from uuid import UUID, uuid4

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, Query, Request, UploadFile, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, UniqueViolation
from pydantic import BaseModel

from ..auth import AuthenticatedUser, get_current_user
from ..config import Settings, get_settings
from ..db import user_transaction
from ..malware import MalwareDetectedError, MalwareScanError, build_malware_scanner
from ..storage import StorageConfigurationError, get_object_storage
from ..upload_safety import (
    UploadPolicy,
    UploadSafetyError,
    inspect_upload,
    read_upload_limited,
    safe_storage_filename,
)

router = APIRouter(prefix="/imports", tags=["imports"])

SUPPORTED_TEMPLATE_CODES = frozenset(
    {"T1","T1B","T2","T3","T4A","T4B","T5","T6","T7","T8","M1","M2","M3","M4"}
)


class ImportUploadResponse(BaseModel):
    source_file_id: UUID
    batch_id: UUID
    status: str
    detected_file_type: str
    content_type: str
    size_bytes: int
    row_count: int
    sha256: str


class DownloadUrlResponse(BaseModel):
    url: str
    expires_in_seconds: int


class ImportCommitResponse(BaseModel):
    batch_id: UUID
    status: str
    fact_count: int
    canonical_commit_hash: str
    reused: bool


def _safety_http_error(exc: UploadSafetyError) -> HTTPException:
    http_status = (
        status.HTTP_413_REQUEST_ENTITY_TOO_LARGE
        if exc.code in {"file_size_limit", "row_limit"}
        else status.HTTP_422_UNPROCESSABLE_ENTITY
    )
    return HTTPException(
        status_code=http_status,
        detail={"type": exc.code, "message": str(exc)},
    )


@router.post(
    "/upload",
    response_model=ImportUploadResponse,
    status_code=status.HTTP_201_CREATED,
)
async def upload_import(
    request: Request,
    outlet_id: UUID = Form(...),
    template_code: str = Form(...),
    file: UploadFile = File(...),
    user: AuthenticatedUser = Depends(get_current_user),
    settings: Settings = Depends(get_settings),
) -> ImportUploadResponse:
    template_code = template_code.strip().upper()
    if template_code not in SUPPORTED_TEMPLATE_CODES:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "unsupported-template", "message": "Unsupported template code."},
        )

    policy = UploadPolicy(
        max_file_size_bytes=settings.upload_max_bytes,
        max_rows=settings.upload_max_rows,
        upload_timeout_seconds=settings.upload_timeout_seconds,
        max_xlsx_entries=settings.xlsx_max_entries,
        max_xlsx_uncompressed_bytes=settings.xlsx_max_uncompressed_bytes,
        max_xlsx_entry_bytes=settings.xlsx_max_entry_bytes,
        max_xlsx_compression_ratio=settings.xlsx_max_compression_ratio,
    )

    try:
        data = await read_upload_limited(file, policy=policy)
        inspection = inspect_upload(data, policy=policy)
    except UploadSafetyError as exc:
        raise _safety_http_error(exc) from exc

    try:
        scanner = build_malware_scanner(settings)
        scan = await scanner.scan(data)
    except MalwareDetectedError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "malware-detected", "message": "Upload failed malware scanning."},
        ) from exc
    except MalwareScanError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"type": "malware-scanner-unavailable", "message": str(exc)},
        ) from exc

    correlation_id = getattr(request.state, "correlation_id", None)
    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            """
            select o.organisation_id
            from outlet o
            where o.id=%s
              and has_outlet_access(o.organisation_id,o.id)
              and has_org_role(
                o.organisation_id,
                array['admin','editor','setup_analyst']::app_role[]
              )
            """,
            (outlet_id,),
        )
        authorised = await result.fetchone()

    if authorised is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Outlet not found")

    organisation_id = authorised["organisation_id"]
    source_file_id = uuid4()
    batch_id = uuid4()
    storage_name = safe_storage_filename(file.filename)
    storage_key = (
        f"org/{organisation_id}/outlet/{outlet_id}/source/"
        f"{source_file_id}/{storage_name}"
    )

    try:
        storage_service = get_object_storage()
    except StorageConfigurationError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"type": "storage-unavailable", "message": str(exc)},
        ) from exc

    try:
        await storage_service.put(
            key=storage_key,
            data=data,
            content_type=inspection.content_type,
            sha256_hex=inspection.sha256_hex,
        )
    except (BotoCoreError, ClientError) as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail={"type": "storage-write-failed", "message": "Could not persist upload."},
        ) from exc

    try:
        async with user_transaction(user.id) as conn:
            await conn.execute(
                """
                insert into source_file(
                  id,organisation_id,outlet_id,template_code,
                  storage_bucket,storage_path,original_filename,sha256,
                  content_type,size_bytes,uploaded_by,
                  detected_file_type,row_count,malware_scan_status,
                  malware_scanner,malware_scanned_at,inspection_json
                )
                values (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'clean',%s,%s,%s)
                """,
                (
                    source_file_id,
                    organisation_id,
                    outlet_id,
                    template_code,
                    settings.storage_bucket,
                    storage_key,
                    file.filename or storage_name,
                    inspection.sha256_hex,
                    inspection.content_type,
                    inspection.size_bytes,
                    user.id,
                    inspection.file_type,
                    inspection.row_count,
                    scan.scanner_name,
                    datetime.now(timezone.utc),
                    json.dumps(inspection.as_metadata()),
                ),
            )
            await conn.execute(
                """
                insert into import_batch(
                  id,organisation_id,outlet_id,source_file_id,template_code,status
                )
                values (%s,%s,%s,%s,%s,'uploaded')
                """,
                (batch_id, organisation_id, outlet_id, source_file_id, template_code),
            )
            await conn.execute(
                """
                insert into audit_log(
                  actor_user_id,organisation_id,outlet_id,
                  action_code,object_type,object_id,correlation_id
                )
                values (%s,%s,%s,'IMPORT_FILE_UPLOADED','source_file',%s,%s)
                """,
                (
                    user.id,
                    organisation_id,
                    outlet_id,
                    str(source_file_id),
                    correlation_id,
                ),
            )
    except Exception:
        try:
            await storage_service.delete(storage_key)
        except Exception:
            pass
        raise

    return ImportUploadResponse(
        source_file_id=source_file_id,
        batch_id=batch_id,
        status="uploaded",
        detected_file_type=inspection.file_type,
        content_type=inspection.content_type,
        size_bytes=inspection.size_bytes,
        row_count=inspection.row_count,
        sha256=inspection.sha256_hex,
    )


@router.get(
    "/files/{source_file_id}/download-url",
    response_model=DownloadUrlResponse,
)
async def source_file_download_url(
    source_file_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> DownloadUrlResponse:
    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            "select storage_bucket,storage_path from source_file where id=%s",
            (source_file_id,),
        )
        row = await result.fetchone()

    if row is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Source file not found")

    try:
        storage_service = get_object_storage()
        if row["storage_bucket"] != storage_service.bucket:
            raise StorageConfigurationError(
                "Stored bucket does not match configured private bucket."
            )
        url = await storage_service.presign_download(
            row["storage_path"],
            expires_seconds=300,
        )
    except StorageConfigurationError as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail={"type": "storage-unavailable", "message": str(exc)},
        ) from exc

    return DownloadUrlResponse(url=url, expires_in_seconds=300)



@router.post(
    "/{batch_id}/commit",
    response_model=ImportCommitResponse,
)
async def commit_import_batch(
    batch_id: UUID,
    request: Request,
    queue_calc: bool = Query(default=False),
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportCommitResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    try:
        async with user_transaction(user.id) as conn:
            template_result = await conn.execute(
                "select template_code from import_batch where id=%s",
                (batch_id,),
            )
            template_row = await template_result.fetchone()
            if template_row is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail="Import batch not found",
                )

            if template_row["template_code"] in {"T2", "T3", "T4A"}:
                result = await conn.execute(
                    """
                    select *
                    from commit_food_cost_import_batch(%s,%s,%s,%s)
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        correlation_id,
                        queue_calc,
                    ),
                )
            elif template_row["template_code"] in {"T1B", "T7"}:
                result = await conn.execute(
                    """
                    select *
                    from commit_revenue_import_batch(%s,%s,%s,%s)
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        correlation_id,
                        queue_calc,
                    ),
                )
            else:
                result = await conn.execute(
                    """
                    select *
                    from commit_financial_import_batch(%s,%s,%s,%s)
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        correlation_id,
                        queue_calc,
                    ),
                )
            row = await result.fetchone()
    except InsufficientPrivilege as exc:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Import batch not found",
        ) from exc
    except UniqueViolation as exc:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "duplicate-batch",
                "message": "A committed batch already exists for this outlet, period, scenario and template. Explicitly supersede it first.",
            },
        ) from exc
    except CheckViolation as exc:
        message = str(exc)
        problem_type = (
            "mapping-required"
            if "unmapped" in message.lower() or "mapping" in message.lower()
            else "validation-failed"
        )
        http_status = (
            status.HTTP_409_CONFLICT
            if problem_type == "mapping-required"
            else status.HTTP_422_UNPROCESSABLE_ENTITY
        )
        raise HTTPException(
            status_code=http_status,
            detail={"type": problem_type, "message": message.splitlines()[0]},
        ) from exc

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Commit returned no result",
        )

    return ImportCommitResponse(
        batch_id=row["committed_batch_id"],
        status=str(row["commit_status"]),
        fact_count=row["fact_count"],
        canonical_commit_hash=row["commit_hash"],
        reused=row["reused"],
    )
