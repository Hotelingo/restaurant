from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from typing import Mapping, Sequence

from .core import calculated_text_result, not_calculated_result, stable_refs
from .model import CalcResult
from .pl import PL_LADDER, results_by_code


@dataclass(frozen=True, slots=True)
class MaterialitySnapshot:
    """Frozen run-level materiality inputs for the P&L sequence."""

    setting_id: str | None
    absolute_threshold: Decimal | None
    percent_threshold: Decimal | None
    approved: bool
    risk_override_enabled: bool

    def __post_init__(self) -> None:
        if self.absolute_threshold is not None and self.absolute_threshold <= 0:
            raise ValueError("absolute_threshold must be positive")
        if self.percent_threshold is not None and not (
            Decimal("0") < self.percent_threshold <= Decimal("1")
        ):
            raise ValueError("percent_threshold must be greater than zero and at most one")


def _optional_decimal(value: object) -> Decimal | None:
    if value is None:
        return None
    if isinstance(value, Decimal):
        return value
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise ValueError(f"Invalid materiality decimal value: {value!r}") from exc


def materiality_snapshot_from_mapping(
    value: Mapping[str, object] | None,
) -> MaterialitySnapshot | None:
    if value is None:
        return None

    return MaterialitySnapshot(
        setting_id=str(value["id"]) if value.get("id") is not None else None,
        absolute_threshold=_optional_decimal(value.get("absolute_threshold")),
        percent_threshold=_optional_decimal(value.get("percent_threshold")),
        approved=value.get("approved_at") is not None,
        risk_override_enabled=bool(value.get("risk_override_enabled", False)),
    )


def _metadata(
    *,
    snapshot: MaterialitySnapshot,
    material: bool,
    selected_code: str | None,
    impact: Decimal | None,
    raw_delta: Decimal | None,
    reason: str | None,
    matched_rules: Sequence[str],
    percentage_ratio: Decimal | None,
) -> tuple[tuple[str, str], ...]:
    return (
        ("material", "true" if material else "false"),
        ("selection_basis", "materiality_only"),
        ("materiality_setting_id", snapshot.setting_id or ""),
        (
            "absolute_threshold",
            format(snapshot.absolute_threshold, "f")
            if snapshot.absolute_threshold is not None
            else "",
        ),
        (
            "percent_threshold",
            format(snapshot.percent_threshold, "f")
            if snapshot.percent_threshold is not None
            else "",
        ),
        ("risk_override_enabled", "true" if snapshot.risk_override_enabled else "false"),
        ("selected_ladder_code", selected_code or ""),
        ("materiality_reason", reason or ""),
        ("matched_rules", "|".join(matched_rules)),
        ("impact", format(impact, "f") if impact is not None else ""),
        ("raw_delta", format(raw_delta, "f") if raw_delta is not None else ""),
        (
            "percentage_ratio",
            format(percentage_ratio, "f") if percentage_ratio is not None else "",
        ),
    )


def first_material_movement(
    variance_results: Sequence[CalcResult],
    comparator_results: Sequence[CalcResult] | None,
    *,
    materiality_snapshot: MaterialitySnapshot | None,
    recurrence_overrides: frozenset[str] = frozenset(),
    risk_overrides: frozenset[str] = frozenset(),
) -> CalcResult:
    """Return the first material P&L movement in the frozen ladder order.

    Materiality is:
      amount_test OR percentage_test OR recurrence_override OR risk_override.

    The output identifies only an economic ladder location and the materiality
    rule(s). It deliberately contains no operating-cause inference.
    """

    if materiality_snapshot is None:
        return not_calculated_result(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            grain_type="sequence",
            grain_key="PL_LADDER",
            unit="ladder_code",
            currency=None,
            explanation_code="MATERIALITY_UNSET",
        )

    if not materiality_snapshot.approved:
        return not_calculated_result(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            grain_type="sequence",
            grain_key="PL_LADDER",
            unit="ladder_code",
            currency=None,
            explanation_code="MATERIALITY_UNCONFIRMED",
        )

    if (
        materiality_snapshot.absolute_threshold is None
        and materiality_snapshot.percent_threshold is None
    ):
        return not_calculated_result(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            grain_type="sequence",
            grain_key="PL_LADDER",
            unit="ladder_code",
            currency=None,
            explanation_code="MATERIALITY_THRESHOLDS_MISSING",
        )

    variance = results_by_code(variance_results)
    if comparator_results is None:
        return not_calculated_result(
            calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
            grain_type="sequence",
            grain_key="PL_LADDER",
            unit="ladder_code",
            currency=None,
            explanation_code="COMPARATOR_NOT_COMMITTED",
            input_refs=stable_refs(*(result.input_refs for result in variance_results)),
        )

    comparator = results_by_code(comparator_results)
    inspected_refs: list[tuple[str, ...]] = []

    for line in PL_LADDER:
        movement = variance.get(line.code)
        comparator_line = comparator.get(line.code)

        if movement is None or comparator_line is None:
            return not_calculated_result(
                calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
                grain_type="sequence",
                grain_key="PL_LADDER",
                unit="ladder_code",
                currency=None,
                explanation_code="SEQUENCE_INPUT_MISSING",
                input_refs=stable_refs(*inspected_refs),
            )

        current_refs = stable_refs(movement.input_refs, comparator_line.input_refs)
        inspected_refs.append(current_refs)

        if (
            movement.calculation_status != "CALCULATED"
            or comparator_line.calculation_status != "CALCULATED"
            or movement.raw_delta is None
            or movement.profit_effect is None
            or comparator_line.value is None
        ):
            return not_calculated_result(
                calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
                grain_type="sequence",
                grain_key="PL_LADDER",
                unit="ladder_code",
                currency=None,
                explanation_code="SEQUENCE_INPUT_NOT_CALCULATED",
                input_refs=stable_refs(*inspected_refs),
            )

        magnitude = abs(movement.raw_delta)
        amount_test = (
            materiality_snapshot.absolute_threshold is not None
            and magnitude >= materiality_snapshot.absolute_threshold
        )

        percentage_ratio: Decimal | None = None
        percentage_test = False
        comparator_magnitude = abs(comparator_line.value)
        if comparator_magnitude != 0:
            percentage_ratio = magnitude / comparator_magnitude
            percentage_test = (
                materiality_snapshot.percent_threshold is not None
                and percentage_ratio >= materiality_snapshot.percent_threshold
            )

        recurrence_test = line.code in recurrence_overrides
        risk_test = (
            materiality_snapshot.risk_override_enabled
            and line.code in risk_overrides
        )

        matched_rules: list[str] = []
        if amount_test:
            matched_rules.append("amount_test")
        if percentage_test:
            matched_rules.append("percentage_test")
        if recurrence_test:
            matched_rules.append("recurrence_override")
        if risk_test:
            matched_rules.append("risk_override")

        if matched_rules:
            return calculated_text_result(
                calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
                grain_type="sequence",
                grain_key="PL_LADDER",
                value_text=line.code,
                unit="ladder_code",
                input_refs=stable_refs(*inspected_refs),
                metadata=_metadata(
                    snapshot=materiality_snapshot,
                    material=True,
                    selected_code=line.code,
                    impact=movement.profit_effect,
                    raw_delta=movement.raw_delta,
                    reason=matched_rules[0],
                    matched_rules=matched_rules,
                    percentage_ratio=percentage_ratio,
                ),
            )

    return calculated_text_result(
        calc_id="SEQ.FIRST_MATERIAL_MOVEMENT",
        grain_type="sequence",
        grain_key="PL_LADDER",
        value_text="NO_MATERIAL_MOVEMENT",
        unit="ladder_code",
        input_refs=stable_refs(*inspected_refs),
        metadata=_metadata(
            snapshot=materiality_snapshot,
            material=False,
            selected_code=None,
            impact=None,
            raw_delta=None,
            reason=None,
            matched_rules=(),
            percentage_ratio=None,
        ),
    )
