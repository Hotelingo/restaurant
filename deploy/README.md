# Hosting runbook — preview environment

Web on **Vercel**; API, worker and ClamAV on a **container host**; database and auth on **Neon**;
files in a private **S3-compatible** bucket. Why this split, and every variable, is in
[`docs/plan/06-environment-contract.md`](../docs/plan/06-environment-contract.md).

Do these in order. Each step says how to check it before moving on. Never paste a password or
connection string into chat, an issue or a commit: put it straight into Neon, Vercel or the host.

## 1 · Neon: a preview branch and the application role

1. In the Neon console, create a branch for preview (e.g. `preview`) from `main`/`production`.
   Never run migrations or tests against `production`.
2. Enable **Neon Auth** on that branch. Note its Auth URL and JWKS URL.
3. Connect to the branch as the owner (**direct**, unpooled connection) with `psql` and create the
   API role **before** migrating (older migrations grant rights to it):

   ```sql
   create role restaurant_app login;
   \password restaurant_app
   ```

   `\password` prompts, so the password never appears in shell history. Do not create this role in
   the Neon console: console-created roles become members of `neon_superuser`.

**Check:** `select rolname, rolsuper, rolbypassrls from pg_roles where rolname = 'restaurant_app';`
shows `f`, `f`.

## 2 · Migrations through the ledger

From a machine with this repository and Python 3.12:

```bash
pip install "psycopg[binary]>=3.2"
export MIGRATION_DATABASE_URL='<owner, direct connection, sslmode=require>'
python scripts/migrate.py --target preview status
python scripts/migrate.py --target preview up
```

If this branch was already migrated by hand before the ledger existed, adopt it once instead:
`python scripts/migrate.py --target preview baseline --through <last file it has>`, then `up`.

**Check:** a second `up` prints `up to date: nothing to apply`.

## 3 · Neon: the worker login

Migration `0041` created `restaurant_worker` without a login. Enable it, still as the owner:

```sql
alter role restaurant_worker login;
\password restaurant_worker
```

**Check:** `select pg_has_role('restaurant_app', 'restaurant_pack_server', 'set');` is `t`
(needed to render and sign Owner Packs). If it is `f`, `restaurant_app` was created after
migrations ran: re-run the final `do $$ … $$` block of `db/migrations/0040_pack_server_role.sql`.

## 4 · Object storage

Create a **private** bucket (AWS S3, or Cloudflare R2 with `AWS_ENDPOINT_URL_S3`) and an access key
limited to that bucket (read, write, delete objects). Owner Pack downloads use short-lived signed
URLs, so the browser must be able to reach the storage endpoint.

## 5 · Container host: ClamAV, API, worker

**Option A — one VM (or any host that runs Docker Compose):**

```bash
cp deploy/.env.example deploy/.env.deploy      # git-ignored; fill in the real values
docker compose -f deploy/docker-compose.yml --env-file deploy/.env.deploy up -d --build
```

Compose starts ClamAV, waits until it is healthy (the first start downloads signatures: allow up to
6 minutes), runs the migration ledger, then starts the API and worker. Give the VM **4 GB of
memory or more**: `clamd` needs 2–3 GB on its own.

**Option B — a managed container platform (Render, Railway, Fly.io, …):** create three services
from this repository, all with the **repository root** as build context:

| Service | Dockerfile | Kind | Health check | Notes |
|---|---|---|---|---|
| clamav | image `clamav/clamav:stable` | private service, port 3310 | — | ≥ 3 GB memory; never public |
| api | `api/Dockerfile` | public web service, port `$PORT` (default 8000) | `GET /health` | pre-deploy command: `python scripts/migrate.py --target preview up` with `MIGRATION_DATABASE_URL` set |
| worker | `workers/Dockerfile` | background worker (no port) | — | `DATABASE_URL` = the `restaurant_worker` login |

Set the API variables from `docs/plan/06-environment-contract.md`, with `CLAMAV_HOST` = the
clamav service's private hostname and `CORS_ORIGINS` = the Vercel URL from step 6 (update it after
step 6 if you create the API first).

**Check:**
- `curl https://<api>/health` returns `{"status":"ok"}`.
- `curl https://<api>/health/ready` returns `"database":"ok"`.
- The worker log shows no errors; it logs only when it picks up work.

## 6 · Vercel: the web app

1. Import the repository in Vercel and set **Root Directory** to `apps/web` (Next.js is detected).
2. Set the variables for the environment you are deploying (Preview and/or Production):
   - `NEON_AUTH_BASE_URL`: the Neon Auth URL from step 1.
   - `NEON_AUTH_COOKIE_SECRET`: 32 or more random characters. Generate it with
     `openssl rand -base64 48`. Use a different value per environment.
   - `NEXT_PUBLIC_API_BASE_URL`: the API's public URL from step 5, with no trailing slash. It is
     baked in at build time, so if it changes, redeploy.
3. Deploy. Add the resulting domain to the API's `CORS_ORIGINS` (exact origin, e.g.
   `https://restaurant-review.vercel.app`) and restart the API. For per-PR preview URLs, set
   `CORS_ORIGIN_REGEX` instead of listing each one.
4. In Neon Auth's settings, allow the Vercel domain so sign-in and sign-up are accepted from it.

**Check:** opening the Vercel URL shows the sign-in page, and registering a new account lands on
organisation setup (not "session expired").

## 7 · Smoke test

Run the ten-step click-through in [`dev/local-stack/README.md`](../dev/local-stack/README.md)
against the hosted app with the Amberside fixtures. Expected: Net Sales 228,500 and Operating
Profit 53,549 (−14,671 against budget); the Owner Pack ends signed and downloadable.

Two things differ from local:
- **Uploads are scanned.** If every upload fails with a scanning error, check `CLAMAV_HOST` and that
  ClamAV is healthy.
- **Invitations are copy-link only.** Share the link securely.

## Changing things later

- **Schema:** add a new, higher-numbered file in `db/migrations`. Deploys run `migrate.py up`,
  which applies only what is new. Never edit an applied file: the runner stops on checksum drift.
- **Code:** redeploy the service. The API and worker are stateless; a failed deploy can be rolled
  back to the previous image. Database changes cannot be rolled back that way: fix forward with a
  new migration.
- **Before real customer data:** run the restore drill (open decision OD-02). Restore a Neon branch
  from a point in time and confirm the app runs against it.
