from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from .core import calculated_result, not_calculated_result, stable_refs
from .model import CalcResult


def _normalise_currency(currency: str) -> str:
    value = currency.strip().upper()
    if len(value) != 3 or not value.isalpha():
        raise ValueError("currency must be a three-letter ISO-style code")
    return value


def _grain(value: str) -> str:
    grain = value.strip().lower()
    if not grain:
        raise ValueError("grain_key cannot be blank")
    return grain


def _decimal_or_none(field_name: str, value: Decimal | None) -> None:
    if value is not None and not isinstance(value, Decimal):
        raise TypeError(f"{field_name} must be Decimal or None")


@dataclass(frozen=True, slots=True)
class RevenueVarianceInput:
    """Canonical T1B revenue diagnosis input for one comparable grain."""

    grain_key: str
    activity_unit_type: str
    actual_units: Decimal | None
    actual_revenue: Decimal | None
    comparator_units: Decimal | None
    comparator_revenue: Decimal | None
    currency: str
    actual_refs: tuple[str, ...] = ()
    comparator_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _grain(self.grain_key)
        if not self.activity_unit_type.strip():
            raise ValueError("activity_unit_type cannot be blank")
        for field_name in (
            "actual_units",
            "actual_revenue",
            "comparator_units",
            "comparator_revenue",
        ):
            _decimal_or_none(field_name, getattr(self, field_name))

        if self.actual_units is not None and self.actual_units < 0:
            raise ValueError("actual_units cannot be negative")
        if self.comparator_units is not None and self.comparator_units < 0:
            raise ValueError("comparator_units cannot be negative")
        _normalise_currency(self.currency)


@dataclass(frozen=True, slots=True)
class ContributionInput:
    """Directly attributable contribution inputs for one supported grain.

    Shared rent, general management salary and arbitrary overhead are
    intentionally absent from this contract: CT must never allocate them merely
    to manufacture a contribution result.
    """

    grain_key: str
    net_sales: Decimal | None
    direct_channel_cost: Decimal | None
    product_cost: Decimal | None
    direct_labour: Decimal | None
    other_direct_operating_cost: Decimal | None
    activity_units: Decimal | None
    currency: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _grain(self.grain_key)
        for field_name in (
            "net_sales",
            "direct_channel_cost",
            "product_cost",
            "direct_labour",
            "other_direct_operating_cost",
            "activity_units",
        ):
            _decimal_or_none(field_name, getattr(self, field_name))
        if self.activity_units is not None and self.activity_units < 0:
            raise ValueError("activity_units cannot be negative")
        _normalise_currency(self.currency)


def _not_calculated(
    *,
    calc_id: str,
    grain_key: str,
    unit: str,
    currency: str | None,
    explanation_code: str,
    refs: tuple[str, ...],
    metadata: tuple[tuple[str, str], ...] = (),
) -> CalcResult:
    return not_calculated_result(
        calc_id=calc_id,
        grain_type="revenue",
        grain_key=grain_key,
        unit=unit,
        currency=currency,
        explanation_code=explanation_code,
        input_refs=refs,
        metadata=metadata,
    )


def calculate_revenue_variance(
    inputs: RevenueVarianceInput,
) -> tuple[CalcResult, ...]:
    """Return the six stable RV results for one meal-period/business grain.

    Average spend is derived from revenue / activity units; source-provided
    average-spend columns are validation evidence, not authoritative inputs.

    The decomposition uses one shared projected-revenue intermediate:
        projected = actual_units * comparator_revenue / comparator_units
        volume     = projected - comparator_revenue
        spend      = actual_revenue - projected

    This is algebraically identical to the frozen formulas while guaranteeing
    that VOLUME_EFFECT + SPEND_EFFECT == TOTAL_VARIANCE without intermediate
    rounding drift. A failed control is therefore a data/implementation defect,
    never a business explanation.
    """
    grain = _grain(inputs.grain_key)
    currency = _normalise_currency(inputs.currency)
    unit_type = inputs.activity_unit_type.strip().lower()
    actual_refs = stable_refs(inputs.actual_refs)
    comparator_refs = stable_refs(inputs.comparator_refs)
    all_refs = stable_refs(actual_refs, comparator_refs)

    if inputs.actual_units is None:
        activity_units = _not_calculated(
            calc_id="RV.ACTIVITY_UNITS",
            grain_key=grain,
            unit=unit_type,
            currency=None,
            explanation_code="ACTIVITY_UNITS_MISSING",
            refs=actual_refs,
        )
    else:
        activity_units = calculated_result(
            calc_id="RV.ACTIVITY_UNITS",
            grain_type="revenue",
            grain_key=grain,
            value=inputs.actual_units,
            unit=unit_type,
            currency=None,
            input_refs=actual_refs,
        )

    if inputs.actual_revenue is None:
        revenue = _not_calculated(
            calc_id="RV.REVENUE",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="REVENUE_MISSING",
            refs=actual_refs,
        )
    else:
        revenue = calculated_result(
            calc_id="RV.REVENUE",
            grain_type="revenue",
            grain_key=grain,
            value=inputs.actual_revenue,
            unit="currency",
            currency=currency,
            input_refs=actual_refs,
        )

    if inputs.actual_revenue is None:
        avg_spend = _not_calculated(
            calc_id="RV.AVG_SPEND",
            grain_key=grain,
            unit="currency_per_activity_unit",
            currency=currency,
            explanation_code="REVENUE_MISSING",
            refs=actual_refs,
        )
    elif inputs.actual_units is None:
        avg_spend = _not_calculated(
            calc_id="RV.AVG_SPEND",
            grain_key=grain,
            unit="currency_per_activity_unit",
            currency=currency,
            explanation_code="ACTIVITY_UNITS_MISSING",
            refs=actual_refs,
        )
    elif inputs.actual_units == 0:
        avg_spend = _not_calculated(
            calc_id="RV.AVG_SPEND",
            grain_key=grain,
            unit="currency_per_activity_unit",
            currency=currency,
            explanation_code="ACTIVITY_UNITS_ZERO",
            refs=actual_refs,
        )
    else:
        avg_spend = calculated_result(
            calc_id="RV.AVG_SPEND",
            grain_type="revenue",
            grain_key=grain,
            value=inputs.actual_revenue / inputs.actual_units,
            unit="currency_per_activity_unit",
            currency=currency,
            input_refs=actual_refs,
            metadata=(("activity_unit_type", unit_type),),
        )

    comparator_missing = (
        inputs.comparator_units is None
        or inputs.comparator_revenue is None
    )
    actual_missing = (
        inputs.actual_units is None
        or inputs.actual_revenue is None
    )

    if comparator_missing:
        volume_effect = _not_calculated(
            calc_id="RV.VOLUME_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_NOT_COMMITTED",
            refs=all_refs,
        )
        spend_effect = _not_calculated(
            calc_id="RV.SPEND_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_NOT_COMMITTED",
            refs=all_refs,
        )
    elif actual_missing:
        volume_effect = _not_calculated(
            calc_id="RV.VOLUME_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="ACTUAL_REVENUE_INPUT_MISSING",
            refs=all_refs,
        )
        spend_effect = _not_calculated(
            calc_id="RV.SPEND_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="ACTUAL_REVENUE_INPUT_MISSING",
            refs=all_refs,
        )
    elif inputs.comparator_units == 0:
        volume_effect = _not_calculated(
            calc_id="RV.VOLUME_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_ACTIVITY_UNITS_ZERO",
            refs=all_refs,
        )
        spend_effect = _not_calculated(
            calc_id="RV.SPEND_EFFECT",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_ACTIVITY_UNITS_ZERO",
            refs=all_refs,
        )
    else:
        projected_revenue = (
            inputs.actual_units * inputs.comparator_revenue
            / inputs.comparator_units
        )
        volume_value = projected_revenue - inputs.comparator_revenue
        spend_value = inputs.actual_revenue - projected_revenue
        comparator_avg_spend = (
            inputs.comparator_revenue / inputs.comparator_units
        )

        volume_effect = calculated_result(
            calc_id="RV.VOLUME_EFFECT",
            grain_type="revenue",
            grain_key=grain,
            value=volume_value,
            unit="currency",
            currency=currency,
            input_refs=all_refs,
            raw_delta=volume_value,
            profit_effect=volume_value,
            metadata=(
                ("formula", "(Ua-Uc)*Sc"),
                ("activity_unit_type", unit_type),
                ("comparator_avg_spend", format(comparator_avg_spend, "f")),
            ),
        )
        spend_effect = calculated_result(
            calc_id="RV.SPEND_EFFECT",
            grain_type="revenue",
            grain_key=grain,
            value=spend_value,
            unit="currency",
            currency=currency,
            input_refs=all_refs,
            raw_delta=spend_value,
            profit_effect=spend_value,
            metadata=(
                ("formula", "Ua*(Sa-Sc)"),
                ("activity_unit_type", unit_type),
                ("comparator_avg_spend", format(comparator_avg_spend, "f")),
            ),
        )

    if inputs.actual_revenue is None:
        total_variance = _not_calculated(
            calc_id="RV.TOTAL_VARIANCE",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="REVENUE_MISSING",
            refs=all_refs,
        )
    elif inputs.comparator_revenue is None:
        total_variance = _not_calculated(
            calc_id="RV.TOTAL_VARIANCE",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code="COMPARATOR_NOT_COMMITTED",
            refs=all_refs,
        )
    else:
        total_value = inputs.actual_revenue - inputs.comparator_revenue
        total_variance = calculated_result(
            calc_id="RV.TOTAL_VARIANCE",
            grain_type="revenue",
            grain_key=grain,
            value=total_value,
            unit="currency",
            currency=currency,
            input_refs=all_refs,
            raw_delta=total_value,
            profit_effect=total_value,
            metadata=(("formula", "Ra-Rc"),),
        )

    if (
        volume_effect.calculation_status == "CALCULATED"
        and spend_effect.calculation_status == "CALCULATED"
        and total_variance.calculation_status == "CALCULATED"
    ):
        if (
            volume_effect.value is None
            or spend_effect.value is None
            or total_variance.value is None
            or volume_effect.value + spend_effect.value != total_variance.value
        ):
            raise ArithmeticError(
                "RV volume/spend decomposition failed exact control identity"
            )

    return (
        activity_units,
        avg_spend,
        revenue,
        volume_effect,
        spend_effect,
        total_variance,
    )


def calculate_contribution(
    inputs: ContributionInput,
) -> tuple[CalcResult, ...]:
    """Return CT contribution, per-activity contribution and margin.

    Every cost input is directly attributable by contract. No shared/structural
    cost field exists, so the engine cannot silently allocate overhead.
    """
    grain = _grain(inputs.grain_key)
    currency = _normalise_currency(inputs.currency)
    refs = stable_refs(inputs.input_refs)

    required = (
        ("NET_SALES_MISSING", inputs.net_sales),
        ("DIRECT_CHANNEL_COST_MISSING", inputs.direct_channel_cost),
        ("PRODUCT_COST_MISSING", inputs.product_cost),
        ("DIRECT_LABOUR_MISSING", inputs.direct_labour),
        ("OTHER_DIRECT_OPERATING_COST_MISSING", inputs.other_direct_operating_cost),
    )
    missing = next((code for code, value in required if value is None), None)

    if missing is not None:
        contribution = _not_calculated(
            calc_id="CT.CONTRIBUTION",
            grain_key=grain,
            unit="currency",
            currency=currency,
            explanation_code=missing,
            refs=refs,
        )
    else:
        assert inputs.net_sales is not None
        assert inputs.direct_channel_cost is not None
        assert inputs.product_cost is not None
        assert inputs.direct_labour is not None
        assert inputs.other_direct_operating_cost is not None
        value = (
            inputs.net_sales
            - inputs.direct_channel_cost
            - inputs.product_cost
            - inputs.direct_labour
            - inputs.other_direct_operating_cost
        )
        contribution = calculated_result(
            calc_id="CT.CONTRIBUTION",
            grain_type="revenue",
            grain_key=grain,
            value=value,
            unit="currency",
            currency=currency,
            input_refs=refs,
            metadata=(
                (
                    "formula",
                    "net_sales-channel-product-direct_labour-other_direct_operating",
                ),
                ("shared_overhead_allocated", "false"),
            ),
        )

    if contribution.calculation_status != "CALCULATED":
        per_activity = _not_calculated(
            calc_id="CT.CONTRIBUTION_PER_ACTIVITY_UNIT",
            grain_key=grain,
            unit="currency_per_activity_unit",
            currency=currency,
            explanation_code="CONTRIBUTION_NOT_CALCULATED",
            refs=refs,
        )
        margin = _not_calculated(
            calc_id="CT.CONTRIBUTION_MARGIN_PCT",
            grain_key=grain,
            unit="ratio",
            currency=None,
            explanation_code="CONTRIBUTION_NOT_CALCULATED",
            refs=refs,
        )
    else:
        assert contribution.value is not None
        if inputs.activity_units is None:
            per_activity = _not_calculated(
                calc_id="CT.CONTRIBUTION_PER_ACTIVITY_UNIT",
                grain_key=grain,
                unit="currency_per_activity_unit",
                currency=currency,
                explanation_code="ACTIVITY_UNITS_MISSING",
                refs=refs,
            )
        elif inputs.activity_units == 0:
            per_activity = _not_calculated(
                calc_id="CT.CONTRIBUTION_PER_ACTIVITY_UNIT",
                grain_key=grain,
                unit="currency_per_activity_unit",
                currency=currency,
                explanation_code="ACTIVITY_UNITS_ZERO",
                refs=refs,
            )
        else:
            per_activity = calculated_result(
                calc_id="CT.CONTRIBUTION_PER_ACTIVITY_UNIT",
                grain_type="revenue",
                grain_key=grain,
                value=contribution.value / inputs.activity_units,
                unit="currency_per_activity_unit",
                currency=currency,
                input_refs=refs,
            )

        if inputs.net_sales is None:
            margin = _not_calculated(
                calc_id="CT.CONTRIBUTION_MARGIN_PCT",
                grain_key=grain,
                unit="ratio",
                currency=None,
                explanation_code="NET_SALES_MISSING",
                refs=refs,
            )
        elif inputs.net_sales == 0:
            margin = _not_calculated(
                calc_id="CT.CONTRIBUTION_MARGIN_PCT",
                grain_key=grain,
                unit="ratio",
                currency=None,
                explanation_code="NET_SALES_ZERO",
                refs=refs,
            )
        else:
            margin = calculated_result(
                calc_id="CT.CONTRIBUTION_MARGIN_PCT",
                grain_type="revenue",
                grain_key=grain,
                value=contribution.value / inputs.net_sales,
                unit="ratio",
                currency=None,
                input_refs=refs,
            )

    return contribution, per_activity, margin
