from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal, Mapping, Sequence

from .core import stable_refs
from .model import CalcResult
from .pl import PL_LADDER, results_by_code

MaterialityRule = Literal[
    "amount_test",
    "percentage_test",
    "recurrence_override",
    "risk_override",
]
SequenceStatus = Literal["CALCULATED", "NOT_CALCULATED"]


@dataclass(frozen=True, slots=True)
class MaterialitySnapshot:
    """Versioned materiality inputs frozen into a calculation run."""

    snapshot_id: str
    absolute_threshold: Decimal | None
    percentage_threshold: Decimal | None
    confirmed: bool
    risk_override_enabled: bool = False
    source_kind: str | None = None

    def __post_init__(self) -> None:
        if not self.snapshot_id.strip():
            raise ValueError("materiality snapshot_id is required")
        if self.absolute_threshold is not None:
            if not isinstance(self.absolute_threshold, Decimal):
                raise TypeError("absolute_threshold must be Decimal or None")
            if self.absolute_threshold < 0:
                raise ValueError("absolute_threshold cannot be negative")
        if self.percentage_threshold is not None:
            if not isinstance(self.percentage_threshold, Decimal):
                raise TypeError("percentage_threshold must be Decimal or None")
            if self.percentage_threshold < 0:
                raise ValueError("percentage_threshold cannot be negative")


@dataclass(frozen=True, slots=True)
class MaterialityOverrides:
    recurrence_override: bool = False
    risk_override: bool = False


@dataclass(frozen=True, slots=True)
class MaterialityEvaluation:
    line_code: str
    impact: Decimal
    comparator_value: Decimal | None
    movement_pct: Decimal | None
    material: bool
    reasons: tuple[MaterialityRule, ...]


@dataclass(frozen=True, slots=True)
class FirstMaterialMovement:
    calc_id: str
    calculation_status: SequenceStatus
    first_ladder_code: str | None
    impact: Decimal | None
    movement_pct: Decimal | None
    materiality_reasons: tuple[MaterialityRule, ...]
    materiality_snapshot_id: str | None
    explanation_code: str | None
    evaluated_line_codes: tuple[str, ...]
    input_refs: tuple[str, ...]


def evaluate_materiality(
    *,
    line_code: str,
    impact: Decimal,
    comparator_value: Decimal | None,
    snapshot: MaterialitySnapshot,
    overrides: MaterialityOverrides = MaterialityOverrides(),
) -> MaterialityEvaluation:
    """Apply the accepted OR materiality rule and retain every rule that fired."""
    if not isinstance(impact, Decimal):
        raise TypeError("materiality impact must be Decimal")
    if comparator_value is not None and not isinstance(comparator_value, Decimal):
        raise TypeError("comparator_value must be Decimal or None")

    reasons: list[MaterialityRule] = []
    movement_pct: Decimal | None = None

    if (
        snapshot.absolute_threshold is not None
        and abs(impact) >= snapshot.absolute_threshold
    ):
        reasons.append("amount_test")

    if (
        snapshot.percentage_threshold is not None
        and comparator_value is not None
        and comparator_value != 0
    ):
        movement_pct = abs(impact) / abs(comparator_value)
        if movement_pct >= snapshot.percentage_threshold:
            reasons.append("percentage_test")

    if overrides.recurrence_override:
        reasons.append("recurrence_override")

    if snapshot.risk_override_enabled and overrides.risk_override:
        reasons.append("risk_override")

    return MaterialityEvaluation(
        line_code=line_code,
        impact=impact,
        comparator_value=comparator_value,
        movement_pct=movement_pct,
        material=bool(reasons),
        reasons=tuple(reasons),
    )


def first_material_movement(
    variance_results: Sequence[CalcResult],
    comparator_results: Sequence[CalcResult] | None,
    *,
    snapshot: MaterialitySnapshot | None,
    overrides_by_line: Mapping[str, MaterialityOverrides] | None = None,
) -> FirstMaterialMovement:
    """Walk the Management P&L ladder and return its first material movement.

    This function identifies only a location in the economic stairwell. It
    deliberately contains no operating-cause taxonomy or diagnostic language.
    """
    if snapshot is None:
        return FirstMaterialMovement(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            calculation_status="NOT_CALCULATED",
            first_ladder_code=None,
            impact=None,
            movement_pct=None,
            materiality_reasons=(),
            materiality_snapshot_id=None,
            explanation_code="MATERIALITY_NOT_CONFIGURED",
            evaluated_line_codes=(),
            input_refs=(),
        )

    if not snapshot.confirmed:
        return FirstMaterialMovement(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            calculation_status="NOT_CALCULATED",
            first_ladder_code=None,
            impact=None,
            movement_pct=None,
            materiality_reasons=(),
            materiality_snapshot_id=snapshot.snapshot_id,
            explanation_code="MATERIALITY_NOT_CONFIRMED",
            evaluated_line_codes=(),
            input_refs=(),
        )

    overrides = dict(overrides_by_line or {})
    valid_codes = {line.code for line in PL_LADDER}
    unknown_override_codes = set(overrides) - valid_codes
    if unknown_override_codes:
        raise ValueError(
            f"Unknown P&L override line codes: {sorted(unknown_override_codes)}"
        )

    variance = results_by_code(variance_results)
    comparator = (
        results_by_code(comparator_results)
        if comparator_results is not None
        else {}
    )

    evaluated: list[str] = []
    refs: tuple[str, ...] = ()

    for line in PL_LADDER:
        movement = variance.get(line.code)
        if movement is None or movement.calculation_status != "CALCULATED":
            continue
        if movement.profit_effect is None:
            raise ValueError(
                f"Calculated variance {movement.calc_id} is missing profit_effect"
            )

        comparator_result = comparator.get(line.code)
        comparator_value: Decimal | None = None
        comparator_refs: tuple[str, ...] = ()
        if (
            comparator_result is not None
            and comparator_result.calculation_status == "CALCULATED"
        ):
            comparator_value = comparator_result.value
            comparator_refs = comparator_result.input_refs

        evaluated.append(line.code)
        refs = stable_refs(refs, movement.input_refs, comparator_refs)

        result = evaluate_materiality(
            line_code=line.code,
            impact=movement.profit_effect,
            comparator_value=comparator_value,
            snapshot=snapshot,
            overrides=overrides.get(line.code, MaterialityOverrides()),
        )
        if result.material:
            return FirstMaterialMovement(
                calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
                calculation_status="CALCULATED",
                first_ladder_code=line.code,
                impact=result.impact,
                movement_pct=result.movement_pct,
                materiality_reasons=result.reasons,
                materiality_snapshot_id=snapshot.snapshot_id,
                explanation_code=None,
                evaluated_line_codes=tuple(evaluated),
                input_refs=refs,
            )

    if not evaluated:
        return FirstMaterialMovement(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            calculation_status="NOT_CALCULATED",
            first_ladder_code=None,
            impact=None,
            movement_pct=None,
            materiality_reasons=(),
            materiality_snapshot_id=snapshot.snapshot_id,
            explanation_code="NO_CALCULATED_VARIANCES",
            evaluated_line_codes=(),
            input_refs=(),
        )

    return FirstMaterialMovement(
        calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
        calculation_status="CALCULATED",
        first_ladder_code=None,
        impact=None,
        movement_pct=None,
        materiality_reasons=(),
        materiality_snapshot_id=snapshot.snapshot_id,
        explanation_code=None,
        evaluated_line_codes=tuple(evaluated),
        input_refs=refs,
    )
