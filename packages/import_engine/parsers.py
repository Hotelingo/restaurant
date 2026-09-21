from __future__ import annotations

import csv
from io import BytesIO, StringIO
from pathlib import PurePosixPath
import re
from typing import Iterable
import zipfile
import xml.etree.ElementTree as ET

from .model import ParsedDocument, ParsedTable
from .registry import KNOWN_HEADER_TERMS, looks_like_month_header, normalise_text


class ParseError(ValueError):
    pass


def _decode_csv(data: bytes) -> tuple[str, str]:
    for encoding in ("utf-8-sig", "utf-8", "cp1252"):
        try:
            return data.decode(encoding), encoding
        except UnicodeDecodeError:
            continue
    raise ParseError("CSV encoding is not supported")


def _normalise_matrix(rows: Iterable[Iterable[object]]) -> list[list[str]]:
    matrix: list[list[str]] = []
    for row in rows:
        values = ["" if value is None else str(value).strip() for value in row]
        while values and values[-1] == "":
            values.pop()
        if any(value != "" for value in values):
            matrix.append(values)

    width = max((len(row) for row in matrix), default=0)
    if width == 0:
        raise ParseError("Source contains no tabular data")
    return [row + [""] * (width - len(row)) for row in matrix]


def _header_score(row: list[str], index: int) -> tuple[int, int]:
    nonblank = [value for value in row if value.strip()]
    if len(nonblank) < 2:
        return (-1, -index)

    normalised = [normalise_text(value) for value in nonblank]
    known = sum(value in KNOWN_HEADER_TERMS for value in normalised)
    month = sum(looks_like_month_header(value) for value in nonblank)
    unique = len(set(normalised))
    alpha = sum(any(ch.isalpha() for ch in value) for value in nonblank)
    score = known * 20 + month * 10 + unique * 2 + alpha
    return (score, -index)


def _detect_header_row(matrix: list[list[str]]) -> int:
    scores = [(_header_score(row, index), index) for index, row in enumerate(matrix[:25])]
    (best_score, _), best_index = max(scores, key=lambda item: item[0])
    return 0 if best_score < 4 else best_index


def _orientation(headers: tuple[str, ...]) -> str:
    normalised = {normalise_text(header) for header in headers}
    has_explicit_period = "period" in normalised or "effective from" in normalised
    has_month_columns = any(looks_like_month_header(header) for header in headers)
    return "wide_months" if has_month_columns and not has_explicit_period else "rows"


def _table_from_matrix(
    *,
    source_name: str,
    sheet_name: str,
    file_type: str,
    encoding: str | None,
    matrix: list[list[str]],
) -> ParsedTable:
    header_index = _detect_header_row(matrix)
    raw_headers = matrix[header_index]
    width = len(raw_headers)

    headers: list[str] = []
    for index, value in enumerate(raw_headers, start=1):
        cleaned = value.lstrip("\ufeff").strip()
        headers.append(cleaned or f"Column_{index}")

    rows: list[tuple[str, ...]] = []
    for raw in matrix[header_index + 1 :]:
        row = tuple((raw + [""] * width)[:width])
        if any(value != "" for value in row):
            rows.append(row)

    header_tuple = tuple(headers)
    return ParsedTable(
        source_name=source_name,
        sheet_name=sheet_name,
        file_type=file_type,  # type: ignore[arg-type]
        encoding=encoding,
        header_row=header_index + 1,
        headers=header_tuple,
        rows=tuple(rows),
        orientation=_orientation(header_tuple),  # type: ignore[arg-type]
    )


def parse_csv(source_name: str, data: bytes) -> ParsedDocument:
    text, encoding = _decode_csv(data)
    try:
        dialect = csv.Sniffer().sniff(text[:8192], delimiters=",;\t|")
    except csv.Error:
        dialect = csv.excel

    matrix = _normalise_matrix(csv.reader(StringIO(text, newline=""), dialect))
    table = _table_from_matrix(
        source_name=source_name,
        sheet_name="__csv__",
        file_type="csv",
        encoding=encoding,
        matrix=matrix,
    )
    return ParsedDocument(source_name=source_name, file_type="csv", tables=(table,))


_MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
_PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"


def _xlsx_shared_strings(archive: zipfile.ZipFile) -> list[str]:
    path = "xl/sharedStrings.xml"
    if path not in archive.namelist():
        return []
    root = ET.fromstring(archive.read(path))
    return [
        "".join(node.text or "" for node in si.iter(f"{{{_MAIN_NS}}}t"))
        for si in root.findall(f"{{{_MAIN_NS}}}si")
    ]


def _xlsx_sheet_targets(archive: zipfile.ZipFile) -> list[tuple[str, str]]:
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    rel_map = {
        rel.attrib["Id"]: rel.attrib["Target"]
        for rel in rels.findall(f"{{{_PKG_REL_NS}}}Relationship")
    }

    sheets: list[tuple[str, str]] = []
    for sheet in workbook.findall(f".//{{{_MAIN_NS}}}sheet"):
        rel_id = sheet.attrib[f"{{{_REL_NS}}}id"]
        target = rel_map[rel_id].lstrip("/")
        if not target.startswith("xl/"):
            target = str(PurePosixPath("xl") / target)
        sheets.append((sheet.attrib["name"], target))
    return sheets


_CELL_REF_RE = re.compile(r"([A-Z]+)(\d+)")


def _column_index(cell_ref: str) -> int:
    match = _CELL_REF_RE.fullmatch(cell_ref)
    if not match:
        raise ParseError(f"Invalid XLSX cell reference: {cell_ref}")
    result = 0
    for char in match.group(1):
        result = result * 26 + (ord(char) - ord("A") + 1)
    return result - 1


def _xlsx_cell_value(cell: ET.Element, shared: list[str]) -> str:
    cell_type = cell.attrib.get("t")
    if cell_type == "inlineStr":
        inline = cell.find(f"{{{_MAIN_NS}}}is")
        if inline is None:
            return ""
        return "".join(node.text or "" for node in inline.iter(f"{{{_MAIN_NS}}}t")).strip()

    value_node = cell.find(f"{{{_MAIN_NS}}}v")
    if value_node is None or value_node.text is None:
        return ""

    raw = value_node.text
    if cell_type == "s":
        try:
            return shared[int(raw)].strip()
        except (ValueError, IndexError) as exc:
            raise ParseError("XLSX shared-string index is invalid") from exc
    if cell_type == "b":
        return "TRUE" if raw == "1" else "FALSE"
    return raw.strip()


def _xlsx_matrix(archive: zipfile.ZipFile, path: str, shared: list[str]) -> list[list[str]]:
    root = ET.fromstring(archive.read(path))
    rows: list[list[str]] = []
    for row_node in root.findall(f".//{{{_MAIN_NS}}}row"):
        values: list[str] = []
        for cell in row_node.findall(f"{{{_MAIN_NS}}}c"):
            col = _column_index(cell.attrib.get("r", ""))
            while len(values) <= col:
                values.append("")
            values[col] = _xlsx_cell_value(cell, shared)
        rows.append(values)
    return _normalise_matrix(rows)


def parse_xlsx(source_name: str, data: bytes) -> ParsedDocument:
    try:
        with zipfile.ZipFile(BytesIO(data)) as archive:
            required = {"xl/workbook.xml", "xl/_rels/workbook.xml.rels"}
            if not required.issubset(archive.namelist()):
                raise ParseError("XLSX workbook structure is incomplete")

            shared = _xlsx_shared_strings(archive)
            tables = tuple(
                _table_from_matrix(
                    source_name=source_name,
                    sheet_name=sheet_name,
                    file_type="xlsx",
                    encoding=None,
                    matrix=_xlsx_matrix(archive, path, shared),
                )
                for sheet_name, path in _xlsx_sheet_targets(archive)
                if path in archive.namelist()
            )
    except zipfile.BadZipFile as exc:
        raise ParseError("XLSX is not a valid ZIP workbook") from exc
    except ET.ParseError as exc:
        raise ParseError("XLSX contains invalid XML") from exc

    if not tables:
        raise ParseError("XLSX contains no readable worksheets")
    return ParsedDocument(source_name=source_name, file_type="xlsx", tables=tables)


def parse_source(source_name: str, data: bytes) -> ParsedDocument:
    suffix = PurePosixPath(source_name).suffix.lower()
    if suffix == ".csv":
        return parse_csv(source_name, data)
    if suffix == ".xlsx":
        return parse_xlsx(source_name, data)
    raise ParseError("Only CSV and XLSX are supported by the automated parser")
