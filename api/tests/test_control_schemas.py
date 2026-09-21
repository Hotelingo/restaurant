from datetime import date
from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.control_schemas import MaterialityWriteRequest, SettingWriteRequest


def test_percent_setting_normalises_to_decimal_string():
    payload = SettingWriteRequest(
        key="reconciliation_pos_to_pl_pct",
        value="0.005",
    )
    assert payload.value == "0.005"


def test_percent_setting_rejects_percent_style_50():
    with pytest.raises(ValidationError):
        SettingWriteRequest(
            key="reconciliation_pos_to_pl_pct",
            value="50",
        )


def test_materiality_requires_at_least_one_threshold():
    with pytest.raises(ValidationError):
        MaterialityWriteRequest(
            scope_type="general",
            effective_from=date(2026, 9, 21),
        )


def test_materiality_accepts_percentage_only():
    payload = MaterialityWriteRequest(
        scope_type="general",
        percent_threshold=Decimal("0.10"),
        effective_from=date(2026, 9, 21),
    )
    assert payload.absolute_threshold is None
    assert payload.percent_threshold == Decimal("0.10")


def test_primary_comparator_is_controlled():
    with pytest.raises(ValidationError):
        SettingWriteRequest(key="primary_comparator", value="forecast")
