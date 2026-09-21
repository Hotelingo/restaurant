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


-- Forward-fix the Slice 2 import-commit helper after removing permanent
-- source_batch_id uniqueness. Import-triggered enqueue stays idempotent by
-- batch + reason, while explicit later reruns may create new queue requests.
create or replace function _commit_financial_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null,
  p_queue_calc boolean default false,
  p_fault_after_step integer default null
)
returns table (
  committed_batch_id uuid,
  commit_status public.batch_status,
  fact_count bigint,
  commit_hash text,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $commit$
declare
  v_user_id uuid := public.current_app_user_id();
  v_batch public.import_batch%rowtype;
  v_existing jsonb;
  v_operation text := 'import.commit:' || p_batch_id::text;
  v_period_month text;
  v_currency char(3);
  v_ladder_grain boolean := false;
  v_fact_count bigint := 0;
  v_hash text;
  v_summary jsonb;
  v_ready_status text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_fault_after_step is not null
     and (p_fault_after_step < 1 or p_fault_after_step > 9) then
    raise exception 'fault injection step must be between 1 and 9'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Step 1: lock the batch and resolve/verify tenant access.
  select b.* into v_batch
  from public.import_batch b
  where b.id = p_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'import batch not found'
      using errcode = 'no_data_found';
  end if;

  if not public.has_org_role(
       v_batch.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_batch.organisation_id, v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_fault_after_step = 1 then
    raise exception 'FAULT_STEP_1';
  end if;

  insert into public.request_idempotency(user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key
  for update;

  if coalesce(v_existing ? 'committed_batch_id', false) then
    return query
      select
        (v_existing->>'committed_batch_id')::uuid,
        (v_existing->>'commit_status')::public.batch_status,
        (v_existing->>'fact_count')::bigint,
        v_existing->>'commit_hash',
        true;
    return;
  end if;

  if v_batch.status = 'committed' then
    select count(*)::bigint into v_fact_count
    from public.financial_fact ff
    where ff.batch_id = v_batch.id;

    v_hash := v_batch.canonical_commit_hash;

    update public.request_idempotency
    set response_json = jsonb_build_object(
      'committed_batch_id', v_batch.id,
      'commit_status', v_batch.status::text,
      'fact_count', v_fact_count,
      'commit_hash', v_hash
    )
    where user_id = v_user_id
      and operation = v_operation
      and idempotency_key = p_idempotency_key;

    return query select v_batch.id, v_batch.status, v_fact_count, v_hash, true;
    return;
  end if;

  if v_batch.status not in ('ready','warning') then
    raise exception 'batch status % is not committable', v_batch.status
      using errcode = 'check_violation';
  end if;

  if v_batch.template_code not in ('T1','T6') then
    raise exception 'canonical financial commit currently supports T1 and T6 only'
      using errcode = 'feature_not_supported';
  end if;

  -- Step 2: unresolved block validations prohibit commit.
  if public.batch_has_unresolved_blocks(v_batch.id) then
    raise exception 'batch has unresolved block validations'
      using errcode = 'check_violation';
  end if;

  if p_fault_after_step = 2 then
    raise exception 'FAULT_STEP_2';
  end if;

  -- Step 3: verify approved profile and complete batch context.
  if v_batch.period_id is null or v_batch.profile_version_id is null then
    raise exception 'batch requires reporting period and profile version before commit'
      using errcode = 'check_violation';
  end if;

  if not exists (
    select 1
    from public.profile_version pv
    where pv.id = v_batch.profile_version_id
      and pv.organisation_id = v_batch.organisation_id
      and pv.outlet_id = v_batch.outlet_id
      and pv.status = 'approved'
      and pv.approved_at is not null
  ) then
    raise exception 'batch profile version is not approved'
      using errcode = 'check_violation';
  end if;

  select
    to_char(rp.period_start, 'YYYY-MM'),
    o.currency_code
  into v_period_month, v_currency
  from public.reporting_period rp
  join public.outlet o
    on o.organisation_id = rp.organisation_id
   and o.id = rp.outlet_id
  where rp.id = v_batch.period_id
    and rp.organisation_id = v_batch.organisation_id
    and rp.outlet_id = v_batch.outlet_id;

  if v_period_month is null then
    raise exception 'batch reporting period is not available'
      using errcode = 'check_violation';
  end if;

  if not exists (
    select 1 from public.staging_row s where s.batch_id = v_batch.id
  ) then
    raise exception 'batch has no staging rows'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1
    from public.staging_row s
    where s.batch_id = v_batch.id
      and (
        s.parsed_jsonb is null
        or nullif(btrim(s.parsed_jsonb->>'period'), '') is null
        or s.parsed_jsonb->>'period' <> v_period_month
        or nullif(btrim(s.parsed_jsonb->>'amount'), '') is null
      )
  ) then
    raise exception 'staging rows are not canonically parsed for the batch period'
      using errcode = 'check_violation';
  end if;

  if v_batch.template_code = 'T1' and v_batch.scenario <> 'actual' then
    raise exception 'T1 is the R1 actual P&L path; comparator scenarios use T6'
      using errcode = 'check_violation';
  end if;

  if v_batch.template_code = 'T6' and v_batch.scenario = 'actual' then
    raise exception 'T6 requires budget, forecast or prior_year scenario'
      using errcode = 'check_violation';
  end if;

  if p_fault_after_step = 3 then
    raise exception 'FAULT_STEP_3';
  end if;

  -- Step 4: resolve approved mappings and persist canonical account identities.
  if v_batch.template_code = 'T1' then
    if exists (
      select 1
      from public.staging_row s
      where s.batch_id = v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'account_name'), '') is null
    ) then
      raise exception 'T1 staging row is missing account_name'
        using errcode = 'check_violation';
    end if;

    if exists (
      select 1
      from public.staging_row s
      where s.batch_id = v_batch.id
        and not exists (
          select 1
          from public.account_mapping am
          join public.ladder_line ll on ll.id = am.ladder_line_id
          where am.profile_version_id = v_batch.profile_version_id
            and am.source_identity_key = (
              case
                when nullif(btrim(s.parsed_jsonb->>'account_code'), '') is not null
                  then 'code:' || lower(btrim(s.parsed_jsonb->>'account_code'))
                else 'name:' || lower(btrim(s.parsed_jsonb->>'account_name'))
              end
            )
            and not ll.is_calculated
        )
    ) then
      raise exception 'T1 contains an unmapped account or a mapping to a calculated ladder line'
        using errcode = 'check_violation';
    end if;

    insert into public.account(
      organisation_id,outlet_id,account_code,account_name,account_section
    )
    select distinct
      v_batch.organisation_id,
      v_batch.outlet_id,
      nullif(btrim(s.parsed_jsonb->>'account_code'), ''),
      btrim(s.parsed_jsonb->>'account_name'),
      nullif(btrim(s.parsed_jsonb->>'account_section'), '')
    from public.staging_row s
    where s.batch_id = v_batch.id
    on conflict (outlet_id, source_identity_key) do nothing;

  else
    -- T6 may be account-grain or direct management-line grain, never a mixture.
    if exists (
      select 1 from public.staging_row s
      where s.batch_id = v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'management_line'), '') is not null
    ) then
      v_ladder_grain := true;
    end if;

    if v_ladder_grain and exists (
      select 1 from public.staging_row s
      where s.batch_id = v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'management_line'), '') is null
    ) then
      raise exception 'T6 cannot mix account-grain and ladder-grain rows in one batch'
        using errcode = 'check_violation';
    end if;

    if not v_ladder_grain then
      if exists (
        select 1
        from public.staging_row s
        where s.batch_id = v_batch.id
          and nullif(btrim(s.parsed_jsonb->>'account_name'), '') is null
      ) then
        raise exception 'account-grain T6 row is missing account_name'
          using errcode = 'check_violation';
      end if;

      if exists (
        select 1
        from public.staging_row s
        where s.batch_id = v_batch.id
          and not exists (
            select 1
            from public.account_mapping am
            join public.ladder_line ll on ll.id = am.ladder_line_id
            where am.profile_version_id = v_batch.profile_version_id
              and am.source_identity_key = (
                case
                  when nullif(btrim(s.parsed_jsonb->>'account_code'), '') is not null
                    then 'code:' || lower(btrim(s.parsed_jsonb->>'account_code'))
                  else 'name:' || lower(btrim(s.parsed_jsonb->>'account_name'))
                end
              )
              and not ll.is_calculated
          )
      ) then
        raise exception 'T6 contains an unmapped account or calculated-line mapping'
          using errcode = 'check_violation';
      end if;

      insert into public.account(
        organisation_id,outlet_id,account_code,account_name,account_section
      )
      select distinct
        v_batch.organisation_id,
        v_batch.outlet_id,
        nullif(btrim(s.parsed_jsonb->>'account_code'), ''),
        btrim(s.parsed_jsonb->>'account_name'),
        nullif(btrim(s.parsed_jsonb->>'account_section'), '')
      from public.staging_row s
      where s.batch_id = v_batch.id
      on conflict (outlet_id, source_identity_key) do nothing;
    else
      if exists (
        select 1
        from public.staging_row s
        where s.batch_id = v_batch.id
          and not exists (
            select 1
            from public.value_mapping vm
            join public.ladder_line ll
              on ll.code = vm.canonical_value
             and not ll.is_calculated
            where vm.profile_version_id = v_batch.profile_version_id
              and lower(btrim(vm.field_name)) = 'management_line'
              and lower(btrim(vm.source_value)) =
                  lower(btrim(s.parsed_jsonb->>'management_line'))
          )
      ) then
        raise exception 'T6 contains an unmapped management line or calculated-line mapping'
          using errcode = 'check_violation';
      end if;
    end if;
  end if;

  if p_fault_after_step = 4 then
    raise exception 'FAULT_STEP_4';
  end if;

  -- Step 5: insert immutable canonical facts.
  if v_batch.template_code = 'T1'
     or (v_batch.template_code = 'T6' and not v_ladder_grain) then
    insert into public.financial_fact(
      organisation_id,outlet_id,period_id,scenario,
      account_id,ladder_line_id,amount,currency_code,
      batch_id,profile_version_id,staging_row_id
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      v_batch.scenario,
      a.id,
      am.ladder_line_id,
      (s.parsed_jsonb->>'amount')::numeric(20,4),
      v_currency,
      v_batch.id,
      v_batch.profile_version_id,
      s.id
    from public.staging_row s
    join public.account_mapping am
      on am.profile_version_id = v_batch.profile_version_id
     and am.source_identity_key = (
       case
         when nullif(btrim(s.parsed_jsonb->>'account_code'), '') is not null
           then 'code:' || lower(btrim(s.parsed_jsonb->>'account_code'))
         else 'name:' || lower(btrim(s.parsed_jsonb->>'account_name'))
       end
     )
    join public.account a
      on a.organisation_id = v_batch.organisation_id
     and a.outlet_id = v_batch.outlet_id
     and a.source_identity_key = am.source_identity_key
    where s.batch_id = v_batch.id;
  else
    insert into public.financial_fact(
      organisation_id,outlet_id,period_id,scenario,
      account_id,ladder_line_id,amount,currency_code,
      batch_id,profile_version_id,staging_row_id
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      v_batch.scenario,
      null,
      ll.id,
      (s.parsed_jsonb->>'amount')::numeric(20,4),
      v_currency,
      v_batch.id,
      v_batch.profile_version_id,
      s.id
    from public.staging_row s
    join public.value_mapping vm
      on vm.profile_version_id = v_batch.profile_version_id
     and lower(btrim(vm.field_name)) = 'management_line'
     and lower(btrim(vm.source_value)) =
         lower(btrim(s.parsed_jsonb->>'management_line'))
    join public.ladder_line ll
      on ll.code = vm.canonical_value
     and not ll.is_calculated
    where s.batch_id = v_batch.id;
  end if;

  get diagnostics v_fact_count = row_count;
  if v_fact_count = 0 then
    raise exception 'canonical commit produced zero financial facts'
      using errcode = 'check_violation';
  end if;

  if p_fault_after_step = 5 then
    raise exception 'FAULT_STEP_5';
  end if;

  -- Step 6: deterministic fact checksum and summary, excluding random row ids.
  select
    encode(
      public.digest(
        convert_to(
          string_agg(
            concat_ws(
              '|',
              ff.scenario::text,
              ll.code,
              coalesce(a.source_identity_key, 'ladder'),
              ff.amount::text,
              ff.currency_code
            ),
            E'\n'
            order by ll.code, coalesce(a.source_identity_key, ''), ff.amount
          ),
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    ),
    jsonb_build_object(
      'fact_count', count(*)::bigint,
      'amount_total', sum(ff.amount)::text
    )
  into v_hash, v_summary
  from public.financial_fact ff
  join public.ladder_line ll on ll.id = ff.ladder_line_id
  left join public.account a on a.id = ff.account_id
  where ff.batch_id = v_batch.id;

  if v_hash is null then
    raise exception 'canonical checksum could not be produced'
      using errcode = 'check_violation';
  end if;

  if p_fault_after_step = 6 then
    raise exception 'FAULT_STEP_6';
  end if;

  -- Step 7: mark the batch committed. The table trigger independently verifies
  -- that canonical facts exist and no unresolved block remains.
  update public.import_batch
  set status = 'committed',
      committed_by = v_user_id,
      committed_at = now(),
      canonical_commit_hash = v_hash,
      canonical_commit_summary = v_summary
  where id = v_batch.id;

  v_batch.status := 'committed';
  v_batch.canonical_commit_hash := v_hash;

  if p_fault_after_step = 7 then
    raise exception 'FAULT_STEP_7';
  end if;

  -- Step 8: recompute Management P&L data readiness for this period.
  if exists (
    select 1
    from public.import_batch b
    where b.organisation_id = v_batch.organisation_id
      and b.outlet_id = v_batch.outlet_id
      and b.period_id = v_batch.period_id
      and b.template_code = 'T1'
      and b.scenario = 'actual'
      and b.status = 'committed'
  )
  and exists (
    select 1
    from public.import_batch b
    where b.organisation_id = v_batch.organisation_id
      and b.outlet_id = v_batch.outlet_id
      and b.period_id = v_batch.period_id
      and b.template_code = 'T6'
      and b.scenario <> 'actual'
      and b.status = 'committed'
  ) then
    v_ready_status := 'ready';
  else
    v_ready_status := 'partial';
  end if;

  insert into public.data_readiness(
    organisation_id,outlet_id,period_id,capability_code,
    status,latest_batch_id,details_json
  )
  values (
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_batch.period_id,
    'management_pl',
    v_ready_status,
    v_batch.id,
    jsonb_build_object(
      'actual_committed',
      exists (
        select 1 from public.import_batch b
        where b.outlet_id = v_batch.outlet_id
          and b.period_id = v_batch.period_id
          and b.template_code = 'T1'
          and b.scenario = 'actual'
          and b.status = 'committed'
      ),
      'comparator_committed',
      exists (
        select 1 from public.import_batch b
        where b.outlet_id = v_batch.outlet_id
          and b.period_id = v_batch.period_id
          and b.template_code = 'T6'
          and b.scenario <> 'actual'
          and b.status = 'committed'
      )
    )
  )
  on conflict (organisation_id,outlet_id,period_id,capability_code)
  do update
    set status = excluded.status,
        latest_batch_id = excluded.latest_batch_id,
        details_json = excluded.details_json,
        updated_at = now();

  if p_fault_after_step = 8 then
    raise exception 'FAULT_STEP_8';
  end if;

  -- Step 9: optionally enqueue the import-triggered calculation event.
  -- 0019 allows explicit later reruns for the same committed batch, so source_batch_id
  -- is no longer globally unique. Preserve import-commit idempotency by suppressing
  -- only a prior request with the same batch + import-trigger reason.
  if p_queue_calc then
    insert into public.calculation_request_queue(
      organisation_id,outlet_id,period_id,source_batch_id,reason
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      v_batch.id,
      'financial_import_committed'
    where not exists (
      select 1
      from public.calculation_request_queue q
      where q.source_batch_id = v_batch.id
        and q.reason = 'financial_import_committed'
    );
  end if;

  if p_fault_after_step = 9 then
    raise exception 'FAULT_STEP_9';
  end if;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,after_hash,correlation_id
  )
  values (
    v_user_id,
    v_batch.organisation_id,
    v_batch.outlet_id,
    'IMPORT_BATCH_COMMITTED',
    'import_batch',
    v_batch.id::text,
    v_hash,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json = jsonb_build_object(
    'committed_batch_id', v_batch.id,
    'commit_status', 'committed',
    'fact_count', v_fact_count,
    'commit_hash', v_hash
  )
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  return query
    select v_batch.id, 'committed'::public.batch_status, v_fact_count, v_hash, false;
end
$commit$;

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
