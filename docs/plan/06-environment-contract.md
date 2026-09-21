# Environment Contract — local / preview / production

**Status:** accepted groundwork contract  
**Date:** 2026-09-21

## Principle

Environment separation is a security boundary, not a naming convention.

- **local**: developer machine/local Supabase only.
- **preview**: isolated non-production Supabase project used by branch/PR deployments.
- **production**: customer data and released application only.

Preview and production must never share:
- Supabase project/database;
- Storage buckets;
- service-role keys;
- Vercel environment variables;
- database connection strings.

## Web environment

The browser may receive only public values:
- `APP_ENV`
- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_ANON_KEY`
- `NEXT_PUBLIC_API_BASE_URL`

A Supabase service-role key must never be present in `apps/web`, browser bundles, or public logs.

## API environment

Server-only values include:
- `SUPABASE_URL`
- `SUPABASE_SERVICE_ROLE_KEY`
- `DATABASE_URL`
- allowed CORS origins;
- later: worker/queue and signing configuration.

## CI rule

CI may apply migrations only to disposable test databases or the designated preview environment.

CI must never run a migration or seed directly against production. The repository guard
`scripts/guard_db_target.py` enforces this policy. Production database changes require the
controlled manual release path plus explicit acknowledgement.

## Vercel

- Pull requests use Preview deployments and preview-only environment variables.
- Production deployments use production-only variables.
- A Preview deployment must fail closed if preview Supabase values are absent; it must never fall
  back to production variables.

## Supabase

Use separate projects for preview and production. Local development should prefer Supabase local
stack where practical.

The first real Slice 1 migration application must be against the isolated preview project. The
production project is not touched until the Slice 1 acceptance path is green in preview.

## Secrets

- Real secrets are stored in the deployment platform/GitHub environment, not repository files.
- `.env.example` contains placeholders only.
- Logs must not emit JWTs, service-role keys, database URLs, magic-link tokens, MFA codes or signed
  Storage URLs.

## Promotion rule

The promotion sequence is:

`local tests → PR CI → preview database + preview deployment → acceptance → production release`

Skipping preview is not permitted for schema changes.
