from __future__ import annotations

import asyncio
from io import BytesIO
import unittest
import zipfile

from app.upload_safety import (
    CSV_CONTENT_TYPE,
    XLSX_CONTENT_TYPE,
    UploadPolicy,
    UploadSafetyError,
    inspect_upload,
    read_upload_limited,
    safe_storage_filename,
)


def make_xlsx(*, formula: bool = False, traversal: bool = False) -> bytes:
    formula_xml = "<f>SUM(C2:C2)</f>" if formula else ""
    files = {
        "[Content_Types].xml": """<?xml version="1.0"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>""",
        "xl/workbook.xml": """<?xml version="1.0"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"/>""",
        "xl/_rels/workbook.xml.rels": """<?xml version="1.0"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"/>""",
        "xl/worksheets/sheet1.xml": f"""<?xml version="1.0"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <sheetData>
  <row r="1"><c r="A1" t="inlineStr"><is><t>Account</t></is></c><c r="B1" t="inlineStr"><is><t>Amount</t></is></c></row>
  <row r="2"><c r="A2" t="inlineStr"><is><t>Sales</t></is></c><c r="B2">{formula_xml}<v>100</v></c></row>
 </sheetData>
</worksheet>""",
    }
    if traversal:
        files["../escape.txt"] = "bad"

    output = BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return output.getvalue()


class FakeUpload:
    def __init__(self, chunks: list[bytes], delay: float = 0):
        self.chunks = list(chunks)
        self.delay = delay

    async def read(self, size: int = -1) -> bytes:
        if self.delay:
            await asyncio.sleep(self.delay)
        if not self.chunks:
            return b""
        return self.chunks.pop(0)


class UploadSafetyTests(unittest.IsolatedAsyncioTestCase):
    def test_csv_is_detected_from_content_not_extension(self) -> None:
        report = inspect_upload(b"Account,Amount\nSales,100\n")
        self.assertEqual(report.file_type, "csv")
        self.assertEqual(report.content_type, CSV_CONTENT_TYPE)
        self.assertEqual(report.row_count, 2)
        self.assertEqual(len(report.sha256_hex), 64)

    def test_csv_row_limit_is_enforced(self) -> None:
        with self.assertRaises(UploadSafetyError) as caught:
            inspect_upload(
                b"A,B\n1,2\n3,4\n",
                policy=UploadPolicy(max_rows=2),
            )
        self.assertEqual(caught.exception.code, "row_limit")

    def test_binary_payload_is_not_accepted_as_csv(self) -> None:
        with self.assertRaises(UploadSafetyError) as caught:
            inspect_upload(b"\x00\x01\x02\x03")
        self.assertEqual(caught.exception.code, "binary_content")

    def test_xlsx_is_detected_by_container_structure(self) -> None:
        report = inspect_upload(make_xlsx())
        self.assertEqual(report.file_type, "xlsx")
        self.assertEqual(report.content_type, XLSX_CONTENT_TYPE)
        self.assertEqual(report.row_count, 2)

    def test_xlsx_formula_cells_are_rejected(self) -> None:
        with self.assertRaises(UploadSafetyError) as caught:
            inspect_upload(make_xlsx(formula=True))
        self.assertEqual(caught.exception.code, "xlsx_formula")

    def test_xlsx_path_traversal_is_rejected(self) -> None:
        with self.assertRaises(UploadSafetyError) as caught:
            inspect_upload(make_xlsx(traversal=True))
        self.assertEqual(caught.exception.code, "xlsx_path_traversal")

    def test_xlsx_compression_ratio_limit_is_enforced(self) -> None:
        output = BytesIO()
        with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
            archive.writestr("[Content_Types].xml", "x" * 100_000)
            archive.writestr("xl/workbook.xml", "<workbook/>")
            archive.writestr("xl/_rels/workbook.xml.rels", "<Relationships/>")
            archive.writestr("xl/worksheets/sheet1.xml", "<worksheet><row/></worksheet>")
        with self.assertRaises(UploadSafetyError) as caught:
            inspect_upload(
                output.getvalue(),
                policy=UploadPolicy(max_xlsx_compression_ratio=2),
            )
        self.assertEqual(caught.exception.code, "xlsx_zip_bomb")

    async def test_stream_size_limit_is_enforced(self) -> None:
        upload = FakeUpload([b"1234", b"5678"])
        with self.assertRaises(UploadSafetyError) as caught:
            await read_upload_limited(
                upload,
                policy=UploadPolicy(max_file_size_bytes=6),
                chunk_size=4,
            )
        self.assertEqual(caught.exception.code, "file_size_limit")

    async def test_upload_timeout_is_enforced(self) -> None:
        upload = FakeUpload([b"abc"], delay=0.05)
        with self.assertRaises(UploadSafetyError) as caught:
            await read_upload_limited(
                upload,
                policy=UploadPolicy(upload_timeout_seconds=0.01),
            )
        self.assertEqual(caught.exception.code, "upload_timeout")

    def test_storage_filename_removes_path_and_unsafe_characters(self) -> None:
        self.assertEqual(
            safe_storage_filename("../../Quarter 1 / P&L July.csv"),
            "P_L_July.csv",
        )


if __name__ == "__main__":
    unittest.main()
