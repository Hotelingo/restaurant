# Restaurant Performance Review

Development pack for the Restaurant Performance Review application: a multi-tenant web application
that takes a restaurant's own monthly reports, maps them once, turns them into a reconciled
Management P&L, and drives a disciplined review loop ending in a signed Owner Pack — with every
number traceable back to the file it came from.

**Status: initial development started.** OD-01 through OD-12 were resolved on 2026-09-21. The
Slice 1 schema/RLS baseline is accepted, the v4.3 operational UX addendum is defined, and CI quality
gates now cover golden parity plus Slice 1 database integrity/RLS. Application feature code follows
the work-package sequence; the analytical v4.2 scope remains frozen.

---

## Start here

| If you want to… | Read |
|---|---|
| **Know what's left before first user testing** | [`docs/review/05-readiness-review.md`](docs/review/05-readiness-review.md) |
| Know whether the plan is sound | [`docs/review/01-plan-review.md`](docs/review/01-plan-review.md) |
| See what needs fixing, ranked | [`docs/review/02-gap-register.md`](docs/review/02-gap-register.md) |
| Review the resolved engineering decisions | [`docs/plan/05-open-decisions.md`](docs/plan/05-open-decisions.md) |
| See the operational onboarding/auth addendum | [`docs/design/v4.3-operational-addendum.md`](docs/design/v4.3-operational-addendum.md) |
| Know what gets built, in what order | [`docs/plan/01-development-plan.md`](docs/plan/01-development-plan.md) |
| Hand work to a development agent | [`docs/plan/03-agent-workpackages.md`](docs/plan/03-agent-workpackages.md) |
| Implement a calculation | [`docs/contracts/calc-registry.md`](docs/contracts/calc-registry.md) |
| See the UX | open [`wireframe/restaurant-review-wireframe-v4.2.html`](wireframe/) in a browser |

---

## What was verified

The plan was reviewed as a full-stack engineering proposal rather than read. Three things were
checked by execution, not by inspection:

**1 · The numbers reconcile.** All eleven golden values in the Engineering Freeze were recomputed
from the raw CSV fixtures. Every one ties exactly, and every cross-file tie-out is zero. This is
rare and it substantially de-risks the build.

```
$ python3 tests/golden/test_amberside_parity.py
13 passed, 0 failed
```

**2 · The Slice 1 migrations are accepted and CI-gated.** The baseline has been updated for the
resolved outlet-scope and materiality decisions. PostgreSQL 16 CI applies every Slice 1 migration
from an empty database before running constraint and RLS regression tests.

**3 · The integrity guarantees are executable.** Constraint tests cover cross-tenant foreign keys,
immutability, explicit outlet scope and materiality rules. A separate RLS suite checks all-outlet,
selected-outlet, staff, expired assignment, anonymous and cross-tenant access semantics.

```
$ psql -d rpr_test -f supabase/tests/test_slice1_constraints.sql
psql -d rpr_test -f supabase/tests/test_slice1_rls.sql
PASS  G-02 cross-tenant reporting_period rejected
PASS  G-03 duplicate NULL outlet code rejected
PASS  G-05 approved materiality_setting immutable
PASS  G-05 audit_log append-only
PASS  G-05 restaurant_context versions immutable
PASS  materiality_setting requires at least one threshold
PASS  reporting_period end must not precede start
```

## What the review found

**Verdict: approved to build, with conditions.** The methodology, the screen design and the
arithmetic are sound and should not be reopened. 45 gaps were logged — 16 of them blocking the
first slice. The three most consequential:

- **No row-level security exists.** The architecture document's rule that RLS is enforced in
  PostgreSQL, not only in application code, was unimplemented. Addressed in the proposed migrations.
- **Tenancy was violable through foreign keys**, independently of RLS. Addressed, and now tested.
- **`FC.DECISION_PATH` contradicts its own methodology.** The prototype branches on the *budget*
  gap, which the specification itself says "does not prove operating leakage". On the Amberside
  fixture that routes a 3,070 menu-mix issue into an operating-control hunt over a 943 real gap —
  the precise error the two-story bridge exists to prevent. The written spec is right; the
  prototype is wrong.

Also recovered: four business rules that existed **only** in the prototype's JavaScript and in no
specification document, including the Owner Pack claim validator — one of the best ideas in the
product and one commit away from being lost.

---

## Layout

```
docs/
  review/      the engineering review: findings, gap register, screen inventory
  plan/        development plan, backlog, agent work packages, open decisions
  contracts/   calculation registry and API contract
  source/      the frozen inputs, verbatim and unmodified
supabase/
  migrations/  ACCEPTED slice-1 baseline
  tests/       constraint + RLS regression suites
fixtures/
  amberside/   the golden fixture — do not modify
tests/golden/  parity tests (13/13 passing, no application dependencies)
wireframe/     the v4.2 prototype, kept as the UX contract
```

`docs/source/` is the customer's frozen input, preserved untouched. Everything proposed in response
lives elsewhere and is labelled as a proposal.

---

## The four rules

Every technical decision serves one claim: **traceability**. Raw file → staging row → canonical
fact → immutable calculation snapshot → signed pack, with nothing upstream ever rewritten.

1. **The browser never computes an authoritative number.** Displayed values come from a server-side
   `calc_result`. The prototype's JavaScript uses `parseFloat` and must not be ported.
2. **Clients never write canonical facts or calculation results.** Enforced by the absence of an RLS
   policy, not by convention.
3. **`calc_engine` and `import_engine` have no database or browser dependency.** Pure functions over
   explicit inputs — which is what makes the golden tests meaningful.
4. **Missing is not zero.** `NOT_CALCULATED` is a distinct state with an `explanation_code`. Any
   zero or absent denominator returns it.

If a shortcut would break one of these, the shortcut is not available.

---

## Next steps

1. Merge the v4.3/Slice 1 preparation PR after CI is green.
2. Complete WP-02 monorepo/environment guards and WP-03 production component primitives.
3. Apply the accepted Slice 1 schema to the isolated preview Supabase project only.
4. Implement auth/context and the atomic organisation/outlet bootstrap from the v4.3 addendum.
5. Continue Slice 1 stories S1-3 through S1-9 without changing the frozen analytical scope.

---

## Running the checks

```bash
# Golden parity — standard library only, no application code needed
python3 tests/golden/test_amberside_parity.py

# Database constraints — see supabase/tests/README.md for the Supabase stubs
psql -d rpr_test -f supabase/tests/test_slice1_constraints.sql
```
