-- 0015 · Atomic, idempotent T1/T6 canonical commit
-- Completes the database transaction for the first vertical ingestion path:
-- lock -> validate -> resolve mappings -> insert facts -> checksum -> commit
-- -> readiness -> optional calc request. The private helper exposes fault
-- injection only to database-owner tests; restaurant_app receives the wrapper.

create table data_readiness (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  capability_code text not null,
  status text not null
    check (status in ('partial','ready','not_reconciled','blocked')),
  latest_batch_id uuid,
  details_json jsonb not null default '{}'::jsonb
    check (jsonb_typeof(details_json) = 'object'),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),
  foreign key (organisation_id, outlet_id, latest_batch_id)
    references import_batch(organisation_id, outlet_id, id),
  unique (organisation_id, outlet_id, period_id, capability_code)
);
create index data_readiness_outlet_period_idx
  on data_readiness (outlet_id, period_id, capability_code);

create table calculation_request_queue (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  source_batch_id uuid not null,
  reason text not null,
  status text not null default 'pending'
    check (status in ('pending','running','completed','failed')),
  attempts integer not null default 0 check (attempts >= 0),
  created_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  last_error text,
  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),
  foreign key (organisation_id, outlet_id, source_batch_id)
    references import_batch(organisation_id, outlet_id, id),
  unique (source_batch_id)
);
create index calculation_request_queue_pending_idx
  on calculation_request_queue (created_at)
  where status = 'pending';

alter table data_readiness enable row level security;
alter table calculation_request_queue enable row level security;

create policy data_readiness_read on data_readiness
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

grant select on data_readiness to restaurant_app;
-- calculation_request_queue is intentionally server/worker-only.

create or replace function guard_import_batch_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'import batches are retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'superseded' then
    raise exception 'superseded import batch is immutable'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'committed' then
    if new.status = 'superseded'
       and new.superseded_by_batch_id is not null
       and new.superseded_at is not null
       and (to_jsonb(new) - array[
         'status','superseded_by_batch_id','superseded_at'
       ]) = (to_jsonb(old) - array[
         'status','superseded_by_batch_id','superseded_at'
       ]) then
      return new;
    end if;

    raise exception
      'committed import batch is immutable except controlled supersede'
      using errcode = 'restrict_violation';
  end if;

  if new.status = 'committed' and old.status <> 'committed' then
    if new.committed_by is null
       or new.committed_at is null
       or new.canonical_commit_hash is null
       or new.period_id is null
       or new.profile_version_id is null then
      raise exception 'committed batch requires complete commit metadata'
        using errcode = 'check_violation';
    end if;

    if public.batch_has_unresolved_blocks(new.id) then
      raise exception 'batch has unresolved block validations'
        using errcode = 'check_violation';
    end if;

    if not exists (
      select 1 from public.financial_fact ff where ff.batch_id = new.id
    ) then
      raise exception 'batch cannot be committed without canonical financial facts'
        using errcode = 'check_violation';
    end if;
  end if;

  return new;
end
$$;

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
as $$
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

  -- Step 9: optionally enqueue a later immutable calc run.
  if p_queue_calc then
    insert into public.calculation_request_queue(
      organisation_id,outlet_id,period_id,source_batch_id,reason
    )
    values (
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      v_batch.id,
      'financial_import_committed'
    )
    on conflict (source_batch_id) do nothing;
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
$$;

create or replace function commit_financial_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null,
  p_queue_calc boolean default false
)
returns table (
  committed_batch_id uuid,
  commit_status public.batch_status,
  fact_count bigint,
  commit_hash text,
  reused boolean
)
language sql
security definer
set search_path = ''
as $$
  select *
  from public._commit_financial_import_batch(
    p_batch_id,
    p_idempotency_key,
    p_correlation_id,
    p_queue_calc,
    null
  )
$$;

revoke all on function _commit_financial_import_batch(uuid,text,text,boolean,integer) from public;
revoke all on function commit_financial_import_batch(uuid,text,text,boolean) from public;
grant execute on function commit_financial_import_batch(uuid,text,text,boolean)
  to restaurant_app;

-- Additive migration. Once canonical commits exist, use forward fixes only.
