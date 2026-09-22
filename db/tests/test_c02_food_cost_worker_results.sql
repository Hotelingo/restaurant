\set ON_ERROR_STOP on

do $$
declare
  v_count bigint;
  v_hashes bigint;
  v_first uuid;
  v_second uuid;
  v_review uuid := 'f8000000-0000-0000-0000-000000000401';
begin
  select count(*) into v_count
  from calculation_request_queue
  where review_id=v_review
    and reason='food_cost_c02_review'
    and status='completed'
    and completed_run_id is not null;

  if v_count<>2 then
    raise exception 'FAIL C02 Food Cost worker did not complete both review requests: %',v_count;
  end if;

  select completed_run_id into v_first
  from calculation_request_queue
  where review_id=v_review
    and reason='food_cost_c02_review'
  order by created_at,id
  limit 1;

  select completed_run_id into v_second
  from calculation_request_queue
  where review_id=v_review
    and reason='food_cost_c02_review'
  order by created_at desc,id desc
  limit 1;

  if v_first=v_second then
    raise exception 'FAIL C02 Food Cost rerun reused prior calc_run id';
  end if;

  select count(distinct r.result_hash) into v_hashes
  from calculation_request_queue q
  join calc_run r on r.id=q.completed_run_id
  where q.review_id=v_review
    and q.reason='food_cost_c02_review';

  if v_hashes<>1 then
    raise exception 'FAIL identical C02 Food Cost inputs/evidence produced different hashes';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_first
      and engine_version='food-cost-c02-v1'
      and status='completed'
      and review_id is null
  ) then
    raise exception 'FAIL C02 Food Cost run engine/review-spine contract mismatch';
  end if;

  if (
    select count(*)
    from calc_run_input i
    join import_batch b on b.id=i.batch_id
    join source_file sf on sf.id=b.source_file_id
    where i.run_id=v_first
      and b.status='committed'
      and b.canonical_commit_hash=i.canonical_commit_hash
      and sf.sha256 ~ '^[0-9a-f]{64}$'
      and (
        (i.input_role='item_sales' and b.template_code='T2')
        or (i.input_role='stock' and b.template_code='T3')
        or (i.input_role='item_cost' and b.template_code='T4A')
      )
  )<>3 then
    raise exception 'FAIL C02 Food Cost run lost exact T2/T3/T4A lineage';
  end if;

  if (
    select count(*)
    from calc_run_c02_evidence_input
    where run_id=v_first
  )<>1 then
    raise exception 'FAIL C02 run must pin exactly one supported quantified evidence row';
  end if;

  if not exists(
    select 1
    from calc_run_c02_evidence_input i
    join c02_test_evidence e on e.id=i.c02_evidence_id
    join driver_evidence de on de.id=i.driver_evidence_id
    where i.run_id=v_first
      and e.test_type='waste'
      and e.product_group='food'
      and e.coverage_key='food:july:kitchen-error-comps'
      and e.evidence_status='validated'
      and de.quantified_impact=620
      and jsonb_array_length(e.source_refs)=2
  ) then
    raise exception 'FAIL validated waste/comps evidence is not pinned exactly';
  end if;

  if exists(
    select 1
    from calc_run_c02_evidence_input i
    join c02_test_evidence e on e.id=i.c02_evidence_id
    where i.run_id=v_first
      and e.test_type in ('yield','portion','production')
  ) then
    raise exception 'FAIL observational C02 evidence entered quantitative run inputs';
  end if;

  if (select count(*) from calc_run_c02_override_input where run_id=v_first)<>0 then
    raise exception 'FAIL non-overlapping C02 fixture should not pin an override';
  end if;

  if (select count(*) from calc_result where run_id=v_first)<>23
     or (select count(*) from calc_result where run_id=v_second)<>23 then
    raise exception 'FAIL each C02 Food Cost run must persist 23 results';
  end if;

  if (select count(*) from calc_dependency where run_id=v_first)<>27
     or (select count(*) from calc_dependency where run_id=v_second)<>27 then
    raise exception 'FAIL each C02 Food Cost run must persist 27 dependency edges';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.ACTUAL_VS_EXPECTED'
      and grain_key->>'product_group'='food'
  )<>943 then
    raise exception 'FAIL C02 Food actual-vs-expected mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.DRIVER.WASTE'
      and grain_key->>'product_group'='food'
      and grain_key->>'coverage_key'='food:july:kitchen-error-comps'
  )<>620 then
    raise exception 'FAIL C02 validated waste impact mismatch';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.SUPPORTED_DRIVER_TOTAL'
      and grain_key->>'product_group'='food'
  )<>620 then
    raise exception 'FAIL C02 Food supported-driver total must be 620';
  end if;

  if (
    select value_numeric
    from calc_result
    where run_id=v_first
      and calc_id='FC.RESIDUAL'
      and grain_key->>'product_group'='food'
  )<>323 then
    raise exception 'FAIL C02 Food residual must be 323';
  end if;

  if not exists(
    select 1
    from calc_result
    where run_id=v_first
      and calc_id='FC.DRIVER.WASTE'
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'c02_test_evidence:%'
      )
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref like 'driver_evidence:%'
      )
      and exists(
        select 1 from jsonb_array_elements_text(input_refs) ref
        where ref='pos_comp:KE-JUL'
      )
  ) then
    raise exception 'FAIL C02 driver result lost evidence/source lineage';
  end if;

  if not exists(
    select 1
    from calc_dependency d
    join calc_result parent on parent.id=d.parent_result_id
    join calc_result child on child.id=d.child_result_id
    where d.run_id=v_first
      and d.dependency_role='supported_driver_evidence'
      and parent.calc_id='FC.SUPPORTED_DRIVER_TOTAL'
      and child.calc_id='FC.DRIVER.WASTE'
  ) then
    raise exception 'FAIL supported total does not depend on pinned C02 driver result';
  end if;

  if (
    select count(*)
    from c02_test_evidence
    where review_id=v_review
      and evidence_status='partly_supported'
      and test_type in ('yield','portion','production')
  )<>3 then
    raise exception 'FAIL observational yield/portion/production evidence is missing';
  end if;

  if exists(
    select 1
    from driver_evidence de
    join c02_test_evidence e on e.driver_evidence_id=de.id
    where e.review_id=v_review
      and e.test_type in ('yield','portion','production')
      and de.quantified_impact is not null
  ) then
    raise exception 'FAIL observational C02 rows acquired quantified impacts';
  end if;

  if not exists(
    select 1
    from c02_test_evidence e
    where e.review_id=v_review
      and e.test_type='yield'
      and e.ap_quantity=20
      and e.approved_yield=0.72
      and e.observed_usable_quantity=14.2
  ) then
    raise exception 'FAIL 71% versus 72% yield observation inputs were not retained';
  end if;

  if not exists(
    select 1
    from c02_test_evidence e
    where e.review_id=v_review
      and e.test_type='portion'
      and e.approved_portion=0.280
      and e.observed_avg_portion=0.283
  ) then
    raise exception 'FAIL 283g versus 280g portion observation inputs were not retained';
  end if;

  if not exists(
    select 1
    from c02_test_evidence e
    where e.review_id=v_review
      and e.test_type='production'
      and e.produced_quantity=100
      and e.served_quantity is null
      and e.closing_usable_quantity is null
      and e.documented_nonrevenue_quantity is null
  ) then
    raise exception 'FAIL production observation should retain missing physical balance inputs';
  end if;

  if not exists(
    select 1 from calc_run
    where id=v_second
      and supersedes_calc_run_id=v_first
      and engine_version='food-cost-c02-v1'
  ) then
    raise exception 'FAIL C02 rerun does not supersede prior C02 snapshot';
  end if;

  if exists(
    select 1
    from calc_run r
    join calc_run prior on prior.id=r.supersedes_calc_run_id
    where r.id in (v_first,v_second)
      and prior.engine_version<>r.engine_version
  ) then
    raise exception 'FAIL C02 Food Cost supersession crossed engine modules';
  end if;

  if (
    select count(*)
    from calculation_request_queue
    where review_id=v_review
      and reason='food_cost_c02_review'
  )<>2 then
    raise exception 'FAIL C02 requests did not retain the explicit review anchor';
  end if;

  raise notice 'PASS C02 Food Cost worker reconciles 943 = 620 supported + 323 residual with immutable review evidence lineage';
end
$$;
