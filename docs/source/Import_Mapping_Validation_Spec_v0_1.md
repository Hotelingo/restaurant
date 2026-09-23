# Restaurant Performance Review — Import, Mapping & Validation Specification v0.1

## 1. Import principle

Customers upload reports they already produce. The application maps a report once and remembers the approved profile. Standard eHMS templates are fallback formats, not a requirement.

Accepted R0/R1 file formats:
- CSV
- XLSX

PDF/scans are handled by setup service, not the automated parser.

---

## 2. Standard template registry

| Code | Customer label | Grain | Primary use |
|---|---|---|---|
| T1 | P&L / Trial Balance | outlet × account × period × scenario | Management P&L, reconciliation |
| T1B | Meal-period Sales & Covers | outlet × meal period/business format × period | Revenue diagnosis |
| T2 | POS Item Sales | item × period, optionally meal period/channel | Menu SCREEN, expected usage |
| T3 | Purchases & Stock | product group/category × period | Actual consumption / Food Cost |
| T4A | Item / Product Cost | item × effective date | SCREEN, expected usage |
| T4B | Recipe Ingredient Lines | item recipe × ingredient | detailed expected usage |
| T5 | Labour & Activity | role group × period | labour diagnosis |
| T6 | Budget / Forecast / Prior Year | same grain as T1 | comparator |
| T7 | Customer Source / Channel | source/channel × period | source economics |
| T8 | Check / Transaction Detail | check × item | advanced interactions |
| M1 | Menu Change History | item × change event | TRAIL T |
| M2 | Item Availability | item × period | TRAIL T |
| M3 | Activity / Capacity Evidence | item × resource/evidence period | TRAIL A |
| M4 | Line-up Role | item × role | TRAIL L |

---

## 3. Core fields

### T1 — P&L / Trial Balance
Required:
- Period
- Account Name
- Amount

Conditional:
- Outlet if file covers >1 outlet

Optional:
- Scenario (defaults Actual)
- Account Code
- Account Section
- Department / cost centre
- Currency

Validation:
- Period valid: Block
- Outlet known: Block
- Account name nonblank: Block
- Amount numeric: Block
- Scenario controlled value: Block
- Duplicate outlet/account/period/scenario: Block

### T1B — Meal-period Sales & Covers
Required:
- Period
- Meal Period or Business Format
- Activity Units
- Activity Unit Type
- Revenue

Optional:
- Food Revenue
- Beverage Revenue
- Other Revenue
- Seats / hours / operating days
- comparator columns if uploaded in same file

### T2 — POS Item Sales
Required:
- Period
- Item Code or Item Name
- Units Sold
- Net Revenue

Optional:
- Gross Revenue
- Discount
- Meal Period
- Channel
- Population / category
- availability

### T3 — Purchases & Stock
Required:
- Period
- Product Group
- Opening Inventory
- Purchases
- Closing Inventory

Optional:
- Category
- external inbound transfer
- external outbound transfer
- recorded non-revenue use
- inventory location
- valuation basis

### T4A — Item Cost
Required:
- Item Code or Name
- Effective From
- Approved Product Cost / Unit

Optional:
- Recipe version
- approved portion
- yield
- UOM

### T4B — Recipe Ingredient
Required:
- Item
- Recipe Version
- Effective From
- Ingredient
- Approved Quantity
- UOM
- Yield Factor
- Approved Unit Cost

### T5 — Labour & Activity
Required:
- Period
- Role Group
- Paid Hours
- Labour Cost

Optional:
- Scheduled Hours
- Overtime Hours
- Activity Units
- Activity Type
- wage-rate details

### T6 — Comparator
Same canonical structure as T1.
Scenario must be `budget`, `forecast` or `prior_year`.

### T7 — Customer Source / Channel
Required:
- Period
- Source / Channel

At least one:
- Activity Units
- Attributed Revenue

Optional:
- direct channel/acquisition cost
- commission
- promotion cost
- evidence basis

### T8 — Transactions
Required:
- Check ID
- Transaction timestamp/date
- Item
- Quantity
- Net Revenue

Optional:
- Outlet
- channel
- meal period/occasion
- discount
- guest count

---

## 4. Source profile fingerprint

Fingerprint components:
- normalized sheet name
- normalized ordered header list
- header row number
- data orientation
- source account/item key set hash
- column count
- template code

Do not include volatile row count in the exact-match fingerprint.

---

## 5. Matching hierarchy

### Exact match
Fingerprint exactly matches active profile version:
- apply automatically
- display “Mapping reused from profile vN”

### New rows/items only
Headers/layout unchanged, new accounts/items found:
- auto-map known rows
- new identities enter exception queue
- commit blocked only where the new row affects required reconciliation
- system may suggest destination
- human confirms

### Renamed/moved columns
Use:
1. canonical alias map
2. normalized exact string
3. prior-profile position
4. header similarity

Proposed default confidence bands:
- `>= 0.92`: high-confidence suggestion, still require confirmation when meaning could change
- `0.75–0.9199`: review suggestion
- `< 0.75`: unmapped

These are product defaults, not accounting truths; store them in settings.

### Different layout
New sheet/header orientation:
- create new profile version
- prefill from previous version
- never silently replace active profile

### Wrong period / duplicate
Block.
A second batch supersedes an existing committed batch only after explicit confirmation.

---

## 6. Mapping constraints

### Account mapping
One source account identity → one ladder line within one profile version.

Account identity preference:
1. account code
2. normalized account name when code unavailable

Never map by amount.

### Item mapping
One source item identity → one canonical item within one profile version.

Prefer source item code. Name similarity is suggestion only.

### Value maps
Controlled aliases:
- `Bev` → `Beverage`
- `Dine In` → `Dine-in`
- etc.

### Basis mapping
Every profile freezes:
- sign convention
- tax inclusive/exclusive treatment
- date basis
- currency
- inventory valuation basis where relevant
- units/UOM conversions used by the parser

---

## 7. Closed transform list

Supported in-product transforms:
- trim whitespace
- case normalization
- remove thousands separators
- sign flip
- multiply/divide by fixed factor
- tax strip using configured rate/basis
- parse date
- parse month labels
- unpivot month columns
- split a delimited column
- fixed value
- controlled value map
- controlled UOM conversion

If a customer requires a new arbitrary transform:
- setup service converts outside the product
- transformation recipe is documented
- if repeated for ≥3 customers, consider adding it as a product transform

No customer-specific executable code.

---

## 8. Validation framework

Every rule has:
- rule code
- severity (`Block`, `Warn`, `Info`)
- object scope
- actual value
- expected value/tolerance
- user-facing message
- remediation instruction

### Cross-file rules

Proposed defaults from the development plan:
- POS item/category sales total to category/P&L value within **0.5%**: Block or Warn depending on configured capability.
- Purchases in T3 vs mapped P&L purchases account within **2%**: Warn.
- File without required reconciliation totals: mark affected capability `Not Reconciled`.

Additional recommended rules:
- item revenue cannot materially exceed P&L sales for the same controlled scope
- recipe effective version required for expected usage
- opening inventory should equal prior closing inventory for same boundary; mismatch = Warn/Block by threshold
- activity units must be non-negative
- unsupported negative stock count = Block unless configured return/credit case
- duplicate transaction/check line = Warn/Block by source key

---

## 9. Commit transaction

Commit must be atomic:

1. lock import batch
2. verify no unresolved Block validation
3. verify approved profile version
4. persist resolved mappings on facts
5. insert canonical facts
6. write fact counts/totals checksum
7. set batch committed
8. invalidate/recompute readiness
9. optionally queue a new calc run

If any step fails, no canonical fact is committed.

---

## 10. History rules

- Raw file never changes.
- Staging rows never change after parse completion.
- Profile versions are immutable after approval.
- Committed facts never mutate.
- Correction = superseding batch.
- Re-map of a historical batch = explicit reprocess creating new facts/calc run, old version retained.
- Signed review never points automatically to a later reprocess.

---

## 11. Template/version compatibility

Each standard template has:
- template code
- version
- minimum supported app version
- canonical fields
- validation rules
- migration notes

The import endpoint first reads template metadata when the official template is used; customer exports use profile detection.

---

## 12. Import API contract

Suggested endpoints:

- `POST /imports/upload`
- `POST /imports/{batch_id}/parse`
- `GET /imports/{batch_id}/status`
- `POST /imports/{batch_id}/mapping/confirm`
- `POST /imports/{batch_id}/validate`
- `POST /imports/{batch_id}/commit`
- `POST /imports/{batch_id}/supersede`
- `GET /imports/{batch_id}/exceptions`
- `GET /templates`
- `GET /templates/{code}/download`

All canonical writes happen server-side.