from __future__ import annotations

import asyncio
import csv
from dataclasses import dataclass
from hashlib import sha256
from io import BytesIO, StringIO
from pathlib import PurePosixPath
import re
import unicodedata
from typing import Protocol
import zipfile
import xml.etree.ElementTree as ET


CSV_CONTENT_TYPE = "text/csv"
XLSX_CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


class UploadSafetyError(ValueError):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code


@dataclass(frozen=True, slots=True)
class UploadPolicy:
    max_file_size_bytes: int = 25 * 1024 * 1024
    max_rows: int = 250_000
    upload_timeout_seconds: float = 60.0
    max_xlsx_entries: int = 2_000
    max_xlsx_uncompressed_bytes: int = 150 * 1024 * 1024
    max_xlsx_entry_bytes: int = 50 * 1024 * 1024
    max_xlsx_compression_ratio: float = 100.0


@dataclass(frozen=True, slots=True)
class InspectionReport:
    file_type: str
    content_type: str
    size_bytes: int
    row_count: int
    sha256_hex: str
    encoding: str | None
    xlsx_entry_count: int | None = None
    xlsx_uncompressed_bytes: int | None = None

    def as_metadata(self) -> dict[str, object]:
        return {
            "file_type": self.file_type,
            "content_type": self.content_type,
            "size_bytes": self.size_bytes,
            "row_count": self.row_count,
            "sha256": self.sha256_hex,
            "encoding": self.encoding,
            "xlsx_entry_count": self.xlsx_entry_count,
            "xlsx_uncompressed_bytes": self.xlsx_uncompressed_bytes,
        }


class AsyncReadable(Protocol):
    async def read(self, size: int = -1) -> bytes: ...


async def read_upload_limited(
    upload: AsyncReadable,
    *,
    policy: UploadPolicy,
    chunk_size: int = 1024 * 1024,
) -> bytes:
    if chunk_size <= 0:
        raise ValueError("chunk_size must be positive")

    chunks: list[bytes] = []
    total = 0
    try:
        async with asyncio.timeout(policy.upload_timeout_seconds):
            while True:
                chunk = await upload.read(chunk_size)
                if not chunk:
                    break
                total += len(chunk)
                if total > policy.max_file_size_bytes:
                    raise UploadSafetyError(
                        "file_size_limit",
                        f"Upload exceeds the {policy.max_file_size_bytes}-byte limit.",
                    )
                chunks.append(chunk)
    except TimeoutError as exc:
        raise UploadSafetyError(
            "upload_timeout",
            f"Upload did not complete within {policy.upload_timeout_seconds:g} seconds.",
        ) from exc

    if total == 0:
        raise UploadSafetyError("empty_file", "Upload is empty.")
    return b"".join(chunks)


def safe_storage_filename(filename: str | None) -> str:
    raw = unicodedata.normalize("NFKC", filename or "").replace("\\", "/")
    base = PurePosixPath(raw).name.strip()
    base = re.sub(r"[^A-Za-z0-9._-]+", "_", base)
    base = base.lstrip(".")
    base = base[:180]
    return base or "upload"


def _decode_csv(data: bytes) -> tuple[str, str]:
    if b"\x00" in data:
        raise UploadSafetyError("binary_content", "NUL bytes are not valid CSV content.")

    for encoding in ("utf-8-sig", "utf-8", "cp1252"):
        try:
            text = data.decode(encoding)
            break
        except UnicodeDecodeError:
            continue
    else:
        raise UploadSafetyError("csv_encoding", "CSV encoding is not supported.")

    if text:
        acceptable = sum(
            character.isprintable() or character in "\r\n\t" for character in text
        )
        if acceptable / len(text) < 0.95:
            raise UploadSafetyError(
                "binary_content",
                "Content does not look like a text CSV file.",
            )
    return text, encoding


def _inspect_csv(data: bytes, policy: UploadPolicy) -> InspectionReport:
    text, encoding = _decode_csv(data)
    try:
        dialect = csv.Sniffer().sniff(text[:8192], delimiters=",;\t|")
    except csv.Error:
        dialect = csv.excel

    rows = 0
    multi_column_seen = False
    try:
        for row in csv.reader(StringIO(text, newline=""), dialect):
            if not any(cell.strip() for cell in row):
                continue
            rows += 1
            multi_column_seen = multi_column_seen or len(row) >= 2
            if rows > policy.max_rows:
                raise UploadSafetyError(
                    "row_limit",
                    f"CSV exceeds the {policy.max_rows:,}-row limit.",
                )
    except csv.Error as exc:
        raise UploadSafetyError("invalid_csv", "CSV structure is invalid.") from exc

    if rows == 0:
        raise UploadSafetyError("empty_file", "CSV contains no non-empty rows.")
    if not multi_column_seen:
        raise UploadSafetyError(
            "invalid_csv",
            "CSV does not contain a recognizable multi-column table.",
        )

    return InspectionReport(
        file_type="csv",
        content_type=CSV_CONTENT_TYPE,
        size_bytes=len(data),
        row_count=rows,
        sha256_hex=sha256(data).hexdigest(),
        encoding=encoding,
    )


def _safe_zip_name(name: str) -> bool:
    normalised = name.replace("\\", "/")
    path = PurePosixPath(normalised)
    return not normalised.startswith("/") and ".." not in path.parts


def _inspect_xlsx(data: bytes, policy: UploadPolicy) -> InspectionReport:
    try:
        archive = zipfile.ZipFile(BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise UploadSafetyError("invalid_xlsx", "XLSX container is not a valid ZIP archive.") from exc

    with archive:
        infos = archive.infolist()
        if len(infos) > policy.max_xlsx_entries:
            raise UploadSafetyError(
                "xlsx_zip_bomb",
                f"XLSX contains more than {policy.max_xlsx_entries:,} archive entries.",
            )

        names = {info.filename for info in infos}
        required = {"[Content_Types].xml", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"}
        if not required.issubset(names):
            raise UploadSafetyError(
                "invalid_xlsx",
                "ZIP content is not a supported XLSX workbook.",
            )

        lower_names = {name.lower() for name in names}
        if any(name.endswith("vbaproject.bin") for name in lower_names):
            raise UploadSafetyError("xlsx_macro", "Macro-enabled workbooks are not accepted.")
        if any(name.startswith("xl/externallinks/") for name in lower_names):
            raise UploadSafetyError(
                "xlsx_external_link",
                "XLSX external links are not accepted.",
            )

        total_uncompressed = 0
        for info in infos:
            if not _safe_zip_name(info.filename):
                raise UploadSafetyError(
                    "xlsx_path_traversal",
                    "XLSX contains an unsafe archive path.",
                )
            if info.flag_bits & 0x1:
                raise UploadSafetyError(
                    "xlsx_encrypted",
                    "Encrypted XLSX archive entries are not accepted.",
                )
            if info.file_size > policy.max_xlsx_entry_bytes:
                raise UploadSafetyError(
                    "xlsx_zip_bomb",
                    "An XLSX archive entry exceeds the uncompressed entry-size limit.",
                )
            total_uncompressed += info.file_size
            if total_uncompressed > policy.max_xlsx_uncompressed_bytes:
                raise UploadSafetyError(
                    "xlsx_zip_bomb",
                    "XLSX exceeds the total uncompressed-size limit.",
                )
            if info.file_size > 0:
                ratio = info.file_size / max(info.compress_size, 1)
                if ratio > policy.max_xlsx_compression_ratio:
                    raise UploadSafetyError(
                        "xlsx_zip_bomb",
                        "XLSX compression ratio exceeds the permitted safety limit.",
                    )

        sheet_names = sorted(
            name
            for name in names
            if name.startswith("xl/worksheets/") and name.endswith(".xml")
        )
        if not sheet_names:
            raise UploadSafetyError("invalid_xlsx", "XLSX contains no worksheets.")

        row_count = 0
        formula_cells = 0
        try:
            for sheet_name in sheet_names:
                with archive.open(sheet_name) as stream:
                    for _, element in ET.iterparse(stream, events=("end",)):
                        local_name = element.tag.rsplit("}", 1)[-1]
                        if local_name == "row":
                            row_count += 1
                            if row_count > policy.max_rows:
                                raise UploadSafetyError(
                                    "row_limit",
                                    f"XLSX exceeds the {policy.max_rows:,}-row limit.",
                                )
                        elif local_name == "f":
                            formula_cells += 1
                        element.clear()
        except ET.ParseError as exc:
            raise UploadSafetyError("invalid_xlsx", "XLSX worksheet XML is invalid.") from exc

        if formula_cells:
            raise UploadSafetyError(
                "xlsx_formula",
                (
                    f"XLSX contains {formula_cells} formula cell(s). "
                    "R1 accepts values-only workbooks so formulas cannot execute "
                    "or enter stored source data."
                ),
            )
        if row_count == 0:
            raise UploadSafetyError("empty_file", "XLSX contains no worksheet rows.")

        return InspectionReport(
            file_type="xlsx",
            content_type=XLSX_CONTENT_TYPE,
            size_bytes=len(data),
            row_count=row_count,
            sha256_hex=sha256(data).hexdigest(),
            encoding=None,
            xlsx_entry_count=len(infos),
            xlsx_uncompressed_bytes=total_uncompressed,
        )


def inspect_upload(data: bytes, *, policy: UploadPolicy | None = None) -> InspectionReport:
    policy = policy or UploadPolicy()
    if not data:
        raise UploadSafetyError("empty_file", "Upload is empty.")
    if len(data) > policy.max_file_size_bytes:
        raise UploadSafetyError(
            "file_size_limit",
            f"Upload exceeds the {policy.max_file_size_bytes}-byte limit.",
        )

    if zipfile.is_zipfile(BytesIO(data)):
        return _inspect_xlsx(data, policy)
    return _inspect_csv(data, policy)
