from __future__ import annotations

import unittest

from packages.import_engine.mapping import (
    AccountMappingRule,
    ItemMappingRule,
    MappingError,
    account_identity,
    item_identity,
    resolve_account_mapping,
    resolve_item_mapping,
)


class MappingResolverTests(unittest.TestCase):
    def test_account_code_is_preferred_over_name(self) -> None:
        rule = AccountMappingRule("4000", "Food sales", "NET_SALES")
        row = {"Account_Code": "4000", "Account_Name": "Food sales renamed", "Amount": "999999"}
        self.assertEqual(
            resolve_account_mapping(row, rules=(rule,)),
            rule,
        )

    def test_account_name_is_normalised_only_when_code_is_absent(self) -> None:
        rule = AccountMappingRule(None, "Platform commissions and marketing", "CHANNEL_COST")
        row = {
            "Account_Code": "",
            "Account_Name": "  PLATFORM commissions-and marketing  ",
            "Amount": "3600",
        }
        self.assertEqual(
            resolve_account_mapping(row, rules=(rule,)),
            rule,
        )

    def test_amount_cannot_change_account_mapping_result(self) -> None:
        rule = AccountMappingRule("5000", "Food cost of sales", "PRODUCT_COST")
        low = {"Account_Code": "5000", "Account_Name": "Food cost of sales", "Amount": "1"}
        high = {"Account_Code": "5000", "Account_Name": "Food cost of sales", "Amount": "9999999"}

        self.assertEqual(resolve_account_mapping(low, rules=(rule,)), rule)
        self.assertEqual(resolve_account_mapping(high, rules=(rule,)), rule)

    def test_unknown_account_is_not_guessed_from_amount(self) -> None:
        rule = AccountMappingRule("5000", "Food cost of sales", "PRODUCT_COST")
        row = {"Account_Code": "9999", "Account_Name": "Unknown", "Amount": "61343"}
        self.assertIsNone(resolve_account_mapping(row, rules=(rule,)))

    def test_duplicate_account_identity_is_rejected(self) -> None:
        rules = (
            AccountMappingRule("4000", "Food sales", "NET_SALES"),
            AccountMappingRule("4000", "Renamed food sales", "OTHER_DIRECT"),
        )
        with self.assertRaises(MappingError):
            resolve_account_mapping(
                {"Account_Code": "4000", "Account_Name": "Food sales"},
                rules=rules,
            )

    def test_item_code_is_preferred_over_name(self) -> None:
        rule = ItemMappingRule("F01", "Ribeye Steak", "ITEM:RIBEYE")
        row = {"Item_Code": "F01", "Item": "Ribeye renamed", "Net_Revenue": "40500"}
        self.assertEqual(resolve_item_mapping(row, rules=(rule,)), rule)

    def test_item_name_fallback_is_normalised(self) -> None:
        rule = ItemMappingRule(None, "House Burger", "ITEM:HOUSE_BURGER")
        row = {"Item_Code": "", "Item": " house-burger ", "Net_Revenue": "35200"}
        self.assertEqual(resolve_item_mapping(row, rules=(rule,)), rule)

    def test_empty_source_identity_is_rejected(self) -> None:
        with self.assertRaises(MappingError):
            account_identity("", " ")
        with self.assertRaises(MappingError):
            item_identity(None, None)


if __name__ == "__main__":
    unittest.main()
