from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

from .registry import normalise_text


class MappingError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class AccountMappingRule:
    source_account_code: str | None
    source_account_name: str
    ladder_line_key: str


@dataclass(frozen=True, slots=True)
class ItemMappingRule:
    source_item_code: str | None
    source_item_name: str
    canonical_item_key: str


def account_identity(code: object | None, name: object | None) -> tuple[str, str]:
    code_text = "" if code is None else str(code).strip()
    name_text = "" if name is None else str(name).strip()

    if code_text:
        return ("code", normalise_text(code_text))
    if name_text:
        return ("name", normalise_text(name_text))
    raise MappingError("Account mapping requires a source code or source name")


def item_identity(code: object | None, name: object | None) -> tuple[str, str]:
    code_text = "" if code is None else str(code).strip()
    name_text = "" if name is None else str(name).strip()

    if code_text:
        return ("code", normalise_text(code_text))
    if name_text:
        return ("name", normalise_text(name_text))
    raise MappingError("Item mapping requires a source code or source name")


def _account_index(
    rules: Sequence[AccountMappingRule],
) -> dict[tuple[str, str], AccountMappingRule]:
    index: dict[tuple[str, str], AccountMappingRule] = {}
    for rule in rules:
        key = account_identity(rule.source_account_code, rule.source_account_name)
        if key in index:
            raise MappingError(f"Duplicate source account identity: {key}")
        index[key] = rule
    return index


def _item_index(
    rules: Sequence[ItemMappingRule],
) -> dict[tuple[str, str], ItemMappingRule]:
    index: dict[tuple[str, str], ItemMappingRule] = {}
    for rule in rules:
        key = item_identity(rule.source_item_code, rule.source_item_name)
        if key in index:
            raise MappingError(f"Duplicate source item identity: {key}")
        index[key] = rule
    return index


def resolve_account_mapping(
    row: Mapping[str, object],
    *,
    rules: Sequence[AccountMappingRule],
    code_field: str = "Account_Code",
    name_field: str = "Account_Name",
) -> AccountMappingRule | None:
    """Resolve by code, or by normalised name when code is absent.

    No amount/value field is accepted or consulted. Two rows with the same
    account identity resolve identically regardless of their financial values.
    """

    key = account_identity(row.get(code_field), row.get(name_field))
    return _account_index(rules).get(key)


def resolve_item_mapping(
    row: Mapping[str, object],
    *,
    rules: Sequence[ItemMappingRule],
    code_field: str = "Item_Code",
    name_field: str = "Item",
) -> ItemMappingRule | None:
    """Resolve by item code, or normalised name when code is absent."""

    key = item_identity(row.get(code_field), row.get(name_field))
    return _item_index(rules).get(key)
