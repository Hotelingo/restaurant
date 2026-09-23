import pytest
from pydantic import ValidationError

from app.schemas import BootstrapRequest


def test_bootstrap_normalizes_currency():
    payload = BootstrapRequest(
        organisation_name="Example Group",
        organisation_slug="example-group",
        outlet_name="Example Bistro",
        currency_code="usd",
        timezone="Africa/Lubumbashi",
        fiscal_year_start_month=1,
    )
    assert payload.currency_code == "USD"


def test_bootstrap_rejects_invalid_slug():
    with pytest.raises(ValidationError):
        BootstrapRequest(
            organisation_name="Example Group",
            organisation_slug="Example Group",
            outlet_name="Example Bistro",
            currency_code="USD",
            timezone="UTC",
            fiscal_year_start_month=1,
        )
