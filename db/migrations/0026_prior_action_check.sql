-- 0026 · Prior-action verification and next-period follow-up
-- Completes S4-5 / SC13: start a new close by checking the previous period's
-- actions before protecting a prior explanation with the new numbers.
--
-- The immutable check records the three review questions carried by the
-- product contract: completed? driver moved? result responded? A controlled
-- outcome may continue, close, or reopen the action. Every verification is
-- also appended to action_event.

create type verification_answer as enum (
  'YES',
  'NO',
  'UNKNOWN'
);

create type verification_outcome as enum (
  'CONTINUE',
  'CLOSE',
  'REOPEN'
);


create table prior_action_check (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  action_id uuid not null,
  verification_period_id uuid not null,

  completed_answer verification_answer not null,
  completion_evidence text,

  driver_moved_answer verification_answer not null,
  driver_evidence text,

  result_responded_answer verification_answer not null,
  result_evidence text,

  outcome verification_outcome not null,
  action_status_before action_status not null,
  action_status_after action_status not null,
  status_tag text check (
    status_tag is null
    or status_tag in ('waiting_on_owner','follow_up_monitor')
  ),

  closure_evidence text,
  reopen_reason text,
  note text,

  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,action_id)
    references action(organisation_id,outlet_id,id),

  foreign key (organisation_id,outlet_id,verification_period_id)
    references reporting_period(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (action_id,verification_period_id),

  check (
    completed_answer='UNKNOWN'
    or nullif(btrim(completion_evidence),'') is not null
  ),
  check (
    driver_moved_answer='UNKNOWN'
    or nullif(btrim(driver_evidence),'') is not null
  ),
  check (
    result_responded_answer='UNKNOWN'
    or nullif(btrim(result_evidence),'') is not null
  ),
  check (
    coalesce(
      nullif(btrim(completion_evidence),''),
      nullif(btrim(driver_evidence),''),
      nullif(btrim(result_evidence),''),
      nullif(btrim(note),'')
    ) is not null
  ),
  check (
    (
      outcome='CLOSE'
      and action_status_after='CLOSED'
      and nullif(btrim(closure_evidence),'') is not null
      and reopen_reason is null
    )
    or
    (
      outcome='REOPEN'
      and action_status_after='REOPENED'
      and nullif(btrim(reopen_reason),'') is not null
      and closure_evidence is null
    )
    or
    (
      outcome='CONTINUE'
      and action_status_after=action_status_before
      and closure_evidence is null
      and reopen_reason is null
    )
  ),
  check (
    status_tag <> 'follow_up_monitor'
    or outcome='CLOSE'
  ),
  check (
    status_tag <> 'waiting_on_owner'
    or outcome='CONTINUE'
  )
);

create index prior_action_check_period_idx
  on prior_action_check(
    outlet_id,verification_period_id,created_at,id
  );

create index prior_action_check_action_idx
  on prior_action_check(action_id,created_at,id);


create trigger prior_action_check_immutable
  before update or delete on prior_action_check
  for each row execute function forbid_mutation();


alter table prior_action_check enable row level security;

create policy prior_action_check_read on prior_action_check
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on prior_action_check to restaurant_app;


create or replace function record_prior_action_check(
  p_action_id uuid,
  p_verification_period_id uuid,
  p_completed_answer text,
  p_completion_evidence text,
  p_driver_moved_answer text,
  p_driver_evidence text,
  p_result_responded_answer text,
  p_result_evidence text,
  p_outcome text,
  p_status_tag text,
  p_closure_evidence text,
  p_reopen_reason text,
  p_note text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  prior_action_check_id uuid,
  resulting_action_status action_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_action public.action%rowtype;
  v_source_period public.reporting_period%rowtype;
  v_verification_period public.reporting_period%rowtype;

  v_completed public.verification_answer;
  v_driver public.verification_answer;
  v_result public.verification_answer;
  v_outcome public.verification_outcome;

  v_completion_evidence text := nullif(btrim(p_completion_evidence),'');
  v_driver_evidence text := nullif(btrim(p_driver_evidence),'');
  v_result_evidence text := nullif(btrim(p_result_evidence),'');
  v_closure_evidence text := nullif(btrim(p_closure_evidence),'');
  v_reopen_reason text := nullif(btrim(p_reopen_reason),'');
  v_note text := nullif(btrim(p_note),'');
  v_status_tag text := nullif(btrim(p_status_tag),'');

  v_status_before public.action_status;
  v_status_after public.action_status;
  v_check_id uuid;

  v_existing jsonb;
  v_operation text := 'action.verify:' || p_action_id::text || ':' ||
                      p_verification_period_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if p_completed_answer not in ('YES','NO','UNKNOWN')
     or p_driver_moved_answer not in ('YES','NO','UNKNOWN')
     or p_result_responded_answer not in ('YES','NO','UNKNOWN') then
    raise exception 'verification answers must be YES, NO or UNKNOWN'
      using errcode='invalid_parameter_value';
  end if;

  if p_outcome not in ('CONTINUE','CLOSE','REOPEN') then
    raise exception 'verification outcome must be CONTINUE, CLOSE or REOPEN'
      using errcode='invalid_parameter_value';
  end if;

  if v_status_tag is not null
     and v_status_tag not in ('waiting_on_owner','follow_up_monitor') then
    raise exception 'unsupported action status tag'
      using errcode='invalid_parameter_value';
  end if;

  v_completed := p_completed_answer::public.verification_answer;
  v_driver := p_driver_moved_answer::public.verification_answer;
  v_result := p_result_responded_answer::public.verification_answer;
  v_outcome := p_outcome::public.verification_outcome;

  if v_completed <> 'UNKNOWN' and v_completion_evidence is null then
    raise exception 'completed YES/NO requires completion evidence'
      using errcode='check_violation';
  end if;

  if v_driver <> 'UNKNOWN' and v_driver_evidence is null then
    raise exception 'driver moved YES/NO requires driver evidence'
      using errcode='check_violation';
  end if;

  if v_result <> 'UNKNOWN' and v_result_evidence is null then
    raise exception 'result responded YES/NO requires result evidence'
      using errcode='check_violation';
  end if;

  if coalesce(
       v_completion_evidence,
       v_driver_evidence,
       v_result_evidence,
       v_note
     ) is null then
    raise exception 'prior-action verification requires evidence or a note'
      using errcode='check_violation';
  end if;

  if v_outcome='CLOSE' and v_closure_evidence is null then
    raise exception 'CLOSE verification outcome requires closure evidence'
      using errcode='check_violation';
  end if;

  if v_outcome='REOPEN' and v_reopen_reason is null then
    raise exception 'REOPEN verification outcome requires a reopen reason'
      using errcode='check_violation';
  end if;

  if v_outcome='CONTINUE'
     and (v_closure_evidence is not null or v_reopen_reason is not null) then
    raise exception 'CONTINUE cannot carry closure evidence or a reopen reason'
      using errcode='check_violation';
  end if;

  if v_outcome='CLOSE' and v_reopen_reason is not null then
    raise exception 'CLOSE cannot carry a reopen reason'
      using errcode='check_violation';
  end if;

  if v_outcome='REOPEN' and v_closure_evidence is not null then
    raise exception 'REOPEN cannot carry new closure evidence'
      using errcode='check_violation';
  end if;

  if v_status_tag='follow_up_monitor' and v_outcome <> 'CLOSE' then
    raise exception 'follow_up_monitor is only valid with a CLOSE verification outcome'
      using errcode='check_violation';
  end if;

  if v_status_tag='waiting_on_owner' and v_outcome <> 'CONTINUE' then
    raise exception 'waiting_on_owner is only valid with a CONTINUE verification outcome'
      using errcode='check_violation';
  end if;

  insert into public.request_idempotency(
    user_id,operation,idempotency_key
  )
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id=v_user_id
    and r.operation=v_operation
    and r.idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'prior_action_check_id',false) then
    return query select
      (v_existing->>'prior_action_check_id')::uuid,
      (v_existing->>'action_status')::public.action_status,
      true;
    return;
  end if;

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
    raise exception 'action is not available in the current context'
      using errcode='insufficient_privilege';
  end if;

  select rp.* into v_source_period
  from public.review rv
  join public.reporting_period rp
    on rp.organisation_id=rv.organisation_id
   and rp.outlet_id=rv.outlet_id
   and rp.id=rv.period_id
  where rv.id=v_action.review_id
    and rv.organisation_id=v_action.organisation_id
    and rv.outlet_id=v_action.outlet_id;

  select rp.* into v_verification_period
  from public.reporting_period rp
  where rp.id=p_verification_period_id
    and rp.organisation_id=v_action.organisation_id
    and rp.outlet_id=v_action.outlet_id;

  if v_source_period.id is null or v_verification_period.id is null then
    raise exception 'verification period is not available in the action context'
      using errcode='no_data_found';
  end if;

  if v_verification_period.period_start <= v_source_period.period_end then
    raise exception 'prior-action verification must use a later reporting period'
      using errcode='check_violation';
  end if;

  if exists (
    select 1
    from public.prior_action_check pac
    where pac.action_id=v_action.id
      and pac.verification_period_id=v_verification_period.id
  ) then
    raise exception 'this action already has a verification for the reporting period'
      using errcode='unique_violation';
  end if;

  v_status_before := v_action.status;

  if v_outcome='CLOSE' then
    v_status_after := 'CLOSED';
  elsif v_outcome='REOPEN' then
    v_status_after := 'REOPENED';
  else
    v_status_after := v_status_before;

    if v_status_before='CLOSED' then
      raise exception 'a closed action must be confirmed CLOSE or explicitly REOPENED'
        using errcode='check_violation';
    end if;
  end if;

  insert into public.prior_action_check(
    organisation_id,outlet_id,action_id,verification_period_id,
    completed_answer,completion_evidence,
    driver_moved_answer,driver_evidence,
    result_responded_answer,result_evidence,
    outcome,action_status_before,action_status_after,status_tag,
    closure_evidence,reopen_reason,note,created_by
  )
  values(
    v_action.organisation_id,
    v_action.outlet_id,
    v_action.id,
    v_verification_period.id,
    v_completed,
    v_completion_evidence,
    v_driver,
    v_driver_evidence,
    v_result,
    v_result_evidence,
    v_outcome,
    v_status_before,
    v_status_after,
    v_status_tag,
    case when v_outcome='CLOSE' then v_closure_evidence else null end,
    case when v_outcome='REOPEN' then v_reopen_reason else null end,
    v_note,
    v_user_id
  )
  returning id into v_check_id;

  if v_outcome='CLOSE' then
    update public.action
    set status='CLOSED',
        status_tag=v_status_tag,
        closure_evidence=coalesce(v_closure_evidence,closure_evidence),
        updated_at=now()
    where id=v_action.id;

  elsif v_outcome='REOPEN' then
    update public.action
    set status='REOPENED',
        status_tag=v_status_tag,
        updated_at=now()
    where id=v_action.id;

  elsif v_action.status_tag is distinct from v_status_tag then
    update public.action
    set status_tag=v_status_tag,
        updated_at=now()
    where id=v_action.id;
  end if;

  insert into public.action_event(
    organisation_id,outlet_id,action_id,event_type,
    from_status,to_status,status_tag,note,evidence,created_by
  )
  values(
    v_action.organisation_id,
    v_action.outlet_id,
    v_action.id,
    'verification',
    v_status_before,
    v_status_after,
    v_status_tag,
    coalesce(
      v_note,
      case
        when v_outcome='REOPEN' then v_reopen_reason
        when v_outcome='CLOSE' then 'Prior action verified and closed'
        else 'Prior action verified; follow-up continues'
      end
    ),
    concat_ws(
      E'\n',
      case when v_completion_evidence is not null
        then 'Completed: '||v_completed::text||' — '||v_completion_evidence end,
      case when v_driver_evidence is not null
        then 'Driver moved: '||v_driver::text||' — '||v_driver_evidence end,
      case when v_result_evidence is not null
        then 'Result responded: '||v_result::text||' — '||v_result_evidence end,
      case when v_closure_evidence is not null
        then 'Closure evidence: '||v_closure_evidence end,
      case when v_reopen_reason is not null
        then 'Reopen reason: '||v_reopen_reason end
    ),
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
    'PRIOR_ACTION_VERIFIED',
    'prior_action_check',
    v_check_id::text,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'prior_action_check_id',v_check_id,
    'action_status',v_status_after::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_check_id,v_status_after,false;
end
$$;


revoke all on function record_prior_action_check(
  uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text
) from public;

grant execute on function record_prior_action_check(
  uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text,text
) to restaurant_app;

-- Verification history is append-only. A changed conclusion is represented by
-- the next reporting period's verification, never by rewriting the prior check.
