-- 0019 · Durable calculation worker orchestration and PL result lineage
-- Implements OD-01 with a Postgres-backed lease queue. The worker is host-portable;
-- no Redis or provider-specific job service is required for R1.

-- Import-triggered calculation requests are events, not one-per-batch forever.
-- Remove the original permanent uniqueness so a later explicit rerun can use the
-- same committed source batch while preserving every prior request/run.
alter table calculation_request_queue
  drop constraint if exists calculation_request_queue_source_batch_id_key;

create index calculation_request_queue_source_batch_idx
  on calculation_request_queue(source_batch_id, created_at desc);

alter table calculation_request_queue
  add column available_at timestamptz not null default now(),
  add column claimed_by text,
  add column heartbeat_at timestamptz,
  add column lease_expires_at timestamptz,
  add column completed_run_id uuid;

alter table calculation_request_queue
  add constraint calculation_request_queue_claimed_by_check
  check (claimed_by is null or length(btrim(claimed_by)) > 0);

create index calculation_request_queue_available_idx
  on calculation_request_queue(available_at, created_at)
  where status = 'pending';

create index calculation_request_queue_lease_idx
  on calculation_request_queue(lease_expires_at)
  where status = 'running';


-- A queue request can have more than one preserved attempt after a worker crash.
-- Each attempt receives a new immutable calc_run rather than mutating partial history.
drop index if exists calc_run_request_unique_idx;

alter table calc_run
  add column attempt_no integer not null default 1
    check (attempt_no > 0);

create unique index calc_run_request_attempt_unique_idx
  on calc_run(request_id, attempt_no)
  where request_id is not null;

alter table calculation_request_queue
  add constraint calculation_request_queue_completed_run_fk
  foreign key (organisation_id, outlet_id, completed_run_id)
  references calc_run(organisation_id, outlet_id, id);


-- Persist the result contract fields needed for direct figure-to-fact lineage and
-- variance auditability. These are nullable only where the calculation type does
-- not use them.
alter table calc_result
  add column input_refs jsonb not null default '[]'::jsonb
    check (jsonb_typeof(input_refs) = 'array'),
  add column raw_delta numeric(20,4),
  add column profit_effect numeric(20,4);

alter table calc_result
  add constraint calc_result_variance_fields_check
  check (
    (raw_delta is null and profit_effect is null)
    or
    (
      calculation_status = 'CALCULATED'
      and raw_delta is not null
      and profit_effect is not null
    )
  );


-- Claim exactly one available request. SKIP LOCKED lets multiple worker
-- containers consume the same durable queue without double-claiming.
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
  reason text,
  attempt_no integer,
  lease_expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
begin
  if p_worker_id is null or length(btrim(p_worker_id)) = 0 then
    raise exception 'worker id is required'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception 'lease seconds must be between 30 and 3600'
      using errcode = 'invalid_parameter_value';
  end if;
  if p_max_attempts < 1 or p_max_attempts > 20 then
    raise exception 'max attempts must be between 1 and 20'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Any running calc attempt whose queue lease expired is terminally failed.
  -- Its immutable partial results remain queryable, and a reclaimed request
  -- receives a fresh run/attempt number.
  update public.calc_run r
  set status = 'failed',
      completed_at = now(),
      error_code = 'WORKER_LEASE_EXPIRED',
      error_message = 'Calculation worker lease expired before completion'
  from public.calculation_request_queue q
  where r.request_id = q.id
    and r.status = 'running'
    and q.status = 'running'
    and q.lease_expires_at is not null
    and q.lease_expires_at < now();

  -- Requests that exhausted their attempt budget fail instead of remaining
  -- permanently stuck in running.
  update public.calculation_request_queue q
  set status = 'failed',
      completed_at = now(),
      last_error = coalesce(q.last_error, 'Calculation worker lease expired after maximum attempts'),
      claimed_by = null,
      heartbeat_at = null,
      lease_expires_at = null
  where q.status = 'running'
    and q.lease_expires_at is not null
    and q.lease_expires_at < now()
    and q.attempts >= p_max_attempts;

  select q.id
  into v_request_id
  from public.calculation_request_queue q
  where (
      (q.status = 'pending' and q.available_at <= now())
      or
      (
        q.status = 'running'
        and q.lease_expires_at is not null
        and q.lease_expires_at < now()
      )
    )
    and q.attempts < p_max_attempts
  order by q.available_at, q.created_at, q.id
  for update skip locked
  limit 1;

  if v_request_id is null then
    return;
  end if;

  return query
  update public.calculation_request_queue q
  set status = 'running',
      attempts = q.attempts + 1,
      started_at = coalesce(q.started_at, now()),
      completed_at = null,
      claimed_by = btrim(p_worker_id),
      heartbeat_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds),
      last_error = null
  where q.id = v_request_id
  returning
    q.id,
    q.organisation_id,
    q.outlet_id,
    q.period_id,
    q.source_batch_id,
    q.reason,
    q.attempts,
    q.lease_expires_at;
end
$$;


create or replace function heartbeat_calculation_request(
  p_request_id uuid,
  p_worker_id text,
  p_lease_seconds integer default 300
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_lease_expires_at timestamptz;
begin
  if p_lease_seconds < 30 or p_lease_seconds > 3600 then
    raise exception 'lease seconds must be between 30 and 3600'
      using errcode = 'invalid_parameter_value';
  end if;

  update public.calculation_request_queue q
  set heartbeat_at = now(),
      lease_expires_at = now() + make_interval(secs => p_lease_seconds)
  where q.id = p_request_id
    and q.status = 'running'
    and q.claimed_by = btrim(p_worker_id)
  returning q.lease_expires_at into v_lease_expires_at;

  if v_lease_expires_at is null then
    raise exception 'calculation request is not owned by this worker'
      using errcode = 'insufficient_privilege';
  end if;

  return v_lease_expires_at;
end
$$;


create or replace function complete_calculation_request(
  p_request_id uuid,
  p_worker_id text,
  p_run_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (
    select 1
    from public.calc_run r
    where r.id = p_run_id
      and r.request_id = p_request_id
      and r.status = 'completed'
  ) then
    raise exception 'completed calc run does not match request'
      using errcode = 'check_violation';
  end if;

  update public.calculation_request_queue q
  set status = 'completed',
      completed_at = now(),
      completed_run_id = p_run_id,
      claimed_by = null,
      heartbeat_at = null,
      lease_expires_at = null,
      last_error = null
  where q.id = p_request_id
    and q.status = 'running'
    and q.claimed_by = btrim(p_worker_id);

  if not found then
    raise exception 'calculation request is not owned by this worker'
      using errcode = 'insufficient_privilege';
  end if;
end
$$;


create or replace function fail_calculation_request(
  p_request_id uuid,
  p_worker_id text,
  p_error text,
  p_retryable boolean,
  p_backoff_seconds integer default 30,
  p_max_attempts integer default 5
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_attempts integer;
  v_status text;
begin
  if p_backoff_seconds < 0 or p_backoff_seconds > 86400 then
    raise exception 'backoff seconds must be between 0 and 86400'
      using errcode = 'invalid_parameter_value';
  end if;

  select q.attempts into v_attempts
  from public.calculation_request_queue q
  where q.id = p_request_id
    and q.status = 'running'
    and q.claimed_by = btrim(p_worker_id)
  for update;

  if v_attempts is null then
    raise exception 'calculation request is not owned by this worker'
      using errcode = 'insufficient_privilege';
  end if;

  if p_retryable and v_attempts < p_max_attempts then
    v_status := 'pending';
    update public.calculation_request_queue q
    set status = 'pending',
        available_at = now() + make_interval(secs => p_backoff_seconds),
        last_error = left(coalesce(p_error,'calculation worker error'), 2000),
        claimed_by = null,
        heartbeat_at = null,
        lease_expires_at = null
    where q.id = p_request_id;
  else
    v_status := 'failed';
    update public.calculation_request_queue q
    set status = 'failed',
        completed_at = now(),
        last_error = left(coalesce(p_error,'calculation worker error'), 2000),
        claimed_by = null,
        heartbeat_at = null,
        lease_expires_at = null
    where q.id = p_request_id;
  end if;

  return v_status;
end
$$;

revoke all on function claim_calculation_request(text,integer,integer) from public;
revoke all on function heartbeat_calculation_request(uuid,text,integer) from public;
revoke all on function complete_calculation_request(uuid,text,uuid) from public;
revoke all on function fail_calculation_request(uuid,text,text,boolean,integer,integer) from public;

-- The dedicated worker uses trusted server database credentials. These functions
-- are deliberately not granted to restaurant_app/client sessions.

-- Additive/forward-fix-only migration. Queue/run history is preserved; retries
-- append new attempts rather than rewriting prior calc snapshots.
