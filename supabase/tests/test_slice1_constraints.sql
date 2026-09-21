-- Slice 1 constraint tests
--
-- Verifies the integrity guarantees that migrations 0002 and 0003 claim.
-- Every test asserts a FAILURE path: the point is that the database refuses
-- things, and a migration that silently stops refusing them is a regression
-- that no feature test would catch.
--
-- Run against a scratch database with the migrations applied. See
-- supabase/tests/README.md.
--
-- These all pass as at 2026-09-21 against PostgreSQL 16.13.

\set ON_ERROR_STOP off
\set QUIET on

begin;

-- ---------------------------------------------------------------- fixtures

insert into ladder_framework (id, code, name)
  values ('11111111-1111-1111-1111-111111111111', 'RPR', 'Restaurant ladder');

insert into organisation (id, name, slug) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Org A', 'org-a'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Org B', 'org-b');

insert into outlet (id, organisation_id, name, code, currency_code) values
  ('a0000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'A Bistro', 'AB', 'GBP'),
  ('b0000000-0000-0000-0000-00000000000b', 'bbbbbbbb-0000-0000-0000-000000000002', 'B Bistro', 'BB', 'GBP');

-- Helper: run a statement, assert it raises.
create or replace function assert_rejects(stmt text, label text) returns void
language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS  %  (%)', label, sqlerrm;
    return;
  end;
  raise exception 'FAIL  % -- statement was accepted but should have been rejected', label;
end $$;

-- ---------------------------------------------------------------- G-02
-- A row combining one organisation's id with another's outlet must be
-- unrepresentable. This is the test most likely to be forgotten, because once
-- the composite foreign keys are in place it passes trivially -- and once they
-- are removed it fails silently in production as a cross-tenant data leak.

select assert_rejects($$
  insert into reporting_period (organisation_id, outlet_id, period_start, period_end, label)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'b0000000-0000-0000-0000-00000000000b',
          '2026-07-01', '2026-07-31', 'Jul 2026')
$$, 'G-02 cross-tenant reporting_period rejected');

-- Control: the matching pair must succeed, or the test above proves nothing.
insert into reporting_period (organisation_id, outlet_id, period_start, period_end, label)
values ('aaaaaaaa-0000-0000-0000-000000000001',
        'a0000000-0000-0000-0000-00000000000a',
        '2026-07-01', '2026-07-31', 'Jul 2026');

-- ---------------------------------------------------------------- G-03
-- NULLS NOT DISTINCT. Without it, unlimited code-less duplicates are possible
-- because PostgreSQL treats each NULL as distinct.

insert into outlet (organisation_id, name, code, currency_code)
values ('aaaaaaaa-0000-0000-0000-000000000001', 'Dup 1', null, 'GBP');

select assert_rejects($$
  insert into outlet (organisation_id, name, code, currency_code)
  values ('aaaaaaaa-0000-0000-0000-000000000001', 'Dup 2', null, 'GBP')
$$, 'G-03 duplicate NULL outlet code rejected');

-- ---------------------------------------------------------------- G-05
-- Immutability. An approved materiality setting is frozen into calc run
-- snapshots; if it can change afterwards, every snapshot referencing it becomes
-- a lie.

insert into materiality_setting
  (id, organisation_id, outlet_id, scope_type, absolute_threshold, percent_threshold,
   effective_from, approved_at)
values ('cccccccc-0000-0000-0000-00000000000c',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'a0000000-0000-0000-0000-00000000000a',
        'general', 2000, 0.02, '2026-07-01', now());

select assert_rejects($$
  update materiality_setting set absolute_threshold = 1
  where id = 'cccccccc-0000-0000-0000-00000000000c'
$$, 'G-05 approved materiality_setting immutable');

insert into audit_log (action_code, object_type, organisation_id)
values ('READ', 'outlet', 'aaaaaaaa-0000-0000-0000-000000000001');

select assert_rejects($$ delete from audit_log $$,
  'G-05 audit_log append-only');

insert into restaurant_context
  (id, organisation_id, outlet_id, version_no, effective_from)
values ('dddddddd-0000-0000-0000-00000000000d',
        'aaaaaaaa-0000-0000-0000-000000000001',
        'a0000000-0000-0000-0000-00000000000a', 1, '2026-07-01');

select assert_rejects($$
  update restaurant_context set service_style = 'casual'
  where id = 'dddddddd-0000-0000-0000-00000000000d'
$$, 'G-05 restaurant_context versions immutable');

-- ---------------------------------------------------------------- domain
-- A materiality setting with neither an absolute nor a percentage threshold
-- cannot make anything material, so it must not exist.

select assert_rejects($$
  insert into materiality_setting (organisation_id, outlet_id, scope_type, effective_from)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'a0000000-0000-0000-0000-00000000000a', 'food', '2026-07-01')
$$, 'materiality_setting requires at least one threshold');

select assert_rejects($$
  insert into reporting_period (organisation_id, outlet_id, period_start, period_end, label)
  values ('aaaaaaaa-0000-0000-0000-000000000001',
          'a0000000-0000-0000-0000-00000000000a',
          '2026-07-31', '2026-07-01', 'Backwards')
$$, 'reporting_period end must not precede start');

rollback;

-- ---------------------------------------------------------------- still to write
--
-- The RLS tests (story S1-2) need connections as distinct roles and so cannot
-- live in a single psql script. Cover, from a second tenant's perspective:
--   1. a user in org A reads zero rows from org B on every tenant table
--   2. an outlet-scoped member reads only outlets in scope
--   3. no membership_outlet rows means all outlets in the organisation
--   4. an anonymous client reads nothing
--   5. an expired staff_assignment grants nothing
--   6. a client INSERT into financial_fact or calc_result fails under every role
