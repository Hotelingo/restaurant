# Agent rules — Restaurant Performance Review

Read `docs/plan/01-development-plan.md`, `docs/plan/04-definition-of-done.md`, and
`docs/plan/07-neon-database-plan.md` before making application or schema changes.

## Non-negotiable architecture

- The browser never computes an authoritative financial number.
- Clients never write canonical facts or calculation results.
- `calc_engine` and `import_engine` remain database/network/browser independent.
- Missing is never silently converted to zero.
- Preserve tenant isolation, immutability, lineage and auditability.

## Neon branch-first workflow

For every feature branch:

1. create/use the matching Git branch;
2. create or select a matching isolated Neon branch with `neon checkout <branch-name>`;
3. run schema work only on that non-production Neon branch;
4. run constraint/RLS tests;
5. run `neon diff production` before schema review/merge.

Never use the Neon `production` branch for iterative development.

Never commit:
- `.neon`;
- `.env*`;
- connection strings;
- Neon API keys;
- auth tokens/secrets.

Automation should use a **project-scoped** Neon API key rather than an account-wide key wherever
possible.

Do not rewrite the accepted schema from scratch merely because the database provider changed.
Adapt the reviewed domain model and explicitly replace provider-specific auth/storage assumptions.
