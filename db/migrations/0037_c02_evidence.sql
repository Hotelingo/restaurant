-- 0037 · Structured C02 driver evidence and coverage contract
-- Slice 8 / S8-2. Adds typed immutable C02 test evidence on top of the
-- existing diagnosis/driver_evidence workflow without rewriting legacy rows.

alter table driver_evidence
  add column if not exists coverage_key text,
  add column if not exists product_group text;

create table c02_test_evidence (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  review_issue_id uuid not null,
  diagnosis_id uuid not null,
  driver_evidence_id uuid not null,
  test_type text not null
    check (test_type in (
      'yield','portion','production','waste','transfer_nonrevenue'
    )),
  product_group text not null
    check (length(btrim(product_group)) > 0),
  coverage_key text not null
    check (length(btrim(coverage_key)) > 0),
  evidence_status text not null
    check (evidence_status in (
      'validated','supported','partly_supported','evidence_required',
      'not_reconciled','not_applicable'
    )),

  -- Yield inputs.
  ap_quantity numeric(20,8),
  approved_yield numeric(20,8),
  observed_usable_quantity numeric(20,8),
  approved_usable_unit_cost numeric(20,8),

  -- Portion inputs.
  approved_portion numeric(20,8),
  observed_avg_portion numeric(20,8),
  representative_portions numeric(20,8),

  -- Production balance inputs.
  produced_quantity numeric(20,8),
  served_quantity numeric(20,8),
  closing_usable_quantity numeric(20,8),
  documented_nonrevenue_quantity numeric(20,8),

  -- Waste / transfer inputs.
  quantity numeric(20,8),
  unit_cost numeric(20,8),
  reason_code text,
  already_in_approved_standard boolean,
  movement_classification text,

  source_refs jsonb not null default '[]'::jsonb
    check (jsonb_typeof(source_refs)='array'),
  supersedes_c02_evidence_id uuid,
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,review_issue_id,diagnosis_id)
    references diagnosis(organisation_id,outlet_id,review_issue_id,id),
  foreign key (organisation_id,outlet_id,driver_evidence_id)
    references driver_evidence(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (driver_evidence_id),

  check (
    supersedes_c02_evidence_id is null
    or supersedes_c02_evidence_id <> id
  ),
  check (
    approved_yield is null
    or (approved_yield >= 0 and approved_yield <= 1)
  ),
  check (
    ap_quantity is null or ap_quantity >= 0
  ),
  check (
    observed_usable_quantity is null or observed_usable_quantity >= 0
  ),
  check (
    approved_usable_unit_cost is null or approved_usable_unit_cost >= 0
  ),
  check (
    approved_portion is null or approved_portion >= 0
  ),
  check (
    observed_avg_portion is null or observed_avg_portion >= 0
  ),
  check (
    representative_portions is null or representative_portions >= 0
  ),
  check (
    produced_quantity is null or produced_quantity >= 0
  ),
  check (
    served_quantity is null or served_quantity >= 0
  ),
  check (
    closing_usable_quantity is null or closing_usable_quantity >= 0
  ),
  check (
    documented_nonrevenue_quantity is null
    or documented_nonrevenue_quantity >= 0
  ),
  check (
    quantity is null or quantity >= 0
  ),
  check (
    unit_cost is null or unit_cost >= 0
  )
);

alter table c02_test_evidence
  add constraint c02_supersedes_same_scope_fk
  foreign key (
    organisation_id,outlet_id,review_id,supersedes_c02_evidence_id
  )
  references c02_test_evidence(
    organisation_id,outlet_id,review_id,id
  );

create index c02_test_evidence_review_idx
  on c02_test_evidence(review_id,product_group,test_type,coverage_key,created_at,id);
create index c02_test_evidence_diagnosis_idx
  on c02_test_evidence(diagnosis_id,created_at,id);


create table c02_coverage_override (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  product_group text not null
    check (length(btrim(product_group)) > 0),
  coverage_key text not null
    check (length(btrim(coverage_key)) > 0),
  reason text not null
    check (length(btrim(reason)) > 0),
  reviewer_id uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (review_id,product_group,coverage_key)
);

create index c02_coverage_override_review_idx
  on c02_coverage_override(review_id,product_group,coverage_key);


create trigger c02_test_evidence_immutable
  before update or delete on c02_test_evidence
  for each row execute function forbid_mutation();

create trigger c02_coverage_override_immutable
  before update or delete on c02_coverage_override
  for each row execute function forbid_mutation();


alter table c02_test_evidence enable row level security;
alter table c02_coverage_override enable row level security;

create policy c02_test_evidence_read on c02_test_evidence
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy c02_coverage_override_read on c02_coverage_override
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on c02_test_evidence,c02_coverage_override to restaurant_app;


create or replace function guard_driver_evidence_c02_contract()
returns trigger
language plpgsql
as $$
declare
  v_driver_code text;
begin
  select code into v_driver_code
  from public.driver_taxonomy
  where id=new.driver_taxonomy_id;

  if v_driver_code in (
    'food_yield','food_portion','food_production',
    'food_waste','food_transfer_nonrevenue'
  ) then
    if new.evidence_status in ('supported','validated')
       and new.quantified_impact is not null
       and (
         nullif(btrim(new.coverage_key),'') is null
         or nullif(btrim(new.product_group),'') is null
       ) then
      raise exception 'quantified supported food evidence requires product_group and coverage_key'
        using errcode='check_violation';
    end if;

    if new.evidence_status not in ('supported','validated')
       and new.quantified_impact is not null then
      raise exception 'unsupported food evidence cannot store a quantified reconciliation impact'
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;

create trigger driver_evidence_c02_contract_guard
  before insert on driver_evidence
  for each row execute function guard_driver_evidence_c02_contract();


create or replace function guard_c02_test_evidence_insert()
returns trigger
language plpgsql
as $$
declare
  v_driver public.driver_evidence%rowtype;
  v_driver_code text;
  v_existing_id uuid;
begin
  select * into v_driver
  from public.driver_evidence
  where id=new.driver_evidence_id;

  if v_driver.id is null
     or v_driver.organisation_id<>new.organisation_id
     or v_driver.outlet_id<>new.outlet_id
     or v_driver.review_issue_id<>new.review_issue_id
     or v_driver.diagnosis_id<>new.diagnosis_id
     or v_driver.evidence_status<>new.evidence_status
     or v_driver.coverage_key is distinct from new.coverage_key
     or v_driver.product_group is distinct from new.product_group then
    raise exception 'C02 typed evidence must match its driver_evidence scope/status/coverage'
      using errcode='check_violation';
  end if;

  select code into v_driver_code
  from public.driver_taxonomy
  where id=v_driver.driver_taxonomy_id;

  if v_driver_code <> case new.test_type
    when 'yield' then 'food_yield'
    when 'portion' then 'food_portion'
    when 'production' then 'food_production'
    when 'waste' then 'food_waste'
    when 'transfer_nonrevenue' then 'food_transfer_nonrevenue'
  end then
    raise exception 'C02 test type does not match the driver taxonomy'
      using errcode='check_violation';
  end if;

  if v_driver.quantified_impact is not null then
    if new.evidence_status not in ('supported','validated') then
      raise exception 'quantified C02 impact requires supported or validated evidence'
        using errcode='check_violation';
    end if;
    if jsonb_array_length(new.source_refs)=0 then
      raise exception 'quantified C02 impact requires direct source refs'
        using errcode='check_violation';
    end if;

    if new.test_type='yield' and (
      new.ap_quantity is null
      or new.approved_yield is null
      or new.observed_usable_quantity is null
      or new.approved_usable_unit_cost is null
    ) then
      raise exception 'quantified yield evidence is missing reproducible typed inputs'
        using errcode='check_violation';
    elsif new.test_type='portion' and (
      new.approved_portion is null
      or new.observed_avg_portion is null
      or new.representative_portions is null
      or new.approved_usable_unit_cost is null
    ) then
      raise exception 'quantified portion evidence is missing reproducible typed inputs'
        using errcode='check_violation';
    elsif new.test_type='production' and (
      new.produced_quantity is null
      or new.served_quantity is null
      or new.closing_usable_quantity is null
      or new.documented_nonrevenue_quantity is null
      or new.approved_usable_unit_cost is null
    ) then
      raise exception 'quantified production evidence is missing reproducible typed inputs'
        using errcode='check_violation';
    elsif new.test_type='waste' and (
      new.quantity is null
      or new.unit_cost is null
      or nullif(btrim(new.reason_code),'') is null
    ) then
      raise exception 'quantified waste evidence is missing reproducible typed inputs'
        using errcode='check_violation';
    elsif new.test_type='waste'
      and coalesce(new.already_in_approved_standard,false) then
      raise exception 'loss already in the approved standard cannot be quantified again'
        using errcode='check_violation';
    elsif new.test_type='transfer_nonrevenue' and (
      new.quantity is null
      or new.unit_cost is null
      or nullif(btrim(new.movement_classification),'') is null
    ) then
      raise exception 'quantified transfer evidence is missing reproducible typed inputs'
        using errcode='check_violation';
    elsif new.test_type='transfer_nonrevenue'
      and new.movement_classification='internal_transfer' then
      raise exception 'internal transfers inside the review boundary cannot be quantified'
        using errcode='check_violation';
    end if;
  end if;

  if new.supersedes_c02_evidence_id is not null then
    if not exists(
      select 1
      from public.c02_test_evidence old
      where old.id=new.supersedes_c02_evidence_id
        and old.organisation_id=new.organisation_id
        and old.outlet_id=new.outlet_id
        and old.review_id=new.review_id
        and old.product_group=new.product_group
        and old.coverage_key=new.coverage_key
    ) then
      raise exception 'superseded C02 evidence must be in the same review/product/coverage scope'
        using errcode='check_violation';
    end if;
  end if;

  if new.evidence_status in ('supported','validated') then
    select e.id into v_existing_id
    from public.c02_test_evidence e
    where e.review_id=new.review_id
      and e.product_group=new.product_group
      and e.coverage_key=new.coverage_key
      and e.evidence_status in ('supported','validated')
      and e.id is distinct from new.supersedes_c02_evidence_id
      and not exists(
        select 1
        from public.c02_test_evidence newer
        where newer.supersedes_c02_evidence_id=e.id
      )
    order by e.created_at,e.id
    limit 1;

    if v_existing_id is not null
       and not exists(
         select 1
         from public.c02_coverage_override o
         where o.review_id=new.review_id
           and o.product_group=new.product_group
           and o.coverage_key=new.coverage_key
       ) then
      raise exception 'overlapping supported C02 coverage requires an immutable reviewer override'
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;

create trigger c02_test_evidence_insert_guard
  before insert on c02_test_evidence
  for each row execute function guard_c02_test_evidence_insert();


create or replace function record_c02_coverage_override(
  p_review_id uuid,
  p_product_group text,
  p_coverage_key text,
  p_reason text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  override_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_existing jsonb;
  v_override_id uuid;
  v_operation text := 'review.c02.coverage_override:'||p_review_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;
  if nullif(btrim(p_product_group),'') is null
     or nullif(btrim(p_coverage_key),'') is null
     or nullif(btrim(p_reason),'') is null then
    raise exception 'product group, coverage key and override reason are required'
      using errcode='check_violation';
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
    raise exception 'review is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'override_id',false) then
    return query select (v_existing->>'override_id')::uuid,true;
    return;
  end if;

  insert into public.c02_coverage_override(
    organisation_id,outlet_id,review_id,product_group,
    coverage_key,reason,reviewer_id
  )
  values(
    v_review.organisation_id,v_review.outlet_id,v_review.id,
    btrim(p_product_group),btrim(p_coverage_key),btrim(p_reason),v_user_id
  )
  on conflict(review_id,product_group,coverage_key)
  do nothing
  returning id into v_override_id;

  if v_override_id is null then
    select id into v_override_id
    from public.c02_coverage_override
    where review_id=v_review.id
      and product_group=btrim(p_product_group)
      and coverage_key=btrim(p_coverage_key);
  end if;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'C02_COVERAGE_OVERRIDE_RECORDED','c02_coverage_override',
    v_override_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('override_id',v_override_id)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_override_id,false;
end
$$;

revoke all on function record_c02_coverage_override(uuid,text,text,text,text,text)
  from public;
grant execute on function record_c02_coverage_override(uuid,text,text,text,text,text)
  to restaurant_app;


create or replace function add_c02_driver_evidence(
  p_issue_id uuid,
  p_test_type text,
  p_product_group text,
  p_coverage_key text,
  p_evidence_source_type text,
  p_evidence_source_id text,
  p_evidence_status text,
  p_quantified_impact numeric,
  p_source_refs jsonb,
  p_inputs jsonb,
  p_supersedes_c02_evidence_id uuid,
  p_note text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  evidence_id uuid,
  c02_evidence_id uuid,
  reconciliation_impact numeric,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_diagnosis_id uuid;
  v_driver_code text;
  v_driver_id uuid;
  v_evidence_id uuid;
  v_c02_id uuid;
  v_recon numeric;
  v_existing jsonb;
  v_operation text := 'issue.c02_driver_evidence.add:'||p_issue_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;
  if p_test_type not in ('yield','portion','production','waste','transfer_nonrevenue') then
    raise exception 'unsupported C02 test type'
      using errcode='invalid_parameter_value';
  end if;
  if p_evidence_status not in (
    'validated','supported','partly_supported','evidence_required',
    'not_reconciled','not_applicable'
  ) then
    raise exception 'unsupported evidence status'
      using errcode='invalid_parameter_value';
  end if;
  if nullif(btrim(p_product_group),'') is null
     or nullif(btrim(p_coverage_key),'') is null
     or nullif(btrim(p_evidence_source_type),'') is null
     or nullif(btrim(p_evidence_source_id),'') is null then
    raise exception 'product group, coverage key and evidence source are required'
      using errcode='check_violation';
  end if;
  if p_source_refs is null or jsonb_typeof(p_source_refs)<>'array' then
    raise exception 'source_refs must be a JSON array'
      using errcode='check_violation';
  end if;
  if p_inputs is null or jsonb_typeof(p_inputs)<>'object' then
    raise exception 'typed C02 inputs must be a JSON object'
      using errcode='check_violation';
  end if;
  if p_evidence_status not in ('supported','validated')
     and p_quantified_impact is not null then
    raise exception 'unsupported C02 evidence cannot store a quantified reconciliation impact'
      using errcode='check_violation';
  end if;

  select * into v_issue
  from public.review_issue
  where id=p_issue_id;

  if v_issue.id is null then
    raise exception 'review issue not found'
      using errcode='no_data_found';
  end if;

  select * into v_review
  from public.review
  where id=v_issue.review_id;

  if v_review.id is null
     or v_review.status<>'in_review'
     or v_issue.issue_status='removed'
     or not public.has_org_role(
       v_issue.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_issue.organisation_id,v_issue.outlet_id
     ) then
    raise exception 'review issue is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  select d.id into v_diagnosis_id
  from public.diagnosis d
  where d.review_issue_id=v_issue.id
  order by d.version_no desc
  limit 1;

  if v_diagnosis_id is null then
    raise exception 'record the diagnosis before adding C02 evidence'
      using errcode='check_violation';
  end if;

  v_driver_code := case p_test_type
    when 'yield' then 'food_yield'
    when 'portion' then 'food_portion'
    when 'production' then 'food_production'
    when 'waste' then 'food_waste'
    when 'transfer_nonrevenue' then 'food_transfer_nonrevenue'
  end;

  select id into v_driver_id
  from public.driver_taxonomy
  where code=v_driver_code and active;

  if v_driver_id is null then
    raise exception 'C02 driver taxonomy is not active'
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

  if coalesce(v_existing ? 'evidence_id',false) then
    return query select
      (v_existing->>'evidence_id')::uuid,
      (v_existing->>'c02_evidence_id')::uuid,
      (v_existing->>'reconciliation_impact')::numeric,
      true;
    return;
  end if;

  insert into public.driver_evidence(
    organisation_id,outlet_id,review_issue_id,diagnosis_id,
    driver_taxonomy_id,evidence_source_type,evidence_source_id,
    evidence_status,quantified_impact,coverage_key,product_group,
    note,approved_by,created_by
  )
  values(
    v_issue.organisation_id,v_issue.outlet_id,v_issue.id,v_diagnosis_id,
    v_driver_id,btrim(p_evidence_source_type),btrim(p_evidence_source_id),
    p_evidence_status,p_quantified_impact,btrim(p_coverage_key),
    btrim(p_product_group),nullif(btrim(p_note),''),
    case when p_evidence_status in ('supported','validated') then v_user_id else null end,
    v_user_id
  )
  returning id,reconciliation_impact into v_evidence_id,v_recon;

  insert into public.c02_test_evidence(
    organisation_id,outlet_id,review_id,review_issue_id,diagnosis_id,
    driver_evidence_id,test_type,product_group,coverage_key,evidence_status,
    ap_quantity,approved_yield,observed_usable_quantity,approved_usable_unit_cost,
    approved_portion,observed_avg_portion,representative_portions,
    produced_quantity,served_quantity,closing_usable_quantity,
    documented_nonrevenue_quantity,
    quantity,unit_cost,reason_code,already_in_approved_standard,
    movement_classification,source_refs,supersedes_c02_evidence_id,created_by
  )
  values(
    v_issue.organisation_id,v_issue.outlet_id,v_review.id,v_issue.id,v_diagnosis_id,
    v_evidence_id,p_test_type,btrim(p_product_group),btrim(p_coverage_key),
    p_evidence_status,
    nullif(p_inputs->>'ap_quantity','')::numeric,
    nullif(p_inputs->>'approved_yield','')::numeric,
    nullif(p_inputs->>'observed_usable_quantity','')::numeric,
    nullif(p_inputs->>'approved_usable_unit_cost','')::numeric,
    nullif(p_inputs->>'approved_portion','')::numeric,
    nullif(p_inputs->>'observed_avg_portion','')::numeric,
    nullif(p_inputs->>'representative_portions','')::numeric,
    nullif(p_inputs->>'produced_quantity','')::numeric,
    nullif(p_inputs->>'served_quantity','')::numeric,
    nullif(p_inputs->>'closing_usable_quantity','')::numeric,
    nullif(p_inputs->>'documented_nonrevenue_quantity','')::numeric,
    nullif(p_inputs->>'quantity','')::numeric,
    nullif(p_inputs->>'unit_cost','')::numeric,
    nullif(btrim(p_inputs->>'reason_code'),''),
    case
      when p_inputs ? 'already_in_approved_standard'
        then (p_inputs->>'already_in_approved_standard')::boolean
      else null
    end,
    nullif(btrim(p_inputs->>'movement_classification'),''),
    p_source_refs,
    p_supersedes_c02_evidence_id,
    v_user_id
  )
  returning id into v_c02_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_issue.organisation_id,v_issue.outlet_id,
    'C02_DRIVER_EVIDENCE_ADDED','c02_test_evidence',
    v_c02_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'evidence_id',v_evidence_id,
    'c02_evidence_id',v_c02_id,
    'reconciliation_impact',v_recon
  )
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_evidence_id,v_c02_id,v_recon,false;
end
$$;

revoke all on function add_c02_driver_evidence(
  uuid,text,text,text,text,text,text,numeric,jsonb,jsonb,uuid,text,text,text
) from public;
grant execute on function add_c02_driver_evidence(
  uuid,text,text,text,text,text,text,numeric,jsonb,jsonb,uuid,text,text,text
) to restaurant_app;
