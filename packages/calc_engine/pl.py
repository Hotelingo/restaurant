from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal, Mapping, Sequence

from .core import calculated_result, not_calculated_result, stable_refs
from .model import CalcResult

LineKind = Literal["revenue_profit", "cost"]


@dataclass(frozen=True, slots=True)
class LadderLine:
    code: str
    calc_id: str
    kind: LineKind
    source: bool
    dependencies: tuple[str, ...] = ()


PL_LADDER: tuple[LadderLine, ...] = (
    LadderLine("NET_SALES", "PL.NET_SALES", "revenue_profit", True),
    LadderLine("PRODUCT_COST", "PL.PRODUCT_COST", "cost", True),
    LadderLine("PRODUCT_MARGIN", "PL.PRODUCT_MARGIN", "revenue_profit", False, ("NET_SALES", "PRODUCT_COST")),
    LadderLine("CHANNEL_COST", "PL.CHANNEL_COST", "cost", True),
    LadderLine("DIRECT_LABOUR", "PL.DIRECT_LABOUR", "cost", True),
    LadderLine("OTHER_DIRECT_OPERATING", "PL.OTHER_DIRECT_OPERATING", "cost", True),
    LadderLine(
        "CONTRIBUTION",
        "PL.CONTRIBUTION",
        "revenue_profit",
        False,
        ("PRODUCT_MARGIN", "CHANNEL_COST", "DIRECT_LABOUR", "OTHER_DIRECT_OPERATING"),
    ),
    LadderLine("SHARED_COST", "PL.SHARED_COST", "cost", True),
    LadderLine("OPERATING_PROFIT", "PL.OPERATING_PROFIT", "revenue_profit", False, ("CONTRIBUTION", "SHARED_COST")),
    LadderLine("OWNER_STRUCTURAL_COST", "PL.OWNER_STRUCTURAL_COST", "cost", True),
    LadderLine("OWNER_RESULT", "PL.OWNER_RESULT", "revenue_profit", False, ("OPERATING_PROFIT", "OWNER_STRUCTURAL_COST")),
)

_LINE_BY_CODE = {line.code: line for line in PL_LADDER}
_SOURCE_CODES = frozenset(line.code for line in PL_LADDER if line.source)


def _normalise_currency(currency: str) -> str:
    value = currency.strip().upper()
    if len(value) != 3 or not value.isalpha():
        raise ValueError("currency must be a three-letter ISO-style code")
    return value


def _validate_source_values(source_values: Mapping[str, Decimal]) -> None:
    unknown = set(source_values) - _SOURCE_CODES
    if unknown:
        raise ValueError(f"Unknown or calculated P&L source codes: {sorted(unknown)}")
    for code, value in source_values.items():
        if not isinstance(value, Decimal):
            raise TypeError(f"P&L source value for {code} must be Decimal")


def _refs_for(code: str, input_refs: Mapping[str, Sequence[str]] | None) -> tuple[str, ...]:
    if not input_refs:
        return ()
    return stable_refs(input_refs.get(code, ()))


def _derive(code: str, results: Mapping[str, CalcResult], *, currency: str) -> CalcResult:
    line = _LINE_BY_CODE[code]
    deps = [results[key] for key in line.dependencies]
    refs = stable_refs(*(dep.input_refs for dep in deps))

    if any(dep.calculation_status != "CALCULATED" for dep in deps):
        return not_calculated_result(
            calc_id=line.calc_id,
            grain_type="management_pl",
            grain_key=line.code,
            unit="currency",
            currency=currency,
            explanation_code="DEPENDENCY_NOT_CALCULATED",
            input_refs=refs,
            metadata=(("line_kind", line.kind),),
        )

    values = [dep.value for dep in deps]
    if any(value is None for value in values):
        raise AssertionError("CALCULATED dependency unexpectedly has no value")
    decimals = [value for value in values if value is not None]

    if code == "PRODUCT_MARGIN":
        value = decimals[0] - decimals[1]
    elif code == "CONTRIBUTION":
        value = decimals[0] - decimals[1] - decimals[2] - decimals[3]
    elif code == "OPERATING_PROFIT":
        value = decimals[0] - decimals[1]
    elif code == "OWNER_RESULT":
        value = decimals[0] - decimals[1]
    else:
        raise AssertionError(f"No formula registered for calculated P&L line {code}")

    return calculated_result(
        calc_id=line.calc_id,
        grain_type="management_pl",
        grain_key=line.code,
        value=value,
        unit="currency",
        currency=currency,
        input_refs=refs,
        metadata=(("line_kind", line.kind),),
    )


def calculate_pl_ladder(
    source_values: Mapping[str, Decimal],
    *,
    currency: str,
    input_refs: Mapping[str, Sequence[str]] | None = None,
) -> tuple[CalcResult, ...]:
    """Calculate the stable eleven-line Management P&L ladder.

    Inputs are canonical positive expense magnitudes keyed by non-calculated
    ladder code. Missing source lines remain explicit NOT_CALCULATED states.
    """
    _validate_source_values(source_values)
    currency_code = _normalise_currency(currency)
    results: dict[str, CalcResult] = {}

    for line in PL_LADDER:
        if line.source:
            value = source_values.get(line.code)
            refs = _refs_for(line.code, input_refs)
            if value is None:
                result = not_calculated_result(
                    calc_id=line.calc_id,
                    grain_type="management_pl",
                    grain_key=line.code,
                    unit="currency",
                    currency=currency_code,
                    explanation_code="INPUT_MISSING",
                    input_refs=refs,
                    metadata=(("line_kind", line.kind),),
                )
            else:
                result = calculated_result(
                    calc_id=line.calc_id,
                    grain_type="management_pl",
                    grain_key=line.code,
                    value=value,
                    unit="currency",
                    currency=currency_code,
                    input_refs=refs,
                    metadata=(("line_kind", line.kind),),
                )
        else:
            result = _derive(line.code, results, currency=currency_code)

        results[line.code] = result

    return tuple(results[line.code] for line in PL_LADDER)


def results_by_code(results: Sequence[CalcResult]) -> dict[str, CalcResult]:
    mapped = {result.grain_key: result for result in results}
    if len(mapped) != len(results):
        raise ValueError("Duplicate P&L grain_key in result set")
    return mapped


def calculate_pl_variances(
    actual_results: Sequence[CalcResult],
    comparator_results: Sequence[CalcResult] | None,
    *,
    currency: str,
) -> tuple[CalcResult, ...]:
    """Return PL.VAR.* results with raw_delta and favourable-positive profit_effect."""
    currency_code = _normalise_currency(currency)
    actual = results_by_code(actual_results)

    if comparator_results is None:
        output: list[CalcResult] = []
        for line in PL_LADDER:
            actual_result = actual.get(line.code)
            output.append(
                not_calculated_result(
                    calc_id=f"PL.VAR.{line.code}",
                    grain_type="management_pl_variance",
                    grain_key=line.code,
                    unit="currency",
                    currency=currency_code,
                    explanation_code="COMPARATOR_NOT_COMMITTED",
                    input_refs=actual_result.input_refs if actual_result else (),
                    metadata=(("line_kind", line.kind),),
                )
            )
        return tuple(output)

    comparator = results_by_code(comparator_results)
    output = []

    for line in PL_LADDER:
        actual_result = actual.get(line.code)
        comparator_result = comparator.get(line.code)

        if actual_result is None or actual_result.calculation_status != "CALCULATED":
            output.append(
                not_calculated_result(
                    calc_id=f"PL.VAR.{line.code}",
                    grain_type="management_pl_variance",
                    grain_key=line.code,
                    unit="currency",
                    currency=currency_code,
                    explanation_code="ACTUAL_LINE_NOT_CALCULATED",
                    input_refs=actual_result.input_refs if actual_result else (),
                    metadata=(("line_kind", line.kind),),
                )
            )
            continue

        if comparator_result is None or comparator_result.calculation_status != "CALCULATED":
            output.append(
                not_calculated_result(
                    calc_id=f"PL.VAR.{line.code}",
                    grain_type="management_pl_variance",
                    grain_key=line.code,
                    unit="currency",
                    currency=currency_code,
                    explanation_code="COMPARATOR_LINE_NOT_CALCULATED",
                    input_refs=stable_refs(
                        actual_result.input_refs,
                        comparator_result.input_refs if comparator_result else (),
                    ),
                    metadata=(("line_kind", line.kind),),
                )
            )
            continue

        if actual_result.value is None or comparator_result.value is None:
            raise AssertionError("CALCULATED P&L result unexpectedly has no value")

        raw_delta = actual_result.value - comparator_result.value
        profit_effect = -raw_delta if line.kind == "cost" else raw_delta

        output.append(
            calculated_result(
                calc_id=f"PL.VAR.{line.code}",
                grain_type="management_pl_variance",
                grain_key=line.code,
                value=profit_effect,
                unit="currency",
                currency=currency_code,
                input_refs=stable_refs(actual_result.input_refs, comparator_result.input_refs),
                raw_delta=raw_delta,
                profit_effect=profit_effect,
                metadata=(("line_kind", line.kind),),
            )
        )

    return tuple(output)
