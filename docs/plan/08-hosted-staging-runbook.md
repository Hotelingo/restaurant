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

### Malware scanning on a test stack

Production-like stacks run ClamAV and set `CLAMAV_HOST`. A staging or preview
stack that holds **test data only** may skip the scanner to save cost:

```
APP_ENV=staging
MALWARE_SCAN_MODE=unscanned_testing
```

The API refuses this mode for any other `APP_ENV`, and each file it accepts is
recorded with `malware_scanner = 'unscanned-testing'`. Remove both values (and
set `CLAMAV_HOST`) before any real customer file is uploaded.

## Worker container

Build from the repository root using `workers/Dockerfile`.

Two ways to run it:

- **Polling** (`python -m workers.pl_worker`): a continuously running process
  that checks the queue every few seconds. It keeps its container and the
  database compute awake around the clock.
- **On demand** (`python -m workers.trigger_server`), preferred while traffic
  is low: a small private HTTP service. It drains the queue on start-up and
  whenever the API calls `POST /run`, closes its database connection when the
  queue is empty, and otherwise sends no traffic, so the host can sleep it and
  Neon can scale to zero. Queue claims, leases and retries are unchanged, so a
  lost or duplicate wake-up never loses or double-runs work.

On-demand settings:

| Service | Variable | Value |
|---|---|---|
| worker | `DATABASE_URL` | trusted worker credential (direct, not pooled) |
| worker | `CALC_WORKER_TRIGGER_TOKEN` | random, at least 32 characters |
| worker | start command | `python -m workers.trigger_server` (no public domain; sleep enabled) |
| API | `CALC_WORKER_TRIGGER_URL` | `http://<worker private host>:<PORT>/run` |
| API | `CALC_WORKER_TRIGGER_TOKEN` | same token as the worker |

The API wakes the worker after queueing a calculation and again, at most every
15 seconds, while the Calculate panel polls outstanding work.

A dedicated least-privilege worker database role is still required before
external beta/production use.

## Vercel

Configure the Vercel project with Root Directory `apps/web`. Required values:

- `NEON_AUTH_BASE_URL`
- `NEON_AUTH_COOKIE_SECRET`
- `NEXT_PUBLIC_API_BASE_URL`

No database credential belongs in the Vercel web project.
