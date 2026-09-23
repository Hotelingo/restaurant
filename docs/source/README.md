# Source documents — frozen inputs

These are the customer-supplied planning documents, **preserved verbatim and unmodified**. They are
the baseline the review in `docs/review/` was written against.

Do not edit anything in this directory. Where the review disagrees with a source document, the
disagreement is recorded in `docs/review/02-gap-register.md` and resolved in `docs/contracts/` or
`supabase/migrations/` — never by quietly amending the source.

| File | What it is |
|---|---|
| `Product_Engineering_Freeze_v0_1.md` | R1 scope, build contract, code boundaries, engineering order, the twelve-step acceptance test, golden values, branch practice, definition of ready-to-code |
| `Data_Architecture_and_Supabase_Model_v0_1.md` | The database contract: ~60 tables, enums, RLS design, invariants, repository boundary |
| `Calculation_Engine_Spec_v0_1.md` | Engine contract and the `PL`, `RV`, `CT`, `FC`, `LB`, `OC`, `MN`, `MAT`, `RG` modules |
| `Import_Mapping_Validation_Spec_v0_1.md` | Template registry T1–M4, fingerprinting, matching hierarchy, closed transform list, validation framework, commit transaction |
| `Supabase_Schema_Draft_v0_1.sql` | The original SQL draft. **Superseded** for slice 1 by `supabase/migrations/`, which fixes eleven defects — see that directory's README |
| `Restaurant_Import_Templates_v0_1.xlsx` | Sixteen-sheet template workbook |
| `Development_Handoff_v4_2.md` | The v4.2 UX refactor: six-area customer navigation over the full v4 analytical scope |
| `Preservation_Audit_v4_2.md` | Structural comparison proving v4.2 lost no v4 screens |

## Where the review departs from these documents

Three substantive departures, each argued in full in the review:

- **`FC.DECISION_PATH`** (G-20) — the prototype's implementation contradicts this specification's
  own methodology. The specification is right. Corrected in `docs/contracts/calc-registry.md` §7.2.
- **The SQL draft** (G-01 to G-11) — eleven defects, four of which are security-relevant. Corrected
  for slice 1 in `supabase/migrations/`. The draft itself is untouched above.
- **T6 comparator grain** (G-07) — this specification and the supplied fixture disagree, and the
  schema cannot accommodate the fixture as written. Escalated as OD-03 rather than decided
  unilaterally, because it is a product question.

Everything else in the review adds detail the source documents left open, rather than contradicting
them.
