-- 0023 · Diagnosis and evidence foundation
-- SC12: separates supported facts, hypotheses and unknowns, and enforces the
-- G-28 evidence rule at the database boundary.

insert into driver_taxonomy(code,name,domain,active)
values
  ('volume','Volume','general',true),
  ('rate_price','Rate / price','general',true),
  ('mix','Mix','general',true),
  ('productivity_intensity','Productivity / intensity','general',true),
  ('timing_cutoff','Timing / cut-off','general',true),
  ('classification_mapping','Classification / mapping','general',true),
  ('one_off_structural','One-off / structural','general',true),
  ('food_price_spec','Food price / specification','food',true),
  ('food_yield','Food yield','food',true),
  ('food_portion','Food portion','food',true),
  ('food_production','Food production','food',true),
  ('food_waste','Food waste','food',true),
  ('food_transfer_nonrevenue','Food transfer / non-revenue use','food',true),
  ('food_inventory_data','Food inventory / data quality','food',true)
on conflict (code) do update
set name=excluded.name, domain=excluded.domain, active=true;

create table diagnosis (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_issue_id uuid not null,
  driver_class text not null check (driver_class in (
    'volume','rate_price','mix','productivity_intensity','timing_cutoff',
    'classification_mapping','one_off_structural','not_yet_supported'
  )),
  supported_summary text,
  hypothesis_summary text,
  unknowns text,
  evidence_status text not null check (evidence_status in (
    'validated','supported','partly_supported','evidence_required',
    'not_reconciled','not_applicable'
  )),
  diagnostic_status text not null check (diagnostic_status in (
    'in_progress','evidence_required','ready_for_decision'
  )),
  updated_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,review_issue_id)
    references review_issue(organisation_id,outlet_id,id),
  unique (review_issue_id),
  unique (organisation_id,outlet_id,review_issue_id,id),
  check (
    evidence_status not in ('supported','validated')
    or nullif(btrim(supported_summary),'') is not null
  )
);
create index diagnosis_issue_idx on diagnosis(review_issue_id);

create table driver_evidence (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_issue_id uuid not null,
  diagnosis_id uuid not null,
  driver_taxonomy_id uuid not null references driver_taxonomy(id),
  evidence_source_type text not null check (length(btrim(evidence_source_type)) > 0),
  evidence_source_id text not null check (length(btrim(evidence_source_id)) > 0),
  evidence_status text not null check (evidence_status in (
    'validated','supported','partly_supported','evidence_required',
    'not_reconciled','not_applicable'
  )),
  quantified_impact numeric(20,4),
  reconciliation_impact numeric(20,4) generated always as (
    case
      when evidence_status in ('supported','validated')
        then coalesce(quantified_impact,0::numeric)
      else 0::numeric
    end
  ) stored,
  note text,
  approved_by uuid references neon_auth."user"(id),
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,review_issue_id,diagnosis_id)
    references diagnosis(organisation_id,outlet_id,review_issue_id,id),
  unique (organisation_id,outlet_id,id),
  check (evidence_status <> 'evidence_required' or quantified_impact is null),
  check (evidence_status not in ('supported','validated') or approved_by is not null)
);
create index driver_evidence_issue_idx on driver_evidence(review_issue_id,created_at,id);
create index driver_evidence_diagnosis_idx on driver_evidence(diagnosis_id,created_at,id);

create table evidence_request (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_issue_id uuid not null,
  requested_dataset text not null check (length(btrim(requested_dataset)) > 0),
  reason text not null check (length(btrim(reason)) > 0),
  minimum_fields jsonb not null check (
    jsonb_typeof(minimum_fields)='array'
    and jsonb_array_length(minimum_fields) > 0
  ),
  requested_from text not null check (length(btrim(requested_from)) > 0),
  due_date date not null,
  status text not null default 'open'
    check (status in ('open','fulfilled','cancelled')),
  fulfilled_batch_id uuid,
  fulfilled_at timestamptz,
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,review_issue_id)
    references review_issue(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,fulfilled_batch_id)
    references import_batch(organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,id),
  check (
    (status='open' and fulfilled_batch_id is null and fulfilled_at is null)
    or (status='fulfilled' and fulfilled_batch_id is not null and fulfilled_at is not null)
    or (status='cancelled' and fulfilled_at is null)
  )
);
create index evidence_request_issue_idx
  on evidence_request(review_issue_id,status,due_date);

create trigger driver_evidence_immutable
  before update or delete on driver_evidence
  for each row execute function forbid_mutation();

alter table diagnosis enable row level security;
alter table driver_evidence enable row level security;
alter table evidence_request enable row level security;

create policy diagnosis_read on diagnosis
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy driver_evidence_read on driver_evidence
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy evidence_request_read on evidence_request
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on diagnosis,driver_evidence,evidence_request to restaurant_app;

create or replace function put_issue_diagnosis(
  p_issue_id uuid,
  p_driver_class text,
  p_evidence_status text,
  p_supported_summary text,
  p_hypothesis_summary text,
  p_unknowns text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (diagnosis_id uuid, diagnostic_status text, reused boolean)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_diagnosis_id uuid;
  v_status text;
  v_existing jsonb;
  v_operation text := 'issue.diagnosis.put:' || p_issue_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;
  if p_driver_class not in (
    'volume','rate_price','mix','productivity_intensity','timing_cutoff',
    'classification_mapping','one_off_structural','not_yet_supported'
  ) then
    raise exception 'unsupported driver class' using errcode='invalid_parameter_value';
  end if;
  if p_evidence_status not in (
    'validated','supported','partly_supported','evidence_required',
    'not_reconciled','not_applicable'
  ) then
    raise exception 'unsupported evidence status' using errcode='invalid_parameter_value';
  end if;
  if p_evidence_status in ('supported','validated')
     and nullif(btrim(p_supported_summary),'') is null then
    raise exception 'supported/validated diagnosis requires a supported summary'
      using errcode='check_violation';
  end if;
  if p_driver_class='not_yet_supported'
     and p_evidence_status in ('supported','validated') then
    raise exception 'not_yet_supported cannot be marked supported or validated'
      using errcode='check_violation';
  end if;

  select ri.* into v_issue
  from public.review_issue ri
  where ri.id=p_issue_id
  for update;
  if v_issue.id is null then
    raise exception 'review issue not found' using errcode='no_data_found';
  end if;

  select rv.* into v_review from public.review rv where rv.id=v_issue.review_id;
  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status='removed'
     or not public.has_org_role(v_issue.organisation_id,array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_issue.organisation_id,v_issue.outlet_id) then
    raise exception 'review issue is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;
  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key
  for update;
  if coalesce(v_existing ? 'diagnosis_id',false) then
    return query select
      (v_existing->>'diagnosis_id')::uuid,
      v_existing->>'diagnostic_status',
      true;
    return;
  end if;

  v_status := case
    when p_evidence_status in ('supported','validated') then 'ready_for_decision'
    when p_evidence_status='evidence_required' then 'evidence_required'
    else 'in_progress'
  end;

  insert into public.diagnosis(
    organisation_id,outlet_id,review_issue_id,driver_class,
    supported_summary,hypothesis_summary,unknowns,
    evidence_status,diagnostic_status,updated_by
  )
  values(
    v_issue.organisation_id,v_issue.outlet_id,v_issue.id,p_driver_class,
    nullif(btrim(p_supported_summary),''),
    nullif(btrim(p_hypothesis_summary),''),
    nullif(btrim(p_unknowns),''),
    p_evidence_status,v_status,v_user_id
  )
  on conflict(review_issue_id) do update
  set driver_class=excluded.driver_class,
      supported_summary=excluded.supported_summary,
      hypothesis_summary=excluded.hypothesis_summary,
      unknowns=excluded.unknowns,
      evidence_status=excluded.evidence_status,
      diagnostic_status=excluded.diagnostic_status,
      updated_by=excluded.updated_by,
      updated_at=now()
  returning id into v_diagnosis_id;

  update public.review_issue
  set evidence_status=p_evidence_status,updated_at=now()
  where id=v_issue.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  ) values(
    v_user_id,v_issue.organisation_id,v_issue.outlet_id,
    'ISSUE_DIAGNOSIS_SAVED','diagnosis',v_diagnosis_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'diagnosis_id',v_diagnosis_id,'diagnostic_status',v_status
  )
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key;

  return query select v_diagnosis_id,v_status,false;
end
$$;

create or replace function add_driver_evidence(
  p_issue_id uuid,
  p_driver_code text,
  p_evidence_source_type text,
  p_evidence_source_id text,
  p_evidence_status text,
  p_quantified_impact numeric,
  p_note text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (evidence_id uuid, reconciliation_impact numeric, reused boolean)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_diagnosis_id uuid;
  v_driver_id uuid;
  v_evidence_id uuid;
  v_recon numeric;
  v_existing jsonb;
  v_operation text := 'issue.driver_evidence.add:' || p_issue_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required' using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required' using errcode='invalid_parameter_value';
  end if;
  if p_evidence_status not in (
    'validated','supported','partly_supported','evidence_required',
    'not_reconciled','not_applicable'
  ) then
    raise exception 'unsupported evidence status' using errcode='invalid_parameter_value';
  end if;
  if p_evidence_status='evidence_required' and p_quantified_impact is not null then
    raise exception 'evidence_required cannot carry a quantified impact'
      using errcode='check_violation';
  end if;
  if nullif(btrim(p_evidence_source_type),'') is null
     or nullif(btrim(p_evidence_source_id),'') is null then
    raise exception 'evidence source type and id are required' using errcode='check_violation';
  end if;

  select ri.* into v_issue from public.review_issue ri where ri.id=p_issue_id;
  if v_issue.id is null then
    raise exception 'review issue not found' using errcode='no_data_found';
  end if;
  select rv.* into v_review from public.review rv where rv.id=v_issue.review_id;
  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status='removed'
     or not public.has_org_role(v_issue.organisation_id,array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_issue.organisation_id,v_issue.outlet_id) then
    raise exception 'review issue is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  select d.id into v_diagnosis_id from public.diagnosis d
  where d.review_issue_id=v_issue.id;
  if v_diagnosis_id is null then
    raise exception 'save the diagnosis before adding driver evidence'
      using errcode='check_violation';
  end if;
  select dt.id into v_driver_id from public.driver_taxonomy dt
  where dt.code=p_driver_code and dt.active;
  if v_driver_id is null then
    raise exception 'driver taxonomy code is not active' using errcode='check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;
  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key
  for update;
  if coalesce(v_existing ? 'evidence_id',false) then
    return query select
      (v_existing->>'evidence_id')::uuid,
      (v_existing->>'reconciliation_impact')::numeric,
      true;
    return;
  end if;

  insert into public.driver_evidence(
    organisation_id,outlet_id,review_issue_id,diagnosis_id,
    driver_taxonomy_id,evidence_source_type,evidence_source_id,
    evidence_status,quantified_impact,note,approved_by,created_by
  )
  values(
    v_issue.organisation_id,v_issue.outlet_id,v_issue.id,v_diagnosis_id,
    v_driver_id,btrim(p_evidence_source_type),btrim(p_evidence_source_id),
    p_evidence_status,p_quantified_impact,nullif(btrim(p_note),''),
    case when p_evidence_status in ('supported','validated') then v_user_id else null end,
    v_user_id
  )
  returning id,reconciliation_impact into v_evidence_id,v_recon;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  ) values(
    v_user_id,v_issue.organisation_id,v_issue.outlet_id,
    'DRIVER_EVIDENCE_ADDED','driver_evidence',v_evidence_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'evidence_id',v_evidence_id,'reconciliation_impact',v_recon
  )
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key;

  return query select v_evidence_id,v_recon,false;
end
$$;

create or replace function create_evidence_request(
  p_issue_id uuid,
  p_requested_dataset text,
  p_reason text,
  p_minimum_fields jsonb,
  p_requested_from text,
  p_due_date date,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (evidence_request_id uuid, reused boolean)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_request_id uuid;
  v_existing jsonb;
  v_operation text := 'issue.evidence_request.create:' || p_issue_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required' using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required' using errcode='invalid_parameter_value';
  end if;
  if nullif(btrim(p_requested_dataset),'') is null
     or nullif(btrim(p_reason),'') is null
     or nullif(btrim(p_requested_from),'') is null then
    raise exception 'dataset, reason and requested-from are required' using errcode='check_violation';
  end if;
  if jsonb_typeof(p_minimum_fields) <> 'array'
     or jsonb_array_length(p_minimum_fields)=0 then
    raise exception 'minimum_fields must be a non-empty JSON array' using errcode='check_violation';
  end if;

  select ri.* into v_issue from public.review_issue ri where ri.id=p_issue_id;
  if v_issue.id is null then
    raise exception 'review issue not found' using errcode='no_data_found';
  end if;
  select rv.* into v_review from public.review rv where rv.id=v_issue.review_id;
  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status='removed'
     or not public.has_org_role(v_issue.organisation_id,array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_issue.organisation_id,v_issue.outlet_id) then
    raise exception 'review issue is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;
  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key
  for update;
  if coalesce(v_existing ? 'evidence_request_id',false) then
    return query select (v_existing->>'evidence_request_id')::uuid,true;
    return;
  end if;

  insert into public.evidence_request(
    organisation_id,outlet_id,review_issue_id,
    requested_dataset,reason,minimum_fields,requested_from,due_date,created_by
  )
  values(
    v_issue.organisation_id,v_issue.outlet_id,v_issue.id,
    btrim(p_requested_dataset),btrim(p_reason),p_minimum_fields,
    btrim(p_requested_from),p_due_date,v_user_id
  )
  returning id into v_request_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  ) values(
    v_user_id,v_issue.organisation_id,v_issue.outlet_id,
    'EVIDENCE_REQUEST_CREATED','evidence_request',v_request_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('evidence_request_id',v_request_id)
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key;

  return query select v_request_id,false;
end
$$;

create or replace function fulfill_evidence_request(
  p_evidence_request_id uuid,
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (evidence_request_id uuid, reused boolean)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_request public.evidence_request%rowtype;
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_existing jsonb;
  v_operation text := 'evidence_request.fulfill:' || p_evidence_request_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required' using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required' using errcode='invalid_parameter_value';
  end if;

  select er.* into v_request
  from public.evidence_request er where er.id=p_evidence_request_id for update;
  if v_request.id is null then
    raise exception 'evidence request not found' using errcode='no_data_found';
  end if;
  select ri.* into v_issue from public.review_issue ri where ri.id=v_request.review_issue_id;
  select rv.* into v_review from public.review rv where rv.id=v_issue.review_id;

  if v_review.id is null
     or v_review.status <> 'in_review'
     or not public.has_org_role(v_request.organisation_id,array['admin','editor']::public.app_role[])
     or not public.has_outlet_access(v_request.organisation_id,v_request.outlet_id) then
    raise exception 'evidence request is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;
  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key
  for update;
  if coalesce(v_existing ? 'evidence_request_id',false) then
    return query select (v_existing->>'evidence_request_id')::uuid,true;
    return;
  end if;

  if v_request.status <> 'open' then
    raise exception 'only an open evidence request can be fulfilled'
      using errcode='check_violation';
  end if;

  if not exists(
    select 1 from public.import_batch b
    where b.id=p_batch_id
      and b.organisation_id=v_request.organisation_id
      and b.outlet_id=v_request.outlet_id
      and b.period_id=v_review.period_id
      and b.status='committed'
  ) then
    raise exception 'fulfilling batch must be committed in the review outlet and period'
      using errcode='check_violation';
  end if;

  update public.evidence_request
  set status='fulfilled',fulfilled_batch_id=p_batch_id,
      fulfilled_at=now(),updated_at=now()
  where id=v_request.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  ) values(
    v_user_id,v_request.organisation_id,v_request.outlet_id,
    'EVIDENCE_REQUEST_FULFILLED','evidence_request',v_request.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('evidence_request_id',v_request.id)
  where user_id=v_user_id and operation=v_operation and idempotency_key=p_idempotency_key;

  return query select v_request.id,false;
end
$$;

revoke all on function put_issue_diagnosis(uuid,text,text,text,text,text,text,text) from public;
revoke all on function add_driver_evidence(uuid,text,text,text,text,numeric,text,text,text) from public;
revoke all on function create_evidence_request(uuid,text,text,jsonb,text,date,text,text) from public;
revoke all on function fulfill_evidence_request(uuid,uuid,text,text) from public;

grant execute on function put_issue_diagnosis(uuid,text,text,text,text,text,text,text)
  to restaurant_app;
grant execute on function add_driver_evidence(uuid,text,text,text,text,numeric,text,text,text)
  to restaurant_app;
grant execute on function create_evidence_request(uuid,text,text,jsonb,text,date,text,text)
  to restaurant_app;
grant execute on function fulfill_evidence_request(uuid,uuid,text,text)
  to restaurant_app;

-- G-28 invariant:
-- evidence_required cannot store quantified_impact. Partly-supported or
-- unreconciled evidence may retain an observed amount, but its generated
-- reconciliation_impact remains zero. Only supported/validated evidence can
-- contribute quantitatively.
