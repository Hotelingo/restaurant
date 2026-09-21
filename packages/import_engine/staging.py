from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Mapping

from .model import ParsedTable, parse_decimal
from .registry import normalise_text
from .transforms import TransformError, parse_month_label


class StagingError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class StagingRowDraft:
    source_row_no: int
    raw: Mapping[str, str]
    parsed: Mapping[str, str]
    parse_errors: tuple[Mapping[str, str], ...] = ()

    @property
    def row_status(self) -> str:
        return "error" if self.parse_errors else "parsed"


@dataclass(frozen=True, slots=True)
class FinancialStagingResult:
    rows: tuple[StagingRowDraft, ...]
    field_map: Mapping[str, str]
    month_columns: tuple[str, ...]
    target_period: str


def _source_row_number(table: ParsedTable, zero_based_data_index: int) -> int:
    return table.header_row + 1 + zero_based_data_index


def _header_index(
    table: ParsedTable,
    header_aliases: Mapping[str, str] | None = None,
) -> dict[str, str]:
    aliases = {
        normalise_text(source): normalise_text(target)
        for source, target in (header_aliases or {}).items()
        if normalise_text(source) and normalise_text(target)
    }
    index: dict[str, str] = {}
    for header in table.headers:
        source_key = normalise_text(header)
        key = aliases.get(source_key, source_key)
        if key and key not in index:
            index[key] = header
    return index


def _field_map(
    table: ParsedTable,
    template_code: str,
    header_aliases: Mapping[str, str] | None = None,
) -> dict[str, str]:
    headers = _header_index(table, header_aliases)
    canonical: dict[str, str] = {}

    for key, canonical_name in (
        ("account code", "account_code"),
        ("account name", "account_name"),
        ("account section", "account_section"),
        ("management line", "management_line"),
        ("period", "period"),
        ("amount", "amount"),
    ):
        source_header = headers.get(key)
        if source_header is not None:
            canonical[source_header] = canonical_name

    if template_code == "T1" and "account name" not in headers:
        raise StagingError("T1 requires an Account_Name column")
    if template_code == "T6" and (
        "management line" not in headers and "account name" not in headers
    ):
        raise StagingError(
            "T6 requires Management_Line or account-grain Account_Name"
        )

    return canonical


def _month_columns(table: ParsedTable) -> tuple[tuple[str, str], ...]:
    parsed: list[tuple[str, str]] = []
    seen_periods: set[str] = set()
    for header in table.headers:
        try:
            period = parse_month_label(header)
        except TransformError:
            continue
        if period in seen_periods:
            raise StagingError(
                f"More than one source column resolves to reporting period {period}"
            )
        seen_periods.add(period)
        parsed.append((header, period))
    return tuple(parsed)


def _normalised_amount(
    raw: str,
    *,
    source_row_no: int,
) -> tuple[str | None, Mapping[str, str] | None]:
    try:
        amount: Decimal = parse_decimal(raw)
    except Exception:
        return None, {
            "code": "INVALID_AMOUNT",
            "field": "amount",
            "message": f"Row {source_row_no}: amount is not a valid finance number.",
        }
    return str(amount), None


def build_financial_staging_rows(
    table: ParsedTable,
    *,
    template_code: str,
    target_period: str,
    header_aliases: Mapping[str, str] | None = None,
) -> FinancialStagingResult:
    """Build deterministic T1/T6 staging rows for one target reporting period.

    A batch is period-scoped, so a multi-month wide file contributes only the
    selected month to that batch. The full source remains immutable in object
    storage and the full table still drives fingerprinting/profile matching.
    """

    template = template_code.strip().upper()
    if template not in {"T1", "T6"}:
        raise StagingError("Financial staging currently supports T1 and T6 only")

    try:
        target = parse_month_label(target_period)
    except TransformError as exc:
        raise StagingError(f"Invalid target reporting period: {target_period}") from exc

    source_to_canonical = _field_map(table, template, header_aliases)
    headers = _header_index(table, header_aliases)
    records = table.records()
    months = _month_columns(table)

    explicit_period = headers.get("period")
    explicit_amount = headers.get("amount")
    if explicit_period is not None or explicit_amount is not None:
        if explicit_period is None or explicit_amount is None:
            raise StagingError("Long-form financial data requires both Period and Amount")
        mode = "rows"
    elif months:
        mode = "wide"
    else:
        raise StagingError(
            "Financial data requires Period+Amount or at least one month-labelled value column"
        )

    account_code_header = headers.get("account code")
    account_name_header = headers.get("account name")
    account_section_header = headers.get("account section")
    management_line_header = headers.get("management line")

    output: list[StagingRowDraft] = []
    for index, record in enumerate(records):
        source_row_no = _source_row_number(table, index)
        raw = dict(record)

        if mode == "rows":
            try:
                row_period = parse_month_label(record[explicit_period])
            except TransformError:
                # Keep bad-period rows visible only when the user is trying to
                # import this file as the target period. A malformed period
                # cannot be assigned safely to another batch.
                output.append(
                    StagingRowDraft(
                        source_row_no=source_row_no,
                        raw=raw,
                        parsed={},
                        parse_errors=(
                            {
                                "code": "INVALID_PERIOD",
                                "field": "period",
                                "message": f"Row {source_row_no}: period is not recognised.",
                            },
                        ),
                    )
                )
                continue
            if row_period != target:
                continue
            raw_amount = record[explicit_amount]
        else:
            month_header = next(
                (header for header, period in months if period == target),
                None,
            )
            if month_header is None:
                continue
            raw_amount = record[month_header]

        parsed: dict[str, str] = {"period": target}
        errors: list[Mapping[str, str]] = []

        if account_code_header is not None:
            account_code = record[account_code_header].strip()
            if account_code:
                parsed["account_code"] = account_code
        if account_name_header is not None:
            account_name = record[account_name_header].strip()
            if account_name:
                parsed["account_name"] = account_name
        if account_section_header is not None:
            account_section = record[account_section_header].strip()
            if account_section:
                parsed["account_section"] = account_section
        if management_line_header is not None:
            management_line = record[management_line_header].strip()
            if management_line:
                parsed["management_line"] = management_line

        if template == "T1" and not parsed.get("account_name"):
            errors.append(
                {
                    "code": "MISSING_ACCOUNT_NAME",
                    "field": "account_name",
                    "message": f"Row {source_row_no}: Account_Name is required.",
                }
            )
        if template == "T6" and not (
            parsed.get("management_line") or parsed.get("account_name")
        ):
            errors.append(
                {
                    "code": "MISSING_COMPARATOR_IDENTITY",
                    "field": "management_line",
                    "message": (
                        f"Row {source_row_no}: T6 needs Management_Line "
                        "or Account_Name."
                    ),
                }
            )

        if raw_amount.strip() == "":
            errors.append(
                {
                    "code": "MISSING_AMOUNT",
                    "field": "amount",
                    "message": f"Row {source_row_no}: amount is blank.",
                }
            )
        else:
            normalised, amount_error = _normalised_amount(
                raw_amount,
                source_row_no=source_row_no,
            )
            if amount_error is not None:
                errors.append(amount_error)
            elif normalised is not None:
                parsed["amount"] = normalised

        output.append(
            StagingRowDraft(
                source_row_no=source_row_no,
                raw=raw,
                parsed=parsed,
                parse_errors=tuple(errors),
            )
        )

    if not output:
        raise StagingError(
            f"Source contains no rows for reporting period {target}"
        )

    return FinancialStagingResult(
        rows=tuple(output),
        field_map=source_to_canonical,
        month_columns=tuple(header for header, _ in months),
        target_period=target,
    )
