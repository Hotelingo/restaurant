-- 0025 · Action register and append-only action history
-- Slice 4 / SC13, first small chunk. Actions pin a specific immutable decision
-- revision. The action definition is immutable; only current status/tag/closure
-- evidence may change through the controlled workflow, with every transition
-- appended to action_event.

create type action_status as enum (
  'OPEN_ON_TRACK',
  'CLOSED',
  'OVERDUE_NOT_COMPLETED',
  'REPEATED_ISSUE',
  'REOPENED'
);

create table action (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  review_issue_id uuid not null,
  decision_id uuid not null,

  owner text not null check (length(btrim(owner)) > 0),
  owner_user_id uuid references neon_auth."user"(id),

  lever text,
  guardrail text,
  metric text,
  target_trigger text,
  due_date date,
  cadence text,
  forecast_effect text,

  status action_status not null default 'OPEN_ON_TRACK',
  status_tag text check (
    status_tag is null
    or status_tag in ('waiting_on_owner','follow_up_monitor')
  ),
  closure_evidence text,

  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),

  foreign key (organisation_id,outlet_id,review_issue_id)
    references review_issue(organisation_id,outlet_id,id),

  foreign key (
    organisation_id,outlet_id,review_issue_id,decision_id
  )
    references decision(
      organisation_id,outlet_id,review_issue_id,id
    ),

  unique (organisation_id,outlet_id,id),
  unique (decision_id),

  check (
    status <> 'CLOSED'
    or nullif(btrim(closure_evidence),'') is not null
  )
);

create index action_review_status_idx
  on action(review_id,status,created_at,id);
create index action_issue_idx
  on action(review_issue_id,created_at,id);


create table action_event (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  action_id uuid not null,
  event_type text not null
    check (event_type in ('status_change','comment','verification')),
  from_status action_status,
  to_status action_status,
  status_tag text check (
    status_tag is null
    or status_tag in ('waiting_on_owner','follow_up_monitor')
  ),
  note text,
  evidence text,
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,action_id)
    references action(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),

  check (
    event_type <> 'status_change'
    or to_status is not null
  )
);

create index action_event_action_time_idx
  on action_event(action_id,created_at,id);


-- Action content is the historical record of what was agreed. Only the current
-- status/tag/closure evidence may move; every such change is written by the
-- controlled workflow and mirrored to action_event.
create or replace function guard_action_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op='DELETE' then
    raise exception 'action history is retained; delete is not permitted'
      using errcode='restrict_violation';
  end if;

  if (
    to_jsonb(new) - array[
      'status','status_tag','closure_evidence','updated_at'
    ]
  ) <> (
    to_jsonb(old) - array[
      'status','status_tag','closure_evidence','updated_at'
    ]
  ) then
    raise exception 'action definition is immutable; only status workflow may change'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;

create trigger action_mutation_guard
  before update or delete on action
  for each row execute function guard_action_mutation();

create trigger action_event_immutable
  before update or delete on action_event
  for each row execute function forbid_mutation();


alter table action enable row level security;
alter table action_event enable row level security;

create policy action_read on action
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy action_event_read on action_event
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on action,action_event to restaurant_app;


create or replace function create_action_from_decision(
  p_decision_id uuid,
  p_owner text,
  p_owner_user_id uuid,
  p_forecast_effect text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  action_id uuid,
  action_status action_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_decision public.decision%rowtype;
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_owner text;
  v_action_id uuid;
  v_status public.action_status;
  v_existing jsonb;
  v_operation text := 'action.create:' || p_decision_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select d.* into v_decision
  from public.decision d
  where d.id=p_decision_id;

  if v_decision.id is null then
    raise exception 'decision not found'
      using errcode='no_data_found';
  end if;

  select ri.* into v_issue
  from public.review_issue ri
  where ri.id=v_decision.review_issue_id
  for update;

  select rv.* into v_review
  from public.review rv
  where rv.id=v_issue.review_id;

  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status='removed'
     or v_issue.active_decision_id is distinct from v_decision.id
     or not public.has_org_role(
       v_decision.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_decision.organisation_id,
       v_decision.outlet_id
     ) then
    raise exception 'active decision is not actionable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if p_owner_user_id is not null
     and not exists (
       select 1
       from public.membership m
       where m.organisation_id=v_decision.organisation_id
         and m.user_id=p_owner_user_id
         and m.status='active'
     ) then
    raise exception 'owner_user_id must be an active member of the organisation'
      using errcode='check_violation';
  end if;

  v_owner := coalesce(
    nullif(btrim(p_owner),''),
    nullif(btrim(v_decision.owner),'')
  );

  if v_owner is null then
    raise exception 'action register requires an accountable owner'
      using errcode='check_violation';
  end if;

  insert into public.request_idempotency(
    user_id,operation,idempotency_key
  )
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'action_id',false) then
    return query select
      (v_existing->>'action_id')::uuid,
      (v_existing->>'status')::public.action_status,
      true;
    return;
  end if;

  select a.id,a.status into v_action_id,v_status
  from public.action a
  where a.decision_id=v_decision.id;

  if v_action_id is null then
    insert into public.action(
      organisation_id,outlet_id,review_id,review_issue_id,decision_id,
      owner,owner_user_id,
      lever,guardrail,metric,target_trigger,due_date,cadence,
      forecast_effect,created_by
    )
    values(
      v_decision.organisation_id,
      v_decision.outlet_id,
      v_review.id,
      v_issue.id,
      v_decision.id,
      v_owner,
      p_owner_user_id,
      v_decision.lever,
      v_decision.guardrail,
      v_decision.verification_metric,
      v_decision.target_trigger,
      v_decision.due_date,
      v_decision.cadence,
      nullif(btrim(p_forecast_effect),''),
      v_user_id
    )
    returning id,status into v_action_id,v_status;

    insert into public.audit_log(
      actor_user_id,organisation_id,outlet_id,
      action_code,object_type,object_id,correlation_id
    )
    values(
      v_user_id,
      v_decision.organisation_id,
      v_decision.outlet_id,
      'ACTION_CREATED',
      'action',
      v_action_id::text,
      p_correlation_id
    );
  end if;

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'action_id',v_action_id,
    'status',v_status::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_action_id,v_status,false;
end
$$;


create or replace function transition_action_status(
  p_action_id uuid,
  p_status text,
  p_status_tag text,
  p_closure_evidence text,
  p_note text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  action_id uuid,
  action_status action_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_action public.action%rowtype;
  v_new_status public.action_status;
  v_new_tag text;
  v_closure text;
  v_existing jsonb;
  v_operation text := 'action.status:' || p_action_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if p_status not in (
    'OPEN_ON_TRACK','CLOSED','OVERDUE_NOT_COMPLETED',
    'REPEATED_ISSUE','REOPENED'
  ) then
    raise exception 'unsupported action status'
      using errcode='invalid_parameter_value';
  end if;

  if p_status_tag is not null
     and p_status_tag not in ('waiting_on_owner','follow_up_monitor') then
    raise exception 'unsupported action status tag'
      using errcode='invalid_parameter_value';
  end if;

  v_new_status := p_status::public.action_status;
  v_new_tag := p_status_tag;

  select a.* into v_action
  from public.action a
  where a.id=p_action_id
  for update;

  if v_action.id is null
     or not public.has_org_role(
       v_action.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_action.organisation_id,
       v_action.outlet_id
     ) then
    raise exception 'action is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if v_new_status='CLOSED' then
    v_closure := nullif(btrim(p_closure_evidence),'');
    if v_closure is null then
      raise exception 'closing an action requires closure evidence'
        using errcode='check_violation';
    end if;
  else
    v_closure := v_action.closure_evidence;
  end if;

  insert into public.request_idempotency(
    user_id,operation,idempotency_key
  )
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'action_id',false) then
    return query select
      (v_existing->>'action_id')::uuid,
      (v_existing->>'status')::public.action_status,
      true;
    return;
  end if;

  if v_action.status=v_new_status
     and v_action.status_tag is not distinct from v_new_tag
     and (
       v_new_status <> 'CLOSED'
       or v_action.closure_evidence is not distinct from v_closure
     ) then
    update public.request_idempotency
    set response_json=jsonb_build_object(
      'action_id',v_action.id,
      'status',v_action.status::text
    )
    where user_id=v_user_id
      and operation=v_operation
      and idempotency_key=p_idempotency_key;

    return query select v_action.id,v_action.status,true;
    return;
  end if;

  update public.action
  set status=v_new_status,
      status_tag=v_new_tag,
      closure_evidence=v_closure,
      updated_at=now()
  where id=v_action.id;

  insert into public.action_event(
    organisation_id,outlet_id,action_id,event_type,
    from_status,to_status,status_tag,note,evidence,created_by
  )
  values(
    v_action.organisation_id,
    v_action.outlet_id,
    v_action.id,
    'status_change',
    v_action.status,
    v_new_status,
    v_new_tag,
    nullif(btrim(p_note),''),
    case when v_new_status='CLOSED' then v_closure else null end,
    v_user_id
  );

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,
    v_action.organisation_id,
    v_action.outlet_id,
    'ACTION_STATUS_CHANGED',
    'action',
    v_action.id::text,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'action_id',v_action.id,
    'status',v_new_status::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_action.id,v_new_status,false;
end
$$;


revoke all on function create_action_from_decision(
  uuid,text,uuid,text,text,text
) from public;
revoke all on function transition_action_status(
  uuid,text,text,text,text,text,text
) from public;

grant execute on function create_action_from_decision(
  uuid,text,uuid,text,text,text
) to restaurant_app;
grant execute on function transition_action_status(
  uuid,text,text,text,text,text,text
) to restaurant_app;

-- Prior-period verification is deliberately the next S4-5 chunk. This
-- migration establishes the action register and append-only status history it
-- will reference.
