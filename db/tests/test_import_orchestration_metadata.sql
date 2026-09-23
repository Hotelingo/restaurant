\set ON_ERROR_STOP on

begin;

create or replace function test_assert_eq11(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

create or replace function test_assert_text11(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % -- expected %, got %', label, expected, actual;
  end if;
  raise notice 'PASS  %', label;
end $$;

insert into neon_auth."user" (id,name,email,"emailVerified") values
  ('b0000000-0000-0000-0000-000000000001','Orchestration Admin','orchestration@example.com',false);

set role restaurant_app;
select set_config('app.user_id','b0000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Orchestration Org','orchestration-org','Orchestration Outlet','ORCH',
  'USD'::char(3),'UTC',1::smallint,'orchestration-bootstrap','orchestration-test'
);

select test_assert_eq11(
  (
    select count(*)
    from setting
    where outlet_id=(select id from outlet where code='ORCH')
      and key in (
        'import_profile_match_high',
        'import_profile_match_review',
        'import_header_aliases'
      )
  ),
  3,
  'new outlet receives all three import profile-match settings'
);

select test_assert_text11(
  (
    select value_json::text
    from setting
    where outlet_id=(select id from outlet where code='ORCH')
      and key='import_profile_match_high'
  ),
  '0.92',
  'high confidence default is persisted as outlet setting'
);

select * from put_outlet_setting(
  (select id from outlet where code='ORCH'),
  'import_profile_match_high',
  '0.95'::jsonb,
  'orchestration-setting-high',
  'orchestration-test'
);

select test_assert_text11(
  (
    select value_json::text
    from setting
    where outlet_id=(select id from outlet where code='ORCH')
      and key='import_profile_match_high'
  ),
  '0.95',
  'import profile-match setting is editable through controlled setting function'
);

select * from put_outlet_setting(
  (select id from outlet where code='ORCH'),
  'import_header_aliases',
  '{"gl code":"account code","account description":"account name"}'::jsonb,
  'orchestration-setting-alias',
  'orchestration-test'
);

select test_assert_text11(
  (
    select value_json->>'gl code'
    from setting
    where outlet_id=(select id from outlet where code='ORCH')
      and key='import_header_aliases'
  ),
  'account code',
  'header alias map persists as outlet setting'
);

reset role;

select test_assert_eq11(
  (
    select count(*)
    from information_schema.columns
    where table_schema='public'
      and table_name='import_batch'
      and column_name in (
        'parse_metadata_json',
        'profile_match_tier',
        'profile_match_message',
        'candidate_profile_version_id',
        'parse_completed_at'
      )
  ),
  5,
  'import_batch exposes orchestration metadata columns'
);

rollback;
