\set ON_ERROR_STOP on
begin;

create or replace function t15_eq(actual bigint, expected bigint, label text)
returns void language plpgsql as $$
begin
  if actual <> expected then raise exception 'FAIL % expected % got %',label,expected,actual; end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t15_text(actual text, expected text, label text)
returns void language plpgsql as $$
begin
  if actual is distinct from expected then raise exception 'FAIL % expected % got %',label,expected,actual; end if;
  raise notice 'PASS %',label;
end $$;

create or replace function t15_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin execute stmt;
  exception when others then raise notice 'PASS % (%)',label,sqlerrm; return;
  end;
  raise exception 'FAIL % accepted unexpectedly',label;
end $$;

insert into neon_auth."user"(id,name,email,"emailVerified")
values ('15000000-0000-0000-0000-000000000001','Shortlist Admin','short@example.com',false);

set role restaurant_app;
select set_config('app.user_id','15000000-0000-0000-0000-000000000001',true);
select * from bootstrap_organisation(
  'Short Org','short-org','Short Outlet','SHORT',
  'USD'::char(3),'UTC',1::smallint,'short-bootstrap-key','short-test'
);
insert into reporting_period(organisation_id,outlet_id,period_start,period_end,label)
select organisation_id,id,'2026-07-01','2026-07-31','July 2026'
from outlet where code='SHORT';

reset role;

insert into restaurant_context(
  id,organisation_id,outlet_id,version_no,effective_from,created_by
)
select '15000000-0000-0000-0000-000000000101',
       organisation_id,id,1,'2026-01-01',
       '15000000-0000-0000-0000-000000000001'
from outlet where code='SHORT';

insert into calc_run(
  id,organisation_id,outlet_id,period_id,engine_version,
  settings_snapshot,comparator_scenario,status
)
select '15000000-0000-0000-0000-000000000201',
       o.organisation_id,o.id,rp.id,'pl-v1',
       '{"materiality":{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}}',
       'budget','queued'
from outlet o join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='SHORT';

update calc_run set status='running',started_at=now()
where id='15000000-0000-0000-0000-000000000201';

with f(code,base_id,var_id,comp,delta,effect) as (
 values
 ('NET_SALES','PL.NET_SALES','PL.VAR.NET_SALES',232000::numeric,-3500::numeric,-3500::numeric),
 ('PRODUCT_COST','PL.PRODUCT_COST','PL.VAR.PRODUCT_COST',66908::numeric,3374::numeric,-3374::numeric),
 ('CHANNEL_COST','PL.CHANNEL_COST','PL.VAR.CHANNEL_COST',3300::numeric,300::numeric,-300::numeric),
 ('DIRECT_LABOUR','PL.DIRECT_LABOUR','PL.VAR.DIRECT_LABOUR',79112::numeric,5205::numeric,-5205::numeric),
 ('OTHER_DIRECT_OPERATING','PL.OTHER_DIRECT_OPERATING','PL.VAR.OTHER_DIRECT_OPERATING',2300::numeric,200::numeric,-200::numeric),
 ('SHARED_RESTAURANT_COST','PL.SHARED_COST','PL.VAR.SHARED_RESTAURANT_COST',12160::numeric,2092::numeric,-2092::numeric)
)
insert into calc_result(
 organisation_id,outlet_id,run_id,calc_id,grain_type,grain_key,
 value_numeric,unit,currency_code,calculation_status,evidence_status,result_metadata
)
select o.organisation_id,o.id,'15000000-0000-0000-0000-000000000201',
       f.base_id,'management_pl',
       jsonb_build_object('scenario','budget','ladder_code',f.code),
       f.comp,'currency','USD','CALCULATED','supported','{}'
from outlet o cross join f where o.code='SHORT';

with f(code,var_id,delta,effect) as (
 values
 ('NET_SALES','PL.VAR.NET_SALES',-3500::numeric,-3500::numeric),
 ('PRODUCT_COST','PL.VAR.PRODUCT_COST',3374::numeric,-3374::numeric),
 ('CHANNEL_COST','PL.VAR.CHANNEL_COST',300::numeric,-300::numeric),
 ('DIRECT_LABOUR','PL.VAR.DIRECT_LABOUR',5205::numeric,-5205::numeric),
 ('OTHER_DIRECT_OPERATING','PL.VAR.OTHER_DIRECT_OPERATING',200::numeric,-200::numeric),
 ('SHARED_RESTAURANT_COST','PL.VAR.SHARED_RESTAURANT_COST',2092::numeric,-2092::numeric)
)
insert into calc_result(
 organisation_id,outlet_id,run_id,calc_id,grain_type,grain_key,
 value_numeric,unit,currency_code,calculation_status,evidence_status,
 result_metadata,raw_delta,profit_effect
)
select o.organisation_id,o.id,'15000000-0000-0000-0000-000000000201',
       f.var_id,'management_pl_variance',
       jsonb_build_object('ladder_code',f.code,'actual_scenario','actual','comparator_scenario','budget'),
       f.effect,'currency','USD','CALCULATED','supported','{}',f.delta,f.effect
from outlet o cross join f where o.code='SHORT';

update calc_run set status='completed',completed_at=now(),result_hash=repeat('1',64)
where id='15000000-0000-0000-0000-000000000201';

insert into review(
 id,organisation_id,outlet_id,period_id,status,comparator_scenario,
 context_version_id,materiality_snapshot,active_calc_run_id,
 review_leader_id,frame_confirmed_at
)
select '15000000-0000-0000-0000-000000000401',
       o.organisation_id,o.id,rp.id,'in_review','budget',
       '15000000-0000-0000-0000-000000000101',
       '{"general":{"absolute_threshold":"1000","percent_threshold":"0.10"}}',
       '15000000-0000-0000-0000-000000000201',
       '15000000-0000-0000-0000-000000000001',now()
from outlet o join reporting_period rp
  on rp.organisation_id=o.organisation_id and rp.outlet_id=o.id
where o.code='SHORT';

set role restaurant_app;
select set_config('app.user_id','15000000-0000-0000-0000-000000000001',true);

select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.NET_SALES'),
 null,null,'short-add-0001','short-test');
select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.PRODUCT_COST'),
 null,null,'short-add-0002','short-test');
select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.CHANNEL_COST'),
 null,null,'short-add-0003','short-test');
select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.DIRECT_LABOUR'),
 null,null,'short-add-0004','short-test');
select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.OTHER_DIRECT_OPERATING'),
 null,null,'short-add-0005','short-test');

select t15_eq((select count(*) from review_issue where review_id='15000000-0000-0000-0000-000000000401'),5,'five issues persist');
select t15_text((select materiality_reason from review_issue where ladder_code='CHANNEL_COST'),'management_selection','below-threshold choice is not falsely called material');
select t15_text((select materiality_reason from review_issue where ladder_code='NET_SALES'),'amount_test','materiality rule comes from frozen FRAME snapshot');
select t15_text((select movement_amount::text from review_issue where ladder_code='PRODUCT_COST'),'-3374.0000','profit effect is server-derived');

select t15_rejects($q$
 select * from add_review_issue(
  '15000000-0000-0000-0000-000000000401',
  (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.SHARED_RESTAURANT_COST'),
  null,null,'short-six-no-reason','short-test')
$q$,'sixth issue requires one-line reason');

select * from add_review_issue(
 '15000000-0000-0000-0000-000000000401',
 (select id from calc_result where run_id='15000000-0000-0000-0000-000000000201' and calc_id='PL.VAR.SHARED_RESTAURANT_COST'),
 null,'Owner requested shared-cost discussion','short-six-reason','short-test');

select t15_eq((select count(*) from review_issue where review_id='15000000-0000-0000-0000-000000000401'),6,'sixth issue persists with reason');

select * from reorder_review_issues(
 '15000000-0000-0000-0000-000000000401',
 array[
  (select id from review_issue where ladder_code='DIRECT_LABOUR'),
  (select id from review_issue where ladder_code='PRODUCT_COST'),
  (select id from review_issue where ladder_code='NET_SALES'),
  (select id from review_issue where ladder_code='CHANNEL_COST'),
  (select id from review_issue where ladder_code='OTHER_DIRECT_OPERATING'),
  (select id from review_issue where ladder_code='SHARED_RESTAURANT_COST')
 ]::uuid[],
 'short-reorder-1','short-test');

select t15_eq((select shortlist_order from review_issue where ladder_code='DIRECT_LABOUR'),1,'explicit shortlist order persists');
select t15_eq((select shortlist_order from review_issue where ladder_code='SHARED_RESTAURANT_COST'),6,'last shortlist order persists');

reset role;
select t15_rejects($q$
 update review_issue set movement_amount=999 where ladder_code='NET_SALES'
$q$,'analytic origin is immutable');

set role restaurant_app;
select set_config('app.user_id','15000000-0000-0000-0000-000000000001',true);
select t15_rejects($q$
 insert into review_issue(
  organisation_id,outlet_id,review_id,source_calc_run_id,source_calc_result_id,
  title,movement_amount,ladder_code,module,materiality_reason,shortlist_order,
  evidence_status,created_by
 )
 select rv.organisation_id,rv.outlet_id,rv.id,rv.active_calc_run_id,
        (select id from calc_result where run_id=rv.active_calc_run_id and calc_id='PL.VAR.NET_SALES'),
        'Injected',999,'NET_SALES','PL','injected',99,'supported',
        '15000000-0000-0000-0000-000000000001'
 from review rv where rv.id='15000000-0000-0000-0000-000000000401'
$q$,'application role has no direct issue write');

rollback;
