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
  as $$
    select coalesce(
      nullif(current_setting('request.jwt.claim.sub', true), ''),
      (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  $$;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated')
    then create role authenticated; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon')
    then create role anon; end if;
end $$;
SQL

for f in supabase/migrations/0*.sql; do
  psql -d rpr_test -v ON_ERROR_STOP=1 -f "$f"
done

psql -d rpr_test -f supabase/tests/test_slice1_constraints.sql
psql -d rpr_test -f supabase/tests/test_slice1_rls.sql
```

Expect only `PASS` notices and no `FAIL`. The RLS script grants its test roles normal table
privileges deliberately, so a denied/filtered result proves RLS rather than a missing SQL grant.

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

## RLS coverage — story S1-2

`test_slice1_rls.sql` now covers the Slice 1 tenant boundary using real PostgreSQL RLS semantics:

1. all-outlets membership sees every outlet in its organisation and none outside it;
2. selected-outlets membership sees only joined outlets;
3. selected-outlets with zero join rows fails closed to zero outlets;
4. an outlet-scoped admin cannot expand organisation-wide membership scope;
5. outlet-scoped staff sees only the assigned outlet;
6. expired staff assignments grant nothing;
7. another tenant sees only its own organisation/outlet;
8. anonymous access returns zero customer rows.

Later-slice client-write tests for `financial_fact` and `calc_result` are added when those tables
exist. Run against real PostgreSQL in CI, never a mock.

## Immutability tests for later slices

`0003_immutability.sql` lists the triggers each later slice must add. Each needs a test that
attempts the mutation **as the service role** — the service role is where the risk lives, so a test
proving only that an ordinary client is blocked proves nothing.
