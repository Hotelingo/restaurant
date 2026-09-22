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
    ContributionInput,
    ExpectedUsageItem,
    FoodCostBridgeInput,
    LabourInput,
    OtherCostInput,
    RevenueVarianceInput,
    calculate_decision_path,
    calculate_expected_usage,
    calculate_food_cost_bridge,
    calculate_contribution,
    calculate_labour,
    calculate_other_cost,
    calculate_pl_ladder,
    calculate_pl_variances,
    calculate_residual,
    calculate_revenue_variance,
    calculate_supported_driver_total,
    first_material_movement,
    materiality_snapshot_from_mapping,
)

PL_ENGINE_VERSION = "pl-v1"
FC_ENGINE_VERSION = "food-cost-v1"
REVENUE_ENGINE_VERSION = "revenue-v1"
LABOUR_OTHER_ENGINE_VERSION = "labour-other-v1"
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
class FoodCostGroupSource:
    product_group: str
    opening_inventory: Decimal
    purchases: Decimal
    closing_inventory: Decimal
    product_revenue: Decimal | None
    comparator_cost_pct: Decimal | None
    stock_refs: tuple[str, ...]
    revenue_refs: tuple[str, ...]
    comparator_refs: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class PreparedFoodCostRun:
    run_id: UUID
    claim: Claim
    currency: str
    item_sales_batch_id: UUID
    stock_batch_id: UUID
    item_cost_batch_id: UUID
    expected_usage_items: tuple[ExpectedUsageItem, ...]
    groups: tuple[FoodCostGroupSource, ...]
    settings_snapshot: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class RevenueGrainSource:
    business_view_type: str
    business_view_key: str
    activity_unit_type: str
    actual_units: Decimal
    actual_revenue: Decimal
    comparator_units: Decimal | None
    comparator_revenue: Decimal | None
    refs: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class PreparedRevenueRun:
    run_id: UUID
    claim: Claim
    currency: str
    revenue_activity_batch_id: UUID
    channel_source_batch_id: UUID
    financial_actual_batch_id: UUID
    grains: tuple[RevenueGrainSource, ...]
    financial_values: Mapping[str, Decimal]
    contribution_refs: tuple[str, ...]
    settings_snapshot: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class LabourGrainSource:
    role_group: str
    actual_hours: Decimal
    comparator_hours: Decimal | None
    actual_cost: Decimal
    comparator_cost: Decimal | None
    scheduled_hours: Decimal | None
    overtime_hours: Decimal | None
    activity_units: Decimal | None
    activity_basis: str | None
    refs: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class PreparedLabourOtherRun:
    run_id: UUID
    claim: Claim
    currency: str
    labour_batch_id: UUID
    financial_actual_batch_id: UUID
    financial_comparator_batch_id: UUID | None
    comparator_scenario: str | None
    labour_grains: tuple[LabourGrainSource, ...]
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


def _record_food_cost_engine(result: CalcResult) -> PersistedResult:
    return PersistedResult(
        id=uuid4(),
        category="food_cost",
        line_code=result.grain_key,
        calc_id=result.calc_id,
        grain_type=result.grain_type,
        grain_key={"product_group": result.grain_key},
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


def _food_cost_group_mapping(
    conn: Connection,
    *,
    profile_version_ids: Sequence[UUID],
) -> dict[str, str]:
    if not profile_version_ids:
        return {}

    rows = conn.execute(
        """
        select lower(btrim(source_value)) as source_value,
               lower(btrim(canonical_value)) as canonical_value
        from value_mapping
        where profile_version_id = any(%s)
          and lower(btrim(canonical_value)) in ('food','beverage')
        order by source_value,canonical_value
        """,
        (list(profile_version_ids),),
    ).fetchall()

    mapping: dict[str, str] = {}
    for row in rows:
        source = row["source_value"]
        canonical = row["canonical_value"]
        existing = mapping.get(source)
        if existing is not None and existing != canonical:
            raise WorkerDataError(
                "ITEM_GROUP_MAPPING_CONFLICT",
                f"Source grouping value {source!r} maps to more than one product group",
            )
        mapping[source] = canonical
    return mapping


def _resolve_product_group(
    *,
    explicit_group: object,
    population: object,
    mapping: Mapping[str, str],
) -> str:
    explicit = str(explicit_group or "").strip().casefold()
    if explicit in {"food", "beverage"}:
        return explicit

    source = str(population or "").strip().casefold()
    if source in {"food", "beverage"}:
        return source

    mapped = mapping.get(source)
    if mapped in {"food", "beverage"}:
        return mapped

    raise WorkerDataError(
        "ITEM_GROUP_MAPPING_MISSING",
        (
            "Food Cost item population/product-group is not mapped to the "
            f"canonical food/beverage grouping: {population!r}"
        ),
    )


def prepare_food_cost_run(
    conn: Connection,
    claim: Claim,
) -> PreparedFoodCostRun:
    with conn.transaction():
        context = conn.execute(
            """
            select
              rp.period_start,rp.period_end,
              btrim(o.currency_code) as currency_code
            from reporting_period rp
            join outlet o
              on o.organisation_id=rp.organisation_id
             and o.id=rp.outlet_id
            where rp.organisation_id=%s
              and rp.outlet_id=%s
              and rp.id=%s
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()

        if context is None:
            raise WorkerDataError(
                "REQUEST_CONTEXT_INVALID",
                "Food Cost request does not match an outlet/reporting period",
            )

        settings_snapshot, _ = _snapshot_controls(
            conn,
            outlet_id=claim.outlet_id,
            period_start=context["period_start"],
            period_end=context["period_end"],
        )
        settings_snapshot = {
            **settings_snapshot,
            "food_cost": {
                "inventory_evidence_status": "validated",
                "expected_usage_source": "T2_X_T4A",
            },
        }

        t2 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T2",
        )
        t3 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T3",
        )
        t4a = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T4A",
        )

        if t2 is None or t3 is None or t4a is None:
            raise WorkerDataError(
                "FOOD_COST_INPUTS_NOT_READY",
                "Food Cost calculation requires committed T2, T3 and T4A batches",
                retryable=True,
            )

        group_mapping = _food_cost_group_mapping(
            conn,
            profile_version_ids=(
                t2["profile_version_id"],
                t4a["profile_version_id"],
            ),
        )

        sales_rows = list(
            conn.execute(
                """
                select
                  f.id as fact_id,
                  f.item_id,
                  f.units_sold,
                  f.net_revenue,
                  f.product_group,
                  coalesce(f.population,i.population) as population,
                  i.canonical_item_key
                from item_sales_fact f
                join item i
                  on i.organisation_id=f.organisation_id
                 and i.outlet_id=f.outlet_id
                 and i.id=f.item_id
                where f.batch_id=%s
                order by i.canonical_item_key,f.id
                """,
                (t2["id"],),
            ).fetchall()
        )

        cost_rows = list(
            conn.execute(
                """
                select
                  f.id as fact_id,
                  f.item_id,
                  f.effective_from,
                  f.approved_cost_per_unit,
                  i.canonical_item_key
                from item_cost_snapshot f
                join item i
                  on i.organisation_id=f.organisation_id
                 and i.outlet_id=f.outlet_id
                 and i.id=f.item_id
                where f.batch_id=%s
                order by f.item_id,f.effective_from desc,f.id desc
                """,
                (t4a["id"],),
            ).fetchall()
        )
        cost_candidates: dict[UUID, list[Mapping[str, Any]]] = {}
        for row in cost_rows:
            cost_candidates.setdefault(row["item_id"], []).append(row)

        costs_by_item: dict[UUID, Mapping[str, Any]] = {}
        for item_id, candidates in cost_candidates.items():
            effective = [
                row
                for row in candidates
                if row["effective_from"] <= context["period_end"]
            ]
            costs_by_item[item_id] = effective[0] if effective else candidates[0]

        expected_items: list[ExpectedUsageItem] = []
        revenue_by_group: dict[str, Decimal] = {}
        revenue_refs_by_group: dict[str, list[str]] = {}

        for row in sales_rows:
            group = _resolve_product_group(
                explicit_group=row["product_group"],
                population=row["population"],
                mapping=group_mapping,
            )
            cost = costs_by_item.get(row["item_id"])
            cost_value = (
                cost["approved_cost_per_unit"]
                if cost is not None
                else None
            )
            if cost_value is not None and not isinstance(cost_value, Decimal):
                cost_value = Decimal(str(cost_value))

            cost_effective = (
                cost is None
                or cost["effective_from"] <= context["period_end"]
            )
            sales_ref = f"item_sales_fact:{row['fact_id']}"
            cost_refs = (
                (f"item_cost_snapshot:{cost['fact_id']}",)
                if cost is not None
                else ()
            )

            expected_items.append(
                ExpectedUsageItem(
                    item_key=str(row["canonical_item_key"]),
                    product_group=group,
                    units_sold=(
                        row["units_sold"]
                        if isinstance(row["units_sold"], Decimal)
                        else Decimal(str(row["units_sold"]))
                    ),
                    approved_cost_per_unit=cost_value,
                    cost_effective=cost_effective,
                    sales_refs=(sales_ref,),
                    cost_refs=cost_refs,
                )
            )

            revenue = (
                row["net_revenue"]
                if isinstance(row["net_revenue"], Decimal)
                else Decimal(str(row["net_revenue"]))
            )
            revenue_by_group[group] = (
                revenue_by_group.get(group, Decimal("0")) + revenue
            )
            revenue_refs_by_group.setdefault(group, []).append(sales_ref)

        stock_rows = list(
            conn.execute(
                """
                select
                  id as fact_id,
                  lower(btrim(product_group)) as product_group,
                  opening_inventory,purchases,closing_inventory,
                  source_budget_cost_pct
                from stock_fact
                where batch_id=%s
                order by lower(btrim(product_group)),coalesce(category,''),id
                """,
                (t3["id"],),
            ).fetchall()
        )
        if not stock_rows:
            raise WorkerDataError(
                "STOCK_FACTS_EMPTY",
                "Committed T3 batch has no canonical stock facts",
            )

        stock_groups: dict[str, dict[str, Any]] = {}
        for row in stock_rows:
            group = str(row["product_group"]).casefold()
            if group not in {"food", "beverage"}:
                raise WorkerDataError(
                    "UNSUPPORTED_PRODUCT_GROUP",
                    f"Food Cost supports canonical food/beverage groups, got {group!r}",
                )

            bucket = stock_groups.setdefault(
                group,
                {
                    "opening": Decimal("0"),
                    "purchases": Decimal("0"),
                    "closing": Decimal("0"),
                    "pcts": set(),
                    "refs": [],
                },
            )
            bucket["opening"] += Decimal(str(row["opening_inventory"]))
            bucket["purchases"] += Decimal(str(row["purchases"]))
            bucket["closing"] += Decimal(str(row["closing_inventory"]))
            if row["source_budget_cost_pct"] is not None:
                bucket["pcts"].add(Decimal(str(row["source_budget_cost_pct"])))
            bucket["refs"].append(f"stock_fact:{row['fact_id']}")

        groups: list[FoodCostGroupSource] = []
        for group in sorted(stock_groups):
            bucket = stock_groups[group]
            pcts = bucket["pcts"]
            if len(pcts) > 1:
                raise WorkerDataError(
                    "FOOD_COST_BENCHMARK_AMBIGUOUS",
                    f"More than one benchmark cost percent is present for {group}",
                )
            pct = next(iter(pcts)) if pcts else None
            stock_refs = tuple(sorted(set(bucket["refs"])))
            revenue_refs = tuple(
                sorted(set(revenue_refs_by_group.get(group, [])))
            )
            groups.append(
                FoodCostGroupSource(
                    product_group=group,
                    opening_inventory=bucket["opening"],
                    purchases=bucket["purchases"],
                    closing_inventory=bucket["closing"],
                    product_revenue=revenue_by_group.get(group),
                    comparator_cost_pct=pct,
                    stock_refs=stock_refs,
                    revenue_refs=revenue_refs,
                    comparator_refs=stock_refs if pct is not None else (),
                )
            )

        previous = conn.execute(
            """
            select id
            from calc_run
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and engine_version=%s
              and status='completed'
            order by completed_at desc,id desc
            limit 1
            """,
            (
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                FC_ENGINE_VERSION,
            ),
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
            values (%s,%s,%s,%s,%s,%s,%s,null,'queued',%s,%s)
            """,
            (
                run_id,
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                claim.request_id,
                FC_ENGINE_VERSION,
                Jsonb(_json_safe(settings_snapshot)),
                supersedes_id,
                claim.attempt_no,
            ),
        )

        for batch, role in (
            (t2, "item_sales"),
            (t3, "stock"),
            (t4a, "item_cost"),
        ):
            conn.execute(
                """
                insert into calc_run_input(
                  organisation_id,outlet_id,run_id,batch_id,
                  profile_version_id,input_role,scenario,canonical_commit_hash
                )
                values (%s,%s,%s,%s,%s,%s,'actual'::scenario_code,%s)
                """,
                (
                    claim.organisation_id,
                    claim.outlet_id,
                    run_id,
                    batch["id"],
                    batch["profile_version_id"],
                    role,
                    batch["canonical_commit_hash"],
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

    return PreparedFoodCostRun(
        run_id=run_id,
        claim=claim,
        currency=context["currency_code"],
        item_sales_batch_id=t2["id"],
        stock_batch_id=t3["id"],
        item_cost_batch_id=t4a["id"],
        expected_usage_items=tuple(expected_items),
        groups=tuple(groups),
        settings_snapshot=settings_snapshot,
    )


def calculate_food_cost_bundle(
    prepared: PreparedFoodCostRun,
) -> CalculationBundle:
    persisted: list[PersistedResult] = []
    dependencies: list[tuple[UUID, UUID, str]] = []

    materiality_group = prepared.settings_snapshot.get("materiality", {})
    general_materiality = (
        materiality_group.get("general")
        if isinstance(materiality_group, Mapping)
        else None
    )
    materiality = materiality_snapshot_from_mapping(
        general_materiality if isinstance(general_materiality, Mapping) else None
    )
    food_settings = prepared.settings_snapshot.get("food_cost", {})
    inventory_status = (
        str(food_settings.get("inventory_evidence_status", "validated"))
        if isinstance(food_settings, Mapping)
        else "validated"
    )

    for group in prepared.groups:
        expected = calculate_expected_usage(
            prepared.expected_usage_items,
            product_group=group.product_group,
            currency=prepared.currency,
        )
        bridge = calculate_food_cost_bridge(
            FoodCostBridgeInput(
                product_group=group.product_group,
                opening_inventory=group.opening_inventory,
                purchases=group.purchases,
                closing_inventory=group.closing_inventory,
                product_revenue=group.product_revenue,
                comparator_cost_pct=group.comparator_cost_pct,
                currency=prepared.currency,
                stock_refs=group.stock_refs,
                revenue_refs=group.revenue_refs,
                comparator_refs=group.comparator_refs,
            ),
            expected_usage=expected,
        )
        by_calc = {result.calc_id: result for result in bridge}
        supported_total = calculate_supported_driver_total(
            (),
            product_group=group.product_group,
            currency=prepared.currency,
        )
        residual = calculate_residual(
            by_calc["FC.ACTUAL_VS_EXPECTED"],
            supported_total,
            currency=prepared.currency,
        )
        decision = calculate_decision_path(
            bridge,
            inventory_evidence_status=inventory_status,
            materiality_snapshot=materiality,
            residual=residual,
        )

        engine_results = (*bridge, supported_total, residual, decision)
        records = {
            result.calc_id: _record_food_cost_engine(result)
            for result in engine_results
        }
        persisted.extend(records.values())

        def edge(parent: str, child: str, role: str) -> None:
            dependencies.append(
                (records[parent].id, records[child].id, role)
            )

        edge(
            "FC.ACTUAL_COST_PCT",
            "FC.ACTUAL_CONSUMPTION",
            "numerator",
        )
        edge(
            "FC.BUDGET_GAP",
            "FC.ACTUAL_CONSUMPTION",
            "actual_consumption",
        )
        edge(
            "FC.BUDGET_GAP",
            "FC.BUDGET_BENCHMARK",
            "budget_benchmark",
        )
        edge(
            "FC.EXPECTED_COST_PCT",
            "FC.EXPECTED_USAGE",
            "numerator",
        )
        edge(
            "FC.MENU_MIX_EFFECT",
            "FC.EXPECTED_USAGE",
            "expected_usage",
        )
        edge(
            "FC.MENU_MIX_EFFECT",
            "FC.BUDGET_BENCHMARK",
            "budget_benchmark",
        )
        edge(
            "FC.ACTUAL_VS_EXPECTED",
            "FC.ACTUAL_CONSUMPTION",
            "actual_consumption",
        )
        edge(
            "FC.ACTUAL_VS_EXPECTED",
            "FC.EXPECTED_USAGE",
            "expected_usage",
        )
        edge(
            "FC.RESIDUAL",
            "FC.ACTUAL_VS_EXPECTED",
            "actual_vs_expected",
        )
        edge(
            "FC.RESIDUAL",
            "FC.SUPPORTED_DRIVER_TOTAL",
            "supported_driver_total",
        )
        edge(
            "FC.DECISION_PATH",
            "FC.ACTUAL_VS_EXPECTED",
            "operating_signal",
        )
        edge(
            "FC.DECISION_PATH",
            "FC.RESIDUAL",
            "residual_signal",
        )
        edge(
            "FC.DECISION_PATH",
            "FC.MENU_MIX_EFFECT",
            "menu_economics_context",
        )

    return CalculationBundle(
        results=tuple(persisted),
        dependencies=tuple(dependencies),
        result_hash=canonical_result_hash(persisted),
    )


def _record_revenue_engine(
    result: CalcResult,
    *,
    grain_key: Mapping[str, Any],
    category: str,
) -> PersistedResult:
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


def prepare_revenue_run(
    conn: Connection,
    claim: Claim,
) -> PreparedRevenueRun:
    with conn.transaction():
        context = conn.execute(
            """
            select
              rp.period_start,rp.period_end,
              btrim(o.currency_code) as currency_code
            from reporting_period rp
            join outlet o
              on o.organisation_id=rp.organisation_id
             and o.id=rp.outlet_id
            where rp.organisation_id=%s
              and rp.outlet_id=%s
              and rp.id=%s
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()
        if context is None:
            raise WorkerDataError(
                "REQUEST_CONTEXT_INVALID",
                "Revenue request does not match an outlet/reporting period",
            )

        readiness = conn.execute(
            """
            select status,details_json
            from data_readiness
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and capability_code='revenue_inputs'
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()
        if readiness is None or readiness["status"] != "ready":
            raise WorkerDataError(
                "REVENUE_INPUTS_NOT_READY",
                "Revenue calculation requires reconciled T1B, T7 and T1 inputs",
                retryable=True,
            )

        settings_snapshot, _ = _snapshot_controls(
            conn,
            outlet_id=claim.outlet_id,
            period_start=context["period_start"],
            period_end=context["period_end"],
        )
        settings_snapshot = {
            **settings_snapshot,
            "revenue": {
                "readiness": _json_safe(readiness["details_json"] or {}),
                "activity_unit_rollup": "never_mix_incompatible_unit_types",
                "avg_spend_source": "DERIVED_REVENUE_DIV_ACTIVITY_UNITS",
                "contribution_scope": "outlet_accounting_actual",
            },
        }

        t1b = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T1B",
        )
        t7 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T7",
        )
        t1 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T1",
        )
        if t1b is None or t7 is None or t1 is None:
            raise WorkerDataError(
                "REVENUE_INPUTS_NOT_READY",
                "Revenue calculation requires committed T1B, T7 and T1 batches",
                retryable=True,
            )

        rows = list(
            conn.execute(
                """
                select
                  id as fact_id,business_view_type,business_view_key,
                  activity_unit_type,activity_units,revenue,
                  comparator_activity_units,comparator_revenue
                from revenue_activity_fact
                where batch_id=%s
                order by business_view_type,lower(btrim(business_view_key)),id
                """,
                (t1b["id"],),
            ).fetchall()
        )
        if not rows:
            raise WorkerDataError(
                "REVENUE_ACTIVITY_FACTS_EMPTY",
                "Committed T1B batch has no canonical Revenue facts",
            )

        grains = tuple(
            RevenueGrainSource(
                business_view_type=str(row["business_view_type"]),
                business_view_key=str(row["business_view_key"]),
                activity_unit_type=str(row["activity_unit_type"]),
                actual_units=Decimal(str(row["activity_units"])),
                actual_revenue=Decimal(str(row["revenue"])),
                comparator_units=(
                    Decimal(str(row["comparator_activity_units"]))
                    if row["comparator_activity_units"] is not None
                    else None
                ),
                comparator_revenue=(
                    Decimal(str(row["comparator_revenue"]))
                    if row["comparator_revenue"] is not None
                    else None
                ),
                refs=(f"revenue_activity_fact:{row['fact_id']}",),
            )
            for row in rows
        )

        financial_values, financial_refs = aggregate_financial_facts(
            _load_fact_rows(conn, t1["id"])
        )
        if not financial_values:
            raise WorkerDataError(
                "ACTUAL_FACTS_EMPTY",
                "Committed T1 batch has no canonical financial facts",
            )

        channel_rows = list(
            conn.execute(
                """
                select id as fact_id,direct_channel_cost
                from channel_source_fact
                where batch_id=%s
                order by source_channel,id
                """,
                (t7["id"],),
            ).fetchall()
        )
        if not channel_rows:
            raise WorkerDataError(
                "CHANNEL_SOURCE_FACTS_EMPTY",
                "Committed T7 batch has no canonical source/channel facts",
            )

        t7_channel_cost = sum(
            (
                Decimal(str(row["direct_channel_cost"]))
                for row in channel_rows
                if row["direct_channel_cost"] is not None
            ),
            Decimal("0"),
        )
        accounting_channel_cost = financial_values.get("CHANNEL_COST")
        t7_channel_ties = (
            accounting_channel_cost is not None
            and t7_channel_cost == accounting_channel_cost
        )
        settings_snapshot["revenue"]["t7_channel_cost_ties_to_pnl"] = (
            t7_channel_ties
        )

        required_codes = (
            "NET_SALES",
            "CHANNEL_COST",
            "PRODUCT_COST",
            "DIRECT_LABOUR",
            "OTHER_DIRECT_OPERATING",
        )
        contribution_refs = tuple(
            ref
            for code in required_codes
            for ref in financial_refs.get(code, ())
        )
        if t7_channel_ties:
            contribution_refs = tuple(
                dict.fromkeys(
                    contribution_refs
                    + tuple(
                        f"channel_source_fact:{row['fact_id']}"
                        for row in channel_rows
                    )
                )
            )

        previous = conn.execute(
            """
            select id
            from calc_run
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and engine_version=%s
              and status='completed'
            order by completed_at desc,id desc
            limit 1
            """,
            (
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                REVENUE_ENGINE_VERSION,
            ),
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
            values (%s,%s,%s,%s,%s,%s,%s,null,'queued',%s,%s)
            """,
            (
                run_id,
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                claim.request_id,
                REVENUE_ENGINE_VERSION,
                Jsonb(_json_safe(settings_snapshot)),
                supersedes_id,
                claim.attempt_no,
            ),
        )

        for batch, role in (
            (t1b, "revenue_activity"),
            (t7, "channel_source"),
            (t1, "financial_actual"),
        ):
            conn.execute(
                """
                insert into calc_run_input(
                  organisation_id,outlet_id,run_id,batch_id,
                  profile_version_id,input_role,scenario,canonical_commit_hash
                )
                values (%s,%s,%s,%s,%s,%s,'actual'::scenario_code,%s)
                """,
                (
                    claim.organisation_id,
                    claim.outlet_id,
                    run_id,
                    batch["id"],
                    batch["profile_version_id"],
                    role,
                    batch["canonical_commit_hash"],
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

    return PreparedRevenueRun(
        run_id=run_id,
        claim=claim,
        currency=context["currency_code"],
        revenue_activity_batch_id=t1b["id"],
        channel_source_batch_id=t7["id"],
        financial_actual_batch_id=t1["id"],
        grains=grains,
        financial_values=financial_values,
        contribution_refs=contribution_refs,
        settings_snapshot=settings_snapshot,
    )


def calculate_revenue_bundle(
    prepared: PreparedRevenueRun,
) -> CalculationBundle:
    persisted: list[PersistedResult] = []
    dependencies: list[tuple[UUID, UUID, str]] = []

    for grain in prepared.grains:
        engine_key = (
            f"{grain.business_view_type}:"
            f"{grain.business_view_key.strip().casefold()}"
        )
        engine = calculate_revenue_variance(
            RevenueVarianceInput(
                grain_key=engine_key,
                activity_unit_type=grain.activity_unit_type,
                actual_units=grain.actual_units,
                actual_revenue=grain.actual_revenue,
                comparator_units=grain.comparator_units,
                comparator_revenue=grain.comparator_revenue,
                currency=prepared.currency,
                actual_refs=grain.refs,
                comparator_refs=grain.refs,
            )
        )
        records = {
            result.calc_id: _record_revenue_engine(
                result,
                grain_key={
                    "business_view_type": grain.business_view_type,
                    "business_view_key": grain.business_view_key,
                    "activity_unit_type": grain.activity_unit_type,
                },
                category="revenue",
            )
            for result in engine
        }
        persisted.extend(records.values())

        dependencies.extend(
            (
                (
                    records["RV.AVG_SPEND"].id,
                    records["RV.ACTIVITY_UNITS"].id,
                    "denominator",
                ),
                (
                    records["RV.AVG_SPEND"].id,
                    records["RV.REVENUE"].id,
                    "numerator",
                ),
                (
                    records["RV.TOTAL_VARIANCE"].id,
                    records["RV.VOLUME_EFFECT"].id,
                    "control_component",
                ),
                (
                    records["RV.TOTAL_VARIANCE"].id,
                    records["RV.SPEND_EFFECT"].id,
                    "control_component",
                ),
            )
        )

    # T1B contains mixed activity-unit types in the Amberside fixture
    # (covers/orders/guests). Never sum them into a fabricated outlet unit.
    contribution_engine = calculate_contribution(
        ContributionInput(
            grain_key="outlet",
            net_sales=prepared.financial_values.get("NET_SALES"),
            direct_channel_cost=prepared.financial_values.get("CHANNEL_COST"),
            product_cost=prepared.financial_values.get("PRODUCT_COST"),
            direct_labour=prepared.financial_values.get("DIRECT_LABOUR"),
            other_direct_operating_cost=prepared.financial_values.get(
                "OTHER_DIRECT_OPERATING"
            ),
            activity_units=None,
            currency=prepared.currency,
            input_refs=prepared.contribution_refs,
        )
    )
    contribution_records = {
        result.calc_id: _record_revenue_engine(
            result,
            grain_key={"scope": "outlet"},
            category="contribution",
        )
        for result in contribution_engine
    }
    persisted.extend(contribution_records.values())

    dependencies.extend(
        (
            (
                contribution_records["CT.CONTRIBUTION_PER_ACTIVITY_UNIT"].id,
                contribution_records["CT.CONTRIBUTION"].id,
                "contribution_numerator",
            ),
            (
                contribution_records["CT.CONTRIBUTION_MARGIN_PCT"].id,
                contribution_records["CT.CONTRIBUTION"].id,
                "contribution_numerator",
            ),
        )
    )

    return CalculationBundle(
        results=tuple(persisted),
        dependencies=tuple(dependencies),
        result_hash=canonical_result_hash(persisted),
    )


def _record_labour_other_engine(
    result: CalcResult,
    *,
    grain_key: Mapping[str, Any],
    category: str,
) -> PersistedResult:
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


def prepare_labour_other_run(
    conn: Connection,
    claim: Claim,
) -> PreparedLabourOtherRun:
    with conn.transaction():
        context = conn.execute(
            """
            select
              rp.period_start,rp.period_end,
              btrim(o.currency_code) as currency_code
            from reporting_period rp
            join outlet o
              on o.organisation_id=rp.organisation_id
             and o.id=rp.outlet_id
            where rp.organisation_id=%s
              and rp.outlet_id=%s
              and rp.id=%s
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()
        if context is None:
            raise WorkerDataError(
                "REQUEST_CONTEXT_INVALID",
                "Labour/Other Cost request does not match an outlet/reporting period",
            )

        readiness = conn.execute(
            """
            select status,details_json
            from data_readiness
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and capability_code='labour_inputs'
            """,
            (claim.organisation_id, claim.outlet_id, claim.period_id),
        ).fetchone()
        if readiness is None or readiness["status"] != "ready":
            raise WorkerDataError(
                "LABOUR_INPUTS_NOT_READY",
                "Labour/Other Cost calculation requires reconciled T5/T1 inputs",
                retryable=True,
            )

        settings_snapshot, configured_comparator = _snapshot_controls(
            conn,
            outlet_id=claim.outlet_id,
            period_start=context["period_start"],
            period_end=context["period_end"],
        )

        t5 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T5",
        )
        t1 = _load_batch(
            conn,
            organisation_id=claim.organisation_id,
            outlet_id=claim.outlet_id,
            period_id=claim.period_id,
            scenario="actual",
            template_code="T1",
        )
        if t5 is None or t1 is None:
            raise WorkerDataError(
                "LABOUR_INPUTS_NOT_READY",
                "Labour/Other Cost calculation requires committed T5 and T1 batches",
                retryable=True,
            )

        labour_rows = list(
            conn.execute(
                """
                select
                  id as fact_id,role_group,
                  actual_hours,comparator_hours,
                  actual_cost,comparator_cost,
                  scheduled_hours,overtime_hours,
                  activity_units,activity_basis,
                  comparator_scenario::text
                from labour_fact
                where batch_id=%s
                order by lower(btrim(role_group)),id
                """,
                (t5["id"],),
            ).fetchall()
        )
        if not labour_rows:
            raise WorkerDataError(
                "LABOUR_FACTS_EMPTY",
                "Committed T5 batch has no canonical Labour facts",
            )

        comparator_scenarios = {
            str(row["comparator_scenario"])
            for row in labour_rows
            if row["comparator_scenario"] is not None
        }
        if len(comparator_scenarios) > 1:
            raise WorkerDataError(
                "LABOUR_COMPARATOR_AMBIGUOUS",
                "Committed T5 facts contain more than one comparator scenario",
            )

        t5_comparator = (
            next(iter(comparator_scenarios))
            if comparator_scenarios
            else None
        )
        if (
            t5_comparator is not None
            and configured_comparator is not None
            and t5_comparator != configured_comparator
        ):
            raise WorkerDataError(
                "LABOUR_COMPARATOR_MISMATCH",
                "T5 comparator scenario does not match the configured primary comparator",
            )
        comparator_scenario = t5_comparator or configured_comparator

        has_t5_comparator = any(
            row["comparator_hours"] is not None
            or row["comparator_cost"] is not None
            for row in labour_rows
        )
        if has_t5_comparator and comparator_scenario is None:
            raise WorkerDataError(
                "LABOUR_COMPARATOR_SCENARIO_MISSING",
                "T5 comparator hours/cost require an explicit comparator scenario",
            )

        t6 = None
        if comparator_scenario is not None:
            t6 = _load_batch(
                conn,
                organisation_id=claim.organisation_id,
                outlet_id=claim.outlet_id,
                period_id=claim.period_id,
                scenario=comparator_scenario,
                template_code="T6",
            )
            if has_t5_comparator and t6 is None:
                raise WorkerDataError(
                    "LABOUR_COMPARATOR_BATCH_NOT_COMMITTED",
                    "T5 comparator Labour evidence requires the matching committed T6 batch",
                    retryable=True,
                )

        actual_values, actual_refs = aggregate_financial_facts(
            _load_fact_rows(conn, t1["id"])
        )
        if not actual_values:
            raise WorkerDataError(
                "ACTUAL_FACTS_EMPTY",
                "Committed T1 batch has no canonical financial facts",
            )

        comparator_values = None
        comparator_refs = None
        if t6 is not None:
            comparator_values, comparator_refs = aggregate_financial_facts(
                _load_fact_rows(conn, t6["id"])
            )
            if not comparator_values:
                raise WorkerDataError(
                    "COMPARATOR_FACTS_EMPTY",
                    "Committed T6 batch has no canonical financial facts",
                )

        labour_grains = tuple(
            LabourGrainSource(
                role_group=str(row["role_group"]),
                actual_hours=Decimal(str(row["actual_hours"])),
                comparator_hours=(
                    Decimal(str(row["comparator_hours"]))
                    if row["comparator_hours"] is not None
                    else None
                ),
                actual_cost=Decimal(str(row["actual_cost"])),
                comparator_cost=(
                    Decimal(str(row["comparator_cost"]))
                    if row["comparator_cost"] is not None
                    else None
                ),
                scheduled_hours=(
                    Decimal(str(row["scheduled_hours"]))
                    if row["scheduled_hours"] is not None
                    else None
                ),
                overtime_hours=(
                    Decimal(str(row["overtime_hours"]))
                    if row["overtime_hours"] is not None
                    else None
                ),
                activity_units=(
                    Decimal(str(row["activity_units"]))
                    if row["activity_units"] is not None
                    else None
                ),
                activity_basis=(
                    str(row["activity_basis"])
                    if row["activity_basis"] is not None
                    else None
                ),
                refs=(f"labour_fact:{row['fact_id']}",),
            )
            for row in labour_rows
        )

        readiness_details = _json_safe(readiness["details_json"] or {})
        if (
            has_t5_comparator
            and isinstance(readiness_details, Mapping)
            and readiness_details.get("comparator_pnl_tie") is not True
        ):
            raise WorkerDataError(
                "LABOUR_COMPARATOR_NOT_RECONCILED",
                "T5 comparator Labour cost is not reconciled to T6 Direct Labour",
                retryable=True,
            )

        settings_snapshot = {
            **settings_snapshot,
            "labour_other": {
                "readiness": readiness_details,
                "activity_unit_rollup": "PROHIBITED_ACROSS_ROLE_GROUPS",
                "staffing_diagnosis_from_labour_pct": "PROHIBITED",
                "overtime_rate_evidence": "EXPLICIT_ONLY",
                "other_cost_quantity_rate_evidence": "EXPLICIT_ONLY",
                "other_cost_accounting_grains": [
                    "OTHER_DIRECT_OPERATING",
                    "SHARED_RESTAURANT_COST",
                    "OWNER_STRUCTURAL_COST",
                ],
            },
        }

        previous = conn.execute(
            """
            select id
            from calc_run
            where organisation_id=%s
              and outlet_id=%s
              and period_id=%s
              and engine_version=%s
              and status='completed'
            order by completed_at desc,id desc
            limit 1
            """,
            (
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                LABOUR_OTHER_ENGINE_VERSION,
            ),
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
                LABOUR_OTHER_ENGINE_VERSION,
                Jsonb(_json_safe(settings_snapshot)),
                comparator_scenario,
                supersedes_id,
                claim.attempt_no,
            ),
        )

        for batch, role, scenario in (
            (t5, "labour_detail", "actual"),
            (t1, "labour_financial_actual", "actual"),
        ):
            conn.execute(
                """
                insert into calc_run_input(
                  organisation_id,outlet_id,run_id,batch_id,
                  profile_version_id,input_role,scenario,canonical_commit_hash
                )
                values (%s,%s,%s,%s,%s,%s,%s::scenario_code,%s)
                """,
                (
                    claim.organisation_id,
                    claim.outlet_id,
                    run_id,
                    batch["id"],
                    batch["profile_version_id"],
                    role,
                    scenario,
                    batch["canonical_commit_hash"],
                ),
            )

        if t6 is not None:
            conn.execute(
                """
                insert into calc_run_input(
                  organisation_id,outlet_id,run_id,batch_id,
                  profile_version_id,input_role,scenario,canonical_commit_hash
                )
                values (%s,%s,%s,%s,%s,'labour_financial_comparator',
                        %s::scenario_code,%s)
                """,
                (
                    claim.organisation_id,
                    claim.outlet_id,
                    run_id,
                    t6["id"],
                    t6["profile_version_id"],
                    comparator_scenario,
                    t6["canonical_commit_hash"],
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

    return PreparedLabourOtherRun(
        run_id=run_id,
        claim=claim,
        currency=context["currency_code"],
        labour_batch_id=t5["id"],
        financial_actual_batch_id=t1["id"],
        financial_comparator_batch_id=t6["id"] if t6 is not None else None,
        comparator_scenario=comparator_scenario,
        labour_grains=labour_grains,
        actual_values=actual_values,
        actual_refs=actual_refs,
        comparator_values=comparator_values,
        comparator_refs=comparator_refs,
        settings_snapshot=settings_snapshot,
    )


def calculate_labour_other_bundle(
    prepared: PreparedLabourOtherRun,
) -> CalculationBundle:
    persisted: list[PersistedResult] = []
    dependencies: list[tuple[UUID, UUID, str]] = []

    for grain in prepared.labour_grains:
        engine = calculate_labour(
            LabourInput(
                grain_key=grain.role_group,
                actual_hours=grain.actual_hours,
                comparator_hours=grain.comparator_hours,
                actual_cost=grain.actual_cost,
                comparator_cost=grain.comparator_cost,
                currency=prepared.currency,
                activity_units=grain.activity_units,
                activity_basis=grain.activity_basis,
                overtime_hours=grain.overtime_hours,
                scheduled_hours=grain.scheduled_hours,
                overtime_actual_rate=None,
                overtime_comparator_rate=None,
                input_refs=grain.refs,
            )
        )
        records = {
            result.calc_id: _record_labour_other_engine(
                result,
                grain_key={
                    "role_group": grain.role_group,
                    "activity_basis": grain.activity_basis,
                },
                category="labour",
            )
            for result in engine
        }
        persisted.extend(records.values())

        dependencies.extend(
            (
                (
                    records["LB.TOTAL_VARIANCE"].id,
                    records["LB.HOURS_EFFECT_RAW"].id,
                    "control_component",
                ),
                (
                    records["LB.TOTAL_VARIANCE"].id,
                    records["LB.RATE_EFFECT_RAW"].id,
                    "control_component",
                ),
                (
                    records["LB.OVERTIME_RATE_EFFECT"].id,
                    records["LB.OVERTIME_HOURS"].id,
                    "overtime_hours",
                ),
            )
        )

    other_cost_codes = (
        "OTHER_DIRECT_OPERATING",
        "SHARED_RESTAURANT_COST",
        "OWNER_STRUCTURAL_COST",
    )
    for line_code in other_cost_codes:
        actual_cost = prepared.actual_values.get(line_code)
        comparator_cost = (
            prepared.comparator_values.get(line_code)
            if prepared.comparator_values is not None
            else None
        )
        refs = tuple(
            dict.fromkeys(
                prepared.actual_refs.get(line_code, ())
                + (
                    prepared.comparator_refs.get(line_code, ())
                    if prepared.comparator_refs is not None
                    else ()
                )
            )
        )
        engine = calculate_other_cost(
            OtherCostInput(
                grain_key=line_code,
                actual_cost=actual_cost,
                comparator_cost=comparator_cost,
                currency=prepared.currency,
                input_refs=refs,
            )
        )
        records = {
            result.calc_id: _record_labour_other_engine(
                result,
                grain_key={
                    "ladder_code": line_code,
                    "actual_scenario": "actual",
                    "comparator_scenario": prepared.comparator_scenario,
                },
                category="other_cost",
            )
            for result in engine
        }
        persisted.extend(records.values())
        dependencies.extend(
            (
                (
                    records["OC.TOTAL_VARIANCE"].id,
                    records["OC.QUANTITY_EFFECT"].id,
                    "optional_decomposition_component",
                ),
                (
                    records["OC.TOTAL_VARIANCE"].id,
                    records["OC.RATE_EFFECT"].id,
                    "optional_decomposition_component",
                ),
            )
        )

    return CalculationBundle(
        results=tuple(persisted),
        dependencies=tuple(dependencies),
        result_hash=canonical_result_hash(persisted),
    )


def _source_template_code(conn: Connection, claim: Claim) -> str:
    row = conn.execute(
        """
        select template_code
        from import_batch
        where id=%s
          and organisation_id=%s
          and outlet_id=%s
          and period_id=%s
        """,
        (
            claim.source_batch_id,
            claim.organisation_id,
            claim.outlet_id,
            claim.period_id,
        ),
    ).fetchone()
    if row is None:
        raise WorkerDataError(
            "REQUEST_SOURCE_BATCH_INVALID",
            "Calculation request source batch is outside the request context",
        )
    return str(row["template_code"]).upper()


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
    template_code: str,
) -> Mapping[str, Any] | None:
    """Load one committed canonical batch for an exact template/scenario.

    Template is mandatory: once Food Cost actual-source templates exist, a
    scenario-only lookup can select T2/T3/T4A as the P&L actual by recency.
    """
    return conn.execute(
        """
        select
          b.id,b.profile_version_id,b.scenario::text,b.canonical_commit_hash,
          b.committed_at,b.template_code
        from import_batch b
        where b.organisation_id=%s
          and b.outlet_id=%s
          and b.period_id=%s
          and b.scenario=%s::scenario_code
          and b.template_code=%s
          and b.status='committed'
          and b.canonical_commit_hash is not null
        order by b.committed_at desc,b.id desc
        limit 1
        """,
        (organisation_id, outlet_id, period_id, scenario, template_code),
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
            template_code="T1",
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
                template_code="T6",
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
              and engine_version=%s
              and status='completed'
            order by completed_at desc,id desc
            limit 1
            """,
            (
                claim.organisation_id,
                claim.outlet_id,
                claim.period_id,
                PL_ENGINE_VERSION,
            ),
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
    prepared: PreparedRun | PreparedFoodCostRun | PreparedRevenueRun | PreparedLabourOtherRun,
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

    prepared: PreparedRun | PreparedFoodCostRun | PreparedRevenueRun | PreparedLabourOtherRun | None = None
    try:
        source_template = _source_template_code(conn, claim)
        if (
            source_template in {"T2", "T3", "T4A"}
            or claim.reason.startswith("food_cost")
        ):
            prepared = prepare_food_cost_run(conn, claim)
            bundle = calculate_food_cost_bundle(prepared)
            engine_version = FC_ENGINE_VERSION
        elif (
            source_template in {"T1B", "T7"}
            or claim.reason.startswith("revenue")
        ):
            prepared = prepare_revenue_run(conn, claim)
            bundle = calculate_revenue_bundle(prepared)
            engine_version = REVENUE_ENGINE_VERSION
        elif (
            source_template == "T5"
            or claim.reason.startswith("labour")
        ):
            prepared = prepare_labour_other_run(conn, claim)
            bundle = calculate_labour_other_bundle(prepared)
            engine_version = LABOUR_OTHER_ENGINE_VERSION
        else:
            prepared = prepare_run(conn, claim)
            bundle = calculate_pl_bundle(prepared)
            engine_version = PL_ENGINE_VERSION

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
        engine_version=engine_version,
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
    parser = argparse.ArgumentParser(description="Restaurant calculation worker")
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
