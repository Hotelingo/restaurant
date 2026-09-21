from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal, Mapping, Sequence

from .mapping import AccountMappingRule, resolve_account_mapping
from .model import ParsedTable, parse_decimal
from .transforms import TransformError, parse_month_label


ScenarioCode = Literal["actual", "budget", "forecast", "prior_year"]


class CanonicalisationError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class FinancialFactDraft:
    source_row_no: int
    period: str
    scenario: ScenarioCode
    account_code: str | None
    account_name: str | None
    account_section: str | None
    ladder_line_code: str
    amount: Decimal
    currency_code: str

    @property
    def grain(self) -> Literal["account", "ladder"]:
        return "account" if self.account_name is not None else "ladder"


def _normalise_currency(currency_code: str) -> str:
    currency = currency_code.strip().upper()
    if len(currency) != 3 or not currency.isalpha():
        raise CanonicalisationError("currency_code must be a three-letter ISO-style code")
    return currency


def _month_columns(table: ParsedTable) -> tuple[str, ...]:
    columns: list[str] = []
    for header in table.headers:
        try:
            parse_month_label(header)
        except TransformError:
            continue
        columns.append(header)
    return tuple(columns)


def _source_row_number(table: ParsedTable, zero_based_data_index: int) -> int:
    # header_row is 1-based. The first data row is one row after the header.
    return table.header_row + 1 + zero_based_data_index


def build_account_grain_financial_drafts(
    table: ParsedTable,
    *,
    account_rules: Sequence[AccountMappingRule],
    currency_code: str,
    scenario: ScenarioCode = "actual",
    code_field: str = "Account_Code",
    name_field: str = "Account_Name",
    section_field: str = "Account_Section",
    period_field: str = "Period",
    amount_field: str = "Amount",
) -> tuple[FinancialFactDraft, ...]:
    """Canonicalise T1-style account-grain financial data.

    Mapping is resolved solely from account code/name through approved profile
    rules. Source suggested management-line labels and monetary amounts are not
    consulted when selecting the ladder line.
    """

    currency = _normalise_currency(currency_code)
    records = table.records()
    month_columns = _month_columns(table)

    if period_field in table.headers and amount_field in table.headers:
        value_columns = ((period_field, amount_field),)
    elif month_columns:
        value_columns = tuple((month, month) for month in month_columns)
    else:
        raise CanonicalisationError(
            "Account-grain financial source needs Period+Amount or a month-labelled value column"
        )

    drafts: list[FinancialFactDraft] = []
    for index, record in enumerate(records):
        rule = resolve_account_mapping(
            record,
            rules=account_rules,
            code_field=code_field,
            name_field=name_field,
        )
        if rule is None:
            raise CanonicalisationError(
                f"Unmapped source account at row {_source_row_number(table, index)}"
            )

        code = record.get(code_field, "").strip() or None
        name = record.get(name_field, "").strip()
        if not name:
            raise CanonicalisationError(
                f"Account name is blank at row {_source_row_number(table, index)}"
            )
        section = record.get(section_field, "").strip() or None

        for period_source, value_source in value_columns:
            if period_source == period_field:
                period_raw = record[period_field]
                amount_raw = record[amount_field]
                try:
                    period = parse_month_label(period_raw)
                except TransformError as exc:
                    raise CanonicalisationError(
                        f"Invalid period at row {_source_row_number(table, index)}: {period_raw}"
                    ) from exc
            else:
                period = parse_month_label(period_source)
                amount_raw = record[value_source]

            if amount_raw.strip() == "":
                continue

            try:
                amount = parse_decimal(amount_raw)
            except Exception as exc:
                raise CanonicalisationError(
                    f"Invalid amount at row {_source_row_number(table, index)}"
                ) from exc

            drafts.append(
                FinancialFactDraft(
                    source_row_no=_source_row_number(table, index),
                    period=period,
                    scenario=scenario,
                    account_code=code,
                    account_name=name,
                    account_section=section,
                    ladder_line_code=rule.ladder_line_key,
                    amount=amount,
                    currency_code=currency,
                )
            )

    return tuple(drafts)


def build_ladder_grain_comparator_drafts(
    table: ParsedTable,
    *,
    management_line_map: Mapping[str, str],
    currency_code: str,
    scenario: Literal["budget", "forecast", "prior_year"],
    line_field: str = "Management_Line",
    period_field: str = "Period",
    amount_field: str = "Amount",
) -> tuple[FinancialFactDraft, ...]:
    """Canonicalise management-line comparator data such as T6.

    No synthetic account is created. The management-line mapping is an explicit
    profile/config input. Amounts never influence destination selection.
    """

    currency = _normalise_currency(currency_code)
    records = table.records()
    month_columns = _month_columns(table)
    normalised_map = {
        key.strip().casefold(): value for key, value in management_line_map.items()
    }

    if period_field in table.headers and amount_field in table.headers:
        value_columns = ((period_field, amount_field),)
    elif month_columns:
        value_columns = tuple((month, month) for month in month_columns)
    else:
        raise CanonicalisationError(
            "Ladder-grain comparator needs Period+Amount or a month-labelled value column"
        )

    drafts: list[FinancialFactDraft] = []
    for index, record in enumerate(records):
        source_line = record.get(line_field, "").strip()
        if not source_line:
            raise CanonicalisationError(
                f"Management line is blank at row {_source_row_number(table, index)}"
            )

        ladder_code = normalised_map.get(source_line.casefold())
        if ladder_code is None:
            raise CanonicalisationError(
                f"Unmapped management line at row {_source_row_number(table, index)}: {source_line}"
            )

        for period_source, value_source in value_columns:
            if period_source == period_field:
                period_raw = record[period_field]
                amount_raw = record[amount_field]
                try:
                    period = parse_month_label(period_raw)
                except TransformError as exc:
                    raise CanonicalisationError(
                        f"Invalid period at row {_source_row_number(table, index)}: {period_raw}"
                    ) from exc
            else:
                period = parse_month_label(period_source)
                amount_raw = record[value_source]

            if amount_raw.strip() == "":
                continue
            try:
                amount = parse_decimal(amount_raw)
            except Exception as exc:
                raise CanonicalisationError(
                    f"Invalid amount at row {_source_row_number(table, index)}"
                ) from exc

            drafts.append(
                FinancialFactDraft(
                    source_row_no=_source_row_number(table, index),
                    period=period,
                    scenario=scenario,
                    account_code=None,
                    account_name=None,
                    account_section=None,
                    ladder_line_code=ladder_code,
                    amount=amount,
                    currency_code=currency,
                )
            )

    return tuple(drafts)
