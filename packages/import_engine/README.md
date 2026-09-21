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


## Closed transform registry

The import engine exposes exactly thirteen supported transforms:

1. trim whitespace;
2. case normalization;
3. remove thousands separators;
4. sign flip;
5. multiply/divide by a fixed factor;
6. tax strip using an explicit rate and inclusive/exclusive basis;
7. parse date;
8. parse month labels;
9. unpivot month columns;
10. split a delimited column;
11. fixed value;
12. controlled value map;
13. controlled UOM conversion.

TransformSpec validates codes against this registry. The dispatcher contains no
eval, exec, import path, expression language, callback or customer-provided
function hook. Value maps, UOM conversion factors, tax rates and confidence
settings remain explicit profile/settings data.

Wide Amberside P&L and Budget fixtures are handled by unpivot_month_columns().
Budget/forecast scenario values can then be supplied by the fixed_value
transform rather than inferred from an amount.


## Mapping identity contract

Account and item resolution never uses financial amounts. Account identity is
source account code when present, otherwise normalised account name. Item
identity is source item code when present, otherwise normalised item name.
Unknown identities remain unmapped rather than being guessed from value
similarity.

Persistence lives in PostgreSQL. Approved profile versions and their column,
account, item, value and transform mappings are immutable. The Slice 2 item
mapping stores a stable canonical_item_key because the canonical item dimension
is deliberately introduced in Slice 5; that later migration must add/backfill
item_id without rewriting approved profile history.


## Validation contract

ValidationResult always carries rule code, severity, scope, actual value,
expected value, tolerance, a customer-facing message and a remediation
instruction. Missing cross-file reconciliation totals produce an explicit
not_reconciled capability status rather than a fabricated zero.

Accepted R1 starting tolerances are exposed as caller-overridable defaults:
POS/category sales to P&L = 0.5%; T3 purchases to mapped P&L purchases = 2%.
They are product defaults/settings, not calculation arithmetic tolerances.

The validation gate refuses commit whenever any block-severity result remains
unresolved. Warnings and not-reconciled capability states remain visible but
do not masquerade as resolved evidence.
