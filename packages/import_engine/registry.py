from __future__ import annotations

from dataclasses import dataclass
import re
import unicodedata


def normalise_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).lstrip("\ufeff").strip().lower()
    value = re.sub(r"[_\-\/]+", " ", value)
    value = re.sub(r"[^0-9a-z]+", " ", value)
    return " ".join(value.split())


KNOWN_HEADER_TERMS = frozenset(
    {
        "period", "account code", "account name", "account section", "amount",
        "scenario", "management line", "suggested management line",
        "meal period", "business format", "units", "unit basis",
        "activity units", "activity unit type", "revenue", "net revenue",
        "net price", "item", "item code", "population", "product group",
        "opening inventory", "purchases", "closing inventory",
        "approved cost per unit", "recipe version", "yield factor",
        "role group", "area", "paid hours", "labour cost",
        "customer source", "channel", "check id", "qty", "quantity",
        "effective from",
    }
)

_MONTHS = (
    "january|jan|february|feb|march|mar|april|apr|may|june|jun|"
    "july|jul|august|aug|september|sep|sept|october|oct|"
    "november|nov|december|dec"
)
_MONTH_RE = re.compile(
    rf"^(?:(?:budget|forecast|prior year) )?(?:{_MONTHS}) \d{{4}}$|^\d{{4}} \d{{1,2}}$"
)


def looks_like_month_header(value: str) -> bool:
    return bool(_MONTH_RE.match(normalise_text(value)))


@dataclass(frozen=True, slots=True)
class TemplateIdentity:
    code: str
    key_fields: tuple[tuple[str, ...], ...]


TEMPLATE_IDENTITIES: dict[str, TemplateIdentity] = {
    "T1": TemplateIdentity("T1", (("account code",), ("account name",))),
    "T1B": TemplateIdentity("T1B", (("meal period",), ("business format",))),
    "T2": TemplateIdentity("T2", (("item code",), ("item",))),
    "T3": TemplateIdentity("T3", (("product group",),)),
    "T4A": TemplateIdentity("T4A", (("item code",), ("item",))),
    "T4B": TemplateIdentity("T4B", (("item code",), ("item",))),
    "T5": TemplateIdentity("T5", (("role group",), ("area",))),
    "T6": TemplateIdentity(
        "T6", (("management line",), ("account code",), ("account name",))
    ),
    "T7": TemplateIdentity("T7", (("customer source",), ("channel",))),
    "T8": TemplateIdentity("T8", (("item code",), ("item",), ("check id",))),
    "M1": TemplateIdentity("M1", (("item code",), ("item",))),
    "M2": TemplateIdentity("M2", (("item code",), ("item",))),
    "M3": TemplateIdentity("M3", (("item code",), ("item",))),
    "M4": TemplateIdentity("M4", (("item code",), ("item",))),
}
