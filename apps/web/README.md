# Web application boundary

Target: Next.js + TypeScript on Vercel.

This package is **presentation and interaction only**.

## Allowed
- Supabase Auth client/session integration.
- Calling typed server API contracts.
- Rendering values already produced by the server.
- Local UI state, validation hints, loading/empty/error states.

## Forbidden
- Authoritative financial calculations.
- Direct imports from `packages/calc_engine` or `packages/import_engine`.
- Direct writes to canonical facts, calculation results, committed batches, or signed packs.
- Service-role credentials in browser code.

The v4.2 wireframe is a behavioural/design reference. Its arithmetic JavaScript must not be ported.

The v4.3 operational addendum defines auth, onboarding, first-run and recovery journeys.
