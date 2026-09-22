\set ON_ERROR_STOP on
begin;

create or replace function t21_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t21_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t21_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)',label,sqlerrm;
    return;
  end;
  raise exception 'FAIL % accepted unexpectedly',label;
end $$;


insert into neon_auth."user"(id,name,email,"emailVerified")
values
  ('21000000-0000-0000-0000-000000000001','Pack Manager','manager21@example.com',false),
  ('21000000-0000-0000-0000-000000000002','Pack Reviewer','reviewer21@example.com',false);

set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Signoff Org','signoff-org','Signoff Outlet','SIGNOFF',
  'USD'::char(3),'UTC',1::smallint,'signoff-bootstrap-0001','signoff-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-08-01','2026-08-31','August 2026'
from outlet where code='SIGNOFF';

reset role;

insert into membership(
  organisation_id,user_id,role,outlet_scope_mode,active
)
select
  id,
  '21000000-0000-0000-0000-000000000002',
  'reviewer',
  'all_outlets',
  true
from organisation where slug='signoff-org';

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '21000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '21000000-0000-0000-0000-000000000001'
from outlet where code='SIGNOFF';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '21000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='SIGNOFF';

update calc_run
set status='running',started_at=now()
where id='21000000-0000-0000-0000-000000000201';

insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata
)
select
  '21000000-0000-0000-0000-000000000301',
  o.organisation_id,o.id,
  '21000000-0000-0000-0000-000000000201',
  'PL.OPERATING_PROFIT','management_pl',
  '{"scenario":"actual","ladder_code":"OPERATING_PROFIT"}',
  53549,'currency','USD','CALCULATED','supported','{}'
from outlet o where o.code='SIGNOFF';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('3',64)
where id='21000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '21000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '21000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '21000000-0000-0000-0000-000000000201',
  '21000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='SIGNOFF';

update calc_run
set review_id='21000000-0000-0000-0000-000000000401'
where id='21000000-0000-0000-0000-000000000201';


-- Manager creates the pack and claim, then submits for review.
set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from create_pack_version(
  '21000000-0000-0000-0000-000000000401',
  'signoff-pack-create-01',
  'signoff-test'
);

select * from create_pack_claim(
  (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'headline',
  'Operating profit was 53,549.',
  'supported',
  array['21000000-0000-0000-0000-000000000301'::uuid],
  'signoff-claim-create1',
  'signoff-test'
);

select * from submit_pack_for_review(
  (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'signoff-submit-0001',
  'signoff-test'
);

select t21_text(
  (select status::text from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'in_review',
  'manager submits pack into reviewer workflow'
);


-- Reviewer accepts the claim and creates a threaded comment.
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select * from review_pack_claim(
  (select id from claim where section_code='headline'),
  'accept',
  'signoff-claim-accept1',
  'signoff-test'
);

select t21_text(
  (
    select review_check_snapshot->>'status_echo'
    from claim where section_code='headline'
  ),
  'confirmed_by_reviewer',
  'accepted claim stores reviewer manual-check attestation'
);

select * from create_review_comment(
  '21000000-0000-0000-0000-000000000401',
  null,
  'Please state the reconciliation caveat explicitly.',
  'signoff-comment-root1',
  'signoff-test'
);

select t21_eq(
  (select count(*) from review_comment where resolution_status='open'),
  1,
  'reviewer comment persists as open'
);

-- Manager can reply in the same thread but cannot resolve reviewer comments.
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from create_review_comment(
  '21000000-0000-0000-0000-000000000401',
  (select id from review_comment where parent_comment_id is null),
  'Disclosure updated in the pack.',
  'signoff-comment-reply1',
  'signoff-test'
);

select t21_eq(
  (select count(*) from review_comment),
  2,
  'threaded reply persists under the same review'
);

select t21_rejects($q$
  select * from resolve_review_comment(
    (select id from review_comment where parent_comment_id is null),
    'Manager tries to self-clear reviewer comment.',
    'signoff-comment-badres',
    'signoff-test'
  )
$q$,'non-reviewer cannot resolve the reviewer thread');


-- Final rendering metadata is attached by the trusted renderer path.
reset role;
update pack_version
set artifact_bucket='uploads',
    artifact_path='org/signoff-org/outlet/SIGNOFF/packs/august-v1.pdf',
    artifact_sha256=repeat('b',64),
    renderer_version='chromium-pinned-v1',
    template_version='owner-pack-v1',
    updated_at=now()
where review_id='21000000-0000-0000-0000-000000000401';


-- Direct application sessions cannot call the final signoff function.
set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select t21_rejects($q$
  select * from record_pack_signoff(
    (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
    'signed',null,array['Management P&L'],array[]::text[],
    '{"passed":true}'::jsonb,
    'signoff-direct-bypass1',
    'signoff-test'
  )
$q$,'restaurant_app cannot bypass server review gate to sign');


-- Simulate the API service role. Open comments still block a forged passing snapshot.
reset role;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select t21_rejects($q$
  select * from record_pack_signoff(
    (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
    'signed',null,array['Management P&L'],array[]::text[],
    '{"passed":true}'::jsonb,
    'signoff-open-comment1',
    'signoff-test'
  )
$q$,'open reviewer comment blocks server signoff even with passing snapshot');


-- Reviewer resolves both comments, requests changes once, then manager resubmits.
set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select * from resolve_review_comment(
  (select id from review_comment where parent_comment_id is null),
  'Caveat now states the limitation.',
  'signoff-comment-resolve1',
  'signoff-test'
);

select * from resolve_review_comment(
  (select id from review_comment where parent_comment_id is not null),
  'Reply acknowledged.',
  'signoff-comment-resolve2',
  'signoff-test'
);

reset role;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select * from record_pack_signoff(
  (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'changes_requested',
  'Clarify one narrative phrase.',
  array['Management P&L'],
  array['Cross-module reconciliation'],
  '{}'::jsonb,
  'signoff-request-change1',
  'signoff-test'
);

select t21_text(
  (select status::text from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'changes_requested',
  'request changes is persisted on pack version'
);

set role restaurant_app;
select set_config('app.user_id','21000000-0000-0000-0000-000000000001',true);

select * from submit_pack_for_review(
  (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'signoff-resubmit-001',
  'signoff-test'
);

reset role;
select set_config('app.user_id','21000000-0000-0000-0000-000000000002',true);

select * from record_pack_signoff(
  (select id from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'signed',
  'Reviewed subject to the stated cross-module scope.',
  array['Management P&L'],
  array['Cross-module reconciliation'],
  '{"passed":true,"failures":[]}'::jsonb,
  'signoff-final-0001',
  'signoff-test'
);

select t21_text(
  (select status::text from pack_version where review_id='21000000-0000-0000-0000-000000000401'),
  'signed',
  'passing server gate signs and locks the pack'
);

select t21_eq(
  (select count(*) from signoff where decision='changes_requested'),
  1,
  'changes-requested decision remains in history'
);

select t21_eq(
  (select count(*) from signoff where decision='signed'),
  1,
  'signed decision remains in history'
);

select t21_text(
  (select calc_run_id::text from signoff where decision='signed'),
  '21000000-0000-0000-0000-000000000201',
  'signoff explicitly pins the pack calculation run'
);

select t21_rejects($q$
  update signoff set caveat='rewrite history'
  where decision='signed'
$q$,'signoff history is immutable');

select t21_rejects($q$
  update review_comment set body='rewrite comment'
  where parent_comment_id is null
$q$,'comment body is immutable');

rollback;
