from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

from .food_cost import FoodCostDriverImpact, SUPPORTED_DRIVER_STATUSES
from .model import CalcResult
from .core import stable_refs


C02EvidenceStatus = Literal[
    "validated",
    "supported",
    "partly_supported",
    "evidence_required",
    "not_reconciled",
    "not_applicable",
]

TRANSFER_CLASSIFICATIONS = frozenset(
    {"external_transfer", "approved_nonrevenue", "internal_transfer"}
)


def _key(value: str, field_name: str) -> str:
    cleaned = value.strip()
    if not cleaned:
        raise ValueError(f"{field_name} cannot be blank")
    return cleaned


def _currency(value: str) -> str:
    code = value.strip().upper()
    if len(code) != 3 or not code.isalpha():
        raise ValueError("currency must be a three-letter ISO-style code")
    return code


def _optional_decimal(
    field_name: str,
    value: Decimal | None,
    *,
    nonnegative: bool = True,
) -> None:
    if value is not None and not isinstance(value, Decimal):
        raise TypeError(f"{field_name} must be Decimal or None")
    if nonnegative and value is not None and value < 0:
        raise ValueError(f"{field_name} cannot be negative")


def _status(value: str) -> str:
    if value not in {
        "validated",
        "supported",
        "partly_supported",
        "evidence_required",
        "not_reconciled",
        "not_applicable",
    }:
        raise ValueError("unsupported C02 evidence status")
    return value


def _metadata(
    *,
    coverage_key: str,
    evidence_status: str,
    pairs: tuple[tuple[str, str], ...] = (),
) -> tuple[tuple[str, str], ...]:
    return (
        ("coverage_key", coverage_key),
        ("source_evidence_status", evidence_status),
        *pairs,
    )


def _not_calculated(
    *,
    calc_id: str,
    grain_key: str,
    currency: str,
    explanation_code: str,
    coverage_key: str,
    evidence_status: str,
    input_refs: tuple[str, ...],
    metadata: tuple[tuple[str, str], ...] = (),
) -> CalcResult:
    return CalcResult(
        calc_id=calc_id,
        grain_type="food_cost_driver",
        grain_key=grain_key,
        value=None,
        value_text=None,
        unit="currency",
        currency=currency,
        calculation_status="NOT_CALCULATED",
        evidence_status="evidence_required",
        explanation_code=explanation_code,
        input_refs=stable_refs(input_refs),
        metadata=_metadata(
            coverage_key=coverage_key,
            evidence_status=evidence_status,
            pairs=metadata,
        ),
    )


def _calculated(
    *,
    calc_id: str,
    grain_key: str,
    currency: str,
    impact: Decimal,
    coverage_key: str,
    evidence_status: str,
    input_refs: tuple[str, ...],
    metadata: tuple[tuple[str, str], ...],
) -> CalcResult:
    if evidence_status not in SUPPORTED_DRIVER_STATUSES:
        raise ValueError("quantified C02 driver requires supported or validated evidence")
    return CalcResult(
        calc_id=calc_id,
        grain_type="food_cost_driver",
        grain_key=grain_key,
        value=impact,
        value_text=None,
        unit="currency",
        currency=currency,
        calculation_status="CALCULATED",
        evidence_status=evidence_status,
        explanation_code=None,
        input_refs=stable_refs(input_refs),
        raw_delta=impact,
        profit_effect=-impact,
        metadata=_metadata(
            coverage_key=coverage_key,
            evidence_status=evidence_status,
            pairs=metadata,
        ),
    )


def _evidence_ready(
    *,
    calc_id: str,
    grain_key: str,
    currency: str,
    coverage_key: str,
    evidence_status: str,
    input_refs: tuple[str, ...],
) -> CalcResult | None:
    if evidence_status in SUPPORTED_DRIVER_STATUSES:
        return None
    return _not_calculated(
        calc_id=calc_id,
        grain_key=grain_key,
        currency=currency,
        explanation_code="DRIVER_EVIDENCE_NOT_SUPPORTED",
        coverage_key=coverage_key,
        evidence_status=evidence_status,
        input_refs=input_refs,
    )


@dataclass(frozen=True, slots=True)
class YieldTestInput:
    grain_key: str
    ap_quantity: Decimal | None
    approved_yield: Decimal | None
    observed_usable_quantity: Decimal | None
    approved_usable_unit_cost: Decimal | None
    currency: str
    evidence_status: C02EvidenceStatus
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key, "grain_key")
        _key(self.coverage_key, "coverage_key")
        _currency(self.currency)
        _status(self.evidence_status)
        for name in (
            "ap_quantity",
            "approved_yield",
            "observed_usable_quantity",
            "approved_usable_unit_cost",
        ):
            _optional_decimal(name, getattr(self, name))
        if self.approved_yield is not None and self.approved_yield > 1:
            raise ValueError("approved_yield must be a ratio from 0 to 1")


@dataclass(frozen=True, slots=True)
class PortionTestInput:
    grain_key: str
    approved_portion: Decimal | None
    observed_avg_portion: Decimal | None
    representative_portions: Decimal | None
    approved_usable_unit_cost: Decimal | None
    currency: str
    evidence_status: C02EvidenceStatus
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key, "grain_key")
        _key(self.coverage_key, "coverage_key")
        _currency(self.currency)
        _status(self.evidence_status)
        for name in (
            "approved_portion",
            "observed_avg_portion",
            "representative_portions",
            "approved_usable_unit_cost",
        ):
            _optional_decimal(name, getattr(self, name))


@dataclass(frozen=True, slots=True)
class ProductionTestInput:
    grain_key: str
    produced_quantity: Decimal | None
    served_quantity: Decimal | None
    closing_usable_quantity: Decimal | None
    documented_nonrevenue_quantity: Decimal | None
    approved_usable_unit_cost: Decimal | None
    currency: str
    evidence_status: C02EvidenceStatus
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key, "grain_key")
        _key(self.coverage_key, "coverage_key")
        _currency(self.currency)
        _status(self.evidence_status)
        for name in (
            "produced_quantity",
            "served_quantity",
            "closing_usable_quantity",
            "documented_nonrevenue_quantity",
            "approved_usable_unit_cost",
        ):
            _optional_decimal(name, getattr(self, name))


@dataclass(frozen=True, slots=True)
class WasteTestInput:
    grain_key: str
    quantity: Decimal | None
    unit_cost: Decimal | None
    reason_code: str
    already_in_approved_standard: bool
    currency: str
    evidence_status: C02EvidenceStatus
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key, "grain_key")
        _key(self.coverage_key, "coverage_key")
        _key(self.reason_code, "reason_code")
        _currency(self.currency)
        _status(self.evidence_status)
        _optional_decimal("quantity", self.quantity)
        _optional_decimal("unit_cost", self.unit_cost)


@dataclass(frozen=True, slots=True)
class TransferNonRevenueTestInput:
    grain_key: str
    quantity: Decimal | None
    unit_cost: Decimal | None
    movement_classification: str
    currency: str
    evidence_status: C02EvidenceStatus
    coverage_key: str
    input_refs: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        _key(self.grain_key, "grain_key")
        _key(self.coverage_key, "coverage_key")
        _currency(self.currency)
        _status(self.evidence_status)
        _optional_decimal("quantity", self.quantity)
        _optional_decimal("unit_cost", self.unit_cost)
        if self.movement_classification not in TRANSFER_CLASSIFICATIONS:
            raise ValueError(
                "movement_classification must be external_transfer, "
                "approved_nonrevenue or internal_transfer"
            )


def calculate_yield_driver(inputs: YieldTestInput) -> CalcResult:
    calc_id = "FC.DRIVER.YIELD"
    grain = _key(inputs.grain_key, "grain_key")
    coverage = _key(inputs.coverage_key, "coverage_key")
    currency = _currency(inputs.currency)
    evidence_status = _status(inputs.evidence_status)
    evidence_gap = _evidence_ready(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
    )
    if evidence_gap is not None:
        return evidence_gap

    for value, code in (
        (inputs.ap_quantity, "AP_QUANTITY_MISSING"),
        (inputs.approved_yield, "APPROVED_YIELD_MISSING"),
        (inputs.observed_usable_quantity, "OBSERVED_USABLE_QUANTITY_MISSING"),
        (inputs.approved_usable_unit_cost, "APPROVED_USABLE_UNIT_COST_MISSING"),
    ):
        if value is None:
            return _not_calculated(
                calc_id=calc_id,
                grain_key=grain,
                currency=currency,
                explanation_code=code,
                coverage_key=coverage,
                evidence_status=evidence_status,
                input_refs=inputs.input_refs,
            )

    assert inputs.ap_quantity is not None
    assert inputs.approved_yield is not None
    assert inputs.observed_usable_quantity is not None
    assert inputs.approved_usable_unit_cost is not None

    if inputs.ap_quantity == 0:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="AP_QUANTITY_ZERO",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )
    if inputs.approved_yield == 0:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="APPROVED_YIELD_ZERO",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )

    theoretical_usable = inputs.ap_quantity * inputs.approved_yield
    actual_yield = inputs.observed_usable_quantity / inputs.ap_quantity
    usable_shortfall = theoretical_usable - inputs.observed_usable_quantity
    impact = usable_shortfall * inputs.approved_usable_unit_cost

    return _calculated(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        impact=impact,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
        metadata=(
            ("formula", "(AP_QTY*APPROVED_YIELD-OBSERVED_USABLE_QTY)*APPROVED_USABLE_UNIT_COST"),
            ("ap_quantity", format(inputs.ap_quantity, "f")),
            ("approved_yield", format(inputs.approved_yield, "f")),
            ("actual_yield", format(actual_yield, "f")),
            ("theoretical_usable_quantity", format(theoretical_usable, "f")),
            ("observed_usable_quantity", format(inputs.observed_usable_quantity, "f")),
            ("usable_shortfall", format(usable_shortfall, "f")),
            ("approved_usable_unit_cost", format(inputs.approved_usable_unit_cost, "f")),
        ),
    )


def calculate_portion_driver(inputs: PortionTestInput) -> CalcResult:
    calc_id = "FC.DRIVER.PORTION"
    grain = _key(inputs.grain_key, "grain_key")
    coverage = _key(inputs.coverage_key, "coverage_key")
    currency = _currency(inputs.currency)
    evidence_status = _status(inputs.evidence_status)
    evidence_gap = _evidence_ready(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
    )
    if evidence_gap is not None:
        return evidence_gap

    for value, code in (
        (inputs.approved_portion, "APPROVED_PORTION_MISSING"),
        (inputs.observed_avg_portion, "OBSERVED_AVG_PORTION_MISSING"),
        (inputs.representative_portions, "REPRESENTATIVE_PORTIONS_MISSING"),
        (inputs.approved_usable_unit_cost, "APPROVED_USABLE_UNIT_COST_MISSING"),
    ):
        if value is None:
            return _not_calculated(
                calc_id=calc_id,
                grain_key=grain,
                currency=currency,
                explanation_code=code,
                coverage_key=coverage,
                evidence_status=evidence_status,
                input_refs=inputs.input_refs,
            )

    assert inputs.approved_portion is not None
    assert inputs.observed_avg_portion is not None
    assert inputs.representative_portions is not None
    assert inputs.approved_usable_unit_cost is not None

    if inputs.approved_portion == 0:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="APPROVED_PORTION_ZERO",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )

    excess_per_portion = inputs.observed_avg_portion - inputs.approved_portion
    variance_ratio = excess_per_portion / inputs.approved_portion
    supported_excess_usage = excess_per_portion * inputs.representative_portions
    impact = supported_excess_usage * inputs.approved_usable_unit_cost

    return _calculated(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        impact=impact,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
        metadata=(
            ("formula", "(OBSERVED_AVG_PORTION-APPROVED_PORTION)*REPRESENTATIVE_PORTIONS*APPROVED_USABLE_UNIT_COST"),
            ("approved_portion", format(inputs.approved_portion, "f")),
            ("observed_avg_portion", format(inputs.observed_avg_portion, "f")),
            ("portion_variance", format(excess_per_portion, "f")),
            ("portion_variance_ratio", format(variance_ratio, "f")),
            ("representative_portions", format(inputs.representative_portions, "f")),
            ("supported_excess_usage", format(supported_excess_usage, "f")),
            ("approved_usable_unit_cost", format(inputs.approved_usable_unit_cost, "f")),
        ),
    )


def calculate_production_driver(inputs: ProductionTestInput) -> CalcResult:
    calc_id = "FC.DRIVER.PRODUCTION"
    grain = _key(inputs.grain_key, "grain_key")
    coverage = _key(inputs.coverage_key, "coverage_key")
    currency = _currency(inputs.currency)
    evidence_status = _status(inputs.evidence_status)
    evidence_gap = _evidence_ready(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
    )
    if evidence_gap is not None:
        return evidence_gap

    for value, code in (
        (inputs.produced_quantity, "PRODUCED_QUANTITY_MISSING"),
        (inputs.served_quantity, "SERVED_QUANTITY_MISSING"),
        (inputs.closing_usable_quantity, "CLOSING_USABLE_QUANTITY_MISSING"),
        (
            inputs.documented_nonrevenue_quantity,
            "DOCUMENTED_NONREVENUE_QUANTITY_MISSING",
        ),
        (inputs.approved_usable_unit_cost, "APPROVED_USABLE_UNIT_COST_MISSING"),
    ):
        if value is None:
            return _not_calculated(
                calc_id=calc_id,
                grain_key=grain,
                currency=currency,
                explanation_code=code,
                coverage_key=coverage,
                evidence_status=evidence_status,
                input_refs=inputs.input_refs,
            )

    assert inputs.produced_quantity is not None
    assert inputs.served_quantity is not None
    assert inputs.closing_usable_quantity is not None
    assert inputs.documented_nonrevenue_quantity is not None
    assert inputs.approved_usable_unit_cost is not None

    unaccounted = (
        inputs.produced_quantity
        - inputs.served_quantity
        - inputs.closing_usable_quantity
        - inputs.documented_nonrevenue_quantity
    )
    if unaccounted < 0:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="PRODUCTION_BALANCE_NEGATIVE",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
            metadata=(("unaccounted_quantity", format(unaccounted, "f")),),
        )

    impact = unaccounted * inputs.approved_usable_unit_cost
    return _calculated(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        impact=impact,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
        metadata=(
            ("formula", "(PRODUCED-SERVED-CLOSING_USABLE-DOCUMENTED_NONREVENUE)*APPROVED_USABLE_UNIT_COST"),
            ("produced_quantity", format(inputs.produced_quantity, "f")),
            ("served_quantity", format(inputs.served_quantity, "f")),
            ("closing_usable_quantity", format(inputs.closing_usable_quantity, "f")),
            (
                "documented_nonrevenue_quantity",
                format(inputs.documented_nonrevenue_quantity, "f"),
            ),
            ("unaccounted_quantity", format(unaccounted, "f")),
            ("approved_usable_unit_cost", format(inputs.approved_usable_unit_cost, "f")),
            (
                "interpretation",
                "explicit_production_balance_not_inferred_from_financial_amounts",
            ),
        ),
    )


def calculate_waste_driver(inputs: WasteTestInput) -> CalcResult:
    calc_id = "FC.DRIVER.WASTE"
    grain = _key(inputs.grain_key, "grain_key")
    coverage = _key(inputs.coverage_key, "coverage_key")
    currency = _currency(inputs.currency)
    evidence_status = _status(inputs.evidence_status)
    evidence_gap = _evidence_ready(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
    )
    if evidence_gap is not None:
        return evidence_gap

    if inputs.already_in_approved_standard:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="LOSS_ALREADY_IN_APPROVED_STANDARD",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
            metadata=(("reason_code", inputs.reason_code.strip()),),
        )

    if inputs.quantity is None:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="WASTE_QUANTITY_MISSING",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )
    if inputs.unit_cost is None:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="WASTE_UNIT_COST_MISSING",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )

    impact = inputs.quantity * inputs.unit_cost
    return _calculated(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        impact=impact,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
        metadata=(
            ("formula", "REASON_CODED_QUANTITY*SUPPORTED_UNIT_COST"),
            ("quantity", format(inputs.quantity, "f")),
            ("unit_cost", format(inputs.unit_cost, "f")),
            ("reason_code", inputs.reason_code.strip()),
            ("already_in_approved_standard", "false"),
        ),
    )


def calculate_transfer_nonrevenue_driver(
    inputs: TransferNonRevenueTestInput,
) -> CalcResult:
    calc_id = "FC.DRIVER.TRANSFER_NONREVENUE"
    grain = _key(inputs.grain_key, "grain_key")
    coverage = _key(inputs.coverage_key, "coverage_key")
    currency = _currency(inputs.currency)
    evidence_status = _status(inputs.evidence_status)
    evidence_gap = _evidence_ready(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
    )
    if evidence_gap is not None:
        return evidence_gap

    if inputs.movement_classification == "internal_transfer":
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="INTERNAL_TRANSFER_WITHIN_REVIEW_BOUNDARY",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
            metadata=(("movement_classification", "internal_transfer"),),
        )

    if inputs.quantity is None:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="TRANSFER_QUANTITY_MISSING",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )
    if inputs.unit_cost is None:
        return _not_calculated(
            calc_id=calc_id,
            grain_key=grain,
            currency=currency,
            explanation_code="TRANSFER_UNIT_COST_MISSING",
            coverage_key=coverage,
            evidence_status=evidence_status,
            input_refs=inputs.input_refs,
        )

    impact = inputs.quantity * inputs.unit_cost
    return _calculated(
        calc_id=calc_id,
        grain_key=grain,
        currency=currency,
        impact=impact,
        coverage_key=coverage,
        evidence_status=evidence_status,
        input_refs=inputs.input_refs,
        metadata=(
            ("formula", "BOUNDARY_MOVEMENT_QUANTITY*SUPPORTED_UNIT_COST"),
            ("quantity", format(inputs.quantity, "f")),
            ("unit_cost", format(inputs.unit_cost, "f")),
            ("movement_classification", inputs.movement_classification),
        ),
    )


def driver_impact_from_c02(result: CalcResult) -> FoodCostDriverImpact:
    if result.calc_id not in {
        "FC.DRIVER.YIELD",
        "FC.DRIVER.PORTION",
        "FC.DRIVER.PRODUCTION",
        "FC.DRIVER.WASTE",
        "FC.DRIVER.TRANSFER_NONREVENUE",
    }:
        raise ValueError("result is not a typed C02 food-cost driver")

    metadata = dict(result.metadata)
    coverage_key = metadata.get("coverage_key", "").strip()
    evidence_status = metadata.get("source_evidence_status", "").strip()
    if not coverage_key:
        raise ValueError("C02 result is missing coverage_key metadata")
    if not evidence_status:
        raise ValueError("C02 result is missing source evidence status metadata")

    return FoodCostDriverImpact(
        driver_code=result.calc_id,
        impact=(
            result.value
            if result.calculation_status == "CALCULATED"
            and result.value is not None
            else Decimal("0")
        ),
        evidence_status=evidence_status,
        coverage_key=coverage_key,
        input_refs=result.input_refs,
    )
