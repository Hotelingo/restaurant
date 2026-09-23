from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

CalculationStatus = Literal["CALCULATED", "NOT_CALCULATED"]
EvidenceStatus = Literal["supported", "validated", "evidence_required"]


@dataclass(frozen=True, slots=True)
class CalcResult:
    """Stable, immutable calculation-engine result contract."""

    calc_id: str
    grain_type: str
    grain_key: str
    value: Decimal | None
    unit: str
    currency: str | None
    calculation_status: CalculationStatus
    evidence_status: EvidenceStatus
    explanation_code: str | None
    value_text: str | None = None
    input_refs: tuple[str, ...] = ()
    raw_delta: Decimal | None = None
    profit_effect: Decimal | None = None
    metadata: tuple[tuple[str, str], ...] = ()

    def __post_init__(self) -> None:
        if self.calculation_status == "CALCULATED":
            if (self.value is None) == (self.value_text is None):
                raise ValueError(
                    "CALCULATED result requires exactly one numeric or text value"
                )
            if self.value_text is not None and not self.value_text.strip():
                raise ValueError("CALCULATED text value cannot be blank")
            if self.explanation_code is not None:
                raise ValueError("CALCULATED result cannot carry an explanation_code")
        elif self.calculation_status == "NOT_CALCULATED":
            if self.value is not None or self.value_text is not None:
                raise ValueError(
                    "NOT_CALCULATED result cannot carry a numeric or text value"
                )
            if not self.explanation_code:
                raise ValueError("NOT_CALCULATED result requires an explanation_code")
        else:
            raise ValueError(f"Unsupported calculation_status: {self.calculation_status}")

        if self.raw_delta is not None and self.calculation_status != "CALCULATED":
            raise ValueError("raw_delta is only valid on CALCULATED results")
        if self.profit_effect is not None and self.calculation_status != "CALCULATED":
            raise ValueError("profit_effect is only valid on CALCULATED results")
