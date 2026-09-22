from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal

from .core import calculated_result, not_calculated_result, stable_refs
from .model import CalcResult


def _currency(value: str) -> str:
    code = value.strip().upper()
    if len(code) != 3 or not code.isalpha():
        raise ValueError("currency must be a three-letter ISO-style code")
    return code


def _key(value: str) -> str:
    key = value.strip()
    if not key:
        raise ValueError("grain_key cannot be blank")
    return key


def _decimal_or_none(field_name: str, value: Decimal | None) -> None:
    if value is not None and not isinstance(value, Decimal):
        raise TypeError(f"{field_name} must be Decimal or None")


@dataclass(frozen=True, slots=True)
class LabourInput:
    grain_key: str
    actual_hours: Decimal | None
    comparator_hours: Decimal | None
    actual_cost: Decimal | None
    comparator_cost: Decimal | None
    currency: str
    activity_units: Decimal | None = None
    activity_basis: str | None = None
    overtime_hours: Decimal | None = None
    scheduled_hours: Decimal | None = None
    overtime_actual_rate: Decimal | None = None
    overtime_comparator_rate: Decimal | None = None
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key)
        _currency(self.currency)
        for field_name in (
            "actual_hours",
            "comparator_hours",
            "actual_cost",
            "comparator_cost",
            "activity_units",
            "overtime_hours",
            "scheduled_hours",
            "overtime_actual_rate",
            "overtime_comparator_rate",
        ):
            _decimal_or_none(field_name, getattr(self, field_name))

        for field_name in (
            "actual_hours",
            "comparator_hours",
            "activity_units",
            "overtime_hours",
            "scheduled_hours",
        ):
            value = getattr(self, field_name)
            if value is not None and value < 0:
                raise ValueError(f"{field_name} cannot be negative")

        if self.activity_units is not None:
            if self.activity_basis is None or not self.activity_basis.strip():
                raise ValueError(
                    "activity_basis is required whenever activity_units are supplied"
                )


@dataclass(frozen=True, slots=True)
class OtherCostInput:
    grain_key: str
    actual_cost: Decimal | None
    comparator_cost: Decimal | None
    currency: str
    actual_qty: Decimal | None = None
    comparator_qty: Decimal | None = None
    actual_rate: Decimal | None = None
    comparator_rate: Decimal | None = None
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key)
        _currency(self.currency)
        for field_name in (
            "actual_cost",
            "comparator_cost",
            "actual_qty",
            "comparator_qty",
            "actual_rate",
            "comparator_rate",
        ):
            _decimal_or_none(field_name, getattr(self, field_name))
        for field_name in ("actual_qty", "comparator_qty"):
            value = getattr(self, field_name)
            if value is not None and value < 0:
                raise ValueError(f"{field_name} cannot be negative")


def _not_calc(
    *,
    calc_id: str,
    grain_type: str,
    grain_key: str,
    unit: str,
    currency: str | None,
    code: str,
    refs: tuple[str, ...],
    metadata: tuple[tuple[str, str], ...] = (),
) -> CalcResult:
    return not_calculated_result(
        calc_id=calc_id,
        grain_type=grain_type,
        grain_key=grain_key,
        unit=unit,
        currency=currency,
        explanation_code=code,
        input_refs=refs,
        metadata=metadata,
    )


def calculate_labour(inputs: LabourInput) -> tuple[CalcResult, ...]:
    """Calculate one role-group Labour diagnostic.

    Activity units are contextual denominators for this role-group grain. The
    engine never aggregates them across role groups; callers must preserve the
    explicit activity_basis because the same workload measure can legitimately
    be repeated across several role groups.
    """
    grain = _key(inputs.grain_key)
    currency = _currency(inputs.currency)
    refs = stable_refs(inputs.input_refs)
    basis = inputs.activity_basis.strip() if inputs.activity_basis else None
    basis_meta = (("activity_basis", basis),) if basis else ()

    if inputs.actual_cost is None:
        actual_rate = _not_calc(
            calc_id="LB.ACTUAL_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="ACTUAL_COST_MISSING", refs=refs,
        )
    elif inputs.actual_hours is None:
        actual_rate = _not_calc(
            calc_id="LB.ACTUAL_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="ACTUAL_HOURS_MISSING", refs=refs,
        )
    elif inputs.actual_hours == 0:
        actual_rate = _not_calc(
            calc_id="LB.ACTUAL_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="ACTUAL_HOURS_ZERO", refs=refs,
        )
    else:
        actual_rate = calculated_result(
            calc_id="LB.ACTUAL_RATE", grain_type="labour", grain_key=grain,
            value=inputs.actual_cost / inputs.actual_hours,
            unit="currency_per_hour", currency=currency, input_refs=refs,
        )

    if inputs.comparator_cost is None:
        comparator_rate = _not_calc(
            calc_id="LB.COMPARATOR_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="COMPARATOR_COST_MISSING", refs=refs,
        )
    elif inputs.comparator_hours is None:
        comparator_rate = _not_calc(
            calc_id="LB.COMPARATOR_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="COMPARATOR_HOURS_MISSING", refs=refs,
        )
    elif inputs.comparator_hours == 0:
        comparator_rate = _not_calc(
            calc_id="LB.COMPARATOR_RATE", grain_type="labour", grain_key=grain,
            unit="currency_per_hour", currency=currency,
            code="COMPARATOR_HOURS_ZERO", refs=refs,
        )
    else:
        comparator_rate = calculated_result(
            calc_id="LB.COMPARATOR_RATE", grain_type="labour", grain_key=grain,
            value=inputs.comparator_cost / inputs.comparator_hours,
            unit="currency_per_hour", currency=currency, input_refs=refs,
        )

    effects_ready = (
        inputs.actual_hours is not None
        and inputs.comparator_hours is not None
        and inputs.comparator_hours != 0
        and inputs.actual_cost is not None
        and inputs.comparator_cost is not None
    )
    if effects_ready:
        assert inputs.actual_hours is not None
        assert inputs.comparator_hours is not None
        assert inputs.actual_cost is not None
        assert inputs.comparator_cost is not None
        projected_cost = (
            inputs.actual_hours * inputs.comparator_cost
            / inputs.comparator_hours
        )
        hours_value = projected_cost - inputs.comparator_cost
        rate_value = inputs.actual_cost - projected_cost

        hours_effect = calculated_result(
            calc_id="LB.HOURS_EFFECT_RAW", grain_type="labour", grain_key=grain,
            value=hours_value, unit="currency", currency=currency,
            input_refs=refs, raw_delta=hours_value,
            profit_effect=-hours_value,
            metadata=(("formula", "(Ha-Hc)*Rc"),),
        )
        rate_effect = calculated_result(
            calc_id="LB.RATE_EFFECT_RAW", grain_type="labour", grain_key=grain,
            value=rate_value, unit="currency", currency=currency,
            input_refs=refs, raw_delta=rate_value,
            profit_effect=-rate_value,
            metadata=(("formula", "Ha*(Ra-Rc)"),),
        )
    else:
        code = (
            "COMPARATOR_HOURS_ZERO"
            if inputs.comparator_hours == 0
            else "LABOUR_EFFECT_INPUT_MISSING"
        )
        hours_effect = _not_calc(
            calc_id="LB.HOURS_EFFECT_RAW", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency, code=code, refs=refs,
        )
        rate_effect = _not_calc(
            calc_id="LB.RATE_EFFECT_RAW", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency, code=code, refs=refs,
        )

    if inputs.actual_cost is None:
        total = _not_calc(
            calc_id="LB.TOTAL_VARIANCE", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency,
            code="ACTUAL_COST_MISSING", refs=refs,
        )
    elif inputs.comparator_cost is None:
        total = _not_calc(
            calc_id="LB.TOTAL_VARIANCE", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency,
            code="COMPARATOR_COST_MISSING", refs=refs,
        )
    else:
        total_value = inputs.actual_cost - inputs.comparator_cost
        total = calculated_result(
            calc_id="LB.TOTAL_VARIANCE", grain_type="labour", grain_key=grain,
            value=total_value, unit="currency", currency=currency,
            input_refs=refs, raw_delta=total_value,
            profit_effect=-total_value,
            metadata=(("formula", "Ca-Cc"),),
        )

    if (
        hours_effect.calculation_status == "CALCULATED"
        and rate_effect.calculation_status == "CALCULATED"
        and total.calculation_status == "CALCULATED"
    ):
        assert hours_effect.value is not None
        assert rate_effect.value is not None
        assert total.value is not None
        if hours_effect.value + rate_effect.value != total.value:
            raise ArithmeticError(
                "LB hours/rate decomposition failed exact control identity"
            )

    def per_activity(
        calc_id: str,
        numerator: Decimal | None,
        unit: str,
        missing_code: str,
    ) -> CalcResult:
        if numerator is None:
            return _not_calc(
                calc_id=calc_id, grain_type="labour", grain_key=grain,
                unit=unit, currency=currency, code=missing_code, refs=refs,
                metadata=basis_meta,
            )
        if inputs.activity_units is None:
            return _not_calc(
                calc_id=calc_id, grain_type="labour", grain_key=grain,
                unit=unit, currency=currency, code="ACTIVITY_UNITS_MISSING",
                refs=refs, metadata=basis_meta,
            )
        if inputs.activity_units == 0:
            return _not_calc(
                calc_id=calc_id, grain_type="labour", grain_key=grain,
                unit=unit, currency=currency, code="ACTIVITY_UNITS_ZERO",
                refs=refs, metadata=basis_meta,
            )
        return calculated_result(
            calc_id=calc_id, grain_type="labour", grain_key=grain,
            value=numerator / inputs.activity_units, unit=unit,
            currency=currency, input_refs=refs, metadata=basis_meta,
        )

    hours_per_activity = per_activity(
        "LB.HOURS_PER_ACTIVITY",
        inputs.actual_hours,
        "hours_per_activity_unit",
        "ACTUAL_HOURS_MISSING",
    )
    cost_per_activity = per_activity(
        "LB.COST_PER_ACTIVITY",
        inputs.actual_cost,
        "currency_per_activity_unit",
        "ACTUAL_COST_MISSING",
    )

    if inputs.overtime_hours is None:
        overtime_hours = _not_calc(
            calc_id="LB.OVERTIME_HOURS", grain_type="labour", grain_key=grain,
            unit="hours", currency=None, code="OVERTIME_HOURS_MISSING", refs=refs,
        )
    else:
        overtime_hours = calculated_result(
            calc_id="LB.OVERTIME_HOURS", grain_type="labour", grain_key=grain,
            value=inputs.overtime_hours, unit="hours", currency=None,
            input_refs=refs,
        )

    if inputs.overtime_hours is None:
        overtime_rate_effect = _not_calc(
            calc_id="LB.OVERTIME_RATE_EFFECT", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency,
            code="OVERTIME_HOURS_MISSING", refs=refs,
        )
    elif (
        inputs.overtime_actual_rate is None
        or inputs.overtime_comparator_rate is None
    ):
        overtime_rate_effect = _not_calc(
            calc_id="LB.OVERTIME_RATE_EFFECT", grain_type="labour", grain_key=grain,
            unit="currency", currency=currency,
            code="OVERTIME_RATE_EVIDENCE_MISSING", refs=refs,
        )
    else:
        overtime_rate_value = inputs.overtime_hours * (
            inputs.overtime_actual_rate - inputs.overtime_comparator_rate
        )
        overtime_rate_effect = calculated_result(
            calc_id="LB.OVERTIME_RATE_EFFECT", grain_type="labour",
            grain_key=grain, value=overtime_rate_value,
            unit="currency", currency=currency, input_refs=refs,
            raw_delta=overtime_rate_value, profit_effect=-overtime_rate_value,
        )

    return (
        actual_rate,
        comparator_rate,
        hours_effect,
        rate_effect,
        total,
        hours_per_activity,
        cost_per_activity,
        overtime_hours,
        overtime_rate_effect,
    )


def calculate_other_cost(inputs: OtherCostInput) -> tuple[CalcResult, ...]:
    """Quantity/rate bridge for a material cost with explicit evidence only."""
    grain = _key(inputs.grain_key)
    currency = _currency(inputs.currency)
    refs = stable_refs(inputs.input_refs)

    if inputs.actual_cost is None:
        total = _not_calc(
            calc_id="OC.TOTAL_VARIANCE", grain_type="other_cost",
            grain_key=grain, unit="currency", currency=currency,
            code="ACTUAL_COST_MISSING", refs=refs,
        )
    elif inputs.comparator_cost is None:
        total = _not_calc(
            calc_id="OC.TOTAL_VARIANCE", grain_type="other_cost",
            grain_key=grain, unit="currency", currency=currency,
            code="COMPARATOR_COST_MISSING", refs=refs,
        )
    else:
        total_value = inputs.actual_cost - inputs.comparator_cost
        total = calculated_result(
            calc_id="OC.TOTAL_VARIANCE", grain_type="other_cost",
            grain_key=grain, value=total_value, unit="currency",
            currency=currency, input_refs=refs, raw_delta=total_value,
            profit_effect=-total_value,
        )

    quantity_ready = (
        inputs.actual_qty is not None
        and inputs.comparator_qty is not None
        and inputs.comparator_rate is not None
    )
    rate_ready = (
        inputs.actual_qty is not None
        and inputs.actual_rate is not None
        and inputs.comparator_rate is not None
    )

    if quantity_ready:
        assert inputs.actual_qty is not None
        assert inputs.comparator_qty is not None
        assert inputs.comparator_rate is not None
        q_value = (
            inputs.actual_qty - inputs.comparator_qty
        ) * inputs.comparator_rate
        quantity = calculated_result(
            calc_id="OC.QUANTITY_EFFECT", grain_type="other_cost",
            grain_key=grain, value=q_value, unit="currency",
            currency=currency, input_refs=refs, raw_delta=q_value,
            profit_effect=-q_value,
        )
    else:
        quantity = _not_calc(
            calc_id="OC.QUANTITY_EFFECT", grain_type="other_cost",
            grain_key=grain, unit="currency", currency=currency,
            code="QUANTITY_RATE_EVIDENCE_MISSING", refs=refs,
        )

    if rate_ready:
        assert inputs.actual_qty is not None
        assert inputs.actual_rate is not None
        assert inputs.comparator_rate is not None
        r_value = inputs.actual_qty * (
            inputs.actual_rate - inputs.comparator_rate
        )
        rate = calculated_result(
            calc_id="OC.RATE_EFFECT", grain_type="other_cost",
            grain_key=grain, value=r_value, unit="currency",
            currency=currency, input_refs=refs, raw_delta=r_value,
            profit_effect=-r_value,
        )
    else:
        rate = _not_calc(
            calc_id="OC.RATE_EFFECT", grain_type="other_cost",
            grain_key=grain, unit="currency", currency=currency,
            code="QUANTITY_RATE_EVIDENCE_MISSING", refs=refs,
        )

    if (
        quantity.calculation_status == "CALCULATED"
        and rate.calculation_status == "CALCULATED"
        and total.calculation_status == "CALCULATED"
    ):
        assert quantity.value is not None
        assert rate.value is not None
        assert total.value is not None
        if quantity.value + rate.value != total.value:
            raise ArithmeticError(
                "OC quantity/rate decomposition failed exact control identity"
            )

    return quantity, rate, total
