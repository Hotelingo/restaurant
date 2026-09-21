from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, datetime
from decimal import Decimal, InvalidOperation
import re
from typing import Literal, Mapping, Sequence

from .model import ParsedTable, parse_decimal


class TransformError(ValueError):
    pass


TransformCode = Literal[
    "trim_whitespace",
    "case_normalization",
    "remove_thousands_separators",
    "sign_flip",
    "fixed_factor",
    "tax_strip",
    "parse_date",
    "parse_month_label",
    "unpivot_month_columns",
    "split_delimited",
    "fixed_value",
    "controlled_value_map",
    "controlled_uom_conversion",
]

CLOSED_TRANSFORM_CODES: frozenset[str] = frozenset(
    {
        "trim_whitespace",
        "case_normalization",
        "remove_thousands_separators",
        "sign_flip",
        "fixed_factor",
        "tax_strip",
        "parse_date",
        "parse_month_label",
        "unpivot_month_columns",
        "split_delimited",
        "fixed_value",
        "controlled_value_map",
        "controlled_uom_conversion",
    }
)


@dataclass(frozen=True, slots=True)
class TransformSpec:
    code: str
    params: Mapping[str, object] = field(default_factory=dict)

    def __post_init__(self) -> None:
        if self.code not in CLOSED_TRANSFORM_CODES:
            raise TransformError(f"Unsupported transform code: {self.code}")


def trim_whitespace(value: str) -> str:
    return value.strip()


def case_normalization(
    value: str,
    *,
    mode: Literal["lower", "upper", "title", "casefold"] = "casefold",
) -> str:
    text = value.strip()
    if mode == "lower":
        return text.lower()
    if mode == "upper":
        return text.upper()
    if mode == "title":
        return text.title()
    if mode == "casefold":
        return text.casefold()
    raise TransformError(f"Unsupported case-normalization mode: {mode}")


def remove_thousands_separators(
    value: str,
    *,
    separators: Sequence[str] = (",", "\u00a0", "\u202f"),
) -> str:
    result = value.strip()
    for separator in separators:
        if not isinstance(separator, str) or separator == "":
            raise TransformError("Thousands separators must be non-empty strings")
        result = result.replace(separator, "")
    return result


def sign_flip(value: str | Decimal) -> Decimal:
    number = value if isinstance(value, Decimal) else parse_decimal(value)
    return -number


def fixed_factor(
    value: str | Decimal,
    *,
    factor: str | Decimal,
    operation: Literal["multiply", "divide"] = "multiply",
) -> Decimal:
    number = value if isinstance(value, Decimal) else parse_decimal(value)
    multiplier = factor if isinstance(factor, Decimal) else Decimal(factor)
    if operation == "multiply":
        return number * multiplier
    if operation == "divide":
        if multiplier == 0:
            raise TransformError("Cannot divide by zero")
        return number / multiplier
    raise TransformError(f"Unsupported fixed-factor operation: {operation}")


def tax_strip(
    value: str | Decimal,
    *,
    rate: str | Decimal,
    basis: Literal["inclusive", "exclusive"],
) -> Decimal:
    amount = value if isinstance(value, Decimal) else parse_decimal(value)
    tax_rate = rate if isinstance(rate, Decimal) else Decimal(rate)
    if tax_rate < 0:
        raise TransformError("Tax rate cannot be negative")
    if basis == "exclusive":
        return amount
    if basis == "inclusive":
        return amount / (Decimal("1") + tax_rate)
    raise TransformError(f"Unsupported tax basis: {basis}")


_DATE_FORMATS = (
    "%Y-%m-%d",
    "%d/%m/%Y",
    "%d-%m-%Y",
    "%m/%d/%Y",
    "%Y/%m/%d",
    "%d %b %Y",
    "%d %B %Y",
)


def parse_date(
    value: str,
    *,
    formats: Sequence[str] = _DATE_FORMATS,
) -> date:
    text = value.strip()
    if not text:
        raise TransformError("Date value is blank")

    for format_string in formats:
        try:
            return datetime.strptime(text, format_string).date()
        except ValueError:
            continue
    raise TransformError(f"Unsupported date value: {value}")


_MONTH_NAME_TO_NUMBER = {
    "jan": 1,
    "january": 1,
    "feb": 2,
    "february": 2,
    "mar": 3,
    "march": 3,
    "apr": 4,
    "april": 4,
    "may": 5,
    "jun": 6,
    "june": 6,
    "jul": 7,
    "july": 7,
    "aug": 8,
    "august": 8,
    "sep": 9,
    "sept": 9,
    "september": 9,
    "oct": 10,
    "october": 10,
    "nov": 11,
    "november": 11,
    "dec": 12,
    "december": 12,
}
_SCENARIO_PREFIXES = ("budget", "forecast", "prior year", "prior_year", "actual")


def parse_month_label(value: str) -> str:
    text = value.strip().lower()
    text = re.sub(r"[_/.\-]+", " ", text)
    text = " ".join(text.split())

    for prefix in _SCENARIO_PREFIXES:
        prefix_normalised = prefix.replace("_", " ")
        if text.startswith(prefix_normalised + " "):
            text = text[len(prefix_normalised) + 1 :]
            break

    numeric = re.fullmatch(r"(\d{4})\s+(\d{1,2})", text)
    if numeric:
        year = int(numeric.group(1))
        month = int(numeric.group(2))
        if 1 <= month <= 12:
            return f"{year:04d}-{month:02d}"

    named = re.fullmatch(r"([a-z]+)\s+(\d{4})", text)
    if named:
        month = _MONTH_NAME_TO_NUMBER.get(named.group(1))
        if month is not None:
            return f"{int(named.group(2)):04d}-{month:02d}"

    raise TransformError(f"Unsupported month label: {value}")


def split_delimited(
    value: str,
    *,
    delimiter: str,
    expected_parts: int | None = None,
    strip_parts: bool = True,
) -> tuple[str, ...]:
    if delimiter == "":
        raise TransformError("Delimiter cannot be empty")
    parts = tuple(value.split(delimiter))
    if strip_parts:
        parts = tuple(part.strip() for part in parts)
    if expected_parts is not None and len(parts) != expected_parts:
        raise TransformError(
            f"Expected {expected_parts} parts separated by {delimiter!r}; got {len(parts)}"
        )
    return parts


def fixed_value(*, value: object) -> object:
    return value


def controlled_value_map(
    value: str,
    *,
    mapping: Mapping[str, str],
    case_sensitive: bool = False,
) -> str:
    if case_sensitive:
        if value not in mapping:
            raise TransformError(f"No controlled mapping for value: {value}")
        return mapping[value]

    lookup = {key.strip().casefold(): mapped for key, mapped in mapping.items()}
    key = value.strip().casefold()
    if key not in lookup:
        raise TransformError(f"No controlled mapping for value: {value}")
    return lookup[key]


def controlled_uom_conversion(
    value: str | Decimal,
    *,
    from_uom: str,
    to_uom: str,
    conversions: Mapping[tuple[str, str], str | Decimal],
) -> Decimal:
    number = value if isinstance(value, Decimal) else parse_decimal(value)
    normalised = {
        (source.strip().casefold(), target.strip().casefold()):
        (factor if isinstance(factor, Decimal) else Decimal(factor))
        for (source, target), factor in conversions.items()
    }
    key = (from_uom.strip().casefold(), to_uom.strip().casefold())
    if key not in normalised:
        raise TransformError(f"No controlled UOM conversion from {from_uom} to {to_uom}")
    return number * normalised[key]


def unpivot_month_columns(
    table: ParsedTable,
    *,
    id_columns: Sequence[str] | None = None,
    period_field: str = "Period",
    value_field: str = "Amount",
    month_columns: Sequence[str] | None = None,
    include_blank: bool = False,
) -> tuple[dict[str, str], ...]:
    records = table.records()
    header_set = set(table.headers)

    if id_columns is None:
        if month_columns is None:
            detected: list[str] = []
            for header in table.headers:
                try:
                    parse_month_label(header)
                except TransformError:
                    continue
                detected.append(header)
            month_columns = tuple(detected)
        month_set = set(month_columns)
        id_columns = tuple(header for header in table.headers if header not in month_set)

    if month_columns is None:
        month_columns = tuple(header for header in table.headers if header not in set(id_columns))

    missing = (set(id_columns) | set(month_columns)) - header_set
    if missing:
        raise TransformError(f"Unpivot references unknown columns: {sorted(missing)}")
    if not month_columns:
        raise TransformError("No month columns supplied or detected")

    parsed_months = {header: parse_month_label(header) for header in month_columns}

    output: list[dict[str, str]] = []
    for record in records:
        identity = {column: record[column] for column in id_columns}
        for header in month_columns:
            raw_value = record[header]
            if raw_value == "" and not include_blank:
                continue
            output.append(
                {
                    **identity,
                    period_field: parsed_months[header],
                    value_field: raw_value,
                }
            )
    return tuple(output)


def apply_scalar_transform(value: object, spec: TransformSpec) -> object:
    """Execute only a member of the closed transform registry.

    There is intentionally no callback, expression, import path, eval/exec or
    customer-supplied function hook in this dispatcher.
    """

    code = spec.code
    params = dict(spec.params)

    if code == "trim_whitespace":
        return trim_whitespace(str(value))
    if code == "case_normalization":
        return case_normalization(str(value), **params)
    if code == "remove_thousands_separators":
        return remove_thousands_separators(str(value), **params)
    if code == "sign_flip":
        return sign_flip(value)  # type: ignore[arg-type]
    if code == "fixed_factor":
        return fixed_factor(value, **params)  # type: ignore[arg-type]
    if code == "tax_strip":
        return tax_strip(value, **params)  # type: ignore[arg-type]
    if code == "parse_date":
        return parse_date(str(value), **params)
    if code == "parse_month_label":
        return parse_month_label(str(value))
    if code == "split_delimited":
        return split_delimited(str(value), **params)
    if code == "fixed_value":
        return fixed_value(**params)
    if code == "controlled_value_map":
        return controlled_value_map(str(value), **params)
    if code == "controlled_uom_conversion":
        return controlled_uom_conversion(value, **params)  # type: ignore[arg-type]
    if code == "unpivot_month_columns":
        raise TransformError("unpivot_month_columns is a table transform")

    raise TransformError(f"Unsupported scalar transform code: {code}")


def apply_table_transform(table: ParsedTable, spec: TransformSpec) -> object:
    if spec.code != "unpivot_month_columns":
        raise TransformError(f"{spec.code} is not a table transform")
    return unpivot_month_columns(table, **dict(spec.params))
