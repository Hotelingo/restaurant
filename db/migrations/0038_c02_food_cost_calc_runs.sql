-- 0038 · C02-aware Food Cost calculation persistence
-- Slice 8 / S8-3. Review-specific C02 evidence is pinned beside the immutable
-- T2/T3/T4A inputs without associating the supporting calc_run to the review
-- FRAME itself.

alter table calculation_request_queue
  add column review_id uuid;

alter table calculation_request_queue
  add constraint calculation_request_review_same_tenant_fk
  foreign key (organisation_id,outlet_id,review_id)
  references review(organisation_id,outlet_id,id);

create index calculation_request_review_idx
  on calculation_request_queue(review_id,created_at desc)
  where review_id is not null;


create table calc_run_c02_evidence_input (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  run_id uuid not null,
  review_id uuid not null,
  c02_evidence_id uuid not null,
  driver_evidence_id uuid not null,
  product_group text not null,
  coverage_key text not null,
  evidence_status text not null,
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,run_id)
    references calc_run(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,c02_evidence_id)
    references c02_test_evidence(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,driver_evidence_id)
    references driver_evidence(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (run_id,c02_evidence_id),

  check (length(btrim(product_group)) > 0),
  check (length(btrim(coverage_key)) > 0),
  check (evidence_status in ('supported','validated'))
);

create index calc_run_c02_evidence_run_idx
  on calc_run_c02_evidence_input(run_id,product_group,coverage_key);


create table calc_run_c02_override_input (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  run_id uuid not null,
  review_id uuid not null,
  override_id uuid not null,
  product_group text not null,
  coverage_key text not null,
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,run_id)
    references calc_run(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,override_id)
    references c02_coverage_override(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (run_id,override_id),

  check (length(btrim(product_group)) > 0),
  check (length(btrim(coverage_key)) > 0)
);

create index calc_run_c02_override_run_idx
  on calc_run_c02_override_input(run_id,product_group,coverage_key);


create or replace function guard_calc_run_c02_evidence_input()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_request public.calculation_request_queue%rowtype;
  v_evidence public.c02_test_evidence%rowtype;
begin
  select * into v_run
  from public.calc_run
  where id=new.run_id;

  if v_run.id is null
     or v_run.organisation_id<>new.organisation_id
     or v_run.outlet_id<>new.outlet_id
     or v_run.status not in ('queued','running')
     or v_run.engine_version<>'food-cost-c02-v1'
     or v_run.request_id is null then
    raise exception 'C02 evidence input requires an active food-cost-c02-v1 run'
      using errcode='check_violation';
  end if;

  select * into v_request
  from public.calculation_request_queue
  where id=v_run.request_id;

  if v_request.review_id is distinct from new.review_id then
    raise exception 'C02 evidence review must match the calculation request review'
      using errcode='check_violation';
  end if;

  select * into v_evidence
  from public.c02_test_evidence
  where id=new.c02_evidence_id;

  if v_evidence.id is null
     or v_evidence.organisation_id<>new.organisation_id
     or v_evidence.outlet_id<>new.outlet_id
     or v_evidence.review_id<>new.review_id
     or v_evidence.driver_evidence_id<>new.driver_evidence_id
     or v_evidence.product_group<>new.product_group
     or v_evidence.coverage_key<>new.coverage_key
     or v_evidence.evidence_status<>new.evidence_status
     or v_evidence.evidence_status not in ('supported','validated')
     or exists(
       select 1
       from public.c02_test_evidence newer
       where newer.supersedes_c02_evidence_id=v_evidence.id
     ) then
    raise exception 'C02 run input must pin active supported/validated evidence in the request review'
      using errcode='check_violation';
  end if;

  return new;
end
$$;

create trigger calc_run_c02_evidence_input_guard
  before insert on calc_run_c02_evidence_input
  for each row execute function guard_calc_run_c02_evidence_input();

create trigger calc_run_c02_evidence_input_immutable
  before update or delete on calc_run_c02_evidence_input
  for each row execute function forbid_mutation();


create or replace function guard_calc_run_c02_override_input()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_request public.calculation_request_queue%rowtype;
  v_override public.c02_coverage_override%rowtype;
begin
  select * into v_run
  from public.calc_run where id=new.run_id;

  if v_run.id is null
     or v_run.organisation_id<>new.organisation_id
     or v_run.outlet_id<>new.outlet_id
     or v_run.status not in ('queued','running')
     or v_run.engine_version<>'food-cost-c02-v1'
     or v_run.request_id is null then
    raise exception 'C02 override input requires an active food-cost-c02-v1 run'
      using errcode='check_violation';
  end if;

  select * into v_request
  from public.calculation_request_queue
  where id=v_run.request_id;

  if v_request.review_id is distinct from new.review_id then
    raise exception 'C02 override review must match the calculation request review'
      using errcode='check_violation';
  end if;

  select * into v_override
  from public.c02_coverage_override
  where id=new.override_id;

  if v_override.id is null
     or v_override.organisation_id<>new.organisation_id
     or v_override.outlet_id<>new.outlet_id
     or v_override.review_id<>new.review_id
     or v_override.product_group<>new.product_group
     or v_override.coverage_key<>new.coverage_key then
    raise exception 'C02 run override must match the request review/product/coverage scope'
      using errcode='check_violation';
  end if;

  return new;
end
$$;

create trigger calc_run_c02_override_input_guard
  before insert on calc_run_c02_override_input
  for each row execute function guard_calc_run_c02_override_input();

create trigger calc_run_c02_override_input_immutable
  before update or delete on calc_run_c02_override_input
  for each row execute function forbid_mutation();


alter table calc_run_c02_evidence_input enable row level security;
alter table calc_run_c02_override_input enable row level security;

create policy calc_run_c02_evidence_input_read on calc_run_c02_evidence_input
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy calc_run_c02_override_input_read on calc_run_c02_override_input
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on calc_run_c02_evidence_input,calc_run_c02_override_input
  to restaurant_app;


-- Forward-fix the worker claim contract with an optional review anchor.
create or replace function claim_calculation_request(
  p_worker_id text,
  p_lease_seconds integer default 300,
  p_max_attempts integer default 5
)
returns table (
  request_id uuid,
  organisation_id uuid,
  outlet_id uuid,
  period_id uuid,
  source_batch_id uuid,
  review_id uuid,
  reason text,
  attempt_no integer,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_request_id uuid;
begin
  if p_worker_id is null or length(btrim(p_worker_id))=0 then
    raise exception 'worker id is required'
      using errcode='invalid_parameter_value';
  end if;
  if p_lease_seconds<30 or p_lease_seconds>3600 then
    raise exception 'lease seconds must be between 30 and 3600'
      using errcode='invalid_parameter_value';
  end if;
  if p_max_attempts<1 or p_max_attempts>20 then
    raise exception 'max attempts must be between 1 and 20'
      using errcode='invalid_parameter_value';
  end if;

  update public.calc_run r
  set status='failed',
      completed_at=now(),
      error_code='WORKER_LEASE_EXPIRED',
      error_message='Calculation worker lease expired before completion'
  from public.calculation_request_queue q
  where r.request_id=q.id
    and r.status='running'
    and q.status='running'
    and q.lease_expires_at is not null
    and q.lease_expires_at<now();

  update public.calculation_request_queue q
  set status='failed',
      completed_at=now(),
      last_error=coalesce(q.last_error,'Calculation worker lease expired after maximum attempts'),
      claimed_by=null,
      heartbeat_at=null,
      lease_expires_at=null
  where q.status='running'
    and q.lease_expires_at is not null
    and q.lease_expires_at<now()
    and q.attempts>=p_max_attempts;

  select q.id into v_request_id
  from public.calculation_request_queue q
  where (
      (q.status='pending' and q.available_at<=now())
      or (
        q.status='running'
        and q.lease_expires_at is not null
        and q.lease_expires_at<now()
      )
    )
    and q.attempts<p_max_attempts
  order by q.available_at,q.created_at,q.id
  for update skip locked
  limit 1;

  if v_request_id is null then
    return;
  end if;

  return query
  update public.calculation_request_queue q
  set status='running',
      attempts=q.attempts+1,
      started_at=coalesce(q.started_at,now()),
      completed_at=null,
      claimed_by=btrim(p_worker_id),
      heartbeat_at=now(),
      lease_expires_at=now()+make_interval(secs=>p_lease_seconds),
      last_error=null
  where q.id=v_request_id
  returning
    q.id,q.organisation_id,q.outlet_id,q.period_id,q.source_batch_id,
    q.review_id,q.reason,q.attempts,q.lease_expires_at;
end
$$;

revoke all on function claim_calculation_request(text,integer,integer) from public;


create or replace function request_food_cost_c02_calculation(
  p_review_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_source_batch_id uuid;
  v_existing jsonb;
  v_request_id uuid;
  v_operation text := 'food_cost.c02.calculate:'||p_review_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_review
  from public.review
  where id=p_review_id
  for update;

  if v_review.id is null
     or v_review.status<>'in_review'
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_review.organisation_id,v_review.outlet_id
     ) then
    raise exception 'review is not available for C02 recalculation'
      using errcode='insufficient_privilege';
  end if;

  if not exists(
    select 1
    from public.data_readiness dr
    where dr.organisation_id=v_review.organisation_id
      and dr.outlet_id=v_review.outlet_id
      and dr.period_id=v_review.period_id
      and dr.capability_code='food_cost_inputs'
      and dr.status='ready'
  ) then
    raise exception 'C02-aware Food Cost requires ready T2/T3/T4A inputs'
      using errcode='check_violation';
  end if;

  if not exists(
    select 1
    from public.review_issue ri
    where ri.review_id=v_review.id
      and ri.issue_status<>'removed'
      and ri.ladder_code='PRODUCT_COST'
  ) then
    raise exception 'review must contain an active Product Cost issue before C02 reconciliation'
      using errcode='check_violation';
  end if;

  if not exists(
    select 1
    from public.c02_test_evidence e
    join public.driver_evidence de
      on de.organisation_id=e.organisation_id
     and de.outlet_id=e.outlet_id
     and de.id=e.driver_evidence_id
    where e.review_id=v_review.id
      and e.evidence_status in ('supported','validated')
      and de.quantified_impact is not null
      and not exists(
        select 1 from public.c02_test_evidence newer
        where newer.supersedes_c02_evidence_id=e.id
      )
  ) then
    raise exception 'review has no active supported/validated C02 evidence'
      using errcode='check_violation';
  end if;

  select b.id into v_source_batch_id
  from public.import_batch b
  where b.organisation_id=v_review.organisation_id
    and b.outlet_id=v_review.outlet_id
    and b.period_id=v_review.period_id
    and b.template_code='T3'
    and b.status='committed'
  order by b.committed_at desc,b.id desc
  limit 1;

  if v_source_batch_id is null then
    raise exception 'committed T3 stock batch is required'
      using errcode='check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'request_id',false) then
    return (v_existing->>'request_id')::uuid;
  end if;

  insert into public.calculation_request_queue(
    organisation_id,outlet_id,period_id,source_batch_id,review_id,reason,status
  )
  values(
    v_review.organisation_id,v_review.outlet_id,v_review.period_id,
    v_source_batch_id,v_review.id,'food_cost_c02_review','pending'
  )
  returning id into v_request_id;

  update public.request_idempotency
  set response_json=jsonb_build_object('request_id',v_request_id)
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'FOOD_COST_C02_CALCULATION_REQUESTED','calculation_request_queue',
    v_request_id::text,p_correlation_id
  );

  return v_request_id;
end
$$;

revoke all on function request_food_cost_c02_calculation(uuid,text,text)
  from public;
grant execute on function request_food_cost_c02_calculation(uuid,text,text)
  to restaurant_app;
