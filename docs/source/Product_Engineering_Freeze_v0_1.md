# Restaurant Performance Review — Product / Engineering Freeze v0.1

## Decision

Use the v4.2 wireframe as the UX/functional baseline.

Target infrastructure:
- **Supabase:** Auth, PostgreSQL, Storage, RLS
- **GitHub:** separate Restaurant repository
- **Vercel:** web deployment and API deployment entry point
- **Architecture pattern:** Next.js/TypeScript frontend + FastAPI/Python server API, matching the proven hotel-app separation of browser UI from server-authoritative calculations

The Restaurant application remains a separate product, repository and Supabase project from the Hotel application.

## Build contract

The application is organized around:
**Review → Issues → Evidence → Diagnosis → Decision → Action/Test → Verification**

Data architecture:
**Raw file → Staging → Canonical facts → Calc snapshot → Review / signed pack**

## Code boundaries

### `apps/web`
- customer navigation from v4.2
- role-based views
- no authoritative financial calculations
- no direct writes to canonical facts

### `api`
- authentication/context checks
- upload orchestration
- import commits
- calculation runs
- review gates
- pack generation
- signed URLs

### `packages/import_engine`
- CSV/XLSX parsers
- fingerprints
- source profile matching
- mapping
- validations
- deterministic canonical DTOs

### `packages/calc_engine`
- Decimal-based pure calculation functions
- stable calc IDs
- evidence/status outputs
- no DB dependencies

### `supabase`
- migrations
- RLS policies
- seed reference tables
- storage policies
- Amberside golden fixture

## Engineering order

1. Foundation: auth/tenancy/outlet/context/periods/RLS.
2. Ingestion: Storage → source file → profile → staging → validation → commit.
3. P&L: canonical financial facts → calc run → management ladder → reconciliation → SEQUENCE.
4. Review loop: FRAME → shortlist → diagnosis → dispositions → action register → owner pack → sign-off.
5. Summary Food Cost: T3 → actual consumption → Budget benchmark → gap/residual.
6. Revenue: meal-period volume/spend and contribution.
7. Labour / Other Costs.
8. Expected usage/C02 detailed tests.
9. Menu SCREEN → TRAIL → Decision → TEST.
10. Advanced transactions/interactions/connectors later.

## First vertical slice acceptance

A brand-new test organisation must be able to:

1. Create outlet/context.
2. Upload T1 P&L and T6 Budget.
3. Reuse an existing mapping profile or resolve one new account.
4. Validate and atomically commit.
5. Produce a reconciled Management P&L.
6. Create an immutable calc run.
7. Identify the first material movement.
8. Shortlist one issue.
9. Record a valid management disposition.
10. Create action/evidence request.
11. Produce Owner Pack v1.
12. Request reviewer changes or sign.
13. Preserve all source/mapping/calc lineage.

No Food Cost or Menu functionality should be allowed to bypass this core traceability path.

## Golden test strategy

Use the unified Amberside fixture as a deterministic test pack.

Critical parity assertions:
- July Net Sales = 228,500
- July Product Cost = 70,282
- July Product Margin = 158,218
- July Contribution = 67,801
- July Operating Profit = 53,549
- July Budget Operating Profit = 68,220
- July Operating Profit variance = -14,671
- July Food Sales = 191,100
- July Food actual consumption = 61,343
- July Food expected usage = 60,400
- July actual-vs-expected Food gap = 943

These become automated unit/integration fixtures before UI work is considered complete.

## Environments

- `local`
- `preview`
- `production`

Use a separate Supabase project/database for development/preview from production.
Never point local/preview migrations or seed jobs at production.
Vercel preview deployments use preview environment variables only.

## Branch / PR practice

- protected `main`
- short-lived feature branches
- migrations reviewed in PR
- calculation changes require test-fixture update or explicit “no expected-value change”
- no destructive migration without rollback/forward-fix plan
- database schema and API contracts versioned in repository

## Definition of ready-to-code

Coding starts only after:
- schema names/columns accepted
- calc IDs/formulas accepted
- import template fields accepted
- validation severities accepted
- mapping rules accepted
- RLS/role matrix accepted
- Amberside golden values accepted