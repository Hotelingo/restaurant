from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal, Mapping, Sequence

from .model import parse_decimal

Severity = Literal["block", "warn", "info"]
CapabilityStatus = Literal["reconciled", "not_reconciled"]


DEFAULT_POS_PNL_TOLERANCE = Decimal("0.005")
DEFAULT_PURCHASES_PNL_TOLERANCE = Decimal("0.02")


@dataclass(frozen=True, slots=True)
class ValidationResult:
    rule_code: str
    severity: Severity
    scope: str
    actual: object | None
    expected: object | None
    tolerance: object | None
    message: str
    remediation: str
    capability_status: CapabilityStatus = "reconciled"
    resolved: bool = False
    resolution_note: str | None = None

    @property
    def is_blocking(self) -> bool:
        return self.severity == "block" and not self.resolved


@dataclass(frozen=True, slots=True)
class ValidationGate:
    can_commit: bool
    unresolved_block_count: int
    not_reconciled_count: int


def _to_decimal(value: str | Decimal | int | float) -> Decimal:
    if isinstance(value, Decimal):
        return value
    if isinstance(value, int):
        return Decimal(value)
    if isinstance(value, float):
        return Decimal(str(value))
    return parse_decimal(value)


def relative_difference(actual: Decimal, expected: Decimal) -> Decimal:
    """Absolute relative difference against the expected/reference value.

    If expected is exactly zero, exact equality is 0 and any non-zero actual is
    treated as an infinite miss by returning Decimal('Infinity').
    """

    if expected == 0:
        return Decimal("0") if actual == 0 else Decimal("Infinity")
    return abs(actual - expected) / abs(expected)


def validate_reconciliation(
    *,
    rule_code: str,
    scope: str,
    actual: str | Decimal | int | float | None,
    expected: str | Decimal | int | float | None,
    tolerance_ratio: str | Decimal,
    failure_severity: Severity,
    message_label: str,
    remediation: str,
) -> ValidationResult:
    tolerance = (
        tolerance_ratio
        if isinstance(tolerance_ratio, Decimal)
        else Decimal(str(tolerance_ratio))
    )
    if tolerance < 0:
        raise ValueError("tolerance_ratio cannot be negative")

    if actual is None or expected is None:
        return ValidationResult(
            rule_code=rule_code,
            severity="info",
            scope=scope,
            actual=actual,
            expected=expected,
            tolerance=tolerance,
            message=f"{message_label}: required reconciliation total is missing.",
            remediation=remediation,
            capability_status="not_reconciled",
        )

    actual_decimal = _to_decimal(actual)
    expected_decimal = _to_decimal(expected)
    difference = relative_difference(actual_decimal, expected_decimal)

    if difference <= tolerance:
        return ValidationResult(
            rule_code=rule_code,
            severity="info",
            scope=scope,
            actual=actual_decimal,
            expected=expected_decimal,
            tolerance=tolerance,
            message=f"{message_label}: totals reconcile within tolerance.",
            remediation="No action required.",
            capability_status="reconciled",
        )

    return ValidationResult(
        rule_code=rule_code,
        severity=failure_severity,
        scope=scope,
        actual=actual_decimal,
        expected=expected_decimal,
        tolerance=tolerance,
        message=(
            f"{message_label}: totals differ by {difference:.6%}, "
            f"above the configured {tolerance:.6%} tolerance."
        ),
        remediation=remediation,
        capability_status="reconciled",
    )


def validate_pos_to_pnl_sales(
    *,
    pos_totals: Mapping[str, str | Decimal | int | float | None],
    pnl_totals: Mapping[str, str | Decimal | int | float | None],
    tolerance_ratio: Decimal = DEFAULT_POS_PNL_TOLERANCE,
    failure_severity: Severity = "block",
) -> tuple[ValidationResult, ...]:
    scopes = sorted(set(pos_totals) | set(pnl_totals))
    return tuple(
        validate_reconciliation(
            rule_code=f"POS_PNL_SALES_{scope.upper().replace(' ', '_')}",
            scope=scope,
            actual=pos_totals.get(scope),
            expected=pnl_totals.get(scope),
            tolerance_ratio=tolerance_ratio,
            failure_severity=failure_severity,
            message_label=f"POS to P&L sales reconciliation for {scope}",
            remediation=(
                "Check period/outlet scope, tax basis, discounts, mapping and "
                "whether all POS categories are included."
            ),
        )
        for scope in scopes
    )


def validate_purchases_to_pnl(
    *,
    purchases_total: str | Decimal | int | float | None,
    pnl_purchases_total: str | Decimal | int | float | None,
    scope: str,
    tolerance_ratio: Decimal = DEFAULT_PURCHASES_PNL_TOLERANCE,
) -> ValidationResult:
    return validate_reconciliation(
        rule_code=f"T3_PNL_PURCHASES_{scope.upper().replace(' ', '_')}",
        scope=scope,
        actual=purchases_total,
        expected=pnl_purchases_total,
        tolerance_ratio=tolerance_ratio,
        failure_severity="warn",
        message_label=f"T3 purchases to P&L purchases reconciliation for {scope}",
        remediation=(
            "Confirm the P&L purchases account mapping and period/cut-off. "
            "If no comparable P&L purchases total exists, keep the capability "
            "explicitly Not Reconciled."
        ),
    )


def validate_non_negative_activity(
    *,
    value: str | Decimal | int | float | None,
    scope: str,
    field_name: str = "activity_units",
) -> ValidationResult:
    if value is None:
        return ValidationResult(
            rule_code="ACTIVITY_UNITS_REQUIRED",
            severity="block",
            scope=scope,
            actual=None,
            expected=">= 0",
            tolerance=None,
            message=f"{field_name} is required for {scope}.",
            remediation="Provide a numeric activity value or correct the field mapping.",
        )

    number = _to_decimal(value)
    if number < 0:
        return ValidationResult(
            rule_code="ACTIVITY_UNITS_NEGATIVE",
            severity="block",
            scope=scope,
            actual=number,
            expected=">= 0",
            tolerance=None,
            message=f"{field_name} cannot be negative for {scope}.",
            remediation="Correct the source activity units before commit.",
        )

    return ValidationResult(
        rule_code="ACTIVITY_UNITS_NON_NEGATIVE",
        severity="info",
        scope=scope,
        actual=number,
        expected=">= 0",
        tolerance=None,
        message=f"{field_name} is non-negative for {scope}.",
        remediation="No action required.",
    )


def validate_stock_value(
    *,
    value: str | Decimal | int | float | None,
    scope: str,
    field_name: str,
    allow_negative_return_credit: bool = False,
) -> ValidationResult:
    if value is None:
        return ValidationResult(
            rule_code="STOCK_VALUE_REQUIRED",
            severity="block",
            scope=scope,
            actual=None,
            expected="numeric",
            tolerance=None,
            message=f"{field_name} is required for {scope}.",
            remediation="Provide the stock value or correct the field mapping.",
        )

    number = _to_decimal(value)
    if number < 0 and not allow_negative_return_credit:
        return ValidationResult(
            rule_code="STOCK_VALUE_NEGATIVE_UNSUPPORTED",
            severity="block",
            scope=scope,
            actual=number,
            expected=">= 0 unless configured return/credit",
            tolerance=None,
            message=f"{field_name} is negative for {scope} without a configured return/credit case.",
            remediation=(
                "Correct the source value or explicitly configure the row as a "
                "supported return/credit case."
            ),
        )

    return ValidationResult(
        rule_code="STOCK_VALUE_ACCEPTED",
        severity="info",
        scope=scope,
        actual=number,
        expected=">= 0 or configured return/credit",
        tolerance=None,
        message=f"{field_name} is acceptable for {scope}.",
        remediation="No action required.",
    )


def validation_gate(results: Sequence[ValidationResult]) -> ValidationGate:
    unresolved_blocks = sum(result.is_blocking for result in results)
    not_reconciled = sum(
        result.capability_status == "not_reconciled" for result in results
    )
    return ValidationGate(
        can_commit=unresolved_blocks == 0,
        unresolved_block_count=unresolved_blocks,
        not_reconciled_count=not_reconciled,
    )
