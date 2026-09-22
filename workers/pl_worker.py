from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import date, datetime
from decimal import Decimal, ROUND_HALF_UP
from hashlib import sha256
import json
import logging
import os
import socket
import time
from typing import Any, Iterable, Mapping, Sequence
from uuid import UUID, uuid4

import psycopg
from psycopg import Connection
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from packages.calc_engine import (
    PL_LADDER,
    CalcResult,
    ExpectedUsageItem,
    FoodCostBridgeInput,
    calculate_decision_path,
    calculate_expected_usage,
    calculate_food_cost_bridge,
    calculate_pl_ladder,
    calculate_pl_variances,
    calculate_residual,
    calculate_supported_driver_total,
    first_material_movement,
    materiality_snapshot_from_mapping,
)

PL_ENGINE_VERSION = "pl-v1"
FC_ENGINE_VERSION = "food-cost-v1"
PERSISTENCE_QUANTUM = Decimal("0.0001")

logger = logging.getLogger("restaurant.calc_worker")


class WorkerDataError(RuntimeError):
    def __init__(self, code: str, message: str, *, retryable: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


@dataclass(frozen=True, slots=True)
class Claim:
    request_id: UUID
    organisation_id: UUID
    outlet_id: UUID
    period_id: UUID
    source_batch_id: UUID
    reason: str
    attempt_no: int


@dataclass(frozen=True, slots=True)
class PreparedRun:
    run_id: UUID
    claim: Claim
    currency: str
    comparator_scenario: str | None
    actual_values: Mapping[str, Decimal]
    actual_refs: Mapping[str, tuple[str, ...]]
    comparator_values: Mapping[str, Decimal] | None
    comparator_refs: Mapping[str, tuple[str, ...]] | None
    settings_snapshot: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class PersistedResult:
    id: UUID
    category: str
    line_code: str
    calc_id: str
    grain_type: str
    grain_key: Mapping[str, Any]
    value_numeric: Decimal | None
    value_text: str | None
    unit: str
    currency: str | None
    calculation_status: str
    evidence_status: str
    explanation_code: str | None
    input_refs: tuple[str, ...]
    raw_delta: Decimal | None
    profit_effect: Decimal | None
    metadata: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class CalculationBundle:
    results: tuple[PersistedResult, ...]
    dependencies: tuple[tuple[UUID, UUID, str], ...]
    result_hash: str


def _json_safe(value: Any) -> Any:
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, UUID):
        return str(value)
    if isinstance(value, (date, datetime)):
        return value.isoformat()
    if isinstance(value, Mapping):
        return {str(key): _json_safe(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_safe(item) for item in value]
    return value


def _decimal_for_storage(value: Decimal | None) -> Decimal | None:
    if value is None:
        return None
    return value.quantize(PERSISTENCE_QUANTUM, rounding=ROUND_HALF_UP)


def aggregate_financial_facts(
    rows: Iterable[Mapping[str, Any]],
) -> tuple[dict[str, Decimal], dict[str, tuple[str, ...]]]:
    """Aggregate canonical fact rows by non-calculated ladder code.

    Amounts never influence destination selection. The canonical ladder code
    is already fixed by the approved import mapping before the worker runs.
    """
    source_codes = {line.code for line in PL_LADDER if line.source}
    totals: dict[str, Decimal] = {}
    refs: dict[str, list[str]] = {}

    for row in rows:
        code = str(row["ladder_code"])
        if code not in source_codes:
            raise WorkerDataError(
                "UNSUPPORTED_LADDER_CODE",
                f"Canonical fact uses unsupported/calculated ladder code {code}",
            )

        amount = row["amount"]
        if not isinstance(amount, Decimal):
            amount = Decimal(str(amount))

        totals[code] = totals.get(code, Decimal("0")) + amount
        refs.setdefault(code, []).append(f"financial_fact:{row['fact_id']}")

    stable_refs = {
        code: tuple(sorted(set(values)))
        for code, values in refs.items()
    }
    return totals, stable_refs


def _metadata_dict(result: CalcResult) -> dict[str, Any]:
    return {key: value for key, value in result.metadata}


def _record_from_engine(
    result: CalcResult,
    *,
    category: str,
    scenario: str | None,
    comparator_scenario: str | None = None,
) -> PersistedResult:
    if category == "variance":
        grain_key: dict[str, Any] = {
            "ladder_code": result.grain_key,
            "actual_scenario": "actual",
            "comparator_scenario": comparator_scenario,
        }
    elif category == "sequence":
        grain_key = {"sequence": result.grain_key}
    else:
        grain_key = {
            "ladder_code": result.grain_key,
            "scenario": scenario,
        }

    return PersistedResult(
        id=uuid4(),
        category=category,
        line_code=result.grain_key,
        calc_id=result.calc_id,
        grain_type=result.grain_type,
        grain_key=grain_key,
        value_numeric=_decimal_for_storage(result.value),
        value_text=result.value_text,
        unit=result.unit,
        currency=result.currency,
        calculation_status=result.calculation_status,
        evidence_status=result.evidence_status,
        explanation_code=result.explanation_code,
        input_refs=tuple(result.input_refs),
        raw_delta=_decimal_for_storage(result.raw_delta),
        profit_effect=_decimal_for_storage(result.profit_effect),
        metadata=_metadata_dict(result),
    )


def _canonical_result_payload(result: PersistedResult) -> dict[str, Any]:
    return {
        "category": result.category,
        "line_code": result.line_code,
        "calc_id": result.calc_id,
        "grain_type": result.grain_type,
        "grain_key": _json_safe(result.grain_key),
        "value_numeric": (
            format(result.value_numeric, "f")
            if result.value_numeric is not None
            else None
        ),
        "value_text": result.value_text,
        "unit": result.unit,
        "currency": result.currency,
        "calculation_status": result.calculation_status,
        "evidence_status": result.evidence_status,
        "explanation_code": result.explanation_code,
        "input_refs": list(result.input_refs),
        "raw_delta": (
            format(result.raw_delta, "f")
            if result.raw_delta is not None
            else None
        ),
        "profit_effect": (
            format(result.profit_effect, "f")
            if result.profit_effect is not None
            else None
        ),
        "metadata": _json_safe(result.metadata),
    }


def canonical_result_hash(results: Sequence[PersistedResult]) -> str:
    payload = sorted(
        (_canonical_result_payload(result) for result in results),
        key=lambda item: (
            item["category"],
            item["calc_id"],
            json.dumps(item["grain_key"], sort_keys=True, separators=(",", ":")),
        ),
    )
    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")
    return sha256(encoded).hexdigest()


def calculate_pl_bundle(prepared: PreparedRun) -> CalculationBundle:
    actual_engine = calculate_pl_ladder(
        prepared.actual_values,
        currency=prepared.currency,
        input_refs=prepared.actual_refs,
    )

    comparator_engine: tuple[CalcResult, ...] | None = None
    if prepared.comparator_values is not None:
        comparator_engine = calculate_pl_ladder(
            prepared.comparator_values,
            currency=prepared.currency,
            input_refs=prepared.comparator_refs,
        )

    variance_engine = calculate_pl_variances(
        actual_engine,
        comparator_engine,
        currency=prepared.currency,
    )

    materiality_group = prepared.settings_snapshot.get("materiality", {})
    general_materiality = (
        materiality_group.get("general")
        if isinstance(materiality_group, Mapping)
        else None
    )
    sequence_engine = first_material_movement(
        variance_engine,
        comparator_engine,
        materiality_snapshot=materiality_snapshot_from_mapping(
            general_materiality if isinstance(general_materiality, Mapping) else None
        ),
        # Recurrence/risk events are explicit engine inputs. R1 does not infer
        # them from the configuration JSON; later review-period evidence may
        # supply these sets without changing the materiality formula.
        recurrence_overrides=frozenset(),
        risk_overrides=frozenset(),
    )

    persisted: list[PersistedResult] = []
    for result in actual_engine:
        persisted.append(
            _record_from_engine(
                result,
                category="actual",
                scenario="actual",
            )
        )

    if comparator_engine is not None:
        for result in comparator_engine:
            persisted.append(
                _record_from_engine(
                    result,
                    category="comparator",
                    scenario=prepared.comparator_scenario,
                )
            )

    for result in variance_engine:
        persisted.append(
            _record_from_engine(
                result,
                category="variance",
                scenario=None,
                comparator_scenario=prepared.comparator_scenario,
            )
        )

    persisted.append(
        _record_from_engine(
            sequence_engine,
            category="sequence",
            scenario=None,
            comparator_scenario=prepared.comparator_scenario,
        )
    )

    by_key = {
        (result.category, result.line_code): result
        for result in persisted
    }
    dependencies: list[tuple[UUID, UUID, str]] = []

    for category in ("actual", "comparator"):
        if category == "comparator" and comparator_engine is None:
            continue
        for line in PL_LADDER:
            if line.source:
                continue
            parent = by_key[(category, line.code)]
            for dependency_code in line.dependencies:
                child = by_key[(category, dependency_code)]
                dependencies.append((parent.id, child.id, "formula_input"))

    for line in PL_LADDER:
        parent = by_key[("variance", line.code)]
        actual_child = by_key[("actual", line.code)]
        dependencies.append((parent.id, actual_child.id, "actual_input"))
        if comparator_engine is not None:
            comparator_child = by_key[("comparator", line.code)]
            dependencies.append(
                (parent.id, comparator_child.id, "comparator_input")
            )

    sequence_parent = by_key[("sequence", "PL_LADDER")]
    ladder_codes = [line.code for line in PL_LADDER]
    if sequence_engine.value_text in ladder_codes:
        inspected_codes = ladder_codes[: ladder_codes.index(sequence_engine.value_text) + 1]
    elif sequence_engine.value_text == "NO_MATERIAL_MOVEMENT":
        inspected_codes = ladder_codes
    elif sequence_engine.explanation_code == "COMPARATOR_NOT_COMMITTED":
        inspected_codes = ladder_codes
    else:
        inspected_codes = []

    for code in inspected_codes:
        variance_child = by_key[("variance", code)]
        dependencies.append(
            (sequence_parent.id, variance_child.id, "sequence_inspected")
        )
        if comparator_engine is not None:
            comparator_child = by_key[("comparator", code)]
            dependencies.append(
                (sequence_parent.id, comparator_child.id, "sequence_denominator")
            )

    return CalculationBundle(
        results=tuple(persisted),
        dependencies=tuple(dependencies),
        result_hash=canonical_result_hash(persisted),
    )


def _log(event: str, **fields: Any) -> None:
    logger.info(
        json.dumps(
            {"event": event, **_json_safe(fields)},
            sort_keys=True,
            separators=(",", ":"),
        )
    )


def claim_one(
    conn: Connection,
    *,
    worker_id: str,
    lease_seconds: int,
    max_attempts: int,
) -> Claim | None:
    with conn.transaction():
        row = conn.execute(
            """
            select *
            from claim_calculation_request(%s,%s,%s)
            """,
            (worker_id, lease_seconds, max_attempts),
        ).fetchone()

    if row is None:
        return None

    return Claim(
        request_id=row["request_id"],
        organisation_id=row["organisation_id"],
        outlet_id=row["outlet_id"],
        period_id=row["period_id"],
        source_batch_id=row["source_batch_id"],
        reason=row["reason"],
        attempt_no=row["attempt_no"],
    )


def _load_batch(
    conn: Connection,
    *,
    organisation_id: UUID,
    outlet_id: UUID,
    period_id: UUID,
    scenario: str,
) -> Mapping[str, Any] | None:
    return conn.execute(
        """
        select
          b.id,b.profile_version_id,b.scenario::text,b.canonical_commit_hash,
          b.committed_at
        from import_batch b
        where b.organisation_id=%s
          and b.outlet_id=%s
          and b.period_id=%s
          and b.scenario=%s::scenario_code
          and b.status='committed'
          and b.canonical_commit_hash is not null
        order by b.committed_at desc,b.id desc
        limit 1
        """,
        (organisation_id, outlet_id, period_id, scenario),
    ).fetchone()


def _load_fact_rows(conn: Connection, batch_id: UUID) -> list[Mapping[str, Any]]:
    return list(
        conn.execute(
            """
            select
              ff.id as fact_id,
              ll.code as ladder_code,
              ff.amount
            from financial_fact ff
            join ladder_line ll on ll.id=ff.ladder_line_id
            where ff.batch_id=%s
            order by ll.display_order,ff.id
            """,
            (batch_id,),
        ).fetchall()
    )


def _snapshot_controls(
    conn: Connection,
    *,
    outlet_id: UUID,
    period_start: date,
    period_end: date,
) -> tuple[dict[str, Any], str | None]:
    setting_rows = conn.execute(
        """
        select key,value_json
        from setting
        where outlet_id=%s
        order by key
        """,
        (outlet_id,),
    ).fetchall()
    settings = {row["key"]: row["value_json"] for row in setting_rows}

    primary = settings.get("primary_comparator")
    if primary is not None and primary not in {"budget", "prior_year", "forecast"}:
        raise WorkerDataError(
            "INVALID_PRIMARY_COMPARATOR",
            "primary_comparator setting is not a supported scenario",
        )

    materiality_rows = conn.execute(
        """
        select distinct on (scope_type)
          id,scope_type::text,absolute_threshold,percent_threshold,
          source_kind::text,proposal_basis,recurrence_rule,
          risk_override_enabled,effective_from,effective_to,
          approved_by,approved_at,created_at
        from materiality_setting
        where outlet_id=%s
          and effective_from <= %s
          and (effective_to is null or effective_to >= %s)
        order by
          scope_type,
          (approved_at is not null) desc,
          effective_from desc,
          created_at desc,
          id desc
        """,
        (outlet_id, period_end, period_start),
    ).fetchall()

    materiality = {
        row["scope_type"]: {
            "id": str(row["id"]),
            "absolute_threshold": _json_safe(row["absolute_threshold"]),
            "percent_threshold": _json_safe(row["percent_threshold"]),
            "source_kind": row["source_kind"],
            "proposal_basis": _json_safe(row["proposal_basis"]),
            "recurrence_rule": _json_safe(row["recurrence_rule"]),
            "risk_override_enabled": row["risk_override_enabled"],
            "effective_from": row["effective_from"].isoformat(),
            "effective_to": (
                row["effective_to"].isoformat()
                if row["effective_to"] is not None
                else None
            ),
            "approved_by": (
                str(row["approved_by"])
                if row["approved_by"] is not None
                else None
            ),
            "approved_at": (
                row["approved_at"].isoformat()
                if row["approved_at"] is not None
                else None
            ),
        }
        for row in materiality_rows
    }

    return {
        "outlet_settings": _json_safe(settings),
        "materiality": materiality,
        "period": {
            "start": period_start.isoformat(),
            "end": period_end.isoformat(),
        },
    }, primary


def prepare_run(conn: Connection, claim: Claim) -> PreparedRun:
    with conn.transaction():
        context = conn.execute(
            """
            select
              rp.period_start,rp.period_end,
              btrim(o.currency_code) as currency_code,
              source.scenario::text as source_scenario
            from reporting_period rp
            join outlet o
              on o.organisation_id=rp.organisation_id
             and o.id=rp.outlet_id
            join import_batch source
              on source.organisation_id=rp.organisation_id
             and source.outlet_id=rp.outlet_id
             and source.id=%s
            where rp.organisation_id=%s
              and rp.outlet_id=%s
              and rp.id=%s
            """,
            (
                claim.source_batch_id,
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
            ),
        ).fetchone()

        if context is None:
            raise WorkerDataError(
                "REQUEST_CONTEXT_INVALID",
                "Calculation request does not match outlet/period source context",
            )

        settings_snapshot, configured_comparator = _snapshot_controls(
            conn,
            outlet_id=claim.outlet_id,
            period_start=context["period_start"],
            period_end=context["period_end"],
        )

        comparator_scenario = configured_comparator
        comparator_basis = "outlet_setting" if configured_comparator else None
        if comparator_scenario is None and context["source_scenario"] != "actual":
            comparator_scenario = context["source_scenario"]
            comparator_basis = "request_source_scenario"

        settings_snapshot = {
            **settings_snapshot,
            "comparator_selection": {
                "scenario": comparator_scenario,
                "basis": comparator_basis,
            },
        }

        actual_batch = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
        )
        if actual_batch is None:
            raise WorkerDataError(
                "ACTUAL_BATCH_NOT_COMMITTED",
                "No committed actual P&L batch exists for the calculation period",
                retryable=True,
            )

        comparator_batch = None
        if comparator_scenario is not None:
            comparator_batch = _load_batch(
                conn,
                organisation_id=claim.organisation_id,
                outlet_id=claim.outlet_id,
                period_id=claim.period_id,
                scenario=comparator_scenario,
            )

        actual_values, actual_refs = aggregate_financial_facts(
            _load_fact_rows(conn, actual_batch["id"])
        )
        if not actual_values:
            raise WorkerDataError(
                "ACTUAL_FACTS_EMPTY",
                "Committed actual batch has no canonical financial facts",
            )

        comparator_values: Mapping[str, Decimal] | None = None
        comparator_refs: Mapping[str, tuple[str, ...]] | None = None
        if comparator_batch is not None:
            comparator_values, comparator_refs = aggregate_financial_facts(
                _load_fact_rows(conn, comparator_batch["id"])
            )
            if not comparator_values:
                raise WorkerDataError(
                    "COMPARATOR_FACTS_EMPTY",
                    "Committed comparator batch has no canonical financial facts",
                )

        previous = conn.execute(
            """
            select id
            from calc_run
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and status='completed'
            order by completed_at desc,id desc
            limit 1
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()
        supersedes_id = previous["id"] if previous else None

        run_id = uuid4()
        conn.execute(
            """
            insert into calc_run(
              id,organisation_id,outlet_id,period_id,request_id,
              engine_version,settings_snapshot,comparator_scenario,
              status,supersedes_calc_run_id,attempt_no
            )
            values (%s,%s,%s,%s,%s,%s,%s,%s::scenario_code,'queued',%s,%s)
            """,
            (
                run_id,
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                claim.request_id,
                PL_ENGINE_VERSION,
                Jsonb(_json_safe(settings_snapshot)),
                comparator_scenario,
                supersedes_id,
                claim.attempt_no,
            ),
        )

        conn.execute(
            """
            insert into calc_run_input(
              organisation_id,outlet_id,run_id,batch_id,
              profile_version_id,input_role,scenario,canonical_commit_hash
            )
            values (%s,%s,%s,%s,%s,'actual',%s::scenario_code,%s)
            """,
            (
                claim.organisation_id,
                claim.outlet_id,
                run_id,
                actual_batch["id"],
                actual_batch["profile_version_id"],
                actual_batch["scenario"],
                actual_batch["canonical_commit_hash"],
            ),
        )

        if comparator_batch is not None:
            conn.execute(
                """
                insert into calc_run_input(
                  organisation_id,outlet_id,run_id,batch_id,
                  profile_version_id,input_role,scenario,canonical_commit_hash
                )
                values (%s,%s,%s,%s,%s,'comparator',%s::scenario_code,%s)
                """,
                (
                    claim.organisation_id,
                    claim.outlet_id,
                    run_id,
                    comparator_batch["id"],
                    comparator_batch["profile_version_id"],
                    comparator_batch["scenario"],
                    comparator_batch["canonical_commit_hash"],
                ),
            )

        conn.execute(
            """
            update calc_run
            set status='running',started_at=now()
            where id=%s
            """,
            (run_id,),
        )

    return PreparedRun(
        run_id=run_id,
        claim=claim,
        currency=context["currency_code"],
        comparator_scenario=comparator_scenario,
        actual_values=actual_values,
        actual_refs=actual_refs,
        comparator_values=comparator_values,
        comparator_refs=comparator_refs,
        settings_snapshot=settings_snapshot,
    )


def persist_bundle(
    conn: Connection,
    *,
    worker_id: str,
    prepared: PreparedRun,
    bundle: CalculationBundle,
) -> None:
    with conn.transaction():
        conn.execute(
            "select heartbeat_calculation_request(%s,%s,%s)",
            (prepared.claim.request_id, worker_id, 300),
        )

        for result in bundle.results:
            conn.execute(
                """
                insert into calc_result(
                  id,organisation_id,outlet_id,run_id,
                  calc_id,grain_type,grain_key,value_numeric,value_text,
                  unit,currency_code,calculation_status,evidence_status,
                  explanation_code,result_metadata,input_refs,
                  raw_delta,profit_effect
                )
                values (
                  %s,%s,%s,%s,
                  %s,%s,%s,%s,%s,
                  %s,%s,%s,%s,
                  %s,%s,%s,
                  %s,%s
                )
                """,
                (
                    result.id,
                    prepared.claim.organisation_id,
                    prepared.claim.outlet_id,
                    prepared.run_id,
                    result.calc_id,
                    result.grain_type,
                    Jsonb(_json_safe(result.grain_key)),
                    result.value_numeric,
                    result.value_text,
                    result.unit,
                    result.currency,
                    result.calculation_status,
                    result.evidence_status,
                    result.explanation_code,
                    Jsonb(_json_safe(result.metadata)),
                    Jsonb(list(result.input_refs)),
                    result.raw_delta,
                    result.profit_effect,
                ),
            )

        for parent_id, child_id, role in bundle.dependencies:
            conn.execute(
                """
                insert into calc_dependency(
                  organisation_id,outlet_id,run_id,
                  parent_result_id,child_result_id,dependency_role
                )
                values (%s,%s,%s,%s,%s,%s)
                """,
                (
                    prepared.claim.organisation_id,
                    prepared.claim.outlet_id,
                    prepared.run_id,
                    parent_id,
                    child_id,
                    role,
                ),
            )

        conn.execute(
            """
            update calc_run
            set status='completed',completed_at=now(),result_hash=%s
            where id=%s
            """,
            (bundle.result_hash, prepared.run_id),
        )
        conn.execute(
            "select complete_calculation_request(%s,%s,%s)",
            (prepared.claim.request_id, worker_id, prepared.run_id),
        )


def fail_claim(
    conn: Connection,
    *,
    worker_id: str,
    claim: Claim,
    run_id: UUID | None,
    error_code: str,
    message: str,
    retryable: bool,
    max_attempts: int,
) -> None:
    backoff_seconds = min(900, 30 * (2 ** max(claim.attempt_no - 1, 0)))

    with conn.transaction():
        if run_id is not None:
            conn.execute(
                """
                update calc_run
                set status='failed',
                    completed_at=now(),
                    error_code=%s,
                    error_message=%s
                where id=%s and status='running'
                """,
                (error_code, message[:2000], run_id),
            )

        conn.execute(
            """
            select fail_calculation_request(%s,%s,%s,%s,%s,%s)
            """,
            (
                claim.request_id,
                worker_id,
                f"{error_code}: {message}",
                retryable,
                backoff_seconds,
                max_attempts,
            ),
        )


def run_once(
    conn: Connection,
    *,
    worker_id: str,
    lease_seconds: int = 300,
    max_attempts: int = 5,
) -> bool:
    claim = claim_one(
        conn,
        worker_id=worker_id,
        lease_seconds=lease_seconds,
        max_attempts=max_attempts,
    )
    if claim is None:
        return False

    _log(
        "calc_request_started",
        request_id=claim.request_id,
        outlet_id=claim.outlet_id,
        period_id=claim.period_id,
        attempt_no=claim.attempt_no,
        worker_id=worker_id,
    )

    prepared: PreparedRun | None = None
    try:
        prepared = prepare_run(conn, claim)
        bundle = calculate_pl_bundle(prepared)
        persist_bundle(
            conn,
            worker_id=worker_id,
            prepared=prepared,
            bundle=bundle,
        )
    except WorkerDataError as exc:
        fail_claim(
            conn,
            worker_id=worker_id,
            claim=claim,
            run_id=prepared.run_id if prepared else None,
            error_code=exc.code,
            message=str(exc),
            retryable=exc.retryable,
            max_attempts=max_attempts,
        )
        _log(
            "calc_request_failed",
            request_id=claim.request_id,
            run_id=prepared.run_id if prepared else None,
            error_code=exc.code,
            retryable=exc.retryable,
        )
        return True
    except Exception as exc:
        fail_claim(
            conn,
            worker_id=worker_id,
            claim=claim,
            run_id=prepared.run_id if prepared else None,
            error_code="UNEXPECTED_WORKER_ERROR",
            message=type(exc).__name__,
            retryable=True,
            max_attempts=max_attempts,
        )
        _log(
            "calc_request_failed",
            request_id=claim.request_id,
            run_id=prepared.run_id if prepared else None,
            error_code="UNEXPECTED_WORKER_ERROR",
            retryable=True,
        )
        raise

    _log(
        "calc_request_completed",
        request_id=claim.request_id,
        run_id=prepared.run_id,
        result_hash=bundle.result_hash,
        result_count=len(bundle.results),
    )
    return True


def _worker_id() -> str:
    configured = os.getenv("CALC_WORKER_ID")
    if configured and configured.strip():
        return configured.strip()
    return f"{socket.gethostname()}:{os.getpid()}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Restaurant P&L calculation worker")
    parser.add_argument("--once", action="store_true", help="Process at most one available request")
    parser.add_argument(
        "--poll-seconds",
        type=float,
        default=float(os.getenv("CALC_WORKER_POLL_SECONDS", "2")),
    )
    parser.add_argument(
        "--lease-seconds",
        type=int,
        default=int(os.getenv("CALC_WORKER_LEASE_SECONDS", "300")),
    )
    parser.add_argument(
        "--max-attempts",
        type=int,
        default=int(os.getenv("CALC_WORKER_MAX_ATTEMPTS", "5")),
    )
    args = parser.parse_args()

    database_url = os.getenv("DATABASE_URL")
    if not database_url:
        raise SystemExit("DATABASE_URL is required")

    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(message)s")
    worker_id = _worker_id()

    with psycopg.connect(database_url, row_factory=dict_row) as conn:
        while True:
            handled = run_once(
                conn,
                worker_id=worker_id,
                lease_seconds=args.lease_seconds,
                max_attempts=args.max_attempts,
            )
            if args.once:
                return 0
            if not handled:
                time.sleep(max(args.poll_seconds, 0.1))


if __name__ == "__main__":
    raise SystemExit(main())
