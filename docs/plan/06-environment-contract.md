# Environment Contract — local / preview / production

**Status:** accepted; revised 2026-09-23 for the deployed stack (Neon, Neon Auth, Vercel,
container host). Supersedes the Supabase-era version.

## Principle

Environment separation is a security boundary, not a naming convention.

- **local**: a developer machine or `dev/local-stack` (PostgreSQL, Better Auth stand-in, moto S3).
- **preview**: an isolated **Neon branch** (never `production`), its own Neon Auth, a Vercel
  preview/staging deployment, and its own API, worker and bucket.
- **production**: customer data and the released application only.

Preview and production must never share a Neon branch or database, database roles or passwords,
a storage bucket or its keys, the Neon Auth cookie secret, or Vercel/host environment variables.

## Where each part runs

| Part | Host | Why |
|---|---|---|
| Web (`apps/web`) | **Vercel** | Next.js; stateless; preview deployments per PR |
| API (`api/`) | **container host** (e.g. Render, Railway, Fly.io) | uploads up to 25 MB (Vercel functions accept ~4.5 MB per request), 60 s upload processing, and a ClamAV sidecar |
| Worker (`workers/`) | **same container host**, always-on process | polls the calculation queue; Vercel has no long-running processes |
| ClamAV (`clamd`) | **same container host**, private network only | required outside local/test/CI; uploads fail closed without it |
| Database + auth | **Neon** branch + Neon Auth | |
| Object storage | **S3-compatible**, private bucket (AWS S3 or Cloudflare R2) | uploads and rendered Owner Packs |

## Database roles

| Role | Used by | Connection | Rights |
|---|---|---|---|
| owner (e.g. `neondb_owner`) | migrations only | **direct** (unpooled) | schema owner; never used by a running service |
| `restaurant_app` | API | **pooled** | RLS-enforced; per-user identity via `app.user_id` |
| `restaurant_pack_server` | API, two calls only | (no login) | render attach + sign-off; `SET LOCAL ROLE` from `restaurant_app` (migration 0040) |
| `restaurant_worker` | worker | pooled or direct | reads facts, writes calculation snapshots, queue functions only (migration 0041) |

`restaurant_app` and `restaurant_worker` passwords are set with SQL (`alter role … login password …`),
not by creating roles in the Neon console, which would add `neon_superuser` membership.

## Web environment (Vercel)

| Variable | Scope | Notes |
|---|---|---|
| `NEON_AUTH_BASE_URL` | server | Neon Auth URL of this environment's branch |
| `NEON_AUTH_COOKIE_SECRET` | server, **secret** | ≥ 32 random characters; unique per environment |
| `NEXT_PUBLIC_API_BASE_URL` | public, **build time** | the API's public HTTPS URL; changing it needs a redeploy |

Nothing else reaches the browser. No database URL, storage key or worker credential ever belongs in
`apps/web`.

## API environment (container host)

| Variable | Notes |
|---|---|
| `APP_ENV` | `preview` or `production` (anything but `local`/`test`/`ci` enforces malware scanning) |
| `DATABASE_URL` | `restaurant_app`, **pooled** Neon connection, `sslmode=require` |
| `NEON_AUTH_BASE_URL`, `NEON_AUTH_JWKS_URL` | same Neon Auth as the web app |
| `CORS_ORIGINS` | comma-separated exact origins, e.g. the Vercel production domain |
| `CORS_ORIGIN_REGEX` | optional full-match pattern for Vercel preview URLs |
| `STORAGE_BUCKET`, `AWS_REGION`, `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | private bucket; key scoped to that bucket only |
| `CLAMAV_HOST`, `CLAMAV_PORT` | private address of `clamd` |
| `MIGRATION_DATABASE_URL` | **pre-deploy step only**: owner, direct connection |

## Worker environment

| Variable | Notes |
|---|---|
| `DATABASE_URL` | `restaurant_worker` login |
| `CALC_WORKER_ID` | optional; defaults to hostname:pid |
| `CALC_WORKER_POLL_SECONDS`, `CALC_WORKER_LEASE_SECONDS`, `CALC_WORKER_MAX_ATTEMPTS` | optional tuning |

## Migrations

Only `python scripts/migrate.py --target <preview|production> up`, as the host's pre-deploy step
or by hand (see `db/migrations/README.md`). The ledger makes it safe to re-run on every deploy.

## CI rule

CI may apply migrations only to disposable test databases or the designated preview environment.
CI must never migrate or seed production: `scripts/guard_db_target.py` (also enforced inside
`scripts/migrate.py`) refuses it, and a manual production run needs
`ALLOW_PRODUCTION_DB_CHANGE=YES_I_UNDERSTAND`.

## Vercel

- Pull requests use Preview deployments and preview-only variables.
- Production deployments use production-only variables.
- A Preview deployment must fail closed if its variables are absent; it must never fall back to
  production values.

## Secrets

- Real secrets live in Vercel, the container host and GitHub environments, never in repository
  files. `.env*` files are git-ignored; `.env.example` files hold placeholders only.
- Logs must not emit JWTs, cookie secrets, database URLs, storage keys, invitation tokens or
  signed storage URLs.

## Promotion rule

`local tests → PR CI → preview database + preview deployment → acceptance → production release`

Skipping preview is not permitted for schema changes.
