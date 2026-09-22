-- 0021 · Slice 4 review + FRAME foundation
-- A review is the human decision layer above one immutable calculation snapshot.
-- FRAME freezes the comparator, context version and the materiality settings that
-- produced the pinned calculation run. Customer sessions receive controlled
-- functions for mutation and SELECT-only table access.

create type review_status as enum (
  'draft',
  'in_review',
  'changes_requested',
  'signed',
  'released',
  'closed'
);

alter table restaurant_context
  add constraint restaurant_context_tenant_outlet_id_unique
  unique (organisation_id, outlet_id, id);

create table review (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  status review_status not null default 'draft',
  comparator_scenario scenario_code not null,
  context_version_id uuid not null,
  materiality_snapshot jsonb not null
    check (jsonb_typeof(materiality_snapshot) = 'object'),
  active_calc_run_id uuid not null,
  review_leader_id uuid not null references neon_auth."user"(id),

  close_status_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(close_status_snapshot) = 'object'),
  comparator_rationale text,
  definition_continuity_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(definition_continuity_snapshot) = 'object'),
  decision_impact_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(decision_impact_snapshot) = 'object'),

  frame_confirmed_by uuid references neon_auth."user"(id),
  frame_confirmed_at timestamptz,
  started_at timestamptz not null default now(),
  closed_at timestamptz,
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, context_version_id)
    references restaurant_context(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, active_calc_run_id)
    references calc_run(organisation_id, outlet_id, id),

  unique (organisation_id, outlet_id, id),

  check (comparator_scenario <> 'actual'),
  check (
    (status = 'draft' and frame_confirmed_by is null and frame_confirmed_at is null)
    or
    (status <> 'draft' and frame_confirmed_by is not null and frame_confirmed_at is not null)
  ),
  check (
    (status in ('released','closed') and closed_at is not null)
    or
    (status not in ('released','closed') and closed_at is null)
  )
);

create unique index review_one_active_per_outlet_period_idx
  on review(outlet_id, period_id)
  where status not in ('released','closed');

create index review_outlet_period_history_idx
  on review(outlet_id, period_id, created_at desc);

create index review_calc_run_idx
  on review(active_calc_run_id);

-- The architecture allows future review-triggered recalculations to identify the
-- review when the calc run is created. Existing completed runs are never mutated
-- merely to establish the reverse link; review.active_calc_run_id is the pin.
alter table calc_run
  add column review_id uuid;

alter table calc_run
  add constraint calc_run_review_same_tenant_fk
  foreign key (organisation_id, outlet_id, review_id)
  references review(organisation_id, outlet_id, id);

create index calc_run_review_idx
  on calc_run(review_id)
  where review_id is not null;


create or replace function validate_review_snapshot()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_period public.reporting_period%rowtype;
  v_context public.restaurant_context%rowtype;
begin
  select * into v_run
  from public.calc_run r
  where r.id = new.active_calc_run_id;

  if v_run.id is null
     or v_run.organisation_id <> new.organisation_id
     or v_run.outlet_id <> new.outlet_id
     or v_run.period_id <> new.period_id
     or v_run.status <> 'completed'
     or v_run.comparator_scenario is null
     or v_run.comparator_scenario <> new.comparator_scenario then
    raise exception 'review must pin a completed calc run in the same outlet/period and comparator'
      using errcode = 'check_violation';
  end if;

  if new.materiality_snapshot is distinct from
     coalesce(v_run.settings_snapshot->'materiality','{}'::jsonb) then
    raise exception 'review materiality snapshot must equal the pinned calc-run snapshot'
      using errcode = 'check_violation';
  end if;

  select * into v_period
  from public.reporting_period rp
  where rp.id = new.period_id
    and rp.organisation_id = new.organisation_id
    and rp.outlet_id = new.outlet_id;

  select * into v_context
  from public.restaurant_context rc
  where rc.id = new.context_version_id
    and rc.organisation_id = new.organisation_id
    and rc.outlet_id = new.outlet_id;

  if v_period.id is null
     or v_context.id is null
     or v_context.effective_from > v_period.period_end
     or (
       v_context.effective_to is not null
       and v_context.effective_to < v_period.period_start
     ) then
    raise exception 'review context version is not effective for the reporting period'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger review_snapshot_guard
  before insert on review
  for each row execute function validate_review_snapshot();


create or replace function guard_review_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'review history is retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  -- Slice 4.1 permits exactly one mutation: confirmation of a draft FRAME.
  -- Later review-loop migrations may extend this function with tightly-scoped
  -- workflow transitions; pinned snapshot fields remain immutable.
  if old.status = 'draft'
     and new.status = 'in_review'
     and old.frame_confirmed_at is null
     and new.frame_confirmed_at is not null
     and new.frame_confirmed_by is not null
     and new.comparator_rationale is not null
     and length(btrim(new.comparator_rationale)) > 0
     and (
       to_jsonb(new) - array[
         'status',
         'close_status_snapshot',
         'comparator_rationale',
         'definition_continuity_snapshot',
         'decision_impact_snapshot',
         'frame_confirmed_by',
         'frame_confirmed_at'
       ]
     ) = (
       to_jsonb(old) - array[
         'status',
         'close_status_snapshot',
         'comparator_rationale',
         'definition_continuity_snapshot',
         'decision_impact_snapshot',
         'frame_confirmed_by',
         'frame_confirmed_at'
       ]
     ) then
    return new;
  end if;

  raise exception 'review snapshot is immutable outside controlled workflow transitions'
    using errcode = 'restrict_violation';
end
$$;

create trigger review_mutation_guard
  before update or delete on review
  for each row execute function guard_review_mutation();


alter table review enable row level security;

create policy review_read on review
  for select to restaurant_app
  using (
    has_org_access(organisation_id)
    and has_outlet_access(organisation_id,outlet_id)
  );

grant select on review to restaurant_app;


create or replace function create_review(
  p_outlet_id uuid,
  p_period_id uuid,
  p_calc_run_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  review_id uuid,
  review_status public.review_status,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_run public.calc_run%rowtype;
  v_period public.reporting_period%rowtype;
  v_context_id uuid;
  v_materiality jsonb;
  v_review_id uuid;
  v_existing jsonb;
  v_operation text := 'review.create:' || p_outlet_id::text || ':' || p_period_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(
       v_org_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_org_id,p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values (v_user_id,v_operation,p_idempotency_key)
  on conflict (user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'review_id',false) then
    return query
      select
        (v_existing->>'review_id')::uuid,
        (v_existing->>'review_status')::public.review_status,
        true;
    return;
  end if;

  select * into v_period
  from public.reporting_period rp
  where rp.id=p_period_id
    and rp.organisation_id=v_org_id
    and rp.outlet_id=p_outlet_id;

  if v_period.id is null then
    raise exception 'reporting period is not available in this outlet'
      using errcode = 'check_violation';
  end if;

  select * into v_run
  from public.calc_run r
  where r.id=p_calc_run_id
    and r.organisation_id=v_org_id
    and r.outlet_id=p_outlet_id
    and r.period_id=p_period_id
    and r.status='completed';

  if v_run.id is null or v_run.comparator_scenario is null then
    raise exception 'review requires a completed calculation run with a comparator'
      using errcode = 'check_violation';
  end if;

  select rc.id into v_context_id
  from public.restaurant_context rc
  where rc.organisation_id=v_org_id
    and rc.outlet_id=p_outlet_id
    and rc.effective_from <= v_period.period_end
    and (rc.effective_to is null or rc.effective_to >= v_period.period_start)
  order by rc.effective_from desc,rc.version_no desc,rc.created_at desc,rc.id desc
  limit 1;

  if v_context_id is null then
    raise exception 'review requires a restaurant context version effective for the period'
      using errcode = 'check_violation';
  end if;

  v_materiality := coalesce(v_run.settings_snapshot->'materiality','{}'::jsonb);

  if jsonb_typeof(v_materiality) <> 'object'
     or jsonb_typeof(v_materiality->'general') <> 'object'
     or nullif(v_materiality->'general'->>'approved_at','') is null
     or (
       v_materiality->'general'->'absolute_threshold' is null
       and v_materiality->'general'->'percent_threshold' is null
     ) then
    raise exception 'formal review requires confirmed general materiality in the pinned calc run'
      using errcode = 'check_violation';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_outlet_id::text || ':' || p_period_id::text,
      2101
    )
  );

  insert into public.review(
    organisation_id,outlet_id,period_id,status,
    comparator_scenario,context_version_id,materiality_snapshot,
    active_calc_run_id,review_leader_id
  )
  values (
    v_org_id,p_outlet_id,p_period_id,'draft',
    v_run.comparator_scenario,v_context_id,v_materiality,
    v_run.id,v_user_id
  )
  returning id into v_review_id;

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'review_id',v_review_id,
    'review_status','draft'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,after_hash,correlation_id
  )
  values (
    v_user_id,v_org_id,p_outlet_id,
    'REVIEW_CREATED','review',v_review_id::text,
    v_run.result_hash,p_correlation_id
  );

  return query
    select v_review_id,'draft'::public.review_status,false;
end
$$;

revoke all on function create_review(uuid,uuid,uuid,text,text) from public;
grant execute on function create_review(uuid,uuid,uuid,text,text)
  to restaurant_app;


create or replace function confirm_review_frame(
  p_review_id uuid,
  p_close_status jsonb,
  p_comparator_rationale text,
  p_definition_continuity jsonb,
  p_decision_impact jsonb,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  review_id uuid,
  review_status public.review_status,
  frame_confirmed_at timestamptz,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_existing jsonb;
  v_operation text := 'review.frame.confirm:' || p_review_id::text;
  v_confirmed_at timestamptz;
  v_key text;
  v_value text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  select * into v_review
  from public.review r
  where r.id=p_review_id
  for update;

  if v_review.id is null
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_review.organisation_id,
       v_review.outlet_id
     ) then
    raise exception 'review is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values (v_user_id,v_operation,p_idempotency_key)
  on conflict (user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'review_id',false) then
    return query
      select
        (v_existing->>'review_id')::uuid,
        (v_existing->>'review_status')::public.review_status,
        (v_existing->>'frame_confirmed_at')::timestamptz,
        true;
    return;
  end if;

  if v_review.status <> 'draft' then
    raise exception 'only a draft review can confirm FRAME'
      using errcode = 'check_violation';
  end if;

  if jsonb_typeof(p_close_status) <> 'object'
     or not p_close_status ?& array[
       'accounts_closed',
       'material_invoices_in',
       'inventory_count_complete',
       'cutoff_checked'
     ] then
    raise exception 'FRAME close status requires all four close checks'
      using errcode = 'check_violation';
  end if;

  for v_key,v_value in
    select key,value
    from jsonb_each_text(p_close_status)
    where key in (
      'accounts_closed',
      'material_invoices_in',
      'inventory_count_complete',
      'cutoff_checked'
    )
  loop
    if v_value not in ('yes','no','na') then
      raise exception 'FRAME close check % must be yes, no or na',v_key
        using errcode = 'check_violation';
    end if;
  end loop;

  if nullif(btrim(p_comparator_rationale),'') is null then
    raise exception 'FRAME requires a comparator rationale'
      using errcode = 'check_violation';
  end if;

  if jsonb_typeof(p_definition_continuity) <> 'object'
     or not p_definition_continuity ?& array[
       'meal_period_definitions',
       'unit_definitions',
       'cost_classification',
       'comparator_basis',
       'operating_days'
     ] then
    raise exception 'FRAME definition continuity requires all five checks'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1
    from unnest(array[
      'meal_period_definitions',
      'unit_definitions',
      'cost_classification',
      'comparator_basis',
      'operating_days'
    ]) as k(key)
    where jsonb_typeof(p_definition_continuity->k.key) <> 'object'
       or coalesce(p_definition_continuity->k.key->>'status','') not in ('same','changed')
       or coalesce(p_definition_continuity->k.key->>'reviewed','false') <> 'true'
  ) then
    raise exception 'every FRAME definition check needs status same/changed and reviewed=true'
      using errcode = 'check_violation';
  end if;

  if jsonb_typeof(p_decision_impact) <> 'object'
     or not p_decision_impact ?& array[
       'safety',
       'control',
       'legal_compliance',
       'guest_impact',
       'recurrence'
     ] then
    raise exception 'FRAME decision-impact snapshot requires all five trigger flags'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1
    from unnest(array[
      'safety',
      'control',
      'legal_compliance',
      'guest_impact',
      'recurrence'
    ]) as k(key)
    where jsonb_typeof(p_decision_impact->k.key) <> 'boolean'
  ) then
    raise exception 'FRAME decision-impact trigger values must be booleans'
      using errcode = 'check_violation';
  end if;

  v_confirmed_at := now();

  update public.review
  set status='in_review',
      close_status_snapshot=p_close_status,
      comparator_rationale=btrim(p_comparator_rationale),
      definition_continuity_snapshot=p_definition_continuity,
      decision_impact_snapshot=p_decision_impact,
      frame_confirmed_by=v_user_id,
      frame_confirmed_at=v_confirmed_at
  where id=p_review_id;

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'review_id',p_review_id,
    'review_status','in_review',
    'frame_confirmed_at',v_confirmed_at
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values (
    v_user_id,
    v_review.organisation_id,
    v_review.outlet_id,
    'REVIEW_FRAME_CONFIRMED',
    'review',
    p_review_id::text,
    p_correlation_id
  );

  return query
    select
      p_review_id,
      'in_review'::public.review_status,
      v_confirmed_at,
      false;
end
$$;

revoke all on function confirm_review_frame(
  uuid,jsonb,text,jsonb,jsonb,text,text
) from public;

grant execute on function confirm_review_frame(
  uuid,jsonb,text,jsonb,jsonb,text,text
) to restaurant_app;

-- Review snapshots are forward-only. Later Slice 4 migrations may add controlled
-- workflow transitions but must not rewrite comparator/context/materiality/run pins.
