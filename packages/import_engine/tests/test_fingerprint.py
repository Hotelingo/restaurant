from __future__ import annotations

from dataclasses import replace
from uuid import UUID
import unittest

from packages.import_engine import (
    ConfidenceBands,
    ParsedTable,
    ProfileScope,
    ProfileVersion,
    build_fingerprint,
    match_profile,
)

ORG_A = UUID("60000000-0000-0000-0000-000000000001")
ORG_B = UUID("60000000-0000-0000-0000-000000000002")
OUTLET = UUID("60000000-0000-0000-0000-000000000010")


def table(headers: tuple[str, ...], rows: tuple[tuple[str, ...], ...], *, sheet: str = "__csv__") -> ParsedTable:
    return ParsedTable(
        source_name="test.csv",
        sheet_name=sheet,
        file_type="csv",
        encoding="utf-8",
        header_row=1,
        headers=headers,
        rows=rows,
        orientation="wide_months" if any("2026" in value for value in headers) else "rows",
    )


def profile_for(source: ParsedTable, scope: ProfileScope, version: int = 1) -> ProfileVersion:
    fingerprint, keys = build_fingerprint(source, scope.template_code)
    return ProfileVersion(
        scope=scope,
        version=version,
        fingerprint=fingerprint,
        source_keys=keys,
        headers=source.headers,
    )


class FingerprintTests(unittest.TestCase):
    def setUp(self) -> None:
        self.scope = ProfileScope(ORG_A, OUTLET, "T1")
        self.bands = ConfidenceBands(high=0.92, review=0.75)
        self.aliases = {"gl code": "account code", "account description": "account name"}
        self.base = table(
            ("Account_Code", "Account_Name", "July_2026"),
            (("4000", "Food sales", "100"), ("5000", "Food cost", "30")),
        )

    def test_row_count_is_excluded_from_fingerprint(self) -> None:
        duplicate_row = table(
            self.base.headers,
            self.base.rows + (("4000", "Food sales", "100"),),
        )
        first, _ = build_fingerprint(self.base, "T1")
        second, _ = build_fingerprint(duplicate_row, "T1")
        self.assertEqual(first.signature, second.signature)

    def test_reupload_exactly_reuses_profile(self) -> None:
        profile = profile_for(self.base, self.scope, version=4)
        result = match_profile(
            scope=self.scope,
            table=self.base,
            profiles=(profile,),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "exact")
        self.assertEqual(result.message, "Mapping reused from profile v4")

    def test_new_source_identity_is_new_rows_only(self) -> None:
        profile = profile_for(self.base, self.scope)
        expanded = table(
            self.base.headers,
            self.base.rows + (("6100", "Packaging", "5"),),
        )
        result = match_profile(
            scope=self.scope,
            table=expanded,
            profiles=(profile,),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "new_rows_only")

    def test_renamed_and_moved_columns_are_review_candidate(self) -> None:
        profile = profile_for(self.base, self.scope)
        drifted = table(
            ("July 2026", "GL Code", "Account Description"),
            (("100", "4000", "Food sales"), ("30", "5000", "Food cost")),
        )
        result = match_profile(
            scope=self.scope,
            table=drifted,
            profiles=(profile,),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "renamed_moved_columns")
        self.assertTrue(all(item.band != "unmapped" for item in result.suggestions))

    def test_different_sheet_is_different_layout(self) -> None:
        profile = profile_for(self.base, self.scope)
        changed = replace(self.base, sheet_name="Other Sheet")
        result = match_profile(
            scope=self.scope,
            table=changed,
            profiles=(profile,),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "different_layout")

    def test_profile_matching_is_strictly_tenant_scoped(self) -> None:
        other_scope = ProfileScope(ORG_B, OUTLET, "T1")
        other = profile_for(self.base, other_scope)
        result = match_profile(
            scope=self.scope,
            table=self.base,
            profiles=(other,),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "different_layout")
        self.assertIsNone(result.profile)

    def test_collision_inside_scope_requires_manual_resolution(self) -> None:
        one = profile_for(self.base, self.scope, version=1)
        two = profile_for(self.base, self.scope, version=2)
        result = match_profile(
            scope=self.scope,
            table=self.base,
            profiles=(one, two),
            confidence_bands=self.bands,
            aliases=self.aliases,
        )
        self.assertEqual(result.tier, "manual_resolution")
        self.assertIsNone(result.profile)

    def test_confidence_bands_have_no_implicit_product_default(self) -> None:
        with self.assertRaises(ValueError):
            ConfidenceBands(high=0.75, review=0.92)


if __name__ == "__main__":
    unittest.main()
