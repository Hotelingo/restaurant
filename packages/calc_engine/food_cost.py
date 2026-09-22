from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Sequence

from .core import (
    calculated_result,
    calculated_text_result,
    not_calculated_result,
    ratio_result,
    stable_refs,
)
from .materiality import MaterialitySnapshot
from .model import CalcResult

SUPPORTED_DRIVER_STATUSES = frozenset({"supported", "validated"})

DECISION_PATHS = (
    "VALIDATE_FIRST",
    "OPERATING_CONTROL_INVESTIGATION",
    "FAVOURABLE_VALIDATE_DATA",
    "MENU_ECONOMIC_HANDOFF",
    "NO_MATERIAL_GAP",
)


@dataclass(frozen=True, slots=True)
class ExpectedUsageItem:
    item_key: str
    product_group: str
    units_sold: Decimal
    approved_cost_per_unit: Decimal | None
    cost_effective: bool = True
    sales_refs: tuple[str, ...] = ()
    cost_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.item_key.strip():
            raise ValueError("item_key cannot be blank")
        if not self.product_group.strip():
            raise ValueError("product_group cannot be blank")
        if not isinstance(self.units_sold, Decimal):
            raise TypeError("units_sold must be Decimal")
        if (
            self.approved_cost_per_unit is not None
            and not isinstance(self.approved_cost_per_unit, Decimal)
        ):
            raise TypeError("approved_cost_per_unit must be Decimal or None")


@dataclass(frozen=True, slots=True)
class FoodCostBridgeInput:
    product_group: str
    opening_inventory: Decimal
    purchases: Decimal
    closing_inventory: Decimal
    product_revenue: Decimal | None
    comparator_cost_pct: Decimal | None
    currency: str
    stock_refs: tuple[str, ...] = ()
    revenue_refs: tuple[str, ...] = ()
    comparator_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.product_group.strip():
            raise ValueError("product_group cannot be blank")
        for field_name in ("opening_inventory", "purchases", "closing_inventory"):
            value = getattr(self, field_name)
            if not isinstance(value, Decimal):
                raise TypeError(f"{field_name} must be Decimal")
        if self.product_revenue is not None and not isinstance(
            self.product_revenue, Decimal
        ):
            raise TypeError("product_revenue must be Decimal or None")
        if self.comparator_cost_pct is not None:
            if not isinstance(self.comparator_cost_pct, Decimal):
                raise TypeError("comparator_cost_pct must be Decimal or None")
            if self.comparator_cost_pct < 0:
                raise ValueError("comparator_cost_pct cannot be negative")


@dataclass(frozen=True, slots=True)
class FoodCostDriverImpact:
    driver_code: str
    impact: Decimal
    evidence_status: str
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not self.driver_code.startswith("FC.DRIVER."):
            raise ValueError("driver_code must use the FC.DRIVER.* registry")
        if not isinstance(self.impact, Decimal):
            raise TypeError("driver impact must be Decimal")
        if not self.coverage_key.strip():
            raise ValueError("coverage_key cannot be blank")
        if (
            self.evidence_status not in SUPPORTED_DRIVER_STATUSES
            and self.impact != Decimal("0")
        ):
            raise ValueError(
                "unsupported driver evidence cannot carry a quantified impact"
            )


def _normalise_currency(currency: str) -> str:
    value = currency.strip().upper()
    if len(value) != 3 or not value.isalpha():
        raise ValueError("currency must be a three-letter ISO-style code")
    return value


def _grain(product_group: str) -> str:
    return product_group.strip().lower()


def _by_id(results: Sequence[CalcResult]) -> dict[str, CalcResult]:
    mapped = {result.calc_id: result for result in results}
    if len(mapped) != len(results):
        raise ValueError("duplicate calc_id in food-cost result set")
    return mapped


def calculate_expected_usage(
    items: Sequence[ExpectedUsageItem],
    *,
    product_group: str,
    currency: str,
) -> CalcResult:
    """Preferred T2 × T4A expected-usage path.

    Expected usage is derived from units sold and the approved effective item
    cost snapshot. It is never accepted from T3 as an imported canonical fact.
    """
    group = _grain(product_group)
    currency_code = _normalise_currency(currency)
    selected = [item for item in items if _grain(item.product_group) == group]
    refs = stable_refs(
        *(stable_refs(item.sales_refs, item.cost_refs) for item in selected)
    )

    if not selected:
        return not_calculated_result(
            calc_id="FC.EXPECTED_USAGE",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency_code,
            explanation_code="ITEM_SALES_MISSING",
            input_refs=refs,
            metadata=(("derivation", "T2_X_T4A"),),
        )

    if any(not item.cost_effective for item in selected):
        return not_calculated_result(
            calc_id="FC.EXPECTED_USAGE",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency_code,
            explanation_code="ITEM_COST_NOT_EFFECTIVE",
            input_refs=refs,
            metadata=(("derivation", "T2_X_T4A"),),
        )

    if any(item.approved_cost_per_unit is None for item in selected):
        return not_calculated_result(
            calc_id="FC.EXPECTED_USAGE",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency_code,
            explanation_code="ITEM_COST_MISSING",
            input_refs=refs,
            metadata=(("derivation", "T2_X_T4A"),),
        )

    total = sum(
        (
            item.units_sold * item.approved_cost_per_unit
            for item in selected
            if item.approved_cost_per_unit is not None
        ),
        Decimal("0"),
    )

    return calculated_result(
        calc_id="FC.EXPECTED_USAGE",
        grain_type="food_cost",
        grain_key=group,
        value=total,
        unit="currency",
        currency=currency_code,
        input_refs=refs,
        metadata=(
            ("derivation", "T2_X_T4A"),
            ("item_count", str(len(selected))),
        ),
    )


def calculate_food_cost_bridge(
    inputs: FoodCostBridgeInput,
    *,
    expected_usage: CalcResult,
) -> tuple[CalcResult, ...]:
    """Return the eight stable two-story food-cost bridge calculations."""
    group = _grain(inputs.product_group)
    currency = _normalise_currency(inputs.currency)

    if expected_usage.calc_id != "FC.EXPECTED_USAGE":
        raise ValueError("expected_usage must be FC.EXPECTED_USAGE")
    if expected_usage.grain_key != group:
        raise ValueError("expected_usage product group does not match bridge input")

    consumption = inputs.opening_inventory + inputs.purchases - inputs.closing_inventory

    actual_consumption = calculated_result(
        calc_id="FC.ACTUAL_CONSUMPTION",
        grain_type="food_cost",
        grain_key=group,
        value=consumption,
        unit="currency",
        currency=currency,
        input_refs=inputs.stock_refs,
        metadata=(("formula", "opening+purchases-closing"),),
    )

    actual_cost_pct = ratio_result(
        calc_id="FC.ACTUAL_COST_PCT",
        grain_type="food_cost",
        grain_key=group,
        numerator=consumption,
        denominator=inputs.product_revenue,
        input_refs=stable_refs(inputs.stock_refs, inputs.revenue_refs),
    )

    if inputs.product_revenue is None:
        budget_benchmark = not_calculated_result(
            calc_id="FC.BUDGET_BENCHMARK",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="PRODUCT_REVENUE_MISSING",
            input_refs=stable_refs(inputs.revenue_refs, inputs.comparator_refs),
        )
    elif inputs.comparator_cost_pct is None:
        budget_benchmark = not_calculated_result(
            calc_id="FC.BUDGET_BENCHMARK",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_COST_PCT_MISSING",
            input_refs=stable_refs(inputs.revenue_refs, inputs.comparator_refs),
        )
    else:
        budget_benchmark = calculated_result(
            calc_id="FC.BUDGET_BENCHMARK",
            grain_type="food_cost",
            grain_key=group,
            value=inputs.product_revenue * inputs.comparator_cost_pct,
            unit="currency",
            currency=currency,
            input_refs=stable_refs(inputs.revenue_refs, inputs.comparator_refs),
        )

    benchmark_refs = stable_refs(
        actual_consumption.input_refs,
        budget_benchmark.input_refs,
    )
    if budget_benchmark.calculation_status != "CALCULATED":
        budget_gap = not_calculated_result(
            calc_id="FC.BUDGET_GAP",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="BUDGET_BENCHMARK_NOT_CALCULATED",
            input_refs=benchmark_refs,
        )
    else:
        if budget_benchmark.value is None:
            raise AssertionError("calculated benchmark unexpectedly has no value")
        budget_gap = calculated_result(
            calc_id="FC.BUDGET_GAP",
            grain_type="food_cost",
            grain_key=group,
            value=consumption - budget_benchmark.value,
            unit="currency",
            currency=currency,
            input_refs=benchmark_refs,
            metadata=(("interpretation", "context_only_not_leakage"),),
        )

    expected_cost_pct = ratio_result(
        calc_id="FC.EXPECTED_COST_PCT",
        grain_type="food_cost",
        grain_key=group,
        numerator=expected_usage.value
        if expected_usage.calculation_status == "CALCULATED"
        else None,
        denominator=inputs.product_revenue,
        input_refs=stable_refs(expected_usage.input_refs, inputs.revenue_refs),
    )

    bridge_refs = stable_refs(
        expected_usage.input_refs,
        budget_benchmark.input_refs,
        actual_consumption.input_refs,
    )

    if (
        expected_usage.calculation_status != "CALCULATED"
        or expected_usage.value is None
    ):
        menu_mix_effect = not_calculated_result(
            calc_id="FC.MENU_MIX_EFFECT",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="EXPECTED_USAGE_NOT_CALCULATED",
            input_refs=bridge_refs,
            metadata=(("interpretation", "menu_economics_not_leakage"),),
        )
        actual_vs_expected = not_calculated_result(
            calc_id="FC.ACTUAL_VS_EXPECTED",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="EXPECTED_USAGE_NOT_CALCULATED",
            input_refs=bridge_refs,
        )
    elif (
        budget_benchmark.calculation_status != "CALCULATED"
        or budget_benchmark.value is None
    ):
        menu_mix_effect = not_calculated_result(
            calc_id="FC.MENU_MIX_EFFECT",
            grain_type="food_cost",
            grain_key=group,
            unit="currency",
            currency=currency,
            explanation_code="BUDGET_BENCHMARK_NOT_CALCULATED",
            input_refs=bridge_refs,
            metadata=(("interpretation", "menu_economics_not_leakage"),),
        )
        actual_vs_expected = calculated_result(
            calc_id="FC.ACTUAL_VS_EXPECTED",
            grain_type="food_cost",
            grain_key=group,
            value=consumption - expected_usage.value,
            unit="currency",
            currency=currency,
            input_refs=stable_refs(
                actual_consumption.input_refs,
                expected_usage.input_refs,
            ),
        )
    else:
        menu_mix_effect = calculated_result(
            calc_id="FC.MENU_MIX_EFFECT",
            grain_type="food_cost",
            grain_key=group,
            value=expected_usage.value - budget_benchmark.value,
            unit="currency",
            currency=currency,
            input_refs=bridge_refs,
            metadata=(("interpretation", "menu_economics_not_leakage"),),
        )
        actual_vs_expected = calculated_result(
            calc_id="FC.ACTUAL_VS_EXPECTED",
            grain_type="food_cost",
            grain_key=group,
            value=consumption - expected_usage.value,
            unit="currency",
            currency=currency,
            input_refs=stable_refs(
                actual_consumption.input_refs,
                expected_usage.input_refs,
            ),
        )

    return (
        actual_consumption,
        actual_cost_pct,
        budget_benchmark,
        budget_gap,
        expected_usage,
        expected_cost_pct,
        menu_mix_effect,
        actual_vs_expected,
    )


def calculate_supported_driver_total(
    drivers: Sequence[FoodCostDriverImpact],
    *,
    product_group: str,
    currency: str,
    overlap_override_reference: str | None = None,
) -> CalcResult:
    """Quantify only supported/validated drivers and prevent double counting."""
    group = _grain(product_group)
    currency_code = _normalise_currency(currency)
    included = [
        driver
        for driver in drivers
        if driver.evidence_status in SUPPORTED_DRIVER_STATUSES
    ]

    coverage_counts: dict[str, int] = {}
    for driver in included:
        coverage_counts[driver.coverage_key] = (
            coverage_counts.get(driver.coverage_key, 0) + 1
        )
    overlapping = sorted(
        key for key, count in coverage_counts.items() if count > 1
    )
    if overlapping and not (
        overlap_override_reference
        and overlap_override_reference.strip()
    ):
        raise ValueError(
            "overlapping coverage_key values require an explicit reviewer override: "
            + ", ".join(overlapping)
        )

    total = sum((driver.impact for driver in included), Decimal("0"))
    refs = stable_refs(*(driver.input_refs for driver in included))
    metadata = [
        ("included_driver_count", str(len(included))),
        ("coverage_keys", "|".join(sorted(coverage_counts))),
    ]
    if overlapping:
        metadata.extend(
            [
                ("overlap_keys", "|".join(overlapping)),
                ("reviewer_override_reference", overlap_override_reference.strip()),
            ]
        )

    return calculated_result(
        calc_id="FC.SUPPORTED_DRIVER_TOTAL",
        grain_type="food_cost",
        grain_key=group,
        value=total,
        unit="currency",
        currency=currency_code,
        input_refs=refs,
        metadata=tuple(metadata),
    )


def calculate_residual(
    actual_vs_expected: CalcResult,
    supported_driver_total: CalcResult,
    *,
    currency: str,
) -> CalcResult:
    if actual_vs_expected.calc_id != "FC.ACTUAL_VS_EXPECTED":
        raise ValueError("actual_vs_expected must be FC.ACTUAL_VS_EXPECTED")
    if supported_driver_total.calc_id != "FC.SUPPORTED_DRIVER_TOTAL":
        raise ValueError(
            "supported_driver_total must be FC.SUPPORTED_DRIVER_TOTAL"
        )
    if actual_vs_expected.grain_key != supported_driver_total.grain_key:
        raise ValueError("food-cost residual inputs must share product-group grain")

    refs = stable_refs(
        actual_vs_expected.input_refs,
        supported_driver_total.input_refs,
    )
    if (
        actual_vs_expected.calculation_status != "CALCULATED"
        or actual_vs_expected.value is None
    ):
        return not_calculated_result(
            calc_id="FC.RESIDUAL",
            grain_type="food_cost",
            grain_key=actual_vs_expected.grain_key,
            unit="currency",
            currency=_normalise_currency(currency),
            explanation_code="ACTUAL_VS_EXPECTED_NOT_CALCULATED",
            input_refs=refs,
        )

    if (
        supported_driver_total.calculation_status != "CALCULATED"
        or supported_driver_total.value is None
    ):
        return not_calculated_result(
            calc_id="FC.RESIDUAL",
            grain_type="food_cost",
            grain_key=actual_vs_expected.grain_key,
            unit="currency",
            currency=_normalise_currency(currency),
            explanation_code="SUPPORTED_DRIVER_TOTAL_NOT_CALCULATED",
            input_refs=refs,
        )

    return calculated_result(
        calc_id="FC.RESIDUAL",
        grain_type="food_cost",
        grain_key=actual_vs_expected.grain_key,
        value=actual_vs_expected.value - supported_driver_total.value,
        unit="currency",
        currency=_normalise_currency(currency),
        input_refs=refs,
    )


def _materiality_matches(
    value: Decimal,
    *,
    basis: Decimal | None,
    snapshot: MaterialitySnapshot,
) -> tuple[bool, tuple[str, ...], Decimal | None]:
    rules: list[str] = []
    magnitude = abs(value)

    if (
        snapshot.absolute_threshold is not None
        and magnitude >= snapshot.absolute_threshold
    ):
        rules.append("amount_test")

    ratio: Decimal | None = None
    if basis is not None and basis != 0:
        ratio = magnitude / abs(basis)
        if (
            snapshot.percent_threshold is not None
            and ratio >= snapshot.percent_threshold
        ):
            rules.append("percentage_test")

    return bool(rules), tuple(rules), ratio


def calculate_decision_path(
    bridge_results: Sequence[CalcResult],
    *,
    inventory_evidence_status: str,
    materiality_snapshot: MaterialitySnapshot | None,
) -> CalcResult:
    """Corrected G-20/G-21 decision path.

    The budget gap is context only. The operating branch is driven solely by
    ACTUAL_VS_EXPECTED; MENU_MIX_EFFECT is a separate menu-economics handoff.
    """
    results = _by_id(bridge_results)
    ave = results.get("FC.ACTUAL_VS_EXPECTED")
    expected = results.get("FC.EXPECTED_USAGE")
    menu = results.get("FC.MENU_MIX_EFFECT")
    benchmark = results.get("FC.BUDGET_BENCHMARK")
    refs = stable_refs(
        ave.input_refs if ave else (),
        expected.input_refs if expected else (),
        menu.input_refs if menu else (),
        benchmark.input_refs if benchmark else (),
    )
    grain = ave.grain_key if ave is not None else (
        menu.grain_key if menu is not None else "unknown"
    )

    if inventory_evidence_status != "validated":
        return calculated_text_result(
            calc_id="FC.DECISION_PATH",
            grain_type="food_cost",
            grain_key=grain,
            value_text="VALIDATE_FIRST",
            unit="decision_path",
            input_refs=refs,
            metadata=(("reason", "inventory_evidence_not_validated"),),
        )

    if (
        materiality_snapshot is None
        or not materiality_snapshot.approved
        or (
            materiality_snapshot.absolute_threshold is None
            and materiality_snapshot.percent_threshold is None
        )
    ):
        return calculated_text_result(
            calc_id="FC.DECISION_PATH",
            grain_type="food_cost",
            grain_key=grain,
            value_text="VALIDATE_FIRST",
            unit="decision_path",
            input_refs=refs,
            metadata=(("reason", "materiality_unset_or_unconfirmed"),),
        )

    if (
        ave is None
        or expected is None
        or ave.calculation_status != "CALCULATED"
        or expected.calculation_status != "CALCULATED"
        or ave.value is None
        or expected.value is None
    ):
        return calculated_text_result(
            calc_id="FC.DECISION_PATH",
            grain_type="food_cost",
            grain_key=grain,
            value_text="VALIDATE_FIRST",
            unit="decision_path",
            input_refs=refs,
            metadata=(("reason", "actual_vs_expected_not_calculated"),),
        )

    ave_material, ave_rules, ave_ratio = _materiality_matches(
        ave.value,
        basis=expected.value,
        snapshot=materiality_snapshot,
    )

    if ave_material and ave.value > 0:
        decision = "OPERATING_CONTROL_INVESTIGATION"
        reason = "actual_vs_expected_adverse_material"
    elif ave_material and ave.value < 0:
        decision = "FAVOURABLE_VALIDATE_DATA"
        reason = "actual_vs_expected_favourable_material"
    else:
        menu_material = False
        menu_rules: tuple[str, ...] = ()
        menu_ratio: Decimal | None = None
        if (
            menu is not None
            and benchmark is not None
            and menu.calculation_status == "CALCULATED"
            and benchmark.calculation_status == "CALCULATED"
            and menu.value is not None
            and benchmark.value is not None
        ):
            menu_material, menu_rules, menu_ratio = _materiality_matches(
                menu.value,
                basis=benchmark.value,
                snapshot=materiality_snapshot,
            )

        if menu_material:
            decision = "MENU_ECONOMIC_HANDOFF"
            reason = "menu_mix_material_operating_gap_not_material"
        else:
            decision = "NO_MATERIAL_GAP"
            reason = "neither_operating_nor_menu_gap_material"

        return calculated_text_result(
            calc_id="FC.DECISION_PATH",
            grain_type="food_cost",
            grain_key=grain,
            value_text=decision,
            unit="decision_path",
            input_refs=refs,
            metadata=(
                ("reason", reason),
                ("actual_vs_expected_rules", "|".join(ave_rules)),
                (
                    "actual_vs_expected_ratio",
                    format(ave_ratio, "f") if ave_ratio is not None else "",
                ),
                ("menu_mix_rules", "|".join(menu_rules)),
                (
                    "menu_mix_ratio",
                    format(menu_ratio, "f") if menu_ratio is not None else "",
                ),
                ("budget_gap_drives_branch", "false"),
            ),
        )

    return calculated_text_result(
        calc_id="FC.DECISION_PATH",
        grain_type="food_cost",
        grain_key=grain,
        value_text=decision,
        unit="decision_path",
        input_refs=refs,
        metadata=(
            ("reason", reason),
            ("actual_vs_expected_rules", "|".join(ave_rules)),
            (
                "actual_vs_expected_ratio",
                format(ave_ratio, "f") if ave_ratio is not None else "",
            ),
            ("budget_gap_drives_branch", "false"),
        ),
    )
