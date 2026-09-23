-- 0021 · Review and FRAME foundation
-- Slice 4 begins the human review layer over immutable calculation snapshots.

create type review_status as enum (
  'draft',
  'in_review',
  'changes_requested',
  'signed',
  'released',
  'closed'
);

alter table restaurant_context
  add constraint restaurant_context_tenant_id_unique
  unique (organisation_id, outlet_id, id);

create table review (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  status review_status not null default 'draft',
  comparator_scenario scenario_code,
  context_version_id uuid,
  materiality_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(materiality_snapshot) = 'object'),
  active_calc_run_id uuid,
  review_leader_id uuid not null references neon_auth."user"(id),
  started_at timestamptz not null default now(),
  frame_confirmed_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, context_version_id)
    references restaurant_context(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, active_calc_run_id)
    references calc_run(organisation_id, outlet_id, id),

  unique (organisation_id, outlet_id, id),

  check (comparator_scenario is null or comparator_scenario <> 'actual'),
  check (
    (status = 'draft'
      and frame_confirmed_at is null
      and comparator_scenario is null
      and context_version_id is null
      and active_calc_run_id is null
      and materiality_snapshot = '{}'::jsonb)
    or
    (status <> 'draft'
      and frame_confirmed_at is not null
      and comparator_scenario is not null
      and context_version_id is not null
      and active_calc_run_id is not null
      and materiality_snapshot <> '{}'::jsonb)
  ),
  check (
    (status = 'closed' and closed_at is not null)
    or (status <> 'closed' and closed_at is null)
  )
);

create unique index review_one_active_per_outlet_period_idx
  on review(outlet_id, period_id)
  where status <> 'closed';

create index review_outlet_period_idx
  on review(outlet_id, period_id, created_at desc);

create index review_status_idx
  on review(status, updated_at desc);

alter table calc_run
  add column review_id uuid;

alter table calc_run
  add constraint calc_run_review_same_tenant_fk
  foreign key (organisation_id, outlet_id, review_id)
  references review(organisation_id, outlet_id, id);

create index calc_run_review_idx
  on calc_run(review_id, created_at desc)
  where review_id is not null;


-- A completed calculation snapshot remains immutable except for the one-time
-- review association explicitly deferred from 0018 until the review table existed.
create or replace function guard_calc_run_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'calculation runs are retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.status in ('completed','failed') then
    if old.status = 'completed'
       and old.review_id is null
       and new.review_id is not null
       and (
         to_jsonb(new) - 'review_id'
       ) = (
         to_jsonb(old) - 'review_id'
       )
       and exists (
         select 1
         from public.review rv
         where rv.id = new.review_id
           and rv.organisation_id = new.organisation_id
           and rv.outlet_id = new.outlet_id
           and rv.period_id = new.period_id
           and rv.active_calc_run_id = new.id
           and rv.frame_confirmed_at is not null
       ) then
      return new;
    end if;

    raise exception 'terminal calculation run is immutable'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'queued'
     and new.status = 'running'
     and new.started_at is not null
     and new.completed_at is null
     and (
       to_jsonb(new) - array['status','started_at']
     ) = (
       to_jsonb(old) - array['status','started_at']
     ) then
    return new;
  end if;

  if old.status = 'running'
     and new.status = 'completed'
     and new.completed_at is not null
     and new.result_hash is not null
     and (
       to_jsonb(new) - array['status','completed_at','result_hash']
     ) = (
       to_jsonb(old) - array['status','completed_at','result_hash']
     ) then
    return new;
  end if;

  if old.status = 'running'
     and new.status = 'failed'
     and new.completed_at is not null
     and new.error_message is not null
     and length(btrim(new.error_message)) > 0
     and (
       to_jsonb(new) - array['status','completed_at','error_code','error_message']
     ) = (
       to_jsonb(old) - array['status','completed_at','error_code','error_message']
     ) then
    return new;
  end if;

  raise exception 'invalid or mutating calculation-run transition % -> %',
    old.status, new.status
    using errcode = 'restrict_violation';
end
$$;


-- The FRAME transition is deliberately narrow: draft → in_review exactly once.
-- Later Slice 4 migrations may add controlled workflow status transitions without
-- allowing the frozen FRAME fields to be rewritten.
create or replace function guard_review_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'review history is retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'draft'
     and new.status = 'in_review'
     and old.frame_confirmed_at is null
     and new.frame_confirmed_at is not null
     and new.comparator_scenario is not null
     and new.context_version_id is not null
     and new.active_calc_run_id is not null
     and new.materiality_snapshot <> '{}'::jsonb
     and (
       to_jsonb(new) - array[
         'status',
         'comparator_scenario',
         'context_version_id',
         'materiality_snapshot',
         'active_calc_run_id',
         'frame_confirmed_at',
         'updated_at'
       ]
     ) = (
       to_jsonb(old) - array[
         'status',
         'comparator_scenario',
         'context_version_id',
         'materiality_snapshot',
         'active_calc_run_id',
         'frame_confirmed_at',
         'updated_at'
       ]
     ) then
    return new;
  end if;

  raise exception 'review may only be changed through an approved workflow transition'
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
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on review to restaurant_app;


create or replace function create_review(
  p_outlet_id uuid,
  p_period_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  created_review_id uuid,
  created_status review_status,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_review_id uuid;
  v_status public.review_status;
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

  select rp.organisation_id into v_org_id
  from public.reporting_period rp
  where rp.id = p_period_id
    and rp.outlet_id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(
       v_org_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_org_id,p_outlet_id) then
    raise exception 'review context is not available to this user'
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
        (v_existing->>'status')::public.review_status,
        true;
    return;
  end if;

  select rv.id,rv.status
    into v_review_id,v_status
  from public.review rv
  where rv.outlet_id=p_outlet_id
    and rv.period_id=p_period_id
    and rv.status <> 'closed'
  order by rv.created_at desc,rv.id desc
  limit 1
  for update;

  if v_review_id is null then
    insert into public.review(
      organisation_id,outlet_id,period_id,review_leader_id
    )
    values (
      v_org_id,p_outlet_id,p_period_id,v_user_id
    )
    returning id,status into v_review_id,v_status;

    insert into public.audit_log(
      actor_user_id,organisation_id,outlet_id,
      action_code,object_type,object_id,correlation_id
    )
    values (
      v_user_id,v_org_id,p_outlet_id,
      'REVIEW_CREATED','review',v_review_id::text,p_correlation_id
    );
  end if;

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'review_id',v_review_id,
    'status',v_status::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_review_id,v_status,false;
end
$$;


create or replace function frame_review(
  p_review_id uuid,
  p_context_version_id uuid,
  p_active_calc_run_id uuid,
  p_comparator_scenario scenario_code,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  framed_review_id uuid,
  framed_status review_status,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_period_start date;
  v_period_end date;
  v_materiality jsonb;
  v_existing jsonb;
  v_operation text := 'review.frame:' || p_review_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_comparator_scenario is null or p_comparator_scenario = 'actual' then
    raise exception 'FRAME requires budget, forecast or prior_year comparator'
      using errcode = 'invalid_parameter_value';
  end if;

  select rv.* into v_review
  from public.review rv
  where rv.id=p_review_id
  for update;

  if v_review.id is null
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_review.organisation_id,v_review.outlet_id) then
    raise exception 'review is not available to this user'
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
        (v_existing->>'status')::public.review_status,
        true;
    return;
  end if;

  if v_review.frame_confirmed_at is not null then
    if v_review.context_version_id = p_context_version_id
       and v_review.active_calc_run_id = p_active_calc_run_id
       and v_review.comparator_scenario = p_comparator_scenario then
      update public.request_idempotency
      set response_json=jsonb_build_object(
        'review_id',v_review.id,
        'status',v_review.status::text
      )
      where user_id=v_user_id
        and operation=v_operation
        and idempotency_key=p_idempotency_key;

      return query select v_review.id,v_review.status,true;
      return;
    end if;

    raise exception 'FRAME is already confirmed and cannot be rewritten'
      using errcode = 'restrict_violation';
  end if;

  if v_review.status <> 'draft' then
    raise exception 'only a draft review can be framed'
      using errcode = 'check_violation';
  end if;

  select rp.period_start,rp.period_end
    into v_period_start,v_period_end
  from public.reporting_period rp
  where rp.id=v_review.period_id
    and rp.organisation_id=v_review.organisation_id
    and rp.outlet_id=v_review.outlet_id;

  if not exists (
    select 1
    from public.restaurant_context rc
    where rc.id=p_context_version_id
      and rc.organisation_id=v_review.organisation_id
      and rc.outlet_id=v_review.outlet_id
      and rc.effective_from <= v_period_end
      and (rc.effective_to is null or rc.effective_to >= v_period_start)
  ) then
    raise exception 'context version is not valid for this review period'
      using errcode = 'check_violation';
  end if;

  select r.settings_snapshot->'materiality'
    into v_materiality
  from public.calc_run r
  where r.id=p_active_calc_run_id
    and r.organisation_id=v_review.organisation_id
    and r.outlet_id=v_review.outlet_id
    and r.period_id=v_review.period_id
    and r.status='completed'
    and r.result_hash is not null
    and r.comparator_scenario=p_comparator_scenario
    and exists (
      select 1
      from public.calc_result cr
      where cr.run_id=r.id
    );

  if v_materiality is null
     or jsonb_typeof(v_materiality) <> 'object'
     or not (v_materiality ? 'general') then
    raise exception 'selected calc run is not a completed FRAME-compatible snapshot'
      using errcode = 'check_violation';
  end if;

  update public.review
  set status='in_review',
      comparator_scenario=p_comparator_scenario,
      context_version_id=p_context_version_id,
      materiality_snapshot=v_materiality,
      active_calc_run_id=p_active_calc_run_id,
      frame_confirmed_at=now(),
      updated_at=now()
  where id=v_review.id;

  update public.calc_run
  set review_id=v_review.id
  where id=p_active_calc_run_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values (
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'REVIEW_FRAME_CONFIRMED','review',v_review.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'review_id',v_review.id,
    'status','in_review'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query
    select v_review.id,'in_review'::public.review_status,false;
end
$$;

revoke all on function create_review(uuid,uuid,text,text) from public;
revoke all on function frame_review(uuid,uuid,uuid,scenario_code,text,text) from public;

grant execute on function create_review(uuid,uuid,text,text)
  to restaurant_app;
grant execute on function frame_review(uuid,uuid,uuid,scenario_code,text,text)
  to restaurant_app;

-- Review identity and confirmed FRAME fields are historical evidence. Later
-- workflow migrations may add controlled status transitions but must not
-- rewrite the confirmed comparator/context/materiality snapshot.
