from __future__ import annotations

from io import BytesIO
from pathlib import Path
from decimal import Decimal
import unittest
import zipfile

from packages.import_engine import ParseError, parse_decimal, parse_source

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "fixtures" / "amberside" / "upload_files"

AMBerside_FILES = {
    "Amberside_PnL_Jul2026.csv": "T1",
    "Amberside_MealPeriods_Jul2026.csv": "T1B",
    "Amberside_POS_ItemSales_Jul2026.csv": "T2",
    "Amberside_Stock_Jul2026.csv": "T3",
    "Amberside_RecipeCosts.csv": "T4A",
    "Amberside_Labour_Jul2026.csv": "T5",
    "Amberside_Budget_Jul2026.csv": "T6",
    "Amberside_CustomerSource_Jul2026.csv": "T7",
    "Amberside_Transactions_Jul2026.csv": "T8",
    "Amberside_MenuHistory_JanAug2026.csv": "M1",
}


def minimal_xlsx() -> bytes:
    files = {
        "[Content_Types].xml": """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
 <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
 <Default Extension="xml" ContentType="application/xml"/>
</Types>""",
        "xl/workbook.xml": """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
 xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
 <sheets><sheet name="P&amp;L" sheetId="1" r:id="rId1"/></sheets>
</workbook>""",
        "xl/_rels/workbook.xml.rels": """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
 <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>""",
        "xl/worksheets/sheet1.xml": """<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
 <sheetData>
  <row r="1">
   <c r="A1" t="inlineStr"><is><t>Account_Code</t></is></c>
   <c r="B1" t="inlineStr"><is><t>Account_Name</t></is></c>
   <c r="C1" t="inlineStr"><is><t>July_2026</t></is></c>
  </row>
  <row r="2">
   <c r="A2" t="inlineStr"><is><t>4000</t></is></c>
   <c r="B2" t="inlineStr"><is><t>Food sales</t></is></c>
   <c r="C2"><v>191100</v></c>
  </row>
 </sheetData>
</worksheet>""",
    }
    output = BytesIO()
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)
    return output.getvalue()


class ParserTests(unittest.TestCase):
    def test_all_ten_amberside_ingestion_fixtures_parse(self) -> None:
        self.assertEqual(len(AMBerside_FILES), 10)
        for filename in AMBerside_FILES:
            with self.subTest(filename=filename):
                document = parse_source(filename, (FIXTURES / filename).read_bytes())
                self.assertEqual(len(document.tables), 1)
                table = document.tables[0]
                self.assertEqual(table.header_row, 1)
                self.assertGreater(table.row_count, 0)
                self.assertGreater(table.column_count, 1)
                self.assertFalse(table.headers[0].startswith("\ufeff"))

    def test_wide_pnl_month_column_remains_header(self) -> None:
        document = parse_source(
            "Amberside_PnL_Jul2026.csv",
            (FIXTURES / "Amberside_PnL_Jul2026.csv").read_bytes(),
        )
        table = document.tables[0]
        self.assertIn("July_2026", table.headers)
        self.assertEqual(table.orientation, "wide_months")

    def test_utf8_bom_and_cp1252_are_supported(self) -> None:
        utf8 = b"\xef\xbb\xbfAccount_Name,Amount\nCafe,100\n"
        self.assertEqual(parse_source("bom.csv", utf8).tables[0].headers[0], "Account_Name")

        cp1252 = "Account_Name,Amount\nCaf\xe9,100\n".encode("cp1252")
        table = parse_source("legacy.csv", cp1252).tables[0]
        self.assertEqual(table.encoding, "cp1252")
        self.assertEqual(table.rows[0][0], "Café")

    def test_finance_number_parser_handles_thousands_and_parentheses(self) -> None:
        self.assertEqual(parse_decimal("1,234.50"), Decimal("1234.50"))
        self.assertEqual(parse_decimal("(1,234.50)"), Decimal("-1234.50"))
        self.assertEqual(parse_decimal("−2,000"), Decimal("-2000"))

    def test_minimal_xlsx_uses_same_intermediate_representation(self) -> None:
        document = parse_source("sample.xlsx", minimal_xlsx())
        table = document.tables[0]
        self.assertEqual(table.file_type, "xlsx")
        self.assertEqual(table.sheet_name, "P&L")
        self.assertEqual(table.headers, ("Account_Code", "Account_Name", "July_2026"))
        self.assertEqual(table.rows[0], ("4000", "Food sales", "191100"))
        self.assertEqual(table.orientation, "wide_months")

    def test_rejects_unsupported_file_type(self) -> None:
        with self.assertRaises(ParseError):
            parse_source("statement.pdf", b"%PDF")


if __name__ == "__main__":
    unittest.main()
