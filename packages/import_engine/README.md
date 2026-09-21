# Import engine

Pure parsing, fingerprinting, profile matching, mapping, validation and
canonical-DTO logic.

Non-negotiable properties:
- no database access;
- no HTTP/network access;
- deterministic output from explicit input;
- no arbitrary customer executable code;
- closed transform list only.

Persistence belongs in the API/ingestion layer, not here.

## Slice 2 parser contract

parse_source(name, bytes) accepts CSV or XLSX and returns the same immutable
ParsedDocument / ParsedTable representation. Customer values remain strings so
identifiers such as account and item codes are never guessed to be numbers.
parse_decimal() is the explicit finance-number helper and handles thousands
separators and accounting negatives after a mapped field is known to be numeric.

Header detection examines the first 25 non-empty rows. Known business headers
and month-labelled wide columns such as July_2026 dominate the score. CSV uses
the stable synthetic sheet name __csv__; XLSX preserves worksheet names.

## Fingerprint contract

build_fingerprint() contains:
- normalised sheet name;
- normalised ordered headers;
- 1-based header row;
- data orientation;
- source account/item key-set hash;
- column count;
- template code.

Row count is deliberately absent. match_profile() supports exact,
new-rows-only, renamed/moved-column and different-layout tiers. Scope is always
(organisation_id, outlet_id, template_code). Multiple viable approved profiles
inside one scope return manual_resolution; the engine never picks one silently.

Confidence bands and alias maps are caller inputs, not buried constants.
