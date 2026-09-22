from __future__ import annotations

from decimal import Decimal
import unittest
from uuid import UUID

from workers.pl_worker import (
    Claim,
    FoodCostGroupSource,
    PreparedFoodCostRun,
    PreparedLabourOtherRun,
    PreparedRevenueRun,
    PreparedRun,
    LabourGrainSource,
    RevenueGrainSource,
    WorkerDataError,
    aggregate_financial_facts,
    calculate_food_cost_bundle,
    calculate_labour_other_bundle,
    calculate_pl_bundle,
    calculate_revenue_bundle,
)


ACTUAL = {
    "NET_SALES": Decimal("228500"),
    "PRODUCT_COST": Decimal("70282"),
    "CHANNEL_COST": Decimal("3600"),
    "DIRECT_LABOUR": Decimal("84317"),
    "OTHER_DIRECT_OPERATING": Decimal("2500"),
    "SHARED_RESTAURANT_COST": Decimal("14252"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}

BUDGET = {
    "NET_SALES": Decimal("232000"),
    "PRODUCT_COST": Decimal("66908"),
    "CHANNEL_COST": Decimal("3300"),
    "DIRECT_LABOUR": Decimal("79112"),
    "OTHER_DIRECT_OPERATING": Decimal("2300"),
    "SHARED_RESTAURANT_COST": Decimal("12160"),
    "OWNER_STRUCTURAL_COST": Decimal("26000"),
}


def _refs(prefix: str, values: dict[str, Decimal]) -> dict[str, tuple[str, ...]]:
    return {
        code: (f"financial_fact:{prefix}-{index}",)
        for index, code in enumerate(values, start=1)
    }


def _prepared(*, with_comparator: bool) -> PreparedRun:
    claim = Claim(
        request_id=UUID("10000000-0000-0000-0000-000000000001"),
        organisation_id=UUID("10000000-0000-0000-0000-000000000002"),
        outlet_id=UUID("10000000-0000-0000-0000-000000000003"),
        period_id=UUID("10000000-0000-0000-0000-000000000004"),
        source_batch_id=UUID("10000000-0000-0000-0000-000000000005"),
        reason="unit-test",
        attempt_no=1,
    )
    return PreparedRun(
        run_id=UUID("10000000-0000-0000-0000-000000000006"),
        claim=claim,
        currency="USD",
        comparator_scenario="budget",
        actual_values=ACTUAL,
        actual_refs=_refs("a", ACTUAL),
        comparator_values=BUDGET if with_comparator else None,
        comparator_refs=_refs("b", BUDGET) if with_comparator else None,
        settings_snapshot={
            "outlet_settings": {"primary_comparator": "budget"},
            "materiality": {
                "general": {
                    "id": "mat-general-v1",
                    "absolute_threshold": "1000",
                    "percent_threshold": "0.10",
                    "risk_override_enabled": False,
                    "approved_at": "2026-07-01T00:00:00+00:00",
                }
            },
        },
    )


def _prepared_food_cost() -> PreparedFoodCostRun:
    claim = Claim(
        request_id=UUID("20000000-0000-0000-0000-000000000001"),
        organisation_id=UUID("20000000-0000-0000-0000-000000000002"),
        outlet_id=UUID("20000000-0000-0000-0000-000000000003"),
        period_id=UUID("20000000-0000-0000-0000-000000000004"),
        source_batch_id=UUID("20000000-0000-0000-0000-000000000005"),
        reason="food_cost_unit_test",
        attempt_no=1,
    )
    from packages.calc_engine import ExpectedUsageItem

    items = (
        ExpectedUsageItem(
            item_key="F01",
            product_group="food",
            units_sold=Decimal("900"),
            approved_cost_per_unit=Decimal("17"),
            sales_refs=("item_sales_fact:f01",),
            cost_refs=("item_cost_snapshot:f01",),
        ),
        ExpectedUsageItem(
            item_key="F02",
            product_group="food",
            units_sold=Decimal("1600"),
            approved_cost_per_unit=Decimal("7"),
            sales_refs=("item_sales_fact:f02",),
            cost_refs=("item_cost_snapshot:f02",),
        ),
        ExpectedUsageItem(
            item_key="F03",
            product_group="food",
            units_sold=Decimal("1500"),
            approved_cost_per_unit=Decimal("5.5"),
            sales_refs=("item_sales_fact:f03",),
            cost_refs=("item_cost_snapshot:f03",),
        ),
        ExpectedUsageItem(
            item_key="F04",
            product_group="food",
            units_sold=Decimal("1400"),
            approved_cost_per_unit=Decimal("6.5"),
            sales_refs=("item_sales_fact:f04",),
            cost_refs=("item_cost_snapshot:f04",),
        ),
        ExpectedUsageItem(
            item_key="F05",
            product_group="food",
            units_sold=Decimal("700"),
            approved_cost_per_unit=Decimal("12.5"),
            sales_refs=("item_sales_fact:f05",),
            cost_refs=("item_cost_snapshot:f05",),
        ),
        ExpectedUsageItem(
            item_key="F06",
            product_group="food",
            units_sold=Decimal("800"),
            approved_cost_per_unit=Decimal("5"),
            sales_refs=("item_sales_fact:f06",),
            cost_refs=("item_cost_snapshot:f06",),
        ),
        ExpectedUsageItem(
            item_key="F07",
            product_group="food",
            units_sold=Decimal("500"),
            approved_cost_per_unit=Decimal("3"),
            sales_refs=("item_sales_fact:f07",),
            cost_refs=("item_cost_snapshot:f07",),
        ),
        ExpectedUsageItem(
            item_key="F08",
            product_group="food",
            units_sold=Decimal("500"),
            approved_cost_per_unit=Decimal("4.6"),
            sales_refs=("item_sales_fact:f08",),
            cost_refs=("item_cost_snapshot:f08",),
        ),
        ExpectedUsageItem(
            item_key="B01",
            product_group="beverage",
            units_sold=Decimal("900"),
            approved_cost_per_unit=Decimal("1.8"),
            sales_refs=("item_sales_fact:b01",),
            cost_refs=("item_cost_snapshot:b01",),
        ),
        ExpectedUsageItem(
            item_key="B02",
            product_group="beverage",
            units_sold=Decimal("500"),
            approved_cost_per_unit=Decimal("4.8"),
            sales_refs=("item_sales_fact:b02",),
            cost_refs=("item_cost_snapshot:b02",),
        ),
        ExpectedUsageItem(
            item_key="B03",
            product_group="beverage",
            units_sold=Decimal("800"),
            approved_cost_per_unit=Decimal("0.9"),
            sales_refs=("item_sales_fact:b03",),
            cost_refs=("item_cost_snapshot:b03",),
        ),
        ExpectedUsageItem(
            item_key="B04",
            product_group="beverage",
            units_sold=Decimal("400"),
            approved_cost_per_unit=Decimal("3.6"),
            sales_refs=("item_sales_fact:b04",),
            cost_refs=("item_cost_snapshot:b04",),
        ),
    )
    groups = (
        FoodCostGroupSource(
            product_group="food",
            opening_inventory=Decimal("9800"),
            purchases=Decimal("62900"),
            closing_inventory=Decimal("11357"),
            product_revenue=Decimal("191100"),
            comparator_cost_pct=Decimal("0.30"),
            stock_refs=("stock_fact:food",),
            revenue_refs=("item_sales_fact:food",),
            comparator_refs=("stock_fact:food",),
        ),
        FoodCostGroupSource(
            product_group="beverage",
            opening_inventory=Decimal("3500"),
            purchases=Decimal("5900"),
            closing_inventory=Decimal("2961"),
            product_revenue=Decimal("27400"),
            comparator_cost_pct=Decimal("0.22"),
            stock_refs=("stock_fact:beverage",),
            revenue_refs=("item_sales_fact:beverage",),
            comparator_refs=("stock_fact:beverage",),
        ),
    )
    return PreparedFoodCostRun(
        run_id=UUID("20000000-0000-0000-0000-000000000006"),
        claim=claim,
        currency="USD",
        item_sales_batch_id=UUID("20000000-0000-0000-0000-000000000011"),
        stock_batch_id=UUID("20000000-0000-0000-0000-000000000012"),
        item_cost_batch_id=UUID("20000000-0000-0000-0000-000000000013"),
        expected_usage_items=items,
        groups=groups,
        settings_snapshot={
            "materiality": {
                "general": {
                    "id": "food-mat-v1",
                    "absolute_threshold": "1000",
                    "percent_threshold": "0.10",
                    "risk_override_enabled": False,
                    "approved_at": "2026-07-01T00:00:00+00:00",
                }
            },
            "food_cost": {
                "inventory_evidence_status": "validated",
                "expected_usage_source": "T2_X_T4A",
            },
        },
    )


def _prepared_revenue() -> PreparedRevenueRun:
    claim = Claim(
        request_id=UUID("60000000-0000-0000-0000-000000000001"),
        organisation_id=UUID("60000000-0000-0000-0000-000000000002"),
        outlet_id=UUID("60000000-0000-0000-0000-000000000003"),
        period_id=UUID("60000000-0000-0000-0000-000000000004"),
        source_batch_id=UUID("60000000-0000-0000-0000-000000000005"),
        reason="revenue_unit_test",
        attempt_no=1,
    )
    rows = (
        ("Brunch", "covers", "700", "25900", "650", "23400"),
        ("Lunch", "covers", "1480", "45880", "1650", "51150"),
        ("Dinner", "covers", "2390", "114720", "2450", "115150"),
        ("Delivery / Takeaway", "orders", "750", "27000", "700", "25200"),
        ("Private Event", "guests", "240", "12480", "250", "14000"),
        ("Corporate / Group", "guests", "90", "2520", "100", "3100"),
    )
    grains = tuple(
        RevenueGrainSource(
            business_view_type="meal_period",
            business_view_key=name,
            activity_unit_type=unit_type,
            actual_units=Decimal(actual_units),
            actual_revenue=Decimal(actual_revenue),
            comparator_units=Decimal(comparator_units),
            comparator_revenue=Decimal(comparator_revenue),
            refs=(f"revenue_activity_fact:{index}",),
        )
        for index, (
            name,unit_type,actual_units,actual_revenue,
            comparator_units,comparator_revenue
        ) in enumerate(rows, start=1)
    )
    return PreparedRevenueRun(
        run_id=UUID("60000000-0000-0000-0000-000000000006"),
        claim=claim,
        currency="USD",
        revenue_activity_batch_id=UUID("60000000-0000-0000-0000-000000000011"),
        channel_source_batch_id=UUID("60000000-0000-0000-0000-000000000012"),
        financial_actual_batch_id=UUID("60000000-0000-0000-0000-000000000013"),
        grains=grains,
        financial_values=ACTUAL,
        contribution_refs=tuple(
            f"financial_fact:ct-{index}"
            for index in range(1, 6)
        ),
        settings_snapshot={
            "revenue": {
                "activity_unit_rollup": "never_mix_incompatible_unit_types",
                "avg_spend_source": "DERIVED_REVENUE_DIV_ACTIVITY_UNITS",
                "contribution_scope": "outlet_accounting_actual",
            }
        },
    )


def _prepared_labour_other() -> PreparedLabourOtherRun:
    claim = Claim(
        request_id=UUID("76000000-0000-0000-0000-000000000001"),
        organisation_id=UUID("76000000-0000-0000-0000-000000000002"),
        outlet_id=UUID("76000000-0000-0000-0000-000000000003"),
        period_id=UUID("76000000-0000-0000-0000-000000000004"),
        source_batch_id=UUID("76000000-0000-0000-0000-000000000005"),
        reason="labour_other_unit_test",
        attempt_no=1,
    )
    rows = (
        ("Dinner FOH","1100","1030","27000","24850","100","2390","dinner_covers"),
        ("Kitchen prep","800","730","20500","18300","40","5650","total_covers"),
        ("Lunch FOH","750","720","17400","16500","20","1480","lunch_covers"),
        ("Bar","400","390","9600","9300","30","3090","brunch_plus_dinner_covers"),
        ("Management / shared","430","410","9817","10162","30","5650","total_covers"),
    )
    grains = tuple(
        LabourGrainSource(
            role_group=name,
            actual_hours=Decimal(actual_hours),
            comparator_hours=Decimal(comparator_hours),
            actual_cost=Decimal(actual_cost),
            comparator_cost=Decimal(comparator_cost),
            scheduled_hours=None,
            overtime_hours=Decimal(overtime_hours),
            activity_units=Decimal(activity_units),
            activity_basis=activity_basis,
            refs=(f"labour_fact:{index}",),
        )
        for index, (
            name,actual_hours,comparator_hours,actual_cost,comparator_cost,
            overtime_hours,activity_units,activity_basis
        ) in enumerate(rows, start=1)
    )
    return PreparedLabourOtherRun(
        run_id=UUID("76000000-0000-0000-0000-000000000006"),
        claim=claim,
        currency="USD",
        labour_batch_id=UUID("76000000-0000-0000-0000-000000000011"),
        financial_actual_batch_id=UUID("76000000-0000-0000-0000-000000000012"),
        financial_comparator_batch_id=UUID("76000000-0000-0000-0000-000000000013"),
        comparator_scenario="budget",
        labour_grains=grains,
        actual_values=ACTUAL,
        actual_refs=_refs("lb-a", ACTUAL),
        comparator_values=BUDGET,
        comparator_refs=_refs("lb-b", BUDGET),
        settings_snapshot={
            "labour_other": {
                "activity_unit_rollup": "PROHIBITED_ACROSS_ROLE_GROUPS",
                "staffing_diagnosis_from_labour_pct": "PROHIBITED",
                "overtime_rate_evidence": "EXPLICIT_ONLY",
                "other_cost_quantity_rate_evidence": "EXPLICIT_ONLY",
            }
        },
    )


class CalcWorkerUnitTests(unittest.TestCase):
    def test_aggregate_uses_canonical_codes_and_never_amounts_for_mapping(self) -> None:
        rows = [
            {
                "fact_id": "f2",
                "ladder_code": "NET_SALES",
                "amount": Decimal("28.50"),
            },
            {
                "fact_id": "f1",
                "ladder_code": "NET_SALES",
                "amount": Decimal("200.00"),
            },
            {
                "fact_id": "f3",
                "ladder_code": "PRODUCT_COST",
                "amount": Decimal("70.25"),
            },
        ]
        totals, refs = aggregate_financial_facts(rows)
        self.assertEqual(totals["NET_SALES"], Decimal("228.50"))
        self.assertEqual(totals["PRODUCT_COST"], Decimal("70.25"))
        self.assertEqual(
            refs["NET_SALES"],
            ("financial_fact:f1", "financial_fact:f2"),
        )

    def test_aggregate_rejects_calculated_destination(self) -> None:
        with self.assertRaises(WorkerDataError) as error:
            aggregate_financial_facts(
                [
                    {
                        "fact_id": "bad",
                        "ladder_code": "OPERATING_PROFIT",
                        "amount": Decimal("1"),
                    }
                ]
            )
        self.assertEqual(error.exception.code, "UNSUPPORTED_LADDER_CODE")

    def test_full_pl_bundle_contains_actual_comparator_and_variance(self) -> None:
        bundle = calculate_pl_bundle(_prepared(with_comparator=True))
        self.assertEqual(len(bundle.results), 34)
        self.assertEqual(len(bundle.dependencies), 44)
        self.assertRegex(bundle.result_hash, r"^[0-9a-f]{64}$")

        actual_op = next(
            result
            for result in bundle.results
            if result.category == "actual"
            and result.calc_id == "PL.OPERATING_PROFIT"
        )
        budget_op = next(
            result
            for result in bundle.results
            if result.category == "comparator"
            and result.calc_id == "PL.OPERATING_PROFIT"
        )
        variance_op = next(
            result
            for result in bundle.results
            if result.category == "variance"
            and result.calc_id == "PL.VAR.OPERATING_PROFIT"
        )

        self.assertEqual(actual_op.value_numeric, Decimal("53549.0000"))
        self.assertEqual(budget_op.value_numeric, Decimal("68220.0000"))
        self.assertEqual(variance_op.raw_delta, Decimal("-14671.0000"))
        self.assertEqual(variance_op.profit_effect, Decimal("-14671.0000"))
        self.assertEqual(variance_op.value_numeric, Decimal("-14671.0000"))

        sequence = next(
            result
            for result in bundle.results
            if result.calc_id == "SEQ.FIRST_MATERIAL_MOVEMENT"
        )
        self.assertEqual(sequence.value_text, "NET_SALES")
        self.assertIsNone(sequence.value_numeric)
        self.assertEqual(sequence.metadata["materiality_reason"], "amount_test")
        self.assertEqual(sequence.metadata["impact"], "-3500")

    def test_missing_comparator_is_persisted_as_not_calculated_not_zero(self) -> None:
        bundle = calculate_pl_bundle(_prepared(with_comparator=False))
        self.assertEqual(len(bundle.results), 23)
        self.assertEqual(len(bundle.dependencies), 32)
        variances = [result for result in bundle.results if result.category == "variance"]
        self.assertEqual(len(variances), 11)
        for result in variances:
            self.assertEqual(result.calculation_status, "NOT_CALCULATED")
            self.assertEqual(result.explanation_code, "COMPARATOR_NOT_COMMITTED")
            self.assertIsNone(result.value_numeric)
            self.assertIsNone(result.raw_delta)
            self.assertIsNone(result.profit_effect)

        sequence = next(
            result
            for result in bundle.results
            if result.calc_id == "SEQ.FIRST_MATERIAL_MOVEMENT"
        )
        self.assertEqual(sequence.calculation_status, "NOT_CALCULATED")
        self.assertEqual(sequence.explanation_code, "COMPARATOR_NOT_COMMITTED")
        self.assertIsNone(sequence.value_numeric)
        self.assertIsNone(sequence.value_text)

    def test_food_cost_bundle_matches_amberside_and_decision_paths(self) -> None:
        bundle = calculate_food_cost_bundle(_prepared_food_cost())
        self.assertEqual(len(bundle.results), 22)
        self.assertEqual(len(bundle.dependencies), 26)
        self.assertRegex(bundle.result_hash, r"^[0-9a-f]{64}$")

        def result(calc_id: str, group: str):
            return next(
                item
                for item in bundle.results
                if item.calc_id == calc_id
                and item.grain_key["product_group"] == group
            )

        self.assertEqual(
            result("FC.ACTUAL_CONSUMPTION", "food").value_numeric,
            Decimal("61343.0000"),
        )
        self.assertEqual(
            result("FC.EXPECTED_USAGE", "food").value_numeric,
            Decimal("60400.0000"),
        )
        self.assertEqual(
            result("FC.ACTUAL_VS_EXPECTED", "food").value_numeric,
            Decimal("943.0000"),
        )
        self.assertEqual(
            result("FC.BUDGET_BENCHMARK", "food").value_numeric,
            Decimal("57330.0000"),
        )
        self.assertEqual(
            result("FC.MENU_MIX_EFFECT", "food").value_numeric,
            Decimal("3070.0000"),
        )
        self.assertEqual(
            result("FC.RESIDUAL", "food").value_numeric,
            Decimal("943.0000"),
        )
        self.assertEqual(
            result("FC.DECISION_PATH", "food").value_text,
            "MENU_ECONOMIC_HANDOFF",
        )
        self.assertEqual(
            result("FC.DECISION_PATH", "beverage").value_text,
            "NO_MATERIAL_GAP",
        )
        self.assertTrue(
            any(
                ref.startswith("item_cost_snapshot:")
                for ref in result("FC.EXPECTED_USAGE", "food").input_refs
            )
        )
        self.assertTrue(
            any(
                ref.startswith("item_sales_fact:")
                for ref in result("FC.EXPECTED_USAGE", "food").input_refs
            )
        )

    def test_food_cost_hash_is_stable_across_new_result_ids(self) -> None:
        first = calculate_food_cost_bundle(_prepared_food_cost())
        second = calculate_food_cost_bundle(_prepared_food_cost())
        self.assertNotEqual(
            {result.id for result in first.results},
            {result.id for result in second.results},
        )
        self.assertEqual(first.result_hash, second.result_hash)

    def test_revenue_bundle_matches_amberside_and_outlet_contribution(self) -> None:
        bundle = calculate_revenue_bundle(_prepared_revenue())
        self.assertEqual(len(bundle.results), 39)
        self.assertEqual(len(bundle.dependencies), 26)
        self.assertRegex(bundle.result_hash, r"^[0-9a-f]{64}$")

        brunch = {
            result.calc_id: result
            for result in bundle.results
            if result.grain_key.get("business_view_key") == "Brunch"
        }
        self.assertEqual(
            brunch["RV.VOLUME_EFFECT"].value_numeric,
            Decimal("1800.0000"),
        )
        self.assertEqual(
            brunch["RV.SPEND_EFFECT"].value_numeric,
            Decimal("700.0000"),
        )
        self.assertEqual(
            brunch["RV.TOTAL_VARIANCE"].value_numeric,
            Decimal("2500.0000"),
        )

        self.assertEqual(
            sum(
                result.value_numeric or Decimal("0")
                for result in bundle.results
                if result.calc_id == "RV.VOLUME_EFFECT"
            ),
            Decimal("-5360.0000"),
        )
        self.assertEqual(
            sum(
                result.value_numeric or Decimal("0")
                for result in bundle.results
                if result.calc_id == "RV.SPEND_EFFECT"
            ),
            Decimal("1860.0000"),
        )
        self.assertEqual(
            sum(
                result.value_numeric or Decimal("0")
                for result in bundle.results
                if result.calc_id == "RV.TOTAL_VARIANCE"
            ),
            Decimal("-3500.0000"),
        )

        contribution = next(
            result
            for result in bundle.results
            if result.calc_id == "CT.CONTRIBUTION"
        )
        per_unit = next(
            result
            for result in bundle.results
            if result.calc_id == "CT.CONTRIBUTION_PER_ACTIVITY_UNIT"
        )
        margin = next(
            result
            for result in bundle.results
            if result.calc_id == "CT.CONTRIBUTION_MARGIN_PCT"
        )
        self.assertEqual(contribution.value_numeric, Decimal("67801.0000"))
        self.assertEqual(per_unit.calculation_status, "NOT_CALCULATED")
        self.assertEqual(per_unit.explanation_code, "ACTIVITY_UNITS_MISSING")
        self.assertEqual(margin.value_numeric, Decimal("0.2967"))
        self.assertTrue(
            all(
                ref.startswith("financial_fact:")
                for ref in contribution.input_refs
            )
        )

    def test_revenue_hash_is_stable_across_new_result_ids(self) -> None:
        first = calculate_revenue_bundle(_prepared_revenue())
        second = calculate_revenue_bundle(_prepared_revenue())
        self.assertNotEqual(
            {result.id for result in first.results},
            {result.id for result in second.results},
        )
        self.assertEqual(first.result_hash, second.result_hash)

    def test_labour_other_bundle_matches_amberside_and_preserves_basis(self) -> None:
        bundle = calculate_labour_other_bundle(_prepared_labour_other())
        self.assertEqual(len(bundle.results), 54)
        self.assertEqual(len(bundle.dependencies), 21)
        self.assertRegex(bundle.result_hash, r"^[0-9a-f]{64}$")

        labour_totals = [
            result
            for result in bundle.results
            if result.calc_id == "LB.TOTAL_VARIANCE"
        ]
        self.assertEqual(len(labour_totals), 5)
        self.assertEqual(
            sum(result.value_numeric or Decimal("0") for result in labour_totals),
            Decimal("5205.0000"),
        )

        for total in labour_totals:
            role = total.grain_key["role_group"]
            hours = next(
                result for result in bundle.results
                if result.calc_id == "LB.HOURS_EFFECT_RAW"
                and result.grain_key["role_group"] == role
            )
            rate = next(
                result for result in bundle.results
                if result.calc_id == "LB.RATE_EFFECT_RAW"
                and result.grain_key["role_group"] == role
            )
            self.assertEqual(
                (hours.value_numeric or Decimal("0"))
                + (rate.value_numeric or Decimal("0")),
                total.value_numeric,
            )
            self.assertLessEqual(
                total.profit_effect or Decimal("0"),
                Decimal("345.0000"),
            )

        kitchen = next(
            result for result in bundle.results
            if result.calc_id == "LB.COST_PER_ACTIVITY"
            and result.grain_key["role_group"] == "Kitchen prep"
        )
        management = next(
            result for result in bundle.results
            if result.calc_id == "LB.COST_PER_ACTIVITY"
            and result.grain_key["role_group"] == "Management / shared"
        )
        self.assertEqual(kitchen.grain_key["activity_basis"], "total_covers")
        self.assertEqual(management.grain_key["activity_basis"], "total_covers")
        self.assertEqual(
            dict(kitchen.metadata)["activity_basis"],
            "total_covers",
        )
        self.assertEqual(
            dict(management.metadata)["activity_basis"],
            "total_covers",
        )

        overtime_rate = [
            result for result in bundle.results
            if result.calc_id == "LB.OVERTIME_RATE_EFFECT"
        ]
        self.assertEqual(len(overtime_rate), 5)
        self.assertTrue(
            all(
                result.calculation_status == "NOT_CALCULATED"
                and result.explanation_code == "OVERTIME_RATE_EVIDENCE_MISSING"
                and result.value_numeric is None
                for result in overtime_rate
            )
        )
        self.assertNotIn(
            "OVERSTAFFED",
            {
                result.value_text
                for result in bundle.results
                if result.value_text
            },
        )

        other_direct = next(
            result for result in bundle.results
            if result.calc_id == "OC.TOTAL_VARIANCE"
            and result.grain_key["ladder_code"] == "OTHER_DIRECT_OPERATING"
        )
        shared = next(
            result for result in bundle.results
            if result.calc_id == "OC.TOTAL_VARIANCE"
            and result.grain_key["ladder_code"] == "SHARED_RESTAURANT_COST"
        )
        owner = next(
            result for result in bundle.results
            if result.calc_id == "OC.TOTAL_VARIANCE"
            and result.grain_key["ladder_code"] == "OWNER_STRUCTURAL_COST"
        )
        self.assertEqual(other_direct.value_numeric, Decimal("200.0000"))
        self.assertEqual(shared.value_numeric, Decimal("2092.0000"))
        self.assertEqual(owner.value_numeric, Decimal("0.0000"))

        oc_driver_legs = [
            result for result in bundle.results
            if result.calc_id in {"OC.QUANTITY_EFFECT", "OC.RATE_EFFECT"}
        ]
        self.assertEqual(len(oc_driver_legs), 6)
        self.assertTrue(
            all(
                result.calculation_status == "NOT_CALCULATED"
                and result.explanation_code == "QUANTITY_RATE_EVIDENCE_MISSING"
                and result.value_numeric is None
                for result in oc_driver_legs
            )
        )

    def test_labour_other_hash_is_stable_across_new_result_ids(self) -> None:
        first = calculate_labour_other_bundle(_prepared_labour_other())
        second = calculate_labour_other_bundle(_prepared_labour_other())
        self.assertNotEqual(
            {result.id for result in first.results},
            {result.id for result in second.results},
        )
        self.assertEqual(first.result_hash, second.result_hash)

    def test_hash_is_stable_even_when_result_row_ids_change(self) -> None:
        first = calculate_pl_bundle(_prepared(with_comparator=True))
        second = calculate_pl_bundle(_prepared(with_comparator=True))
        self.assertNotEqual(
            {result.id for result in first.results},
            {result.id for result in second.results},
        )
        self.assertEqual(first.result_hash, second.result_hash)


if __name__ == "__main__":
    unittest.main()
