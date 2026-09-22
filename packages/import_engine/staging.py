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



@dataclass(frozen=True, slots=True)
class FoodCostStagingResult:
    rows: tuple[StagingRowDraft, ...]
    field_map: Mapping[str, str]
    target_period: str
    ignored_source_fields: tuple[str, ...] = ()
    effective_from_basis: str | None = None


def _food_cost_field_map(
    table: ParsedTable,
    template_code: str,
    header_aliases: Mapping[str, str] | None = None,
) -> tuple[dict[str, str], dict[str, str]]:
    headers = _header_index(table, header_aliases)
    canonical: dict[str, str] = {}

    keys = {
        "period": "period",
        "item code": "item_code",
        "item": "item_name",
        "population": "population",
        "units": "units_sold",
        "units sold": "units_sold",
        "net revenue": "net_revenue",
        "gross revenue": "gross_revenue",
        "discount": "discount",
        "meal period": "meal_period",
        "channel": "channel",
        "product group": "product_group",
        "category": "category",
        "opening inventory": "opening_inventory",
        "purchases": "purchases",
        "closing inventory": "closing_inventory",
        "external inbound transfer": "external_inbound_transfer",
        "external outbound transfer": "external_outbound_transfer",
        "recorded non revenue use": "non_revenue_use",
        "inventory location": "inventory_location",
        "valuation basis": "valuation_basis",
        "revenue": "source_product_revenue",
        "budget cost pct": "source_budget_cost_pct",
        "effective from": "effective_from",
        "approved cost per unit": "approved_cost_per_unit",
        "recipe version": "recipe_version",
        "approved portion": "approved_portion",
        "yield": "yield_factor",
        "yield factor": "yield_factor",
        "uom": "uom",
        "status": "source_status",
    }
    for key, canonical_name in keys.items():
        source = headers.get(key)
        if source is not None:
            canonical[source] = canonical_name

    template = template_code.strip().upper()
    if template in {"T2", "T4A"} and not (
        "item code" in headers or "item" in headers
    ):
        raise StagingError(f"{template} requires Item_Code or Item")
    if template == "T3" and "product group" not in headers:
        raise StagingError("T3 requires Product_Group")

    return canonical, headers


def _parse_required_decimal(
    raw: str,
    *,
    source_row_no: int,
    canonical_field: str,
    label: str,
    errors: list[Mapping[str, str]],
) -> str | None:
    if not raw.strip():
        errors.append(
            {
                "code": f"MISSING_{canonical_field.upper()}",
                "field": canonical_field,
                "message": f"Row {source_row_no}: {label} is required.",
            }
        )
        return None
    try:
        return str(parse_decimal(raw))
    except Exception:
        errors.append(
            {
                "code": f"INVALID_{canonical_field.upper()}",
                "field": canonical_field,
                "message": f"Row {source_row_no}: {label} is not a valid number.",
            }
        )
        return None


def build_food_cost_staging_rows(
    table: ParsedTable,
    *,
    template_code: str,
    target_period: str,
    header_aliases: Mapping[str, str] | None = None,
    effective_from_default: str | None = None,
) -> FoodCostStagingResult:
    """Build deterministic T2/T3/T4A staging rows for one review period.

    T2/T3 files without a Period column are explicitly bound to the selected
    import period (the closed-list fixed-value transform). T4A requires an
    effective date; a caller may provide an explicit fixed default such as the
    review-period start for a source profile that omits it.

    T3 Expected_Usage is intentionally never canonicalised. If that fixture
    convenience column is present it remains only in immutable raw_jsonb and is
    reported in ignored_source_fields.
    """
    template = template_code.strip().upper()
    if template not in {"T2", "T3", "T4A"}:
        raise StagingError("Food-cost staging supports T2, T3 and T4A only")

    try:
        target = parse_month_label(target_period)
    except TransformError as exc:
        raise StagingError(f"Invalid target reporting period: {target_period}") from exc

    source_to_canonical, headers = _food_cost_field_map(
        table, template, header_aliases
    )
    records = table.records()
    period_header = headers.get("period")

    ignored: list[str] = []
    expected_header = headers.get("expected usage")
    if expected_header is not None:
        ignored.append(expected_header)

    def value(record: Mapping[str, str], key: str) -> str:
        source_header = headers.get(key)
        return record.get(source_header, "") if source_header else ""

    output: list[StagingRowDraft] = []
    for index, record in enumerate(records):
        source_row_no = _source_row_number(table, index)
        raw = dict(record)
        parsed: dict[str, str] = {}
        errors: list[Mapping[str, str]] = []

        if period_header is not None:
            try:
                row_period = parse_month_label(record[period_header])
            except TransformError:
                errors.append(
                    {
                        "code": "INVALID_PERIOD",
                        "field": "period",
                        "message": f"Row {source_row_no}: period is not recognised.",
                    }
                )
                row_period = target
            if row_period != target:
                continue
            parsed["period"] = row_period
        else:
            parsed["period"] = target

        if template == "T2":
            item_code = value(record, "item code").strip()
            item_name = value(record, "item").strip()
            if not item_code and not item_name:
                errors.append(
                    {
                        "code": "MISSING_ITEM_IDENTITY",
                        "field": "item_code",
                        "message": (
                            f"Row {source_row_no}: Item_Code or Item is required."
                        ),
                    }
                )
            if item_code:
                parsed["item_code"] = item_code
            if item_name:
                parsed["item_name"] = item_name

            population = value(record, "population").strip()
            if population:
                parsed["population"] = population

            units = _parse_required_decimal(
                value(record, "units"),
                source_row_no=source_row_no,
                canonical_field="units_sold",
                label="Units Sold",
                errors=errors,
            )
            revenue = _parse_required_decimal(
                value(record, "net revenue"),
                source_row_no=source_row_no,
                canonical_field="net_revenue",
                label="Net Revenue",
                errors=errors,
            )
            if units is not None:
                parsed["units_sold"] = units
            if revenue is not None:
                parsed["net_revenue"] = revenue

            for source_key, canonical_key in (
                ("gross revenue", "gross_revenue"),
                ("discount", "discount"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    try:
                        parsed[canonical_key] = str(parse_decimal(raw_value))
                    except Exception:
                        errors.append(
                            {
                                "code": f"INVALID_{canonical_key.upper()}",
                                "field": canonical_key,
                                "message": (
                                    f"Row {source_row_no}: {source_key.title()} "
                                    "is not a valid number."
                                ),
                            }
                        )
            for source_key, canonical_key in (
                ("meal period", "meal_period"),
                ("channel", "channel"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    parsed[canonical_key] = raw_value

        elif template == "T3":
            group = value(record, "product group").strip()
            if not group:
                errors.append(
                    {
                        "code": "MISSING_PRODUCT_GROUP",
                        "field": "product_group",
                        "message": f"Row {source_row_no}: Product_Group is required.",
                    }
                )
            else:
                parsed["product_group"] = group

            category = value(record, "category").strip()
            if category:
                parsed["category"] = category

            for source_key, canonical_key, label in (
                ("opening inventory", "opening_inventory", "Opening Inventory"),
                ("purchases", "purchases", "Purchases"),
                ("closing inventory", "closing_inventory", "Closing Inventory"),
            ):
                number = _parse_required_decimal(
                    value(record, source_key),
                    source_row_no=source_row_no,
                    canonical_field=canonical_key,
                    label=label,
                    errors=errors,
                )
                if number is not None:
                    parsed[canonical_key] = number

            for source_key, canonical_key in (
                ("external inbound transfer", "external_inbound_transfer"),
                ("external outbound transfer", "external_outbound_transfer"),
                ("recorded non revenue use", "non_revenue_use"),
                ("revenue", "source_product_revenue"),
                ("budget cost pct", "source_budget_cost_pct"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    try:
                        parsed[canonical_key] = str(parse_decimal(raw_value))
                    except Exception:
                        errors.append(
                            {
                                "code": f"INVALID_{canonical_key.upper()}",
                                "field": canonical_key,
                                "message": (
                                    f"Row {source_row_no}: {source_key.title()} "
                                    "is not a valid number."
                                ),
                            }
                        )
            for source_key, canonical_key in (
                ("inventory location", "inventory_location"),
                ("valuation basis", "valuation_basis"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    parsed[canonical_key] = raw_value

        else:
            item_code = value(record, "item code").strip()
            item_name = value(record, "item").strip()
            if not item_code and not item_name:
                errors.append(
                    {
                        "code": "MISSING_ITEM_IDENTITY",
                        "field": "item_code",
                        "message": (
                            f"Row {source_row_no}: Item_Code or Item is required."
                        ),
                    }
                )
            if item_code:
                parsed["item_code"] = item_code
            if item_name:
                parsed["item_name"] = item_name

            effective = value(record, "effective from").strip()
            effective_basis = "source"
            if not effective and effective_from_default:
                effective = effective_from_default.strip()
                effective_basis = "fixed_default"
            if not effective:
                errors.append(
                    {
                        "code": "MISSING_EFFECTIVE_FROM",
                        "field": "effective_from",
                        "message": (
                            f"Row {source_row_no}: Effective_From is required "
                            "unless the approved source profile supplies a fixed value."
                        ),
                    }
                )
            else:
                parsed["effective_from"] = effective
                parsed["effective_from_basis"] = effective_basis

            cost = _parse_required_decimal(
                value(record, "approved cost per unit"),
                source_row_no=source_row_no,
                canonical_field="approved_cost_per_unit",
                label="Approved Cost per Unit",
                errors=errors,
            )
            if cost is not None:
                parsed["approved_cost_per_unit"] = cost

            for source_key, canonical_key in (
                ("population", "population"),
                ("recipe version", "recipe_version"),
                ("uom", "uom"),
                ("status", "source_status"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    parsed[canonical_key] = raw_value
            for source_key, canonical_key in (
                ("approved portion", "approved_portion"),
                ("yield factor", "yield_factor"),
                ("yield", "yield_factor"),
            ):
                raw_value = value(record, source_key).strip()
                if raw_value:
                    try:
                        parsed[canonical_key] = str(parse_decimal(raw_value))
                    except Exception:
                        errors.append(
                            {
                                "code": f"INVALID_{canonical_key.upper()}",
                                "field": canonical_key,
                                "message": (
                                    f"Row {source_row_no}: {source_key.title()} "
                                    "is not a valid number."
                                ),
                            }
                        )

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

    return FoodCostStagingResult(
        rows=tuple(output),
        field_map=source_to_canonical,
        target_period=target,
        ignored_source_fields=tuple(ignored),
        effective_from_basis=(
            "fixed_default" if template == "T4A" and effective_from_default else None
        ),
    )



@dataclass(frozen=True, slots=True)
class RevenueStagingResult:
    rows: tuple[StagingRowDraft, ...]
    field_map: Mapping[str, str]
    target_period: str


def _revenue_field_map(
    table: ParsedTable,
    template_code: str,
    header_aliases: Mapping[str, str] | None = None,
) -> tuple[dict[str, str], dict[str, str]]:
    headers = _header_index(table, header_aliases)
    canonical: dict[str, str] = {}

    keys = {
        "period": "period",
        "meal period": "business_view_key",
        "business format": "business_view_key",
        "units": "activity_units",
        "activity units": "activity_units",
        "unit basis": "activity_unit_type",
        "activity unit type": "activity_unit_type",
        "revenue": "revenue",
        "attributed revenue": "revenue",
        "avg spend": "source_avg_spend",
        "budget units": "comparator_activity_units",
        "budget revenue": "comparator_revenue",
        "budget avg spend": "source_comparator_avg_spend",
        "food revenue": "food_revenue",
        "beverage revenue": "beverage_revenue",
        "other revenue": "other_revenue",
        "seats": "seats",
        "hours": "operating_hours",
        "operating days": "operating_days",
        "customer source": "source_channel",
        "source": "source_channel",
        "channel": "source_channel",
        "channel cost": "direct_channel_cost",
        "direct channel cost": "direct_channel_cost",
        "acquisition cost": "direct_channel_cost",
        "commission": "commission",
        "promotion cost": "promotion_cost",
        "evidence status": "source_evidence_status",
        "evidence basis": "source_evidence_status",
    }
    for key, canonical_name in keys.items():
        source = headers.get(key)
        if source is not None:
            canonical[source] = canonical_name

    template = template_code.strip().upper()
    if template == "T1B":
        if "meal period" not in headers and "business format" not in headers:
            raise StagingError("T1B requires Meal_Period or Business_Format")
        if "revenue" not in headers:
            raise StagingError("T1B requires Revenue")
        if "units" not in headers and "activity units" not in headers:
            raise StagingError("T1B requires Units or Activity_Units")
        if "unit basis" not in headers and "activity unit type" not in headers:
            raise StagingError("T1B requires Unit_Basis or Activity_Unit_Type")
    elif template == "T7":
        if not any(key in headers for key in ("customer source", "source", "channel")):
            raise StagingError("T7 requires Customer_Source, Source or Channel")
        if (
            "revenue" not in headers
            and "attributed revenue" not in headers
            and "units" not in headers
            and "activity units" not in headers
        ):
            raise StagingError("T7 requires Attributed Revenue or Activity Units")
    else:
        raise StagingError("Revenue staging supports T1B and T7 only")

    return canonical, headers


def _normalise_source_evidence_status(value: str) -> str:
    status = normalise_text(value)
    mapping = {
        "supported": "supported",
        "validated": "validated",
        "partly supported": "partly_supported",
        "evidence required": "evidence_required",
    }
    return mapping.get(status, status.replace(" ", "_"))


def build_revenue_staging_rows(
    table: ParsedTable,
    *,
    template_code: str,
    target_period: str,
    header_aliases: Mapping[str, str] | None = None,
) -> RevenueStagingResult:
    """Build deterministic T1B/T7 staging rows for one reporting period.

    Amberside T1B/T7 exports omit Period, so absence is handled by the same
    closed-list fixed-value transform used by other period-scoped source files.
    T1B may carry embedded comparator columns; they remain on the same canonical
    business-view fact rather than pretending the source file is a T6 batch.
    """
    template = template_code.strip().upper()
    if template not in {"T1B", "T7"}:
        raise StagingError("Revenue staging supports T1B and T7 only")

    try:
        target = parse_month_label(target_period)
    except TransformError as exc:
        raise StagingError(f"Invalid target reporting period: {target_period}") from exc

    source_to_canonical, headers = _revenue_field_map(
        table, template, header_aliases
    )
    period_header = headers.get("period")
    records = table.records()

    def value(record: Mapping[str, str], *keys: str) -> str:
        for key in keys:
            source_header = headers.get(key)
            if source_header is not None:
                return record.get(source_header, "")
        return ""

    def optional_decimal(
        record: Mapping[str, str],
        *,
        keys: tuple[str, ...],
        canonical_field: str,
        source_row_no: int,
        errors: list[Mapping[str, str]],
    ) -> str | None:
        raw_value = value(record, *keys).strip()
        if not raw_value:
            return None
        try:
            return str(parse_decimal(raw_value))
        except Exception:
            errors.append(
                {
                    "code": f"INVALID_{canonical_field.upper()}",
                    "field": canonical_field,
                    "message": (
                        f"Row {source_row_no}: {canonical_field.replace('_', ' ')} "
                        "is not a valid number."
                    ),
                }
            )
            return None

    output: list[StagingRowDraft] = []
    for index, record in enumerate(records):
        source_row_no = _source_row_number(table, index)
        raw = dict(record)
        parsed: dict[str, str] = {}
        errors: list[Mapping[str, str]] = []

        if period_header is not None:
            try:
                row_period = parse_month_label(record[period_header])
            except TransformError:
                errors.append(
                    {
                        "code": "INVALID_PERIOD",
                        "field": "period",
                        "message": f"Row {source_row_no}: period is not recognised.",
                    }
                )
                row_period = target
            if row_period != target:
                continue
            parsed["period"] = row_period
        else:
            parsed["period"] = target

        if template == "T1B":
            meal_period = value(record, "meal period").strip()
            business_format = value(record, "business format").strip()
            if meal_period:
                parsed["business_view_type"] = "meal_period"
                parsed["business_view_key"] = meal_period
            elif business_format:
                parsed["business_view_type"] = "business_format"
                parsed["business_view_key"] = business_format
            else:
                errors.append(
                    {
                        "code": "MISSING_BUSINESS_VIEW",
                        "field": "business_view_key",
                        "message": (
                            f"Row {source_row_no}: Meal Period or Business Format is required."
                        ),
                    }
                )

            unit_type = value(
                record, "unit basis", "activity unit type"
            ).strip()
            if not unit_type:
                errors.append(
                    {
                        "code": "MISSING_ACTIVITY_UNIT_TYPE",
                        "field": "activity_unit_type",
                        "message": (
                            f"Row {source_row_no}: Activity Unit Type is required."
                        ),
                    }
                )
            else:
                parsed["activity_unit_type"] = unit_type

            units = _parse_required_decimal(
                value(record, "units", "activity units"),
                source_row_no=source_row_no,
                canonical_field="activity_units",
                label="Activity Units",
                errors=errors,
            )
            revenue = _parse_required_decimal(
                value(record, "revenue"),
                source_row_no=source_row_no,
                canonical_field="revenue",
                label="Revenue",
                errors=errors,
            )
            if units is not None:
                parsed["activity_units"] = units
                if Decimal(units) < 0:
                    errors.append(
                        {
                            "code": "ACTIVITY_UNITS_NEGATIVE",
                            "field": "activity_units",
                            "message": (
                                f"Row {source_row_no}: Activity Units cannot be negative."
                            ),
                        }
                    )
            if revenue is not None:
                parsed["revenue"] = revenue

            for keys, canonical_field in (
                (("avg spend",), "source_avg_spend"),
                (("budget units",), "comparator_activity_units"),
                (("budget avg spend",), "source_comparator_avg_spend"),
                (("budget revenue",), "comparator_revenue"),
                (("food revenue",), "food_revenue"),
                (("beverage revenue",), "beverage_revenue"),
                (("other revenue",), "other_revenue"),
                (("seats",), "seats"),
                (("hours",), "operating_hours"),
                (("operating days",), "operating_days"),
            ):
                parsed_value = optional_decimal(
                    record,
                    keys=keys,
                    canonical_field=canonical_field,
                    source_row_no=source_row_no,
                    errors=errors,
                )
                if parsed_value is not None:
                    parsed[canonical_field] = parsed_value

            comparator_units = parsed.get("comparator_activity_units")
            if comparator_units is not None and Decimal(comparator_units) < 0:
                errors.append(
                    {
                        "code": "COMPARATOR_ACTIVITY_UNITS_NEGATIVE",
                        "field": "comparator_activity_units",
                        "message": (
                            f"Row {source_row_no}: comparator Activity Units cannot be negative."
                        ),
                    }
                )

        else:
            source_channel = value(
                record, "customer source", "source", "channel"
            ).strip()
            if not source_channel:
                errors.append(
                    {
                        "code": "MISSING_SOURCE_CHANNEL",
                        "field": "source_channel",
                        "message": (
                            f"Row {source_row_no}: Customer Source / Channel is required."
                        ),
                    }
                )
            else:
                parsed["source_channel"] = source_channel

            activity_units = optional_decimal(
                record,
                keys=("units", "activity units"),
                canonical_field="activity_units",
                source_row_no=source_row_no,
                errors=errors,
            )
            attributed_revenue = optional_decimal(
                record,
                keys=("attributed revenue", "revenue"),
                canonical_field="attributed_revenue",
                source_row_no=source_row_no,
                errors=errors,
            )
            if activity_units is None and attributed_revenue is None:
                errors.append(
                    {
                        "code": "MISSING_T7_MEASURE",
                        "field": "attributed_revenue",
                        "message": (
                            f"Row {source_row_no}: T7 requires Attributed Revenue "
                            "or Activity Units."
                        ),
                    }
                )
            if activity_units is not None:
                parsed["activity_units"] = activity_units
                if Decimal(activity_units) < 0:
                    errors.append(
                        {
                            "code": "ACTIVITY_UNITS_NEGATIVE",
                            "field": "activity_units",
                            "message": (
                                f"Row {source_row_no}: Activity Units cannot be negative."
                            ),
                        }
                    )
            if attributed_revenue is not None:
                parsed["attributed_revenue"] = attributed_revenue

            for keys, canonical_field in (
                (
                    ("channel cost", "direct channel cost", "acquisition cost"),
                    "direct_channel_cost",
                ),
                (("commission",), "commission"),
                (("promotion cost",), "promotion_cost"),
            ):
                parsed_value = optional_decimal(
                    record,
                    keys=keys,
                    canonical_field=canonical_field,
                    source_row_no=source_row_no,
                    errors=errors,
                )
                if parsed_value is not None:
                    parsed[canonical_field] = parsed_value

            evidence = value(
                record, "evidence status", "evidence basis"
            ).strip()
            if evidence:
                parsed["source_evidence_status"] = (
                    _normalise_source_evidence_status(evidence)
                )

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

    return RevenueStagingResult(
        rows=tuple(output),
        field_map=source_to_canonical,
        target_period=target,
    )



@dataclass(frozen=True, slots=True)
class LabourStagingResult:
    rows: tuple[StagingRowDraft, ...]
    field_map: Mapping[str, str]
    target_period: str


def build_labour_staging_rows(
    table: ParsedTable,
    *,
    template_code: str,
    target_period: str,
    header_aliases: Mapping[str, str] | None = None,
) -> LabourStagingResult:
    """Build deterministic T5 role-group Labour staging rows.

    Activity basis is not inferred from role names or numeric values. When the
    source omits Workload_Basis / Activity_Type, the row remains parseable and
    mapping confirmation must supply a profile-scoped role-group basis before
    validation/commit.
    """
    if template_code.strip().upper() != "T5":
        raise StagingError("Labour staging supports T5 only")

    try:
        target = parse_month_label(target_period)
    except TransformError as exc:
        raise StagingError(f"Invalid target reporting period: {target_period}") from exc

    headers = _header_index(table, header_aliases)
    source_to_canonical: dict[str, str] = {}
    keys = {
        "period": "period",
        "role group": "role_group",
        "area": "role_group",
        "paid hours": "actual_hours",
        "labour cost": "actual_cost",
        "budget hours": "comparator_hours",
        "comparator hours": "comparator_hours",
        "budget labour cost": "comparator_cost",
        "comparator labour cost": "comparator_cost",
        "scheduled hours": "scheduled_hours",
        "overtime hours": "overtime_hours",
        "activity units": "activity_units",
        "workload units": "activity_units",
        "covers or orders": "activity_units",
        "activity type": "activity_basis",
        "workload basis": "activity_basis",
        "notes": "notes",
    }
    for key, canonical_name in keys.items():
        source = headers.get(key)
        if source is not None:
            source_to_canonical[source] = canonical_name

    if "role group" not in headers and "area" not in headers:
        raise StagingError("T5 requires Role_Group or Area")
    if "paid hours" not in headers:
        raise StagingError("T5 requires Paid_Hours")
    if "labour cost" not in headers:
        raise StagingError("T5 requires Labour_Cost")

    period_header = headers.get("period")
    records = table.records()

    def value(record: Mapping[str, str], *keys: str) -> str:
        for key in keys:
            source_header = headers.get(key)
            if source_header is not None:
                return record.get(source_header, "")
        return ""

    def optional_decimal(
        record: Mapping[str, str],
        *,
        keys: tuple[str, ...],
        canonical_field: str,
        source_row_no: int,
        errors: list[Mapping[str, str]],
    ) -> str | None:
        raw_value = value(record, *keys).strip()
        if not raw_value:
            return None
        try:
            return str(parse_decimal(raw_value))
        except Exception:
            errors.append(
                {
                    "code": f"INVALID_{canonical_field.upper()}",
                    "field": canonical_field,
                    "message": (
                        f"Row {source_row_no}: {canonical_field.replace('_', ' ')} "
                        "is not a valid number."
                    ),
                }
            )
            return None

    output: list[StagingRowDraft] = []
    for index, record in enumerate(records):
        source_row_no = _source_row_number(table, index)
        raw = dict(record)
        parsed: dict[str, str] = {}
        errors: list[Mapping[str, str]] = []

        if period_header is not None:
            try:
                row_period = parse_month_label(record[period_header])
            except TransformError:
                errors.append(
                    {
                        "code": "INVALID_PERIOD",
                        "field": "period",
                        "message": f"Row {source_row_no}: period is not recognised.",
                    }
                )
                row_period = target
            if row_period != target:
                continue
            parsed["period"] = row_period
        else:
            parsed["period"] = target

        role_group = value(record, "role group", "area").strip()
        if not role_group:
            errors.append(
                {
                    "code": "MISSING_ROLE_GROUP",
                    "field": "role_group",
                    "message": f"Row {source_row_no}: Role Group / Area is required.",
                }
            )
        else:
            parsed["role_group"] = role_group

        actual_hours = _parse_required_decimal(
            value(record, "paid hours"),
            source_row_no=source_row_no,
            canonical_field="actual_hours",
            label="Paid Hours",
            errors=errors,
        )
        actual_cost = _parse_required_decimal(
            value(record, "labour cost"),
            source_row_no=source_row_no,
            canonical_field="actual_cost",
            label="Labour Cost",
            errors=errors,
        )
        if actual_hours is not None:
            parsed["actual_hours"] = actual_hours
            if Decimal(actual_hours) < 0:
                errors.append(
                    {
                        "code": "ACTUAL_HOURS_NEGATIVE",
                        "field": "actual_hours",
                        "message": f"Row {source_row_no}: Paid Hours cannot be negative.",
                    }
                )
        if actual_cost is not None:
            parsed["actual_cost"] = actual_cost

        for keys_tuple, canonical_field in (
            (("budget hours", "comparator hours"), "comparator_hours"),
            (
                ("budget labour cost", "comparator labour cost"),
                "comparator_cost",
            ),
            (("scheduled hours",), "scheduled_hours"),
            (("overtime hours",), "overtime_hours"),
            (
                ("activity units", "workload units", "covers or orders"),
                "activity_units",
            ),
        ):
            parsed_value = optional_decimal(
                record,
                keys=keys_tuple,
                canonical_field=canonical_field,
                source_row_no=source_row_no,
                errors=errors,
            )
            if parsed_value is not None:
                parsed[canonical_field] = parsed_value
                if (
                    canonical_field
                    in {
                        "comparator_hours",
                        "scheduled_hours",
                        "overtime_hours",
                        "activity_units",
                    }
                    and Decimal(parsed_value) < 0
                ):
                    errors.append(
                        {
                            "code": f"{canonical_field.upper()}_NEGATIVE",
                            "field": canonical_field,
                            "message": (
                                f"Row {source_row_no}: "
                                f"{canonical_field.replace('_', ' ').title()} "
                                "cannot be negative."
                            ),
                        }
                    )

        activity_basis = value(
            record, "activity type", "workload basis"
        ).strip()
        if activity_basis:
            parsed["activity_basis"] = activity_basis

        notes = value(record, "notes").strip()
        if notes:
            parsed["notes"] = notes

        if (
            "budget hours" in headers
            or "budget labour cost" in headers
        ):
            parsed["comparator_scenario"] = "budget"

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

    return LabourStagingResult(
        rows=tuple(output),
        field_map=source_to_canonical,
        target_period=target,
    )
