from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP
from typing import Iterable

from .model import CalcResult


def stable_refs(*groups: Iterable[str]) -> tuple[str, ...]:
    """Deduplicate references while preserving deterministic first-seen order."""
    seen: set[str] = set()
    result: list[str] = []
    for group in groups:
        for ref in group:
            if ref not in seen:
                seen.add(ref)
                result.append(ref)
    return tuple(result)


def calculated_result(
    *,
    calc_id: str,
    grain_type: str,
    grain_key: str,
    value: Decimal,
    unit: str,
    currency: str | None,
    input_refs: tuple[str, ...] = (),
    raw_delta: Decimal | None = None,
    profit_effect: Decimal | None = None,
    metadata: tuple[tuple[str, str], ...] = (),
) -> CalcResult:
    if not isinstance(value, Decimal):
        raise TypeError("Calculation values must be Decimal")
    if raw_delta is not None and not isinstance(raw_delta, Decimal):
        raise TypeError("raw_delta must be Decimal")
    if profit_effect is not None and not isinstance(profit_effect, Decimal):
        raise TypeError("profit_effect must be Decimal")

    return CalcResult(
        calc_id=calc_id,
        grain_type=grain_type,
        grain_key=grain_key,
        value=value,
        unit=unit,
        currency=currency,
        calculation_status="CALCULATED",
        evidence_status="supported",
        explanation_code=None,
        input_refs=input_refs,
        raw_delta=raw_delta,
        profit_effect=profit_effect,
        metadata=metadata,
    )


def not_calculated_result(
    *,
    calc_id: str,
    grain_type: str,
    grain_key: str,
    unit: str,
    currency: str | None,
    explanation_code: str,
    input_refs: tuple[str, ...] = (),
    metadata: tuple[tuple[str, str], ...] = (),
) -> CalcResult:
    return CalcResult(
        calc_id=calc_id,
        grain_type=grain_type,
        grain_key=grain_key,
        value=None,
        unit=unit,
        currency=currency,
        calculation_status="NOT_CALCULATED",
        evidence_status="evidence_required",
        explanation_code=explanation_code,
        input_refs=input_refs,
        metadata=metadata,
    )


def ratio_result(
    *,
    calc_id: str,
    grain_type: str,
    grain_key: str,
    numerator: Decimal | None,
    denominator: Decimal | None,
    input_refs: tuple[str, ...] = (),
) -> CalcResult:
    """Safe ratio helper: missing/zero denominators are never numeric zero."""
    if numerator is not None and not isinstance(numerator, Decimal):
        raise TypeError("Ratio numerator must be Decimal or None")
    if denominator is not None and not isinstance(denominator, Decimal):
        raise TypeError("Ratio denominator must be Decimal or None")

    if numerator is None:
        return not_calculated_result(
            calc_id=calc_id,
            grain_type=grain_type,
            grain_key=grain_key,
            unit="ratio",
            currency=None,
            explanation_code="NUMERATOR_MISSING",
            input_refs=input_refs,
        )
    if denominator is None:
        return not_calculated_result(
            calc_id=calc_id,
            grain_type=grain_type,
            grain_key=grain_key,
            unit="ratio",
            currency=None,
            explanation_code="DENOMINATOR_MISSING",
            input_refs=input_refs,
        )
    if denominator == 0:
        return not_calculated_result(
            calc_id=calc_id,
            grain_type=grain_type,
            grain_key=grain_key,
            unit="ratio",
            currency=None,
            explanation_code="DENOMINATOR_ZERO",
            input_refs=input_refs,
        )

    return calculated_result(
        calc_id=calc_id,
        grain_type=grain_type,
        grain_key=grain_key,
        value=numerator / denominator,
        unit="ratio",
        currency=None,
        input_refs=input_refs,
    )


def quantize_money_for_presentation(
    value: Decimal,
    *,
    minor_unit: Decimal,
) -> Decimal:
    """Explicit presentation-only ROUND_HALF_UP quantisation."""
    if not isinstance(value, Decimal) or not isinstance(minor_unit, Decimal):
        raise TypeError("value and minor_unit must be Decimal")
    if minor_unit <= 0:
        raise ValueError("minor_unit must be positive")
    return value.quantize(minor_unit, rounding=ROUND_HALF_UP)
