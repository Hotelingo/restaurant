# Hosted staging deployment

The hosted test stack is intentionally split:

- **Neon**: PostgreSQL, Neon Auth, private object storage.
- **Container host**: FastAPI, calculation worker, and ClamAV.
- **Vercel**: Next.js web application only.

## Database migrations

Before the first migration on a new Neon branch, create the runtime role with SQL
as the branch owner (Neon SQL Editor, correct branch selected):

```sql
create role restaurant_app login password '<generated password>'
  noinherit nobypassrls;
```

Do not create it from the Neon console Roles page: console roles join
`neon_superuser`, which bypasses RLS. Use a generated password (letters and
digits only, so the connection URL needs no escaping) and never reuse a
placeholder.

Persistent databases must use the migration ledger runner:

```bash
MIGRATION_DATABASE_URL='<direct privileged Neon URL>' \
python scripts/run_migrations.py --target preview
```

Check status without applying pending files:

```bash
MIGRATION_DATABASE_URL='<direct privileged Neon URL>' \
python scripts/run_migrations.py --target preview --status
```

The runner records each complete migration filename plus its SHA-256 checksum in
`public.schema_migrations`. It never replays an applied migration and refuses
to continue if an applied file has been edited.

Do **not** use the pooled `restaurant_app` runtime URL for migrations.

## FastAPI container

Build from the repository root using `api/Dockerfile`.

Required runtime variables are documented in `api/.env.example`.

The API must use the pooled `restaurant_app` URL. The migration credential is
separate and should not be available to normal API requests.

## Worker container

Build from the repository root using `workers/Dockerfile`.

The worker is a continuously running background service, not a web service.
A dedicated least-privilege worker database role is still required before
external beta/production use.

## Vercel

Configure the Vercel project with Root Directory `apps/web`. Required values:

- `NEON_AUTH_BASE_URL`
- `NEON_AUTH_COOKIE_SECRET`
- `NEXT_PUBLIC_API_BASE_URL`

No database credential belongs in the Vercel web project.
