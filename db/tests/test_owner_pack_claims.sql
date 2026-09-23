\set ON_ERROR_STOP on
begin;

create or replace function t20_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t20_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t20_bool(actual boolean, expected boolean, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then
    raise exception 'FAIL % expected % got %',label,expected,actual;
  end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t20_rejects(stmt text, label text)
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
values ('20000000-0000-0000-0000-000000000001','Pack Reviewer','pack@example.com',false);

set role restaurant_app;
select set_config('app.user_id','20000000-0000-0000-0000-000000000001',true);

select * from bootstrap_organisation(
  'Pack Org','pack-org','Pack Outlet','PACK',
  'USD'::char(3),'UTC',1::smallint,'pack-bootstrap-0001','pack-test'
);

insert into reporting_period(
  organisation_id,outlet_id,period_start,period_end,label
)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='PACK';

reset role;

-- The same test user is both the organisation admin (bootstrap) and reviewer,
-- allowing creation and reviewer acceptance to be tested separately by role gate.
insert into membership(
  organisation_id,user_id,role,outlet_scope_mode,active
)
select
  id,
  '20000000-0000-0000-0000-000000000001',
  'reviewer',
  'all_outlets',
  true
from organisation where slug='pack-org';

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select
  '20000000-0000-0000-0000-000000000101',
  organisation_id,id,1,'2026-01-01',
  '20000000-0000-0000-0000-000000000001'
from outlet where code='PACK';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select
  '20000000-0000-0000-0000-000000000201',
  o.organisation_id,o.id,rp.id,'pl-v1',
  '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
  'budget','queued'
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='PACK';

update calc_run
set status='running',started_at=now()
where id='20000000-0000-0000-0000-000000000201';

-- Operating profit actual / Budget / variance.
insert into calc_result(
  id,organisation_id,outlet_id,run_id,
  calc_id,grain_type,grain_key,value_numeric,unit,currency_code,
  calculation_status,evidence_status,result_metadata,raw_delta,profit_effect
)
select
  v.id,o.organisation_id,o.id,
  '20000000-0000-0000-0000-000000000201',
  v.calc_id,v.grain_type,v.grain_key,v.value_numeric,
  'currency','USD','CALCULATED','supported','{}',
  v.raw_delta,v.profit_effect
from outlet o
cross join (
  values
    (
      '20000000-0000-0000-0000-000000000301'::uuid,
      'PL.OPERATING_PROFIT'::text,
      'management_pl'::text,
      '{"scenario":"actual","ladder_code":"OPERATING_PROFIT"}'::jsonb,
      53549::numeric,
      null::numeric,
      null::numeric
    ),
    (
      '20000000-0000-0000-0000-000000000302'::uuid,
      'PL.OPERATING_PROFIT'::text,
      'management_pl'::text,
      '{"scenario":"budget","ladder_code":"OPERATING_PROFIT"}'::jsonb,
      68220::numeric,
      null::numeric,
      null::numeric
    ),
    (
      '20000000-0000-0000-0000-000000000303'::uuid,
      'PL.VAR.OPERATING_PROFIT'::text,
      'management_pl_variance'::text,
      '{"ladder_code":"OPERATING_PROFIT"}'::jsonb,
      -14671::numeric,
      -14671::numeric,
      -14671::numeric
    ),
    (
      '20000000-0000-0000-0000-000000000304'::uuid,
      'PL.UTILITIES'::text,
      'supporting_metric'::text,
      '{"scenario":"actual","metric":"utilities"}'::jsonb,
      7750::numeric,
      null::numeric,
      null::numeric
    ),
    (
      '20000000-0000-0000-0000-000000000305'::uuid,
      'PL.UTILITIES.BUDGET'::text,
      'supporting_metric'::text,
      '{"scenario":"budget","metric":"utilities"}'::jsonb,
      6500::numeric,
      null::numeric,
      null::numeric
    ),
    (
      '20000000-0000-0000-0000-000000000306'::uuid,
      'PL.UTILITIES.VARIANCE'::text,
      'supporting_metric_variance'::text,
      '{"metric":"utilities"}'::jsonb,
      -1250::numeric,
      -1250::numeric,
      -1250::numeric
    )
) v(id,calc_id,grain_type,grain_key,value_numeric,raw_delta,profit_effect)
where o.code='PACK';

update calc_run
set status='completed',completed_at=now(),result_hash=repeat('2',64)
where id='20000000-0000-0000-0000-000000000201';

insert into review(
  id,organisation_id,outlet_id,period_id,status,comparator_scenario,
  context_version_id,materiality_snapshot,active_calc_run_id,
  review_leader_id,frame_confirmed_at
)
select
  '20000000-0000-0000-0000-000000000401',
  o.organisation_id,o.id,rp.id,'in_review','budget',
  '20000000-0000-0000-0000-000000000101',
  '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
  '20000000-0000-0000-0000-000000000201',
  '20000000-0000-0000-0000-000000000001',
  now()
from outlet o
join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='PACK';

update calc_run
set review_id='20000000-0000-0000-0000-000000000401'
where id='20000000-0000-0000-0000-000000000201';


set role restaurant_app;
select set_config('app.user_id','20000000-0000-0000-0000-000000000001',true);

select * from create_pack_version(
  '20000000-0000-0000-0000-000000000401',
  'pack-create-v1-0001',
  'pack-test'
);

select t20_eq(
  (select count(*) from pack_version),
  1,
  'review creates one Owner Pack v1'
);

select t20_eq(
  (select version_no from pack_version limit 1),
  1,
  'first Owner Pack version number is one'
);

select t20_text(
  (select calc_run_id::text from pack_version limit 1),
  '20000000-0000-0000-0000-000000000201',
  'pack pins exactly the review completed calc run'
);

-- Idempotent retry cannot duplicate the pack.
select * from create_pack_version(
  '20000000-0000-0000-0000-000000000401',
  'pack-create-v1-0001',
  'pack-retry'
);

select t20_eq(
  (select count(*) from pack_version),
  1,
  'pack creation retry is idempotent'
);


-- Valid headline claim: magnitudes may be written without the engine sign
-- because direction is separately reviewed in SC15.
select * from create_pack_claim(
  (select id from pack_version where version_no=1),
  'headline',
  'Restaurant operating profit was 53,549 against a Budget of 68,220, which is 14,671 below Budget.',
  'supported',
  array[
    '20000000-0000-0000-0000-000000000301'::uuid,
    '20000000-0000-0000-0000-000000000302'::uuid,
    '20000000-0000-0000-0000-000000000303'::uuid
  ],
  'pack-claim-headline-1',
  'pack-test'
);

select t20_bool(
  (claim_check((select id from claim where section_code='headline'))->>'passed')::boolean,
  true,
  'claimCheck accepts figures that match cited engine output'
);

select t20_eq(
  jsonb_array_length(
    claim_check((select id from claim where section_code='headline'))->'unmatched_numbers'
  ),
  0,
  'valid headline has no unmatched figures'
);


-- Wireframe AT14 failure: 1,300 is not the engine's 1,250 variance.
select * from create_pack_claim(
  (select id from pack_version where version_no=1),
  'utilities',
  'Utilities were 7,750 against a Budget of 6,500, which is 1,300 above Budget.',
  'supported',
  array[
    '20000000-0000-0000-0000-000000000304'::uuid,
    '20000000-0000-0000-0000-000000000305'::uuid,
    '20000000-0000-0000-0000-000000000306'::uuid
  ],
  'pack-claim-utilities-1',
  'pack-test'
);

select t20_bool(
  (claim_check((select id from claim where section_code='utilities'))->>'passed')::boolean,
  false,
  'claimCheck fails a number absent from cited engine output'
);

select t20_text(
  (
    claim_check((select id from claim where section_code='utilities'))
    ->'unmatched_numbers'->>0
  ),
  '1300',
  'claimCheck identifies the exact unmatched amount'
);

select t20_rejects($q$
  select * from review_pack_claim(
    (select id from claim where section_code='utilities'),
    'accept',
    'pack-review-bad-0001',
    'pack-test'
  )
$q$,'reviewer cannot accept a claim that fails claimCheck');


-- Reviewer edit fixes only prose; engine output is never recalculated here.
select * from edit_pack_claim(
  (select id from claim where section_code='utilities'),
  'Utilities were 7,750 against a Budget of 6,500, which is 1,250 above Budget.',
  'pack-edit-utilities-1',
  'pack-test'
);

select t20_bool(
  (claim_check((select id from claim where section_code='utilities'))->>'passed')::boolean,
  true,
  'edited utility claim passes when prose matches the engine'
);

select * from review_pack_claim(
  (select id from claim where section_code='utilities'),
  'accept',
  'pack-review-good-0001',
  'pack-test'
);

select t20_text(
  (select claim_status::text from claim where section_code='utilities'),
  'accepted',
  'passing claim can be accepted by reviewer'
);


-- Banned wording from the v4.2 claim checker remains a hard automated failure.
select * from create_pack_claim(
  (select id from pack_version where version_no=1),
  'absolute_wording',
  'The result will always remain 1,250 above Budget.',
  'supported',
  array['20000000-0000-0000-0000-000000000306'::uuid],
  'pack-claim-banned-1',
  'pack-test'
);

select t20_bool(
  (
    claim_check((select id from claim where section_code='absolute_wording'))
    ->>'banned_wording'
  )::boolean,
  true,
  'claimCheck detects banned absolute wording'
);

select t20_bool(
  (claim_check((select id from claim where section_code='absolute_wording'))->>'passed')::boolean,
  false,
  'banned wording prevents automated claim pass'
);


-- Claim provenance requires at least one immutable calc-result citation.
select t20_rejects($q$
  select * from create_pack_claim(
    (select id from pack_version where version_no=1),
    'uncited',
    'Operating profit was 53,549.',
    'supported',
    array[]::uuid[],
    'pack-claim-uncited1',
    'pack-test'
  )
$q$,'claim creation without a calc-result citation is refused');


-- The valid headline can be accepted.
select * from review_pack_claim(
  (select id from claim where section_code='headline'),
  'accept',
  'pack-review-headline1',
  'pack-test'
);

select t20_text(
  (select claim_status::text from claim where section_code='headline'),
  'accepted',
  'reviewer acceptance is stored only after server claimCheck passes'
);


-- Application role has no direct write path to pack/claim tables.
select t20_rejects($q$
  insert into claim(
    organisation_id,outlet_id,pack_version_id,
    section_code,claim_text,evidence_status,created_by
  )
  select
    organisation_id,outlet_id,id,
    'injected','Injected claim','supported',
    '20000000-0000-0000-0000-000000000001'
  from pack_version where version_no=1
$q$,'application role cannot directly insert claims');


reset role;

-- Simulate the later renderer/sign-off controlled path. A signed pack must
-- already carry final immutable artefact metadata.
update pack_version
set status='signed',
    artifact_bucket='uploads',
    artifact_path='org/pack-org/outlet/PACK/packs/july-v1.pdf',
    artifact_sha256=repeat('a',64),
    artifact_source_sha256=repeat('b',64),
    renderer_version='chromium-pinned-v1',
    template_version='owner-pack-v1',
    updated_at=now()
where version_no=1;

select t20_rejects($q$
  update pack_version
  set status='draft'
  where version_no=1
$q$,'signed pack cannot be unlocked');

select t20_rejects($q$
  update claim
  set claim_text='rewrite signed history'
  where section_code='headline'
$q$,'claim text is immutable once its pack is signed');

select t20_rejects($q$
  delete from pack_version where version_no=1
$q$,'signed pack history cannot be deleted');


-- A post-sign change is a new pack version; v1 remains readable and unchanged.
set role restaurant_app;
select set_config('app.user_id','20000000-0000-0000-0000-000000000001',true);

select * from create_pack_version(
  '20000000-0000-0000-0000-000000000401',
  'pack-create-v2-0001',
  'pack-test'
);

select t20_eq(
  (select count(*) from pack_version),
  2,
  'change after sign creates a second pack version'
);

select t20_eq(
  (select version_no from pack_version where status='draft'),
  2,
  'new post-sign pack is version two'
);

select t20_text(
  (
    select supersedes_pack_version_id::text
    from pack_version
    where version_no=2
  ),
  (select id::text from pack_version where version_no=1),
  'new pack version explicitly supersedes signed v1'
);

rollback;
