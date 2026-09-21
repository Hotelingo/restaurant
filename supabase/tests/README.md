# Database tests

## Running locally

These need `auth.users` and `auth.uid()`, which exist in a real Supabase project but not in a bare
PostgreSQL cluster. Against a scratch database:

```bash
createdb rpr_test

psql -d rpr_test -v ON_ERROR_STOP=1 <<'SQL'
create schema if not exists auth;
create table auth.users (id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid
  language sql stable
  as $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated')
    then create role authenticated; end if;
end $$;
SQL

for f in supabase/migrations/0*.sql; do
  psql -d rpr_test -v ON_ERROR_STOP=1 -f "$f"
done

psql -d rpr_test -f supabase/tests/test_slice1_constraints.sql
```

Expect seven `PASS` notices and no `FAIL`. Verified against PostgreSQL 16.13 on 2026-09-21.

Against a local Supabase instance (`supabase start`), skip the stub block — the real `auth` schema
is already there.

## What is covered

`test_slice1_constraints.sql` asserts the integrity guarantees migrations 0002 and 0003 claim:

| Test | Guarantee |
|---|---|
| G-02 cross-tenant rejection | A row combining one organisation's id with another's outlet is rejected by the database |
| G-02 control | The matching pair succeeds — without this, the test above could pass for the wrong reason |
| G-03 NULLS NOT DISTINCT | A second NULL-coded outlet in the same organisation is rejected |
| G-05 materiality immutability | An approved materiality setting cannot be updated |
| G-05 audit append-only | `audit_log` rows cannot be deleted |
| G-05 context immutability | Context versions cannot be updated |
| Domain checks | Materiality needs a threshold; a period cannot end before it starts |

**Every test asserts a failure path.** That is the point: the value of this schema is what it
refuses. A migration that silently stops refusing something is a regression no feature test would
catch.

## Still to write — story S1-2

RLS tests need connections as distinct roles and cannot live in one psql script. From a second
tenant's perspective, cover:

1. A user in org A reads zero rows from org B on every tenant table.
2. An outlet-scoped member reads only outlets in scope.
3. No `membership_outlet` rows means all outlets in the organisation.
4. An anonymous client reads nothing.
5. An expired `staff_assignment` grants nothing.
6. A client INSERT into `financial_fact` or `calc_result` fails under **every** role.

Run against real PostgreSQL in CI, never a mock. A mocked RLS test tells you your mock works.

## Immutability tests for later slices

`0003_immutability.sql` lists the triggers each later slice must add. Each needs a test that
attempts the mutation **as the service role** — the service role is where the risk lives, so a test
proving only that an ordinary client is blocked proves nothing.
