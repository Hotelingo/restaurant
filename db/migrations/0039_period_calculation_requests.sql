-- 0039 · Period calculation requests
--
-- Readiness review finding B2: a calculation could only be queued as a side
-- effect of POST /imports/{id}/commit?queue_calc=true, which defaults to false.
-- Commit a batch without the flag and there was no way, through the API, to
-- ever calculate it -- and no way to re-run a calculation after changing
-- materiality or comparator settings.
--
-- calculation_request_queue is correctly closed to restaurant_app (no policies,
-- no grants), so both the request and the status read are narrow SECURITY
-- DEFINER functions, following the pattern of every other workflow write.
--
-- The worker already dispatches on the source batch template and on the
-- request reason prefix (food_cost* / revenue* / labour*), so a manual request
-- only has to choose the latest committed batch for the module and a reason
-- with the matching prefix. No worker change is needed.

create or replace function request_period_calculation(
  p_period_id uuid,
  p_module    text
) returns table (
  request_id      uuid,
  request_status  text,
  reused          boolean,
  source_batch_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id   uuid := public.current_app_user_id();
  v_org_id    uuid;
  v_outlet_id uuid;
  v_templates text[];
  v_reason    text;
  v_batch_id  uuid;
  v_existing  record;
  v_new_id    uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  v_templates := case p_module
    when 'pl'           then array['T1','T6']
    when 'food_cost'    then array['T2','T3','T4A']
    when 'revenue'      then array['T1B','T7']
    when 'labour_other' then array['T5']
  end;
  if v_templates is null then
    raise exception 'unsupported calculation module: %', p_module
      using errcode = 'invalid_parameter_value';
  end if;
  v_reason := p_module || '_manual_recalculation';

  select rp.organisation_id, rp.outlet_id
    into v_org_id, v_outlet_id
    from public.reporting_period rp
   where rp.id = p_period_id;

  -- Same neutral treatment for "missing" and "not yours".
  if v_org_id is null
     or not public.has_outlet_access(v_org_id, v_outlet_id)
     or not public.has_org_role(
          v_org_id, array['admin','editor','setup_analyst']::public.app_role[]) then
    raise exception 'period is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  select b.id
    into v_batch_id
    from public.import_batch b
   where b.organisation_id = v_org_id
     and b.outlet_id = v_outlet_id
     and b.period_id = p_period_id
     and b.status = 'committed'
     and b.template_code::text = any (v_templates)
   order by b.committed_at desc nulls last, b.id desc
   limit 1;

  if v_batch_id is null then
    raise exception 'no committed source data for this calculation'
      using errcode = 'no_data_found';
  end if;

  -- One outstanding request per period and module: a double click, or a retry
  -- while the worker is busy, returns the request already in the queue.
  select q.id, q.status
    into v_existing
    from public.calculation_request_queue q
   where q.organisation_id = v_org_id
     and q.outlet_id = v_outlet_id
     and q.period_id = p_period_id
     and q.reason = v_reason
     and q.status in ('pending', 'running')
   order by q.created_at desc
   limit 1;

  if found then
    return query select v_existing.id, v_existing.status::text, true, v_batch_id;
    return;
  end if;

  insert into public.calculation_request_queue (
    organisation_id, outlet_id, period_id, source_batch_id, reason
  ) values (
    v_org_id, v_outlet_id, p_period_id, v_batch_id, v_reason
  )
  returning id into v_new_id;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id
  ) values (
    v_user_id, v_org_id, v_outlet_id,
    'CALCULATION_REQUESTED', 'calculation_request', v_new_id::text
  );

  return query select v_new_id, 'pending'::text, false, v_batch_id;
end
$$;

revoke all on function request_period_calculation(uuid,text) from public;
grant execute on function request_period_calculation(uuid,text) to restaurant_app;


-- Status of recent calculation requests for a period, readable by anyone who
-- can see the outlet (viewers included), so the UI can show "calculating".
create or replace function list_period_calculations(p_period_id uuid)
returns table (
  request_id       uuid,
  reason           text,
  request_status   text,
  attempts         integer,
  created_at       timestamptz,
  started_at       timestamptz,
  completed_at     timestamptz,
  completed_run_id uuid,
  last_error       text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_org_id    uuid;
  v_outlet_id uuid;
begin
  if public.current_app_user_id() is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select rp.organisation_id, rp.outlet_id
    into v_org_id, v_outlet_id
    from public.reporting_period rp
   where rp.id = p_period_id;

  if v_org_id is null or not public.has_outlet_access(v_org_id, v_outlet_id) then
    raise exception 'period is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  return query
  select q.id, q.reason, q.status::text, q.attempts,
         q.created_at, q.started_at, q.completed_at, q.completed_run_id,
         left(q.last_error, 300)
    from public.calculation_request_queue q
   where q.organisation_id = v_org_id
     and q.outlet_id = v_outlet_id
     and q.period_id = p_period_id
   order by q.created_at desc
   limit 20;
end
$$;

revoke all on function list_period_calculations(uuid) from public;
grant execute on function list_period_calculations(uuid) to restaurant_app;
