from __future__ import annotations

import unittest
from decimal import Decimal

from packages.calc_engine import (
    PortionTestInput,
    ProductionTestInput,
    TransferNonRevenueTestInput,
    WasteTestInput,
    YieldTestInput,
    calculate_portion_driver,
    calculate_production_driver,
    calculate_supported_driver_total,
    calculate_transfer_nonrevenue_driver,
    calculate_waste_driver,
    calculate_yield_driver,
    driver_impact_from_c02,
)


class C02DriverEngineTests(unittest.TestCase):
    def test_yield_driver_uses_approved_vs_observed_usable_quantity(self) -> None:
        result = calculate_yield_driver(
            YieldTestInput(
                grain_key="food:ribeye",
                ap_quantity=Decimal("20"),
                approved_yield=Decimal("0.72"),
                observed_usable_quantity=Decimal("14.2"),
                approved_usable_unit_cost=Decimal("30"),
                currency="USD",
                evidence_status="validated",
                coverage_key="food:ribeye:batch-1:yield",
                input_refs=("yield_test:batch-1",),
            )
        )

        self.assertEqual(result.calc_id, "FC.DRIVER.YIELD")
        self.assertEqual(result.value, Decimal("6.00"))
        self.assertEqual(result.raw_delta, Decimal("6.00"))
        self.assertEqual(result.profit_effect, Decimal("-6.00"))
        self.assertEqual(result.evidence_status, "validated")
        meta = dict(result.metadata)
        self.assertEqual(meta["actual_yield"], "0.71")
        self.assertEqual(meta["approved_yield"], "0.72")
        self.assertEqual(meta["theoretical_usable_quantity"], "14.40")
        self.assertEqual(meta["usable_shortfall"], "0.20")
        self.assertEqual(meta["coverage_key"], "food:ribeye:batch-1:yield")

    def test_yield_zero_ap_quantity_is_not_calculated(self) -> None:
        result = calculate_yield_driver(
            YieldTestInput(
                grain_key="food:ribeye",
                ap_quantity=Decimal("0"),
                approved_yield=Decimal("0.72"),
                observed_usable_quantity=Decimal("0"),
                approved_usable_unit_cost=Decimal("30"),
                currency="USD",
                evidence_status="supported",
                coverage_key="food:ribeye:zero:yield",
            )
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "AP_QUANTITY_ZERO")
        self.assertIsNone(result.value)

    def test_portion_guide_observation_stays_unquantified_until_supported(self) -> None:
        result = calculate_portion_driver(
            PortionTestInput(
                grain_key="food:ribeye",
                approved_portion=Decimal("280"),
                observed_avg_portion=Decimal("283"),
                representative_portions=Decimal("420"),
                approved_usable_unit_cost=Decimal("0.0215"),
                currency="USD",
                evidence_status="partly_supported",
                coverage_key="food:ribeye:july:portion-sample",
                input_refs=("portion_sample:july",),
            )
        )
        self.assertEqual(result.calc_id, "FC.DRIVER.PORTION")
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(
            result.explanation_code,
            "DRIVER_EVIDENCE_NOT_SUPPORTED",
        )
        self.assertIsNone(result.value)
        impact = driver_impact_from_c02(result)
        self.assertEqual(impact.impact, Decimal("0"))
        self.assertEqual(impact.evidence_status, "partly_supported")

    def test_supported_portion_driver_is_exact(self) -> None:
        result = calculate_portion_driver(
            PortionTestInput(
                grain_key="food:ribeye",
                approved_portion=Decimal("280"),
                observed_avg_portion=Decimal("283"),
                representative_portions=Decimal("420"),
                approved_usable_unit_cost=Decimal("0.0215"),
                currency="USD",
                evidence_status="supported",
                coverage_key="food:ribeye:july:portion-sample",
            )
        )
        self.assertEqual(result.value, Decimal("27.0900"))
        meta = dict(result.metadata)
        self.assertEqual(meta["portion_variance"], "3")
        self.assertEqual(meta["supported_excess_usage"], "1260")

    def test_production_requires_explicit_physical_balance(self) -> None:
        missing = calculate_production_driver(
            ProductionTestInput(
                grain_key="food:buffet",
                produced_quantity=Decimal("100"),
                served_quantity=Decimal("80"),
                closing_usable_quantity=Decimal("10"),
                documented_nonrevenue_quantity=None,
                approved_usable_unit_cost=Decimal("3"),
                currency="USD",
                evidence_status="supported",
                coverage_key="food:buffet:dinner:production",
            )
        )
        self.assertEqual(missing.calculation_status, "NOT_CALCULATED")
        self.assertEqual(
            missing.explanation_code,
            "DOCUMENTED_NONREVENUE_QUANTITY_MISSING",
        )

        complete = calculate_production_driver(
            ProductionTestInput(
                grain_key="food:buffet",
                produced_quantity=Decimal("100"),
                served_quantity=Decimal("80"),
                closing_usable_quantity=Decimal("10"),
                documented_nonrevenue_quantity=Decimal("5"),
                approved_usable_unit_cost=Decimal("3"),
                currency="USD",
                evidence_status="supported",
                coverage_key="food:buffet:dinner:production",
                input_refs=("production_sheet:dinner",),
            )
        )
        self.assertEqual(complete.value, Decimal("15"))
        self.assertEqual(
            dict(complete.metadata)["interpretation"],
            "explicit_production_balance_not_inferred_from_financial_amounts",
        )

    def test_negative_production_balance_is_not_a_synthetic_saving(self) -> None:
        result = calculate_production_driver(
            ProductionTestInput(
                grain_key="food:buffet",
                produced_quantity=Decimal("90"),
                served_quantity=Decimal("80"),
                closing_usable_quantity=Decimal("10"),
                documented_nonrevenue_quantity=Decimal("5"),
                approved_usable_unit_cost=Decimal("3"),
                currency="USD",
                evidence_status="validated",
                coverage_key="food:buffet:dinner:bad-balance",
            )
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(result.explanation_code, "PRODUCTION_BALANCE_NEGATIVE")
        self.assertIsNone(result.value)

    def test_normal_yield_loss_is_not_counted_again_as_waste(self) -> None:
        result = calculate_waste_driver(
            WasteTestInput(
                grain_key="food:ribeye",
                quantity=Decimal("5"),
                unit_cost=Decimal("4"),
                reason_code="normal_trim",
                already_in_approved_standard=True,
                currency="USD",
                evidence_status="validated",
                coverage_key="food:ribeye:batch-1:normal-trim",
            )
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(
            result.explanation_code,
            "LOSS_ALREADY_IN_APPROVED_STANDARD",
        )
        self.assertIsNone(result.value)

    def test_amberside_supported_kitchen_error_waste_is_620(self) -> None:
        result = calculate_waste_driver(
            WasteTestInput(
                grain_key="food",
                quantity=Decimal("620"),
                unit_cost=Decimal("1"),
                reason_code="kitchen_error_comp",
                already_in_approved_standard=False,
                currency="USD",
                evidence_status="validated",
                coverage_key="food:july:kitchen-error-comps",
                input_refs=("pos_comp:KE-7", "waste_log:july"),
            )
        )
        self.assertEqual(result.value, Decimal("620"))
        impact = driver_impact_from_c02(result)
        self.assertEqual(impact.impact, Decimal("620"))
        self.assertEqual(impact.coverage_key, "food:july:kitchen-error-comps")

    def test_internal_transfer_never_enters_bridge(self) -> None:
        result = calculate_transfer_nonrevenue_driver(
            TransferNonRevenueTestInput(
                grain_key="food",
                quantity=Decimal("10"),
                unit_cost=Decimal("4"),
                movement_classification="internal_transfer",
                currency="USD",
                evidence_status="validated",
                coverage_key="food:july:internal-transfer-1",
                input_refs=("transfer:1",),
            )
        )
        self.assertEqual(result.calculation_status, "NOT_CALCULATED")
        self.assertEqual(
            result.explanation_code,
            "INTERNAL_TRANSFER_WITHIN_REVIEW_BOUNDARY",
        )
        self.assertIsNone(result.value)

    def test_external_transfer_can_be_quantified_from_supported_evidence(self) -> None:
        result = calculate_transfer_nonrevenue_driver(
            TransferNonRevenueTestInput(
                grain_key="food",
                quantity=Decimal("10"),
                unit_cost=Decimal("4"),
                movement_classification="external_transfer",
                currency="USD",
                evidence_status="supported",
                coverage_key="food:july:external-transfer-1",
            )
        )
        self.assertEqual(result.value, Decimal("40"))

    def test_duplicate_coverage_is_blocked_until_reviewer_override(self) -> None:
        first = driver_impact_from_c02(
            calculate_waste_driver(
                WasteTestInput(
                    grain_key="food",
                    quantity=Decimal("620"),
                    unit_cost=Decimal("1"),
                    reason_code="kitchen_error_comp",
                    already_in_approved_standard=False,
                    currency="USD",
                    evidence_status="validated",
                    coverage_key="food:july:kitchen-error-comps",
                )
            )
        )
        duplicate = driver_impact_from_c02(
            calculate_transfer_nonrevenue_driver(
                TransferNonRevenueTestInput(
                    grain_key="food",
                    quantity=Decimal("620"),
                    unit_cost=Decimal("1"),
                    movement_classification="approved_nonrevenue",
                    currency="USD",
                    evidence_status="supported",
                    coverage_key="food:july:kitchen-error-comps",
                )
            )
        )

        with self.assertRaisesRegex(
            ValueError,
            "overlapping coverage_key values require an explicit reviewer override",
        ):
            calculate_supported_driver_total(
                (first, duplicate),
                product_group="food",
                currency="USD",
            )

        overridden = calculate_supported_driver_total(
            (first, duplicate),
            product_group="food",
            currency="USD",
            overlap_override_reference="reviewer-override:42",
        )
        self.assertEqual(overridden.value, Decimal("1240"))
        self.assertEqual(
            dict(overridden.metadata)["reviewer_override_reference"],
            "reviewer-override:42",
        )


if __name__ == "__main__":
    unittest.main()
