# Local stack — DEV ONLY

Runs the whole application on one machine with **no Neon cloud access**: PostgreSQL, a local
stand-in for Neon Managed Auth, local S3, the API, the calculation worker and the web app.

This is how the 2026-09-23 readiness review found three defects that every CI job missed (see
`docs/review/05-readiness-review.md`). It is **not** a deployment path. Nothing here may point at
a Neon branch, and the placeholder secrets below are for local use only.

## Why it exists

CI proves a lot, but it has two blind spots:

1. **The API unit tests mock the database**, so SQL never reaches psycopg. Three unescaped `%`
   literals therefore shipped, one of which returned HTTP 500 on every request to the P&L page.
2. **CI's integration steps connect as `postgres`**, a superuser that bypasses row-level security.
   Uploads failed for every real user because the route wrote to `audit_log`, which
   `restaurant_app` may not insert into.

`first_user_journey.py` covers both: it drives the real API over HTTP, as `restaurant_app`, with a
real Better Auth session.

## Components

| Piece | What | Port |
|---|---|---|
| PostgreSQL 16+ | application database `rpr_dev` | 5432 |
| `auth-standin/` | Better Auth 1.6.23 — the library Neon Managed Auth is built on — configured with Neon's cookie prefix (`__Secure-neon-auth.*`), EdDSA JWTs and a JWKS endpoint | 4000 |
| moto | S3-compatible object storage for private uploads | 9000 |
| API | FastAPI, connected as `restaurant_app` | 8000 |
| Web | Next.js production build | 3000 |

## Run it

```bash
# 1 · database: auth stand-in tables first, then every application migration
createdb rpr_dev
psql -d rpr_dev -v ON_ERROR_STOP=1 -f dev/local-stack/neon_auth_standin.sql
for f in db/migrations/0*.sql; do psql -d rpr_dev -v ON_ERROR_STOP=1 -f "$f"; done
psql -d rpr_dev -c "alter role restaurant_app password 'local-dev-only'"

# 2 · auth stand-in
(cd dev/local-stack/auth-standin && npm install && \
  AUTH_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/rpr_dev node server.mjs) &

# 3 · object storage
pip install "moto[server]" && moto_server -H 127.0.0.1 -p 9000 &
python -c "import boto3; boto3.client('s3', endpoint_url='http://127.0.0.1:9000', region_name='us-east-1', aws_access_key_id='local', aws_secret_access_key='local').create_bucket(Bucket='uploads')"

# 4 · API (Python 3.12), as the RLS-enforced runtime role
pip install -e "api[dev]" -r workers/requirements.txt
export APP_ENV=local \
  DATABASE_URL=postgresql://restaurant_app:local-dev-only@127.0.0.1:5432/rpr_dev \
  NEON_AUTH_BASE_URL=http://localhost:4000/neondb/auth \
  NEON_AUTH_JWKS_URL=http://localhost:4000/neondb/auth/.well-known/jwks.json \
  STORAGE_BUCKET=uploads AWS_REGION=us-east-1 AWS_ENDPOINT_URL_S3=http://127.0.0.1:9000 \
  AWS_ACCESS_KEY_ID=local AWS_SECRET_ACCESS_KEY=local
PYTHONPATH=.:api uvicorn app.main:app --app-dir api --port 8000 &

# 5 · web
cd apps/web && npm install && \
  NEON_AUTH_BASE_URL=http://localhost:4000/neondb/auth \
  NEON_AUTH_COOKIE_SECRET=local-dev-only-cookie-secret-at-least-32-chars \
  NEXT_PUBLIC_API_BASE_URL=http://127.0.0.1:8000 \
  npm run build && npm start

# 6 · calculation worker, continuously (the Calculate button queues work for it)
DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:5432/rpr_dev \
  PYTHONPATH=. python -m workers.pl_worker --poll-seconds 1 &
```

Then open <http://localhost:3000>, create an account, and complete setup.

## Click-through test (about 15 minutes)

Uses the Amberside fixtures in `fixtures/amberside/upload_files/`. Everything happens in the
browser; nothing is typed into a database.

1. **Register** at `/auth/register`, then set up organisation → outlet → context (effective from
   2026-07-01) → period "July 2026" (2026-07-01 to 2026-07-31). Choose **Go to outlet Home**.
2. **Set materiality thresholds** (step 3 on the checklist), e.g. 1,000 and 5 %, effective
   2026-07-01. A review cannot be framed on a calculation made without them, and the screens say so.
3. **Data Centre**: upload `Amberside_PnL_Jul2026.csv` as *P&L / trial balance*. The mapping
   screen pre-fills all 15 accounts; confirm, validate, commit. Then upload
   `Amberside_Budget_Jul2026.csv` as *Budget* and do the same.
4. **Calculate**. When it completes, open the Management P&L: Net Sales 228,500, Operating
   Profit 53,549, −14,671 against budget.
5. **Reviews** → Start review → Confirm FRAME. Shortlist e.g. Direct Labour, Product Cost and
   Shared Restaurant Costs.
6. For each movement: save a *Supported* diagnosis with a driver, record an **Act** decision
   (owner, lever, guardrail, metric, due date), then **Add to action register**.
7. **Create Owner Pack** → Open Owner Pack → **Add statement** for each suggestion (the server
   checks every number against the cited results) → **Submit for review**.
8. **Invite a reviewer**: Users & roles (from *All outlets*) → role *Reviewer* → copy the link.
   In a private window, register with that email, open the link and accept. Sign-off must come from
   someone who made none of the decisions; the gate shows this.
9. As the reviewer, open the pack: **Accept** each statement, optionally comment and resolve,
   **Generate file**, then **Sign the Owner Pack**. The gate lists every check and its fix.
10. Back as the owner: **Owner Packs** has the signed version to download; the **Action register**
    lists the three actions; the outlet home shows every step done.

## The first-user journey check

```bash
python dev/local-stack/first_user_journey.py postgresql://postgres:postgres@127.0.0.1:5432/rpr_dev
```

The argument is the **worker's** connection string. The worker currently needs the database owner
because `claim_calculation_request` is granted to no role — see "Carried forward" in the review.

Expected: `RESULT: 30 ok, 0 failed` (the script sets materiality before calculating). That covers sign-up, JWT, bootstrap (plus an idempotent
retry), context, period, materiality, T1 and T6 upload → parse → exceptions → mapping → validate
→ atomic commit (plus an idempotent retry), a worker run, and all eleven golden P&L values.

## Known differences from Neon

- The stand-in is Better Auth itself, not Neon's managed service. Email delivery (magic link,
  password reset, invitations) is not wired, and MFA is not configured.
- Uploads skip malware scanning because `APP_ENV=local` selects the bypass scanner. Any hosted
  environment needs ClamAV, or uploads fail closed.
- Neon branching, `neon diff` and pooled connections are not exercised.
