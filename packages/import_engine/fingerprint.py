from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
from hashlib import sha256
import json
from typing import Literal
from uuid import UUID

from .model import ParsedTable
from .registry import TEMPLATE_IDENTITIES, normalise_text

MatchTier = Literal[
    "exact",
    "new_rows_only",
    "renamed_moved_columns",
    "different_layout",
    "manual_resolution",
]


@dataclass(frozen=True, slots=True)
class ProfileScope:
    organisation_id: UUID
    outlet_id: UUID
    template_code: str


@dataclass(frozen=True, slots=True)
class SourceFingerprint:
    sheet_name: str
    ordered_headers: tuple[str, ...]
    header_row: int
    orientation: str
    key_set_hash: str
    column_count: int
    template_code: str

    @property
    def signature(self) -> str:
        payload = {
            "sheet_name": self.sheet_name,
            "ordered_headers": self.ordered_headers,
            "header_row": self.header_row,
            "orientation": self.orientation,
            "key_set_hash": self.key_set_hash,
            "column_count": self.column_count,
            "template_code": self.template_code,
        }
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        return sha256(encoded).hexdigest()

    @property
    def layout_signature(self) -> tuple[object, ...]:
        return (
            self.sheet_name,
            self.ordered_headers,
            self.header_row,
            self.orientation,
            self.column_count,
            self.template_code,
        )


@dataclass(frozen=True, slots=True)
class ConfidenceBands:
    high: float
    review: float

    def __post_init__(self) -> None:
        if not (0 <= self.review < self.high <= 1):
            raise ValueError("confidence bands require 0 <= review < high <= 1")


@dataclass(frozen=True, slots=True)
class HeaderSuggestion:
    current_header: str
    previous_header: str | None
    confidence: float
    band: Literal["high", "review", "unmapped"]
    method: str


@dataclass(frozen=True, slots=True)
class ProfileVersion:
    scope: ProfileScope
    version: int
    fingerprint: SourceFingerprint
    source_keys: frozenset[str]
    headers: tuple[str, ...]
    approved: bool = True


@dataclass(frozen=True, slots=True)
class ProfileMatch:
    tier: MatchTier
    profile: ProfileVersion | None
    message: str
    suggestions: tuple[HeaderSuggestion, ...] = ()


def _key_columns(table: ParsedTable, template_code: str) -> tuple[int, ...]:
    identity = TEMPLATE_IDENTITIES.get(template_code)
    normalised_headers = tuple(normalise_text(header) for header in table.headers)

    if identity is not None:
        for candidate in identity.key_fields:
            indexes: list[int] = []
            for field in candidate:
                if field not in normalised_headers:
                    indexes = []
                    break
                indexes.append(normalised_headers.index(field))
            if indexes:
                return tuple(indexes)

    return (0,)


def source_keys(table: ParsedTable, template_code: str) -> frozenset[str]:
    indexes = _key_columns(table, template_code)
    values: set[str] = set()
    for row in table.rows:
        parts = [normalise_text(row[index]) for index in indexes if row[index].strip()]
        if parts:
            values.add("\x1f".join(parts))
    return frozenset(values)


def _key_hash(keys: frozenset[str]) -> str:
    return sha256("\x1e".join(sorted(keys)).encode()).hexdigest()


def build_fingerprint(
    table: ParsedTable,
    template_code: str,
) -> tuple[SourceFingerprint, frozenset[str]]:
    keys = source_keys(table, template_code)
    fingerprint = SourceFingerprint(
        sheet_name=normalise_text(table.sheet_name),
        ordered_headers=tuple(normalise_text(header) for header in table.headers),
        header_row=table.header_row,
        orientation=table.orientation,
        key_set_hash=_key_hash(keys),
        column_count=table.column_count,
        template_code=template_code,
    )
    return fingerprint, keys


def _normalise_aliases(aliases: dict[str, str]) -> dict[str, str]:
    return {normalise_text(key): normalise_text(value) for key, value in aliases.items()}


def _header_suggestions(
    current: tuple[str, ...],
    previous: tuple[str, ...],
    *,
    aliases: dict[str, str],
    bands: ConfidenceBands,
) -> tuple[HeaderSuggestion, ...]:
    previous_norm = tuple(normalise_text(value) for value in previous)
    alias_norm = _normalise_aliases(aliases)
    suggestions: list[HeaderSuggestion] = []

    for index, header in enumerate(current):
        current_norm = normalise_text(header)
        method = "similarity"
        best_header: str | None = None
        best_score = 0.0

        if current_norm in previous_norm:
            matched_index = previous_norm.index(current_norm)
            best_header = previous[matched_index]
            best_score = 1.0
            method = "normalised_exact"
        elif current_norm in alias_norm and alias_norm[current_norm] in previous_norm:
            matched_index = previous_norm.index(alias_norm[current_norm])
            best_header = previous[matched_index]
            best_score = 0.99
            method = "alias"
        else:
            for previous_index, previous_value in enumerate(previous_norm):
                similarity = SequenceMatcher(None, current_norm, previous_value).ratio()
                score = similarity
                candidate_method = "similarity"
                if previous_index == index and similarity >= 0.35:
                    score = max(score, 0.80)
                    candidate_method = "prior_position"
                if score > best_score:
                    best_score = score
                    best_header = previous[previous_index]
                    method = candidate_method

        band: Literal["high", "review", "unmapped"]
        if best_score >= bands.high:
            band = "high"
        elif best_score >= bands.review:
            band = "review"
        else:
            band = "unmapped"

        suggestions.append(
            HeaderSuggestion(
                current_header=header,
                previous_header=best_header,
                confidence=round(best_score, 4),
                band=band,
                method=method,
            )
        )

    return tuple(suggestions)


def match_profile(
    *,
    scope: ProfileScope,
    table: ParsedTable,
    profiles: tuple[ProfileVersion, ...],
    confidence_bands: ConfidenceBands,
    aliases: dict[str, str],
) -> ProfileMatch:
    candidates = tuple(
        profile for profile in profiles if profile.approved and profile.scope == scope
    )
    fingerprint, keys = build_fingerprint(table, scope.template_code)

    exact = tuple(
        profile
        for profile in candidates
        if profile.fingerprint.signature == fingerprint.signature
    )
    if len(exact) == 1:
        profile = exact[0]
        return ProfileMatch(
            tier="exact",
            profile=profile,
            message=f"Mapping reused from profile v{profile.version}",
        )
    if len(exact) > 1:
        return ProfileMatch(
            tier="manual_resolution",
            profile=None,
            message="Multiple approved profiles have the same fingerprint in this outlet scope.",
        )

    new_rows = tuple(
        profile
        for profile in candidates
        if profile.fingerprint.layout_signature == fingerprint.layout_signature
        and profile.source_keys < keys
    )
    if len(new_rows) == 1:
        profile = new_rows[0]
        return ProfileMatch(
            tier="new_rows_only",
            profile=profile,
            message=f"Profile v{profile.version} matches the layout; new source identities need review.",
        )
    if len(new_rows) > 1:
        return ProfileMatch(
            tier="manual_resolution",
            profile=None,
            message="Multiple approved profiles could match the new-row layout.",
        )

    renamed: list[tuple[ProfileVersion, tuple[HeaderSuggestion, ...]]] = []
    for profile in candidates:
        if (
            profile.fingerprint.sheet_name != fingerprint.sheet_name
            or profile.fingerprint.orientation != fingerprint.orientation
            or profile.fingerprint.header_row != fingerprint.header_row
            or profile.fingerprint.template_code != fingerprint.template_code
        ):
            continue
        suggestions = _header_suggestions(
            table.headers,
            profile.headers,
            aliases=aliases,
            bands=confidence_bands,
        )
        if suggestions and all(item.band != "unmapped" for item in suggestions):
            renamed.append((profile, suggestions))

    if len(renamed) == 1:
        profile, suggestions = renamed[0]
        return ProfileMatch(
            tier="renamed_moved_columns",
            profile=profile,
            message=f"Profile v{profile.version} is a review candidate after header/layout drift.",
            suggestions=suggestions,
        )
    if len(renamed) > 1:
        return ProfileMatch(
            tier="manual_resolution",
            profile=None,
            message="More than one approved profile matches the renamed/moved-column layout.",
        )

    return ProfileMatch(
        tier="different_layout",
        profile=None,
        message="No approved profile matches this layout; create a new profile version.",
    )
