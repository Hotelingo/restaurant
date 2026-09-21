from datetime import date

import pytest
from pydantic import ValidationError

from app.setup_schemas import ContextVersionRequest, ReportingPeriodRequest


def test_context_preserves_missing_optional_values():
    payload = ContextVersionRequest(effective_from=date(2026, 9, 1))
    assert payload.seats is None
    assert payload.service_style is None
    assert payload.meal_periods == []


def test_context_rejects_negative_capacity():
    with pytest.raises(ValidationError):
        ContextVersionRequest(
            effective_from=date(2026, 9, 1),
            seats=-1,
        )


def test_reporting_period_requires_label():
    with pytest.raises(ValidationError):
        ReportingPeriodRequest(
            period_start=date(2026, 9, 1),
            period_end=date(2026, 9, 30),
            label="",
        )
