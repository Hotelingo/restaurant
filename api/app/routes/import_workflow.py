from __future__ import annotations

from collections import defaultdict
from datetime import date
from hashlib import sha256
from typing import Any, Literal
from uuid import UUID

from botocore.exceptions import BotoCoreError, ClientError
from fastapi import APIRouter, Depends, Header, HTTPException, Request, status
from psycopg.errors import CheckViolation, InsufficientPrivilege, UniqueViolation
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from packages.import_engine import (
    ConfidenceBands,
    ParseError,
    ProfileScope,
    ProfileVersion,
    SourceFingerprint,
    StagingError,
    build_financial_staging_rows,
    build_food_cost_staging_rows,
    build_labour_staging_rows,
    build_revenue_staging_rows,
    build_fingerprint,
    match_profile,
    parse_csv,
    parse_xlsx,
)

from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction
from ..storage import StorageConfigurationError, get_object_storage

router = APIRouter(prefix="/imports", tags=["imports"])

ScenarioCode = Literal["actual", "budget", "forecast", "prior_year"]


class ImportParseRequest(BaseModel):
    period_id: UUID
    scenario: ScenarioCode
    sheet_name: str | None = Field(default=None, min_length=1, max_length=200)
    effective_from_default: date | None = None


class ImportParseResponse(BaseModel):
    batch_id: UUID
    status: str
    staging_row_count: int
    parse_error_count: int
    fingerprint: str
    profile_match_tier: str
    profile_match_message: str
    profile_version_id: UUID | None
    candidate_profile_version_id: UUID | None


class ImportStatusResponse(BaseModel):
    batch_id: UUID
    source_file_id: UUID
    template_code: str
    status: str
    period_id: UUID | None
    scenario: str
    staging_row_count: int
    parse_error_count: int
    unresolved_block_count: int
    warning_count: int
    fingerprint: str | None
    profile_match_tier: str | None
    profile_match_message: str | None
    profile_version_id: UUID | None
    candidate_profile_version_id: UUID | None
    canonical_commit_hash: str | None


class ImportExceptionItem(BaseModel):
    kind: str
    identity: str
    source_row_numbers: list[int]
    source_account_code: str | None = None
    source_account_name: str | None = None
    source_value: str | None = None
    suggested_management_line: str | None = None


class ImportExceptionsResponse(BaseModel):
    batch_id: UUID
    profile_version_id: UUID | None
    candidate_profile_version_id: UUID | None
    exceptions: list[ImportExceptionItem]


class ImportValidateResponse(BaseModel):
    batch_id: UUID
    status: str
    unresolved_block_count: int
    warning_count: int
    validation_count: int


class AccountMappingConfirmation(BaseModel):
    source_account_code: str | None = Field(default=None, max_length=200)
    source_account_name: str = Field(min_length=1, max_length=500)
    ladder_line_code: str = Field(min_length=1, max_length=100)


class ManagementLineMappingConfirmation(BaseModel):
    source_value: str = Field(min_length=1, max_length=500)
    ladder_line_code: str = Field(min_length=1, max_length=100)


class ItemMappingConfirmation(BaseModel):
    source_item_code: str | None = Field(default=None, max_length=200)
    source_item_name: str | None = Field(default=None, max_length=500)
    canonical_item_key: str = Field(min_length=1, max_length=300)


class ProductGroupMappingConfirmation(BaseModel):
    source_value: str = Field(min_length=1, max_length=500)
    canonical_value: Literal["food", "beverage"]


class LabourActivityBasisConfirmation(BaseModel):
    source_role_group: str = Field(min_length=1, max_length=500)
    activity_basis: str = Field(min_length=1, max_length=200)


class MappingConfirmRequest(BaseModel):
    source_label: str | None = Field(default=None, min_length=1, max_length=200)
    base_profile_version_id: UUID | None = None
    account_mappings: list[AccountMappingConfirmation] = Field(
        default_factory=list,
        max_length=10000,
    )
    management_line_mappings: list[ManagementLineMappingConfirmation] = Field(
        default_factory=list,
        max_length=10000,
    )
    item_mappings: list[ItemMappingConfirmation] = Field(
        default_factory=list,
        max_length=10000,
    )
    product_group_mappings: list[ProductGroupMappingConfirmation] = Field(
        default_factory=list,
        max_length=1000,
    )
    labour_activity_basis_mappings: list[LabourActivityBasisConfirmation] = Field(
        default_factory=list,
        max_length=1000,
    )


class MappingConfirmResponse(BaseModel):
    batch_id: UUID
    profile_version_id: UUID
    version_no: int
    status: str
    reused: bool


def _fingerprint_components(
    fingerprint: SourceFingerprint,
    source_keys: frozenset[str],
) -> dict[str, Any]:
    return {
        "sheet_name": fingerprint.sheet_name,
        "ordered_headers": list(fingerprint.ordered_headers),
        "header_row": fingerprint.header_row,
        "orientation": fingerprint.orientation,
        "key_set_hash": fingerprint.key_set_hash,
        "column_count": fingerprint.column_count,
        "template_code": fingerprint.template_code,
        "source_keys": sorted(source_keys),
    }


def _profile_from_row(
    *,
    scope: ProfileScope,
    row: dict[str, Any],
) -> ProfileVersion | None:
    components = row.get("fingerprint_components_json") or {}
    layout = row.get("layout_json") or {}
    try:
        fingerprint = SourceFingerprint(
            sheet_name=str(components["sheet_name"]),
            ordered_headers=tuple(str(value) for value in components["ordered_headers"]),
            header_row=int(components["header_row"]),
            orientation=str(components["orientation"]),
            key_set_hash=str(components["key_set_hash"]),
            column_count=int(components["column_count"]),
            template_code=str(components["template_code"]),
        )
        source_keys = frozenset(str(value) for value in components["source_keys"])
        headers = tuple(str(value) for value in layout["headers"])
    except (KeyError, TypeError, ValueError):
        # Legacy/incomplete metadata is not a valid automatic match candidate.
        return None

    if fingerprint.signature != row["fingerprint_hash"]:
        return None

    return ProfileVersion(
        scope=scope,
        version=row["version_no"],
        fingerprint=fingerprint,
        source_keys=source_keys,
        headers=headers,
        approved=True,
    )


async def _batch_status_payload(conn, batch_id: UUID) -> ImportStatusResponse | None:
    result = await conn.execute(
        """
        select
          b.id as batch_id,b.source_file_id,b.template_code,b.status::text,
          b.period_id,b.scenario::text,b.detected_fingerprint as fingerprint,
          b.profile_match_tier,b.profile_match_message,
          b.profile_version_id,b.candidate_profile_version_id,
          b.canonical_commit_hash,
          (select count(*) from staging_row s where s.batch_id=b.id) as staging_row_count,
          (select count(*) from staging_row s
             where s.batch_id=b.id
               and jsonb_array_length(s.parse_errors) > 0) as parse_error_count,
          (select count(*) from validation_result v
             where v.batch_id=b.id
               and v.severity='block' and not v.resolved) as unresolved_block_count,
          (select count(*) from validation_result v
             where v.batch_id=b.id
               and v.severity='warn' and not v.resolved) as warning_count
        from import_batch b
        where b.id=%s
        """,
        (batch_id,),
    )
    row = await result.fetchone()
    if row is None:
        return None
    return ImportStatusResponse(**row)


@router.post("/{batch_id}/parse", response_model=ImportParseResponse)
async def parse_import_batch(
    batch_id: UUID,
    payload: ImportParseRequest,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportParseResponse:
    # Read and authorise metadata first. RLS plus role checks prevent a caller
    # from using the parse endpoint as an object-storage oracle.
    async with user_transaction(user.id) as conn:
        result = await conn.execute(
            """
            select
              b.id,b.organisation_id,b.outlet_id,b.source_file_id,
              b.template_code,b.status::text,b.period_id,b.scenario::text,
              b.parse_completed_at,b.detected_fingerprint,
              b.profile_match_tier,b.profile_match_message,
              b.profile_version_id,b.candidate_profile_version_id,
              sf.storage_bucket,sf.storage_path,sf.original_filename,
              sf.sha256,sf.detected_file_type,
              rp.period_start,rp.period_end,rp.label
            from import_batch b
            join source_file sf
              on sf.organisation_id=b.organisation_id
             and sf.outlet_id=b.outlet_id
             and sf.id=b.source_file_id
            join reporting_period rp
              on rp.organisation_id=b.organisation_id
             and rp.outlet_id=b.outlet_id
             and rp.id=%s
            where b.id=%s
              and has_outlet_access(b.organisation_id,b.outlet_id)
              and has_org_role(
                b.organisation_id,
                array['admin','editor','setup_analyst']::app_role[]
              )
            """,
            (payload.period_id, batch_id),
        )
        batch = await result.fetchone()

        if batch is None:
            raise HTTPException(status_code=404, detail="Import batch not found")

        if batch["parse_completed_at"] is not None:
            if (
                batch["period_id"] != payload.period_id
                or batch["scenario"] != payload.scenario
            ):
                raise HTTPException(
                    status_code=status.HTTP_409_CONFLICT,
                    detail={
                        "type": "immutable-parse-context",
                        "message": "A parsed batch cannot be rebound to a different period or scenario.",
                    },
                )
            existing = await _batch_status_payload(conn, batch_id)
            if existing is None:
                raise HTTPException(status_code=404, detail="Import batch not found")
            if not existing.fingerprint or not existing.profile_match_tier:
                raise HTTPException(
                    status_code=500,
                    detail="Parsed batch is missing fingerprint metadata",
                )
            return ImportParseResponse(
                batch_id=batch_id,
                status=existing.status,
                staging_row_count=existing.staging_row_count,
                parse_error_count=existing.parse_error_count,
                fingerprint=existing.fingerprint,
                profile_match_tier=existing.profile_match_tier,
                profile_match_message=existing.profile_match_message or "",
                profile_version_id=existing.profile_version_id,
                candidate_profile_version_id=existing.candidate_profile_version_id,
            )

        if batch["status"] != "uploaded":
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "type": "invalid-import-state",
                    "message": f"Batch in status {batch['status']} cannot be parsed.",
                },
            )

        if batch["template_code"] not in {"T1", "T1B", "T2", "T3", "T4A", "T5", "T6", "T7"}:
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail={
                    "type": "unsupported-template",
                    "message": "The current server orchestration path supports T1, T1B, T2, T3, T4A, T5, T6 and T7.",
                },
            )

        if batch["template_code"] in {"T1", "T1B", "T2", "T3", "T4A", "T5", "T7"} and payload.scenario != "actual":
            raise HTTPException(
                status_code=422,
                detail={
                    "type": "invalid-scenario",
                    "message": f"{batch['template_code']} is an actual-source import path.",
                },
            )
        if batch["template_code"] == "T6" and payload.scenario == "actual":
            raise HTTPException(
                status_code=422,
                detail={
                    "type": "invalid-scenario",
                    "message": "T6 requires budget, forecast or prior_year.",
                },
            )

        setting_result = await conn.execute(
            """
            select key,value_json
            from setting
            where outlet_id=%s
              and key in (
                'import_profile_match_high',
                'import_profile_match_review',
                'import_header_aliases'
              )
            """,
            (batch["outlet_id"],),
        )
        settings = {
            row["key"]: row["value_json"]
            for row in await setting_result.fetchall()
        }

        required_settings = {
            "import_profile_match_high",
            "import_profile_match_review",
            "import_header_aliases",
        }
        if not required_settings.issubset(settings):
            raise HTTPException(
                status_code=500,
                detail="Import profile-match settings are incomplete for this outlet",
            )

        profile_result = await conn.execute(
            """
            select
              pv.id,pv.version_no,pv.fingerprint_hash,
              pv.fingerprint_components_json,pv.layout_json,
              pv.source_profile_id
            from profile_version pv
            join source_profile sp on sp.id=pv.source_profile_id
            where pv.organisation_id=%s
              and pv.outlet_id=%s
              and sp.template_code=%s
              and pv.status='approved'
              and pv.approved_at is not null
              -- Only each layout's active version may match. Superseded
              -- versions stay approved for lineage, but matching them would
              -- apply a mapping the user has since changed (Mappings page),
              -- and two versions of one layout would make a match ambiguous.
              and sp.active_profile_version_id=pv.id
            order by pv.created_at desc
            """,
            (
                batch["organisation_id"],
                batch["outlet_id"],
                batch["template_code"],
            ),
        )
        profile_rows = await profile_result.fetchall()

    try:
        storage_service = get_object_storage()
        if batch["storage_bucket"] != storage_service.bucket:
            raise StorageConfigurationError(
                "Stored bucket does not match configured private bucket."
            )
        source_bytes = await storage_service.get(batch["storage_path"])
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
                "message": "Could not retrieve the immutable source file.",
            },
        ) from exc

    if sha256(source_bytes).hexdigest() != batch["sha256"]:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "source-integrity-failed",
                "message": "Stored source bytes do not match the upload SHA-256.",
            },
        )

    try:
        if batch["detected_file_type"] == "csv":
            document = parse_csv(batch["original_filename"], source_bytes)
        elif batch["detected_file_type"] == "xlsx":
            document = parse_xlsx(batch["original_filename"], source_bytes)
        else:
            raise ParseError("Unsupported persisted file type")
    except ParseError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "parse-failed", "message": str(exc)},
        ) from exc

    if payload.sheet_name:
        tables = [table for table in document.tables if table.sheet_name == payload.sheet_name]
        if len(tables) != 1:
            raise HTTPException(
                status_code=422,
                detail={
                    "type": "sheet-selection-invalid",
                    "message": "The requested worksheet was not found exactly once.",
                },
            )
        table = tables[0]
    elif len(document.tables) == 1:
        table = document.tables[0]
    else:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail={
                "type": "sheet-selection-required",
                "message": "Workbook contains multiple worksheets; select one before parsing.",
                "sheets": [table.sheet_name for table in document.tables],
            },
        )

    aliases = settings["import_header_aliases"]
    if not isinstance(aliases, dict) or not all(
        isinstance(key, str) and isinstance(value, str)
        for key, value in aliases.items()
    ):
        raise HTTPException(
            status_code=500,
            detail="Import header aliases setting must be a string-to-string object",
        )

    target_period = batch["period_start"].strftime("%Y-%m")
    try:
        if batch["template_code"] in {"T1", "T6"}:
            staging = build_financial_staging_rows(
                table,
                template_code=batch["template_code"],
                target_period=target_period,
                header_aliases=aliases,
            )
        elif batch["template_code"] in {"T1B", "T7"}:
            staging = build_revenue_staging_rows(
                table,
                template_code=batch["template_code"],
                target_period=target_period,
                header_aliases=aliases,
            )
        elif batch["template_code"] == "T5":
            staging = build_labour_staging_rows(
                table,
                template_code=batch["template_code"],
                target_period=target_period,
                header_aliases=aliases,
            )
        else:
            staging = build_food_cost_staging_rows(
                table,
                template_code=batch["template_code"],
                target_period=target_period,
                header_aliases=aliases,
                effective_from_default=(
                    payload.effective_from_default.isoformat()
                    if payload.effective_from_default is not None
                    else None
                ),
            )
    except StagingError as exc:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "parse-failed", "message": str(exc)},
        ) from exc

    fingerprint, source_keys = build_fingerprint(table, batch["template_code"])
    scope = ProfileScope(
        batch["organisation_id"],
        batch["outlet_id"],
        batch["template_code"],
    )

    profiles: list[ProfileVersion] = []
    profile_row_by_key: dict[tuple[int, str], dict[str, Any]] = {}
    for row in profile_rows:
        profile = _profile_from_row(scope=scope, row=row)
        if profile is None:
            continue
        profiles.append(profile)
        profile_row_by_key[(profile.version, profile.fingerprint.signature)] = row

    try:
        bands = ConfidenceBands(
            high=float(settings["import_profile_match_high"]),
            review=float(settings["import_profile_match_review"]),
        )
    except (TypeError, ValueError) as exc:
        raise HTTPException(
            status_code=500,
            detail="Import profile-match confidence settings are invalid",
        ) from exc

    match = match_profile(
        scope=scope,
        table=table,
        profiles=tuple(profiles),
        confidence_bands=bands,
        aliases=aliases,
    )

    candidate_row = None
    if match.profile is not None:
        candidate_row = profile_row_by_key.get(
            (match.profile.version, match.profile.fingerprint.signature)
        )
    candidate_id = candidate_row["id"] if candidate_row else None
    active_profile_id = candidate_id if match.tier == "exact" else None

    parse_error_count = sum(bool(row.parse_errors) for row in staging.rows)
    next_status = (
        "blocked"
        if parse_error_count
        else "validating"
        if match.tier == "exact"
        else "needs_mapping"
    )

    metadata = {
        "selected_sheet_name": table.sheet_name,
        "headers": list(table.headers),
        "field_map": dict(staging.field_map),
        "month_columns": list(getattr(staging, "month_columns", ())),
        "target_period": staging.target_period,
        "ignored_source_fields": list(
            getattr(staging, "ignored_source_fields", ())
        ),
        "effective_from_default": (
            payload.effective_from_default.isoformat()
            if payload.effective_from_default is not None
            else None
        ),
        "fingerprint_components": _fingerprint_components(fingerprint, source_keys),
        "candidate_source_profile_id": (
            str(candidate_row["source_profile_id"]) if candidate_row else None
        ),
    }

    # Persist staging and the matching decision atomically. If this transaction
    # fails, no partial staging rows are retained.
    async with user_transaction(user.id) as conn:
        lock_result = await conn.execute(
            """
            select status::text,parse_completed_at
            from import_batch
            where id=%s
              and has_outlet_access(organisation_id,outlet_id)
              and has_org_role(
                organisation_id,
                array['admin','editor','setup_analyst']::app_role[]
              )
            for update
            """,
            (batch_id,),
        )
        locked = await lock_result.fetchone()
        if locked is None:
            raise HTTPException(status_code=404, detail="Import batch not found")
        if locked["parse_completed_at"] is not None:
            existing = await _batch_status_payload(conn, batch_id)
            if existing is None or not existing.fingerprint or not existing.profile_match_tier:
                raise HTTPException(status_code=500, detail="Parsed batch metadata is incomplete")
            return ImportParseResponse(
                batch_id=batch_id,
                status=existing.status,
                staging_row_count=existing.staging_row_count,
                parse_error_count=existing.parse_error_count,
                fingerprint=existing.fingerprint,
                profile_match_tier=existing.profile_match_tier,
                profile_match_message=existing.profile_match_message or "",
                profile_version_id=existing.profile_version_id,
                candidate_profile_version_id=existing.candidate_profile_version_id,
            )
        if locked["status"] != "uploaded":
            raise HTTPException(
                status_code=409,
                detail={"type": "invalid-import-state", "message": "Batch changed while parsing."},
            )

        for row in staging.rows:
            inserted = await conn.execute(
                """
                insert into staging_row(
                  organisation_id,outlet_id,batch_id,source_row_no,
                  raw_jsonb,parsed_jsonb,row_status,parse_errors
                )
                select organisation_id,outlet_id,id,%s,%s,%s,%s,%s
                from import_batch
                where id=%s
                returning id
                """,
                (
                    row.source_row_no,
                    Jsonb(dict(row.raw)),
                    Jsonb(dict(row.parsed)),
                    row.row_status,
                    Jsonb(list(row.parse_errors)),
                    batch_id,
                ),
            )
            staging_row = await inserted.fetchone()
            if staging_row is None:
                raise HTTPException(status_code=500, detail="Could not persist staging row")

            for error in row.parse_errors:
                await conn.execute(
                    """
                    insert into validation_result(
                      organisation_id,outlet_id,batch_id,staging_row_id,
                      rule_code,severity,object_scope,field_name,
                      message,remediation,reconciliation_status
                    )
                    select
                      organisation_id,outlet_id,id,%s,
                      %s,'block',%s,%s,%s,%s,'reconciled'
                    from import_batch where id=%s
                    """,
                    (
                        staging_row["id"],
                        error["code"],
                        f"row:{row.source_row_no}",
                        error.get("field"),
                        error["message"],
                        "Correct the source row and upload a corrected file.",
                        batch_id,
                    ),
                )

        await conn.execute(
            """
            update import_batch
            set period_id=%s,
                scenario=%s,
                status=%s,
                detected_fingerprint=%s,
                profile_version_id=%s,
                candidate_profile_version_id=%s,
                profile_match_tier=%s,
                profile_match_message=%s,
                parse_metadata_json=%s,
                parse_completed_at=now()
            where id=%s
            """,
            (
                payload.period_id,
                payload.scenario,
                next_status,
                fingerprint.signature,
                active_profile_id,
                candidate_id,
                match.tier,
                match.message,
                Jsonb(metadata),
                batch_id,
            ),
        )

        # audit_log has no client INSERT policy; the SECURITY DEFINER writer
        # derives actor, organisation and outlet server-side (0038).
        await conn.execute(
            """
            select record_import_audit_event(
              %s,'IMPORT_BATCH_PARSED','import_batch',%s,%s,null
            )
            """,
            (batch_id, str(batch_id), fingerprint.signature),
        )

    return ImportParseResponse(
        batch_id=batch_id,
        status=next_status,
        staging_row_count=len(staging.rows),
        parse_error_count=parse_error_count,
        fingerprint=fingerprint.signature,
        profile_match_tier=match.tier,
        profile_match_message=match.message,
        profile_version_id=active_profile_id,
        candidate_profile_version_id=candidate_id,
    )


@router.get("/{batch_id}/status", response_model=ImportStatusResponse)
async def import_batch_status(
    batch_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportStatusResponse:
    async with user_transaction(user.id) as conn:
        payload = await _batch_status_payload(conn, batch_id)
    if payload is None:
        raise HTTPException(status_code=404, detail="Import batch not found")
    return payload


@router.get("/{batch_id}/exceptions", response_model=ImportExceptionsResponse)
async def import_batch_exceptions(
    batch_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportExceptionsResponse:
    async with user_transaction(user.id) as conn:
        batch_result = await conn.execute(
            """
            select
              id,template_code,profile_version_id,candidate_profile_version_id
            from import_batch
            where id=%s
            """,
            (batch_id,),
        )
        batch = await batch_result.fetchone()
        if batch is None:
            raise HTTPException(status_code=404, detail="Import batch not found")

        staging_result = await conn.execute(
            """
            select source_row_no,raw_jsonb,parsed_jsonb
            from staging_row
            where batch_id=%s
            order by source_row_no
            """,
            (batch_id,),
        )
        rows = await staging_result.fetchall()

        profile_id = batch["profile_version_id"] or batch["candidate_profile_version_id"]
        account_keys: set[str] = set()
        item_keys: set[str] = set()
        management_value_keys: set[str] = set()
        product_group_keys: set[str] = set()
        labour_basis_keys: set[str] = set()

        if profile_id is not None:
            account_result = await conn.execute(
                """
                select source_identity_key
                from account_mapping
                where profile_version_id=%s
                """,
                (profile_id,),
            )
            account_keys = {
                row["source_identity_key"] for row in await account_result.fetchall()
            }

            item_result = await conn.execute(
                """
                select source_identity_key
                from item_mapping
                where profile_version_id=%s
                """,
                (profile_id,),
            )
            item_keys = {
                row["source_identity_key"] for row in await item_result.fetchall()
            }

            value_result = await conn.execute(
                """
                select
                  lower(btrim(field_name)) as field_name,
                  lower(btrim(source_value)) as source_value
                from value_mapping
                where profile_version_id=%s
                """,
                (profile_id,),
            )
            for mapping in await value_result.fetchall():
                if mapping["field_name"] == "management_line":
                    management_value_keys.add(mapping["source_value"])
                elif mapping["field_name"] == "product_group":
                    product_group_keys.add(mapping["source_value"])
                elif mapping["field_name"] == "labour_activity_basis":
                    labour_basis_keys.add(mapping["source_value"])

    grouped: dict[str, dict[str, Any]] = {}
    for row in rows:
        parsed = row["parsed_jsonb"] or {}
        raw = row["raw_jsonb"] or {}

        if batch["template_code"] in {"T1B", "T7"}:
            continue
        if batch["template_code"] in {"T2", "T4A"}:
            code = str(parsed.get("item_code") or "").strip() or None
            name = str(parsed.get("item_name") or "").strip() or None
            if code:
                identity = f"code:{code.casefold()}"
            elif name:
                identity = f"name:{name.casefold()}"
            else:
                identity = f"row:{row['source_row_no']}"
            mapped = identity in item_keys
            kind = "item"
            source_value = None
        elif batch["template_code"] == "T3":
            source_value = str(parsed.get("product_group") or "").strip()
            identity = (
                f"product_group:{source_value.casefold()}"
                if source_value
                else f"row:{row['source_row_no']}"
            )
            mapped = source_value.casefold() in product_group_keys
            kind = "product_group"
            code = None
            name = None
        elif batch["template_code"] == "T5":
            # Explicit source activity basis wins. Mapping is required only
            # when activity units exist but the source omits its semantic basis.
            if (
                parsed.get("activity_units") is None
                or str(parsed.get("activity_basis") or "").strip()
            ):
                continue
            source_value = str(parsed.get("role_group") or "").strip()
            identity = (
                f"labour_activity_basis:{source_value.casefold()}"
                if source_value
                else f"row:{row['source_row_no']}"
            )
            mapped = source_value.casefold() in labour_basis_keys
            kind = "labour_activity_basis"
            code = None
            name = None
        elif parsed.get("management_line"):
            source_value = str(parsed["management_line"]).strip()
            identity = f"management_line:{source_value.casefold()}"
            mapped = source_value.casefold() in management_value_keys
            kind = "management_line"
            code = None
            name = None
        else:
            code = str(parsed.get("account_code") or "").strip() or None
            name = str(parsed.get("account_name") or "").strip() or None
            if code:
                identity = f"code:{code.casefold()}"
            elif name:
                identity = f"name:{name.casefold()}"
            else:
                identity = f"row:{row['source_row_no']}"
            mapped = identity in account_keys
            kind = "account"
            source_value = None

        if mapped:
            continue

        item = grouped.setdefault(
            identity,
            {
                "kind": kind,
                "identity": identity,
                "source_row_numbers": [],
                "source_account_code": code,
                "source_account_name": name,
                "source_value": source_value,
                "suggested_management_line": (
                    raw.get("Suggested_Management_Line")
                    or raw.get("suggested_management_line")
                ),
            },
        )
        item["source_row_numbers"].append(row["source_row_no"])

    return ImportExceptionsResponse(
        batch_id=batch_id,
        profile_version_id=batch["profile_version_id"],
        candidate_profile_version_id=batch["candidate_profile_version_id"],
        exceptions=[ImportExceptionItem(**item) for item in grouped.values()],
    )


@router.post("/{batch_id}/validate", response_model=ImportValidateResponse)
async def validate_import_batch(
    batch_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ImportValidateResponse:
    async with user_transaction(user.id) as conn:
        batch_result = await conn.execute(
            """
            select
              id,organisation_id,outlet_id,template_code,status::text,
              profile_version_id
            from import_batch
            where id=%s
              and has_outlet_access(organisation_id,outlet_id)
              and has_org_role(
                organisation_id,
                array['admin','editor','setup_analyst']::app_role[]
              )
            for update
            """,
            (batch_id,),
        )
        batch = await batch_result.fetchone()
        if batch is None:
            raise HTTPException(status_code=404, detail="Import batch not found")

        if batch["status"] in {"ready", "warning", "committed", "superseded"}:
            counts = await conn.execute(
                """
                select
                  count(*) as validation_count,
                  count(*) filter(where severity='block' and not resolved) as unresolved_block_count,
                  count(*) filter(where severity='warn' and not resolved) as warning_count
                from validation_result where batch_id=%s
                """,
                (batch_id,),
            )
            row = await counts.fetchone()
            return ImportValidateResponse(
                batch_id=batch_id,
                status=batch["status"],
                validation_count=row["validation_count"],
                unresolved_block_count=row["unresolved_block_count"],
                warning_count=row["warning_count"],
            )

        if batch["status"] == "needs_mapping" or batch["profile_version_id"] is None:
            raise HTTPException(
                status_code=status.HTTP_409_CONFLICT,
                detail={
                    "type": "mapping-required",
                    "message": "Confirm all source identities before validation.",
                },
            )

        if batch["status"] == "blocked":
            counts = await conn.execute(
                """
                select
                  count(*) as validation_count,
                  count(*) filter(where severity='block' and not resolved) as unresolved_block_count,
                  count(*) filter(where severity='warn' and not resolved) as warning_count
                from validation_result where batch_id=%s
                """,
                (batch_id,),
            )
            row = await counts.fetchone()
            return ImportValidateResponse(
                batch_id=batch_id,
                status="blocked",
                validation_count=row["validation_count"],
                unresolved_block_count=row["unresolved_block_count"],
                warning_count=row["warning_count"],
            )

        if batch["status"] != "validating":
            raise HTTPException(
                status_code=409,
                detail={
                    "type": "invalid-import-state",
                    "message": f"Batch in status {batch['status']} cannot be validated.",
                },
            )

        # Approved profile is a hard precondition.
        approved = await conn.execute(
            """
            select 1
            from profile_version
            where id=%s and status='approved' and approved_at is not null
            """,
            (batch["profile_version_id"],),
        )
        if await approved.fetchone() is None:
            raise HTTPException(
                status_code=409,
                detail={
                    "type": "mapping-required",
                    "message": "Selected profile version is not approved.",
                },
            )

        staging_result = await conn.execute(
            """
            select id,source_row_no,parsed_jsonb
            from staging_row
            where batch_id=%s
            order by source_row_no
            """,
            (batch_id,),
        )
        staging_rows = await staging_result.fetchall()

        ladder_grain_t6 = (
            batch["template_code"] == "T6"
            and any((row["parsed_jsonb"] or {}).get("management_line") for row in staging_rows)
        )

        missing: list[tuple[dict[str, Any], str, str | None]] = []
        domain_errors: list[tuple[dict[str, Any], str, str, str]] = []

        if batch["template_code"] in {"T2", "T4A"}:
            mapped_result = await conn.execute(
                """
                select source_identity_key
                from item_mapping
                where profile_version_id=%s
                """,
                (batch["profile_version_id"],),
            )
            mapped = {row["source_identity_key"] for row in await mapped_result.fetchall()}
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                code = str(parsed.get("item_code") or "").strip()
                name = str(parsed.get("item_name") or "").strip()
                identity = (
                    f"code:{code.casefold()}"
                    if code
                    else f"name:{name.casefold()}"
                    if name
                    else ""
                )
                if not identity or identity not in mapped:
                    missing.append((row, "item_identity", identity or None))

                if batch["template_code"] == "T2":
                    try:
                        if float(parsed.get("units_sold", "")) < 0:
                            domain_errors.append(
                                (row, "T2_UNITS_NEGATIVE", "units_sold", "Units Sold cannot be negative.")
                            )
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (row, "T2_UNITS_INVALID", "units_sold", "Units Sold must be numeric.")
                        )
                else:
                    if not str(parsed.get("effective_from") or "").strip():
                        domain_errors.append(
                            (row, "T4A_EFFECTIVE_FROM_REQUIRED", "effective_from", "Effective From is required.")
                        )
                    try:
                        if float(parsed.get("approved_cost_per_unit", "")) < 0:
                            domain_errors.append(
                                (row, "T4A_COST_NEGATIVE", "approved_cost_per_unit", "Approved Cost per Unit cannot be negative.")
                            )
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (row, "T4A_COST_INVALID", "approved_cost_per_unit", "Approved Cost per Unit must be numeric.")
                        )

        elif batch["template_code"] == "T3":
            mapped_result = await conn.execute(
                """
                select lower(btrim(source_value)) as source_value
                from value_mapping
                where profile_version_id=%s
                  and lower(btrim(field_name))='product_group'
                """,
                (batch["profile_version_id"],),
            )
            mapped = {row["source_value"] for row in await mapped_result.fetchall()}
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                value = str(parsed.get("product_group") or "").strip()
                if not value or value.casefold() not in mapped:
                    missing.append((row, "product_group", value or None))
                if "expected_usage" in parsed:
                    domain_errors.append(
                        (
                            row,
                            "T3_EXPECTED_USAGE_NOT_CANONICAL",
                            "expected_usage",
                            "Expected Usage must be derived from T2 × T4A, not imported from T3.",
                        )
                    )
                for field in ("opening_inventory", "purchases", "closing_inventory"):
                    try:
                        if float(parsed.get(field, "")) < 0:
                            domain_errors.append(
                                (
                                    row,
                                    "T3_STOCK_NEGATIVE",
                                    field,
                                    f"{field.replace('_', ' ').title()} cannot be negative.",
                                )
                            )
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (
                                row,
                                "T3_STOCK_INVALID",
                                field,
                                f"{field.replace('_', ' ').title()} must be numeric.",
                            )
                        )

        elif batch["template_code"] in {"T1B", "T7"}:
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                if batch["template_code"] == "T1B":
                    if not str(parsed.get("business_view_key") or "").strip():
                        domain_errors.append(
                            (row, "T1B_BUSINESS_VIEW_REQUIRED", "business_view_key", "Meal Period or Business Format is required.")
                        )
                    if not str(parsed.get("activity_unit_type") or "").strip():
                        domain_errors.append(
                            (row, "T1B_ACTIVITY_UNIT_TYPE_REQUIRED", "activity_unit_type", "Activity Unit Type is required.")
                        )
                    for field in ("activity_units", "revenue"):
                        try:
                            value = float(parsed.get(field, ""))
                            if field == "activity_units" and value < 0:
                                domain_errors.append(
                                    (row, "T1B_ACTIVITY_UNITS_NEGATIVE", field, "Activity Units cannot be negative.")
                                )
                        except (TypeError, ValueError):
                            domain_errors.append(
                                (row, f"T1B_{field.upper()}_INVALID", field, f"{field.replace('_', ' ').title()} must be numeric.")
                            )
                    if parsed.get("comparator_activity_units") is not None:
                        try:
                            if float(parsed["comparator_activity_units"]) < 0:
                                domain_errors.append(
                                    (row, "T1B_COMPARATOR_ACTIVITY_UNITS_NEGATIVE", "comparator_activity_units", "Comparator Activity Units cannot be negative.")
                                )
                        except (TypeError, ValueError):
                            domain_errors.append(
                                (row, "T1B_COMPARATOR_ACTIVITY_UNITS_INVALID", "comparator_activity_units", "Comparator Activity Units must be numeric.")
                            )
                else:
                    if not str(parsed.get("source_channel") or "").strip():
                        domain_errors.append(
                            (row, "T7_SOURCE_CHANNEL_REQUIRED", "source_channel", "Customer Source / Channel is required.")
                        )
                    if (
                        parsed.get("activity_units") is None
                        and parsed.get("attributed_revenue") is None
                    ):
                        domain_errors.append(
                            (row, "T7_MEASURE_REQUIRED", "attributed_revenue", "T7 requires Attributed Revenue or Activity Units.")
                        )
                    if parsed.get("activity_units") is not None:
                        try:
                            if float(parsed["activity_units"]) < 0:
                                domain_errors.append(
                                    (row, "T7_ACTIVITY_UNITS_NEGATIVE", "activity_units", "Activity Units cannot be negative.")
                                )
                        except (TypeError, ValueError):
                            domain_errors.append(
                                (row, "T7_ACTIVITY_UNITS_INVALID", "activity_units", "Activity Units must be numeric.")
                            )
                    evidence = str(parsed.get("source_evidence_status") or "").strip()
                    if evidence and evidence not in {
                        "supported", "validated", "partly_supported", "evidence_required"
                    }:
                        domain_errors.append(
                            (row, "T7_EVIDENCE_STATUS_INVALID", "source_evidence_status", "Evidence Status is not a supported canonical value.")
                        )

        elif batch["template_code"] == "T5":
            basis_result = await conn.execute(
                """
                select
                  lower(btrim(source_value)) as source_value,
                  btrim(canonical_value) as activity_basis
                from value_mapping
                where profile_version_id=%s
                  and lower(btrim(field_name))='labour_activity_basis'
                """,
                (batch["profile_version_id"],),
            )
            basis_map = {
                row["source_value"]: row["activity_basis"]
                for row in await basis_result.fetchall()
            }
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                role_group = str(parsed.get("role_group") or "").strip()
                if not role_group:
                    domain_errors.append(
                        (
                            row,
                            "T5_ROLE_GROUP_REQUIRED",
                            "role_group",
                            "Role Group / Area is required.",
                        )
                    )

                for field in ("actual_hours", "actual_cost"):
                    try:
                        value = float(parsed.get(field, ""))
                        if field == "actual_hours" and value < 0:
                            domain_errors.append(
                                (
                                    row,
                                    "T5_ACTUAL_HOURS_NEGATIVE",
                                    field,
                                    "Paid Hours cannot be negative.",
                                )
                            )
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (
                                row,
                                f"T5_{field.upper()}_INVALID",
                                field,
                                f"{field.replace('_', ' ').title()} must be numeric.",
                            )
                        )

                for field in (
                    "comparator_hours",
                    "scheduled_hours",
                    "overtime_hours",
                    "activity_units",
                ):
                    if parsed.get(field) is None:
                        continue
                    try:
                        if float(parsed[field]) < 0:
                            domain_errors.append(
                                (
                                    row,
                                    f"T5_{field.upper()}_NEGATIVE",
                                    field,
                                    f"{field.replace('_', ' ').title()} cannot be negative.",
                                )
                            )
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (
                                row,
                                f"T5_{field.upper()}_INVALID",
                                field,
                                f"{field.replace('_', ' ').title()} must be numeric.",
                            )
                        )

                if parsed.get("comparator_cost") is not None:
                    try:
                        float(parsed["comparator_cost"])
                    except (TypeError, ValueError):
                        domain_errors.append(
                            (
                                row,
                                "T5_COMPARATOR_COST_INVALID",
                                "comparator_cost",
                                "Comparator Labour Cost must be numeric.",
                            )
                        )

                comparator_scenario = str(
                    parsed.get("comparator_scenario") or ""
                ).strip()
                if comparator_scenario and comparator_scenario not in {
                    "budget",
                    "forecast",
                    "prior_year",
                }:
                    domain_errors.append(
                        (
                            row,
                            "T5_COMPARATOR_SCENARIO_INVALID",
                            "comparator_scenario",
                            "Comparator scenario must be budget, forecast or prior_year.",
                        )
                    )

                if parsed.get("activity_units") is not None:
                    source_basis = str(
                        parsed.get("activity_basis") or ""
                    ).strip()
                    mapped_basis = basis_map.get(role_group.casefold())
                    if not source_basis and not mapped_basis:
                        missing.append(
                            (row, "activity_basis", role_group or None)
                        )

        elif ladder_grain_t6:
            mapped_result = await conn.execute(
                """
                select lower(btrim(source_value)) as source_value
                from value_mapping
                where profile_version_id=%s
                  and lower(btrim(field_name))='management_line'
                """,
                (batch["profile_version_id"],),
            )
            mapped = {row["source_value"] for row in await mapped_result.fetchall()}
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                value = str(parsed.get("management_line") or "").strip()
                if not value or value.casefold() not in mapped:
                    missing.append((row, "management_line", value or None))
        else:
            mapped_result = await conn.execute(
                """
                select source_identity_key
                from account_mapping
                where profile_version_id=%s
                """,
                (batch["profile_version_id"],),
            )
            mapped = {row["source_identity_key"] for row in await mapped_result.fetchall()}
            for row in staging_rows:
                parsed = row["parsed_jsonb"] or {}
                code = str(parsed.get("account_code") or "").strip()
                name = str(parsed.get("account_name") or "").strip()
                identity = (
                    f"code:{code.casefold()}"
                    if code
                    else f"name:{name.casefold()}"
                    if name
                    else ""
                )
                if not identity or identity not in mapped:
                    missing.append((row, "account_identity", identity or None))

        for staging_row, field_name, actual in missing:
            await conn.execute(
                """
                insert into validation_result(
                  organisation_id,outlet_id,batch_id,staging_row_id,
                  rule_code,severity,object_scope,field_name,
                  actual_json,message,remediation,reconciliation_status
                )
                values (%s,%s,%s,%s,'MAPPING_MISSING','block',%s,%s,%s,%s,%s,'reconciled')
                """,
                (
                    batch["organisation_id"],
                    batch["outlet_id"],
                    batch_id,
                    staging_row["id"],
                    f"row:{staging_row['source_row_no']}",
                    field_name,
                    Jsonb(actual),
                    (
                        f"Row {staging_row['source_row_no']}: Labour activity basis has no approved mapping."
                        if field_name == "activity_basis"
                        else f"Row {staging_row['source_row_no']}: source identity has no approved mapping."
                    ),
                    (
                        "Confirm the role-group activity basis; do not infer it from the activity-unit amount."
                        if field_name == "activity_basis"
                        else "Confirm the source identity against a non-calculated Management P&L line."
                    ),
                ),
            )

        for staging_row, rule_code, field_name, message in domain_errors:
            await conn.execute(
                """
                insert into validation_result(
                  organisation_id,outlet_id,batch_id,staging_row_id,
                  rule_code,severity,object_scope,field_name,
                  message,remediation,reconciliation_status
                )
                values (%s,%s,%s,%s,%s,'block',%s,%s,%s,%s,'reconciled')
                """,
                (
                    batch["organisation_id"],
                    batch["outlet_id"],
                    batch_id,
                    staging_row["id"],
                    rule_code,
                    f"row:{staging_row['source_row_no']}",
                    field_name,
                    message,
                    "Correct the source field or approved import mapping before commit.",
                ),
            )

        counts = await conn.execute(
            """
            select
              count(*) as validation_count,
              count(*) filter(where severity='block' and not resolved) as unresolved_block_count,
              count(*) filter(where severity='warn' and not resolved) as warning_count
            from validation_result where batch_id=%s
            """,
            (batch_id,),
        )
        row = await counts.fetchone()

        next_status = (
            "blocked"
            if row["unresolved_block_count"] > 0
            else "warning"
            if row["warning_count"] > 0
            else "ready"
        )
        await conn.execute(
            "update import_batch set status=%s where id=%s",
            (next_status, batch_id),
        )

        return ImportValidateResponse(
            batch_id=batch_id,
            status=next_status,
            validation_count=row["validation_count"],
            unresolved_block_count=row["unresolved_block_count"],
            warning_count=row["warning_count"],
        )



@router.post(
    "/{batch_id}/mapping/confirm",
    response_model=MappingConfirmResponse,
)
async def confirm_import_mapping(
    batch_id: UUID,
    payload: MappingConfirmRequest,
    request: Request,
    idempotency_key: str = Header(
        ...,
        alias="Idempotency-Key",
        min_length=8,
        max_length=200,
    ),
    user: AuthenticatedUser = Depends(get_current_user),
) -> MappingConfirmResponse:
    correlation_id = getattr(request.state, "correlation_id", None)

    account_payload = [
        item.model_dump(mode="json")
        for item in payload.account_mappings
    ]
    management_payload = [
        item.model_dump(mode="json")
        for item in payload.management_line_mappings
    ]
    item_payload = [
        item.model_dump(mode="json")
        for item in payload.item_mappings
    ]
    product_group_payload = [
        item.model_dump(mode="json")
        for item in payload.product_group_mappings
    ]
    labour_basis_payload = [
        item.model_dump(mode="json")
        for item in payload.labour_activity_basis_mappings
    ]

    try:
        async with user_transaction(user.id) as conn:
            template_result = await conn.execute(
                "select template_code from import_batch where id=%s",
                (batch_id,),
            )
            template_row = await template_result.fetchone()
            if template_row is None:
                raise HTTPException(status_code=404, detail="Import batch not found")

            base_profile_version_id = payload.base_profile_version_id
            if base_profile_version_id is None:
                # The batch's candidate was chosen when the file was read. If the
                # layout's mapping was revised since, build on the active version
                # so confirming this batch cannot undo that revision.
                active_result = await conn.execute(
                    """
                    select sp.active_profile_version_id
                    from import_batch b
                    join profile_version pv on pv.id=b.candidate_profile_version_id
                    join source_profile sp on sp.id=pv.source_profile_id
                    where b.id=%s
                    """,
                    (batch_id,),
                )
                active_row = await active_result.fetchone()
                if active_row is not None:
                    base_profile_version_id = active_row["active_profile_version_id"]

            if template_row["template_code"] in {"T2", "T3", "T4A"}:
                result = await conn.execute(
                    """
                    select *
                    from confirm_food_cost_mapping(
                      %s,%s,%s,%s,%s::jsonb,%s::jsonb,%s
                    )
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        payload.source_label,
                        base_profile_version_id,
                        Jsonb(item_payload),
                        Jsonb(product_group_payload),
                        correlation_id,
                    ),
                )
            elif template_row["template_code"] in {"T1B", "T7"}:
                result = await conn.execute(
                    """
                    select *
                    from confirm_revenue_mapping(
                      %s,%s,%s,%s,%s
                    )
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        payload.source_label,
                        base_profile_version_id,
                        correlation_id,
                    ),
                )
            elif template_row["template_code"] == "T5":
                result = await conn.execute(
                    """
                    select *
                    from confirm_labour_mapping(
                      %s,%s,%s,%s,%s::jsonb,%s
                    )
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        payload.source_label,
                        base_profile_version_id,
                        Jsonb(labour_basis_payload),
                        correlation_id,
                    ),
                )
            else:
                result = await conn.execute(
                    """
                    select *
                    from confirm_financial_mapping(
                      %s,%s,%s,%s,%s::jsonb,%s::jsonb,%s
                    )
                    """,
                    (
                        batch_id,
                        idempotency_key,
                        payload.source_label,
                        base_profile_version_id,
                        Jsonb(account_payload),
                        Jsonb(management_payload),
                        correlation_id,
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
                "type": "mapping-conflict",
                "message": "The source profile or mapping identity conflicts with an existing version.",
            },
        ) from exc
    except CheckViolation as exc:
        message = str(exc).splitlines()[0]
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail={"type": "mapping-invalid", "message": message},
        ) from exc

    if row is None:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Mapping confirmation returned no result",
        )

    return MappingConfirmResponse(
        batch_id=batch_id,
        profile_version_id=row["confirmed_profile_version_id"],
        version_no=row["confirmed_version_no"],
        status=str(row["confirmed_batch_status"]),
        reused=row["reused"],
    )
