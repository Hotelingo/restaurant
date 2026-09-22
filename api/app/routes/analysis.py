from __future__ import annotations

from collections import defaultdict
from decimal import Decimal
from typing import Any
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query

from ..analysis_schemas import (
    CalcInputTrace,
    CalcResultRead,
    CalcResultsResponse,
    CalcRunSummary,
    FoodCostAnalysisResponse,
    FoodCostGroupRead,
    FoodCostReadinessRead,
    PLAnalysisResponse,
    PLLineRead,
    PeriodSummary,
    ReconciliationLineRead,
    ReconciliationResponse,
)
from ..auth import AuthenticatedUser, get_current_user
from ..db import user_transaction

router = APIRouter(tags=["analysis"])


def _decimal_text(value: Decimal | None) -> str | None:
    return format(value, "f") if value is not None else None


def _result_from_row(row: dict[str, Any]) -> CalcResultRead:
    return CalcResultRead(
        id=row["id"],
        calc_id=row["calc_id"],
        grain_type=row["grain_type"],
        grain_key=row["grain_key"],
        value_numeric=_decimal_text(row["value_numeric"]),
        value_text=row["value_text"],
        unit=row["unit"],
        currency_code=(
            row["currency_code"].strip() if row["currency_code"] is not None else None
        ),
        calculation_status=row["calculation_status"],
        evidence_status=row["evidence_status"],
        explanation_code=row["explanation_code"],
        result_metadata=row["result_metadata"] or {},
        input_refs=list(row["input_refs"] or []),
        raw_delta=_decimal_text(row["raw_delta"]),
        profit_effect=_decimal_text(row["profit_effect"]),
    )


async def _load_run_inputs(conn, run_id: UUID) -> list[CalcInputTrace]:
    result = await conn.execute(
        """
        select
          i.input_role,
          b.template_code,
          i.scenario::text,
          i.batch_id,
          i.profile_version_id,
          i.canonical_commit_hash,
          b.source_file_id,
          sf.original_filename,
          sf.sha256 as source_sha256
        from calc_run_input i
        join import_batch b
          on b.organisation_id=i.organisation_id
         and b.outlet_id=i.outlet_id
         and b.id=i.batch_id
        join source_file sf
          on sf.organisation_id=b.organisation_id
         and sf.outlet_id=b.outlet_id
         and sf.id=b.source_file_id
        where i.run_id=%s
        order by
          case i.input_role when 'actual' then 0 when 'comparator' then 1 else 2 end,
          i.created_at,
          i.id
        """,
        (run_id,),
    )
    return [
        CalcInputTrace(
            **{
                **row,
                "source_sha256": row["source_sha256"],
            }
        )
        for row in await result.fetchall()
    ]


async def _load_run_summary(conn, run_id: UUID) -> CalcRunSummary | None:
    result = await conn.execute(
        """
        select
          id,outlet_id,period_id,engine_version,status,
          comparator_scenario::text,result_hash,
          started_at,completed_at,settings_snapshot
        from calc_run
        where id=%s
          and has_org_access(organisation_id)
          and has_outlet_access(organisation_id,outlet_id)
        """,
        (run_id,),
    )
    row = await result.fetchone()
    if row is None:
        return None
    return CalcRunSummary(
        **row,
        inputs=await _load_run_inputs(conn, run_id),
    )


async def _load_results(
    conn,
    run_id: UUID,
    *,
    module: str | None = None,
    calc_id: str | None = None,
    grain_type: str | None = None,
) -> list[CalcResultRead]:
    clauses = ["run_id=%s"]
    params: list[Any] = [run_id]

    if module:
        clauses.append("calc_id like (%s || '.%')")
        params.append(module)
    if calc_id:
        clauses.append("calc_id=%s")
        params.append(calc_id)
    if grain_type:
        clauses.append("grain_type=%s")
        params.append(grain_type)

    result = await conn.execute(
        f"""
        select
          id,calc_id,grain_type,grain_key,
          value_numeric,value_text,unit,currency_code,
          calculation_status,evidence_status,explanation_code,
          result_metadata,input_refs,raw_delta,profit_effect
        from calc_result
        where {" and ".join(clauses)}
        order by calc_id,grain_key::text,id
        """,
        params,
    )
    return [_result_from_row(row) for row in await result.fetchall()]


async def _latest_completed_pl_run(
    conn,
    *,
    outlet_id: UUID,
    period_id: UUID | None,
) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          r.id as run_id,
          r.outlet_id,
          r.period_id,
          r.engine_version,
          r.status,
          r.comparator_scenario::text,
          r.result_hash,
          r.started_at,
          r.completed_at,
          r.settings_snapshot,
          o.name as outlet_name,
          btrim(o.currency_code) as currency_code,
          rp.label as period_label,
          rp.period_start,
          rp.period_end
        from calc_run r
        join outlet o
          on o.organisation_id=r.organisation_id
         and o.id=r.outlet_id
        join reporting_period rp
          on rp.organisation_id=r.organisation_id
         and rp.outlet_id=r.outlet_id
         and rp.id=r.period_id
        where r.outlet_id=%s
          and r.status='completed'
          and r.engine_version like 'pl-%'
          and has_org_access(r.organisation_id)
          and has_outlet_access(r.organisation_id,r.outlet_id)
          and (%s::uuid is null or r.period_id=%s::uuid)
        order by rp.period_end desc,r.completed_at desc,r.created_at desc,r.id desc
        limit 1
        """,
        (outlet_id, period_id, period_id),
    )
    return await result.fetchone()


@router.get("/calc-runs/{run_id}", response_model=CalcRunSummary)
async def get_calc_run(
    run_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> CalcRunSummary:
    async with user_transaction(user.id) as conn:
        run = await _load_run_summary(conn, run_id)
    if run is None:
        raise HTTPException(status_code=404, detail="Calculation run is not available")
    return run


@router.get("/calc-runs/{run_id}/results", response_model=CalcResultsResponse)
async def get_calc_results(
    run_id: UUID,
    module: str | None = Query(default=None, min_length=1, max_length=24, pattern=r"^[A-Z][A-Z0-9_]*$"),
    calc_id: str | None = Query(default=None, min_length=1, max_length=120),
    grain_type: str | None = Query(default=None, min_length=1, max_length=120),
    user: AuthenticatedUser = Depends(get_current_user),
) -> CalcResultsResponse:
    async with user_transaction(user.id) as conn:
        run = await _load_run_summary(conn, run_id)
        if run is None:
            raise HTTPException(status_code=404, detail="Calculation run is not available")
        results = await _load_results(
            conn,
            run_id,
            module=module,
            calc_id=calc_id,
            grain_type=grain_type,
        )
    return CalcResultsResponse(run_id=run_id, results=results)


@router.get("/outlets/{outlet_id}/analysis/pnl", response_model=PLAnalysisResponse)
async def get_management_pl(
    outlet_id: UUID,
    period_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> PLAnalysisResponse:
    async with user_transaction(user.id) as conn:
        context = await _latest_completed_pl_run(
            conn,
            outlet_id=outlet_id,
            period_id=period_id,
        )
        if context is None:
            raise HTTPException(
                status_code=404,
                detail="No completed Management P&L calculation is available for this outlet/period yet.",
            )

        run_id = context["run_id"]
        run = await _load_run_summary(conn, run_id)
        if run is None:
            raise HTTPException(status_code=404, detail="Calculation run is not available")

        results = await _load_results(conn, run_id)

        ladder_result = await conn.execute(
            """
            select code,name as label,display_order,is_calculated
            from ladder_line
            where code in (
              'NET_SALES','PRODUCT_COST','PRODUCT_MARGIN','CHANNEL_COST',
              'DIRECT_LABOUR','OTHER_DIRECT_OPERATING','CONTRIBUTION',
              'SHARED_RESTAURANT_COST','OPERATING_PROFIT',
              'OWNER_STRUCTURAL_COST','OWNER_RESULT'
            )
            order by display_order
            """
        )
        ladder = await ladder_result.fetchall()

    actual: dict[str, CalcResultRead] = {}
    comparator: dict[str, CalcResultRead] = {}
    variance: dict[str, CalcResultRead] = {}
    sequence: CalcResultRead | None = None

    for item in results:
        line_code = str(item.grain_key.get("ladder_code") or "")
        if item.calc_id == "SEQ.FIRST_MATERIAL_MOVEMENT":
            sequence = item
        elif item.grain_type == "management_pl" and item.grain_key.get("scenario") == "actual":
            actual[line_code] = item
        elif item.grain_type == "management_pl":
            comparator[line_code] = item
        elif item.grain_type == "management_pl_variance":
            variance[line_code] = item

    lines = [
        PLLineRead(
            line_code=row["code"],
            label=row["label"],
            display_order=row["display_order"],
            is_calculated=row["is_calculated"],
            actual=actual.get(row["code"]),
            comparator=comparator.get(row["code"]),
            variance=variance.get(row["code"]),
        )
        for row in ladder
    ]

    return PLAnalysisResponse(
        outlet_id=context["outlet_id"],
        outlet_name=context["outlet_name"],
        currency_code=context["currency_code"],
        period=PeriodSummary(
            id=context["period_id"],
            label=context["period_label"],
            period_start=context["period_start"],
            period_end=context["period_end"],
        ),
        run=run,
        lines=lines,
        first_material_movement=sequence,
    )



async def _food_cost_context(
    conn,
    *,
    outlet_id: UUID,
    period_id: UUID | None,
) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          o.id as outlet_id,
          o.name as outlet_name,
          btrim(o.currency_code) as currency_code,
          rp.id as period_id,
          rp.label as period_label,
          rp.period_start,
          rp.period_end,
          dr.status as readiness_status,
          dr.latest_batch_id,
          dr.details_json
        from outlet o
        join reporting_period rp
          on rp.organisation_id=o.organisation_id
         and rp.outlet_id=o.id
        left join data_readiness dr
          on dr.organisation_id=o.organisation_id
         and dr.outlet_id=o.id
         and dr.period_id=rp.id
         and dr.capability_code='food_cost_inputs'
        where o.id=%s
          and has_org_access(o.organisation_id)
          and has_outlet_access(o.organisation_id,o.id)
          and (%s::uuid is null or rp.id=%s::uuid)
        order by rp.period_end desc,rp.period_start desc,rp.id desc
        limit 1
        """,
        (outlet_id, period_id, period_id),
    )
    return await result.fetchone()


async def _latest_completed_food_cost_run(
    conn,
    *,
    outlet_id: UUID,
    period_id: UUID,
) -> dict[str, Any] | None:
    result = await conn.execute(
        """
        select
          r.id as run_id,
          r.outlet_id,
          r.period_id,
          r.engine_version,
          r.status,
          r.result_hash,
          r.started_at,
          r.completed_at,
          r.settings_snapshot
        from calc_run r
        where r.outlet_id=%s
          and r.period_id=%s
          and r.status='completed'
          and r.engine_version='food-cost-v1'
          and has_org_access(r.organisation_id)
          and has_outlet_access(r.organisation_id,r.outlet_id)
        order by r.completed_at desc,r.created_at desc,r.id desc
        limit 1
        """,
        (outlet_id, period_id),
    )
    return await result.fetchone()


def _food_cost_readiness_from_context(
    context: dict[str, Any],
    *,
    has_completed_run: bool,
) -> FoodCostReadinessRead:
    details = context.get("details_json") or {}
    missing_inputs: list[str] = []
    for key, label in (
        ("t2_item_sales_committed", "T2_ITEM_SALES"),
        ("t3_stock_committed", "T3_STOCK"),
        ("t4a_item_cost_committed", "T4A_ITEM_COST"),
    ):
        if details.get(key) is not True:
            missing_inputs.append(label)

    readiness_status = context.get("readiness_status") or "not_available"

    if has_completed_run:
        calculation_status = "CALCULATED"
        explanation_code = None
    elif readiness_status == "ready":
        calculation_status = "NOT_CALCULATED"
        explanation_code = "FOOD_COST_CALCULATION_NOT_COMPLETED"
    elif readiness_status == "blocked":
        calculation_status = "NOT_CALCULATED"
        explanation_code = "FOOD_COST_INPUTS_BLOCKED"
    elif readiness_status in {"partial", "not_reconciled"}:
        calculation_status = "NOT_CALCULATED"
        explanation_code = "FOOD_COST_INPUTS_INCOMPLETE"
    else:
        calculation_status = "NOT_CALCULATED"
        explanation_code = "FOOD_COST_INPUTS_NOT_IMPORTED"

    return FoodCostReadinessRead(
        status=readiness_status,
        latest_batch_id=context.get("latest_batch_id"),
        details=details,
        missing_inputs=missing_inputs,
        calculation_status=calculation_status,
        explanation_code=explanation_code,
    )


def _food_cost_group_read(
    product_group: str,
    results: list[CalcResultRead],
) -> FoodCostGroupRead:
    by_id = {item.calc_id: item for item in results}
    required = [
        by_id.get("FC.ACTUAL_CONSUMPTION"),
        by_id.get("FC.ACTUAL_COST_PCT"),
        by_id.get("FC.BUDGET_BENCHMARK"),
        by_id.get("FC.BUDGET_GAP"),
        by_id.get("FC.EXPECTED_USAGE"),
        by_id.get("FC.EXPECTED_COST_PCT"),
        by_id.get("FC.MENU_MIX_EFFECT"),
        by_id.get("FC.ACTUAL_VS_EXPECTED"),
        by_id.get("FC.SUPPORTED_DRIVER_TOTAL"),
        by_id.get("FC.RESIDUAL"),
        by_id.get("FC.DECISION_PATH"),
    ]
    evidence_status = (
        "evidence_required"
        if any(
            item is None or item.calculation_status == "NOT_CALCULATED"
            for item in required
        )
        else (
            "validated"
            if all(item.evidence_status == "validated" for item in required if item)
            else "supported"
        )
    )

    return FoodCostGroupRead(
        product_group=product_group,
        evidence_status=evidence_status,
        actual_consumption=by_id.get("FC.ACTUAL_CONSUMPTION"),
        actual_cost_pct=by_id.get("FC.ACTUAL_COST_PCT"),
        budget_benchmark=by_id.get("FC.BUDGET_BENCHMARK"),
        budget_gap=by_id.get("FC.BUDGET_GAP"),
        expected_usage=by_id.get("FC.EXPECTED_USAGE"),
        expected_cost_pct=by_id.get("FC.EXPECTED_COST_PCT"),
        menu_mix_effect=by_id.get("FC.MENU_MIX_EFFECT"),
        actual_vs_expected=by_id.get("FC.ACTUAL_VS_EXPECTED"),
        supported_driver_total=by_id.get("FC.SUPPORTED_DRIVER_TOTAL"),
        residual=by_id.get("FC.RESIDUAL"),
        decision_path=by_id.get("FC.DECISION_PATH"),
    )


@router.get(
    "/outlets/{outlet_id}/analysis/food-cost",
    response_model=FoodCostAnalysisResponse,
)
async def get_food_cost_analysis(
    outlet_id: UUID,
    period_id: UUID | None = Query(default=None),
    user: AuthenticatedUser = Depends(get_current_user),
) -> FoodCostAnalysisResponse:
    """Read persisted Food Cost analysis; never calculate finance in the API/UI."""
    async with user_transaction(user.id) as conn:
        context = await _food_cost_context(
            conn,
            outlet_id=outlet_id,
            period_id=period_id,
        )
        if context is None:
            raise HTTPException(
                status_code=404,
                detail="Outlet/reporting period is not available.",
            )

        run_row = await _latest_completed_food_cost_run(
            conn,
            outlet_id=outlet_id,
            period_id=context["period_id"],
        )

        readiness = _food_cost_readiness_from_context(
            context,
            has_completed_run=run_row is not None,
        )

        if run_row is None:
            return FoodCostAnalysisResponse(
                outlet_id=context["outlet_id"],
                outlet_name=context["outlet_name"],
                currency_code=context["currency_code"],
                period=PeriodSummary(
                    id=context["period_id"],
                    label=context["period_label"],
                    period_start=context["period_start"],
                    period_end=context["period_end"],
                ),
                readiness=readiness,
                run=None,
                groups=[],
            )

        run = await _load_run_summary(conn, run_row["run_id"])
        if run is None:
            raise HTTPException(
                status_code=409,
                detail="Completed Food Cost run is not readable in the current access context.",
            )

        results = await _load_results(
            conn,
            run_row["run_id"],
            module="FC",
            grain_type="food_cost",
        )

    grouped: dict[str, list[CalcResultRead]] = defaultdict(list)
    for item in results:
        product_group = str(item.grain_key.get("product_group") or "").strip().lower()
        if product_group:
            grouped[product_group].append(item)

    groups = [
        _food_cost_group_read(group, grouped[group])
        for group in sorted(grouped)
    ]

    return FoodCostAnalysisResponse(
        outlet_id=context["outlet_id"],
        outlet_name=context["outlet_name"],
        currency_code=context["currency_code"],
        period=PeriodSummary(
            id=context["period_id"],
            label=context["period_label"],
            period_start=context["period_start"],
            period_end=context["period_end"],
        ),
        readiness=readiness,
        run=run,
        groups=groups,
    )


@router.get("/periods/{period_id}/reconciliation", response_model=ReconciliationResponse)
async def get_reconciliation(
    period_id: UUID,
    user: AuthenticatedUser = Depends(get_current_user),
) -> ReconciliationResponse:
    async with user_transaction(user.id) as conn:
        run_result = await conn.execute(
            """
            select
              r.id as run_id,r.outlet_id,
              o.name as outlet_name,btrim(o.currency_code) as currency_code,
              rp.label as period_label,rp.period_start,rp.period_end
            from calc_run r
            join outlet o
              on o.organisation_id=r.organisation_id
             and o.id=r.outlet_id
            join reporting_period rp
              on rp.organisation_id=r.organisation_id
             and rp.outlet_id=r.outlet_id
             and rp.id=r.period_id
            where r.period_id=%s
              and r.status='completed'
              and r.engine_version like 'pl-%'
              and has_org_access(r.organisation_id)
              and has_outlet_access(r.organisation_id,r.outlet_id)
            order by r.completed_at desc,r.created_at desc,r.id desc
            limit 1
            """,
            (period_id,),
        )
        run = await run_result.fetchone()
        if run is None:
            raise HTTPException(
                status_code=404,
                detail="No completed calculation run is available for this reporting period.",
            )

        input_result = await conn.execute(
            """
            select
              i.batch_id,b.source_file_id,sf.original_filename,sf.sha256 as source_sha256
            from calc_run_input i
            join import_batch b
              on b.organisation_id=i.organisation_id
             and b.outlet_id=i.outlet_id
             and b.id=i.batch_id
            join source_file sf
              on sf.organisation_id=b.organisation_id
             and sf.outlet_id=b.outlet_id
             and sf.id=b.source_file_id
            where i.run_id=%s and i.input_role='actual'
            order by i.created_at,i.id
            limit 1
            """,
            (run["run_id"],),
        )
        source = await input_result.fetchone()
        if source is None:
            raise HTTPException(
                status_code=409,
                detail="Completed calculation run has no pinned actual input batch.",
            )

        fact_result = await conn.execute(
            """
            select
              ff.id as fact_id,
              ll.code as line_code,
              ll.name as label,
              ll.display_order,
              a.account_code,
              a.account_name,
              ff.amount
            from financial_fact ff
            join ladder_line ll on ll.id=ff.ladder_line_id
            left join account a on a.id=ff.account_id
            where ff.batch_id=%s
              and not ll.is_calculated
            order by ll.display_order,a.account_code nulls last,a.account_name,ff.id
            """,
            (source["batch_id"],),
        )
        facts = await fact_result.fetchall()

        management_result = await conn.execute(
            """
            select
              id,grain_key,value_numeric,calculation_status,explanation_code
            from calc_result
            where run_id=%s
              and grain_type='management_pl'
              and grain_key->>'scenario'='actual'
            """,
            (run["run_id"],),
        )
        management_rows = await management_result.fetchall()

    management = {
        row["grain_key"].get("ladder_code"): row
        for row in management_rows
    }

    grouped: dict[str, dict[str, Any]] = {}
    for fact in facts:
        group = grouped.setdefault(
            fact["line_code"],
            {
                "label": fact["label"],
                "display_order": fact["display_order"],
                "accounting_amount": Decimal("0"),
                "accounts": [],
                "fact_ids": [],
            },
        )
        group["accounting_amount"] += fact["amount"]
        identifier = None
        if fact["account_code"] and fact["account_name"]:
            identifier = f'{fact["account_code"]} · {fact["account_name"]}'
        elif fact["account_code"]:
            identifier = fact["account_code"]
        elif fact["account_name"]:
            identifier = fact["account_name"]
        if identifier and identifier not in group["accounts"]:
            group["accounts"].append(identifier)
        group["fact_ids"].append(fact["fact_id"])

    lines: list[ReconciliationLineRead] = []
    reconciled = True
    for line_code, group in sorted(grouped.items(), key=lambda item: item[1]["display_order"]):
        calc = management.get(line_code)
        management_amount = (
            calc["value_numeric"]
            if calc is not None and calc["calculation_status"] == "CALCULATED"
            else None
        )
        difference = (
            management_amount - group["accounting_amount"]
            if management_amount is not None
            else None
        )
        line_status = "ties" if difference == 0 else "not_reconciled"
        if line_status != "ties":
            reconciled = False

        lines.append(
            ReconciliationLineRead(
                line_code=line_code,
                label=group["label"],
                display_order=group["display_order"],
                statement_accounts=group["accounts"],
                management_amount=_decimal_text(management_amount),
                accounting_amount=_decimal_text(group["accounting_amount"]) or "0",
                difference=_decimal_text(difference),
                status=line_status,
                calc_result_id=calc["id"] if calc is not None else None,
                financial_fact_ids=group["fact_ids"],
                explanation_code=(
                    calc["explanation_code"]
                    if calc is not None and calc["calculation_status"] != "CALCULATED"
                    else None
                ),
            )
        )

    if not lines:
        reconciled = False

    return ReconciliationResponse(
        outlet_id=run["outlet_id"],
        outlet_name=run["outlet_name"],
        currency_code=run["currency_code"],
        period=PeriodSummary(
            id=period_id,
            label=run["period_label"],
            period_start=run["period_start"],
            period_end=run["period_end"],
        ),
        run_id=run["run_id"],
        source_batch_id=source["batch_id"],
        source_file_id=source["source_file_id"],
        original_filename=source["original_filename"],
        source_sha256=source["source_sha256"],
        status="reconciled" if reconciled else "not_reconciled",
        scope="canonical_pnl_source_lines",
        lines=lines,
        cross_module_status="not_tested",
        cross_module_note=(
            "This Slice 3 reconciliation proves the Management P&L source lines tie to the "
            "committed accounting P&L batch. Stock, item-sales, revenue-source and other "
            "cross-module tie-outs are added with their later slices."
        ),
    )
