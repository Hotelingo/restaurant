from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from typing import Literal

Orientation = Literal["rows", "wide_months"]
FileType = Literal["csv", "xlsx"]


@dataclass(frozen=True, slots=True)
class ParsedTable:
    """Uniform, immutable intermediate representation for one source table."""

    source_name: str
    sheet_name: str
    file_type: FileType
    encoding: str | None
    header_row: int
    headers: tuple[str, ...]
    rows: tuple[tuple[str, ...], ...]
    orientation: Orientation

    @property
    def column_count(self) -> int:
        return len(self.headers)

    @property
    def row_count(self) -> int:
        return len(self.rows)

    def records(self) -> tuple[dict[str, str], ...]:
        return tuple(dict(zip(self.headers, row, strict=True)) for row in self.rows)


@dataclass(frozen=True, slots=True)
class ParsedDocument:
    source_name: str
    file_type: FileType
    tables: tuple[ParsedTable, ...]


def parse_decimal(value: str) -> Decimal:
    """Parse a finance-style decimal without guessing field semantics."""
    text = value.strip()
    if not text:
        raise ValueError("numeric value is blank")

    negative = text.startswith("(") and text.endswith(")")
    if negative:
        text = text[1:-1].strip()

    text = (
        text.replace("\u2212", "-")
        .replace("\u00a0", "")
        .replace("\u202f", "")
        .replace(",", "")
    )
    for symbol in ("$", "€", "£", "¥"):
        text = text.replace(symbol, "")

    number = Decimal(text.strip())
    return -number if negative else number
