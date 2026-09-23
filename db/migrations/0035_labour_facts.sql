-- 0035 · Labour canonical facts (T5)
-- Slice 7 / S7-2. Adds immutable role-group Labour facts, profile-scoped
-- activity-basis mappings, atomic/idempotent commit, and T5 ↔ T1/T6
-- Direct Labour readiness reconciliation.

create table labour_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  role_group text not null,
  actual_hours numeric(20,4) not null check (actual_hours >= 0),
  comparator_hours numeric(20,4)
    check (comparator_hours is null or comparator_hours >= 0),
  actual_cost numeric(20,4) not null,
  comparator_cost numeric(20,4),
  scheduled_hours numeric(20,4)
    check (scheduled_hours is null or scheduled_hours >= 0),
  overtime_hours numeric(20,4)
    check (overtime_hours is null or overtime_hours >= 0),
  activity_units numeric(20,4)
    check (activity_units is null or activity_units >= 0),
  activity_basis text,
  comparator_scenario scenario_code,
  notes text,
  batch_id uuid not null,
  profile_version_id uuid not null,
  staging_row_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,period_id)
    references reporting_period(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,batch_id)
    references import_batch(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,profile_version_id)
    references profile_version(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,staging_row_id)
    references staging_row(organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,id),
  unique (batch_id,staging_row_id),
  check (length(btrim(role_group)) > 0),
  check (
    activity_units is null
    or (activity_basis is not null and length(btrim(activity_basis)) > 0)
  ),
  check (comparator_scenario is null or comparator_scenario <> 'actual')
);
create index labour_fact_period_role_idx
  on labour_fact(outlet_id,period_id,lower(btrim(role_group)));

create trigger labour_fact_immutable
  before update or delete on labour_fact
  for each row execute function forbid_mutation();

alter table labour_fact enable row level security;

create policy labour_fact_read on labour_fact
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on labour_fact to restaurant_app;


create or replace function guard_import_batch_mutation()
returns trigger
language plpgsql
as $$
declare
  v_has_canonical boolean := false;
begin
  if tg_op='DELETE' then
    raise exception 'import batches are retained; delete is not permitted'
      using errcode='restrict_violation';
  end if;

  if old.status='superseded' then
    raise exception 'superseded import batch is immutable'
      using errcode='restrict_violation';
  end if;

  if old.status='committed' then
    if new.status='superseded'
       and new.superseded_by_batch_id is not null
       and new.superseded_at is not null
       and (to_jsonb(new)-array['status','superseded_by_batch_id','superseded_at'])
         = (to_jsonb(old)-array['status','superseded_by_batch_id','superseded_at']) then
      return new;
    end if;
    raise exception 'committed import batch is immutable except controlled supersede'
      using errcode='restrict_violation';
  end if;

  if new.status='committed' and old.status<>'committed' then
    if new.committed_by is null
       or new.committed_at is null
       or new.canonical_commit_hash is null
       or new.period_id is null
       or new.profile_version_id is null then
      raise exception 'committed batch requires complete commit metadata'
        using errcode='check_violation';
    end if;

    if public.batch_has_unresolved_blocks(new.id) then
      raise exception 'batch has unresolved block validations'
        using errcode='check_violation';
    end if;

    if new.template_code in ('T1','T6') then
      select exists(select 1 from public.financial_fact where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T1B' then
      select exists(select 1 from public.revenue_activity_fact where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T2' then
      select exists(select 1 from public.item_sales_fact where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T3' then
      select exists(select 1 from public.stock_fact where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T4A' then
      select exists(select 1 from public.item_cost_snapshot where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T5' then
      select exists(select 1 from public.labour_fact where batch_id=new.id)
        into v_has_canonical;
    elsif new.template_code='T7' then
      select exists(select 1 from public.channel_source_fact where batch_id=new.id)
        into v_has_canonical;
    else
      v_has_canonical := false;
    end if;

    if not v_has_canonical then
      raise exception 'batch cannot be committed without canonical facts for template %',
        new.template_code
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;


create or replace function confirm_labour_mapping(
  p_batch_id uuid,
  p_idempotency_key text,
  p_source_label text default null,
  p_base_profile_version_id uuid default null,
  p_activity_basis_mappings jsonb default '[]'::jsonb,
  p_correlation_id text default null
)
returns table (
  confirmed_profile_version_id uuid,
  confirmed_version_no integer,
  confirmed_batch_status public.batch_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_batch public.import_batch%rowtype;
  v_existing jsonb;
  v_operation text := 'import.mapping.confirm.labour:'||p_batch_id::text;
  v_source_profile_id uuid;
  v_new_profile_id uuid;
  v_version_no integer;
  v_source_label text;
  v_layout jsonb;
  v_components jsonb;
  v_transform_config jsonb := '[]'::jsonb;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;
  if jsonb_typeof(p_activity_basis_mappings)<>'array' then
    raise exception 'activity-basis mappings must be a JSON array'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_batch
  from public.import_batch
  where id=p_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'import batch not found' using errcode='no_data_found';
  end if;
  if not public.has_org_role(
       v_batch.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_batch.organisation_id,v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode='insufficient_privilege';
  end if;
  if v_batch.template_code<>'T5' then
    raise exception 'Labour mapping confirmation supports T5 only'
      using errcode='feature_not_supported';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'profile_version_id',false) then
    return query select
      (v_existing->>'profile_version_id')::uuid,
      (v_existing->>'version_no')::integer,
      (v_existing->>'batch_status')::public.batch_status,
      true;
    return;
  end if;

  if v_batch.status<>'needs_mapping'
     or v_batch.detected_fingerprint is null
     or v_batch.parse_completed_at is null
     or v_batch.parse_metadata_json='{}'::jsonb then
    raise exception 'batch must be parsed and awaiting mapping confirmation'
      using errcode='check_violation';
  end if;
  if exists(
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id and jsonb_array_length(s.parse_errors)>0
  ) then
    raise exception 'parse errors must be corrected before mapping confirmation'
      using errcode='check_violation';
  end if;

  if p_base_profile_version_id is not null then
    select pv.source_profile_id into v_source_profile_id
    from public.profile_version pv
    join public.source_profile sp on sp.id=pv.source_profile_id
    where pv.id=p_base_profile_version_id
      and pv.organisation_id=v_batch.organisation_id
      and pv.outlet_id=v_batch.outlet_id
      and pv.status='approved'
      and pv.approved_at is not null
      and sp.template_code='T5';

    if v_source_profile_id is null then
      raise exception 'base profile version is not an approved T5 profile in this import scope'
        using errcode='check_violation';
    end if;
  else
    v_source_label := nullif(btrim(p_source_label),'');
    if v_source_label is null then
      raise exception 'source_label is required when no base profile is selected'
        using errcode='check_violation';
    end if;

    select id into v_source_profile_id
    from public.source_profile
    where organisation_id=v_batch.organisation_id
      and outlet_id=v_batch.outlet_id
      and template_code='T5'
      and source_label=v_source_label
    for update;

    if v_source_profile_id is null then
      insert into public.source_profile(
        organisation_id,outlet_id,template_code,source_label
      )
      values(
        v_batch.organisation_id,v_batch.outlet_id,'T5',v_source_label
      )
      returning id into v_source_profile_id;
    end if;
  end if;

  select coalesce(max(version_no),0)+1 into v_version_no
  from public.profile_version
  where source_profile_id=v_source_profile_id;

  v_layout := jsonb_build_object(
    'selected_sheet_name',v_batch.parse_metadata_json->>'selected_sheet_name',
    'headers',coalesce(v_batch.parse_metadata_json->'headers','[]'::jsonb),
    'field_map',coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb)
  );
  v_components := coalesce(
    v_batch.parse_metadata_json->'fingerprint_components','{}'::jsonb
  );

  if not exists(
    select 1
    from jsonb_each_text(coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb))
    where value='period'
  ) then
    v_transform_config := jsonb_build_array(
      jsonb_build_object(
        'code','fixed_value',
        'target_field','period',
        'value',v_batch.parse_metadata_json->>'target_period'
      )
    );
  end if;

  insert into public.profile_version(
    organisation_id,outlet_id,source_profile_id,version_no,
    layout_json,fingerprint_hash,fingerprint_components_json,
    transform_config_json,supersedes_profile_version_id
  )
  values(
    v_batch.organisation_id,v_batch.outlet_id,v_source_profile_id,v_version_no,
    v_layout,v_batch.detected_fingerprint,v_components,v_transform_config,
    p_base_profile_version_id
  )
  returning id into v_new_profile_id;

  insert into public.column_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_column,canonical_field,required
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
    key,value,
    value in ('role_group','actual_hours','actual_cost')
  from jsonb_each_text(
    coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb)
  );

  if p_base_profile_version_id is not null then
    insert into public.value_mapping(
      organisation_id,outlet_id,profile_version_id,
      field_name,source_value,canonical_value
    )
    select
      v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
      'labour_activity_basis',source_value,canonical_value
    from public.value_mapping
    where profile_version_id=p_base_profile_version_id
      and lower(btrim(field_name))='labour_activity_basis';
  end if;

  insert into public.value_mapping(
    organisation_id,outlet_id,profile_version_id,
    field_name,source_value,canonical_value
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
    'labour_activity_basis',
    btrim(item->>'source_role_group'),
    btrim(item->>'activity_basis')
  from jsonb_array_elements(p_activity_basis_mappings) item
  where nullif(btrim(item->>'source_role_group'),'') is not null
    and nullif(btrim(item->>'activity_basis'),'') is not null
  on conflict(profile_version_id,field_name,source_value)
  do update set canonical_value=excluded.canonical_value;

  if exists(
    select 1
    from public.staging_row s
    where s.batch_id=v_batch.id
      and s.parsed_jsonb ? 'activity_units'
      and nullif(btrim(coalesce(s.parsed_jsonb->>'activity_basis','')),'') is null
      and not exists(
        select 1
        from public.value_mapping vm
        where vm.profile_version_id=v_new_profile_id
          and lower(btrim(vm.field_name))='labour_activity_basis'
          and lower(btrim(vm.source_value))=
              lower(btrim(s.parsed_jsonb->>'role_group'))
          and length(btrim(vm.canonical_value))>0
      )
  ) then
    raise exception 'every T5 row with activity units requires an explicit source or approved role-group activity basis'
      using errcode='check_violation';
  end if;

  update public.profile_version
  set status='approved',approved_by=v_user_id,approved_at=now()
  where id=v_new_profile_id;

  update public.source_profile
  set active_profile_version_id=v_new_profile_id,updated_at=now()
  where id=v_source_profile_id;

  update public.import_batch
  set profile_version_id=v_new_profile_id,
      candidate_profile_version_id=null,
      status='validating'
  where id=v_batch.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_batch.organisation_id,v_batch.outlet_id,
    'LABOUR_MAPPING_CONFIRMED','profile_version',
    v_new_profile_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'profile_version_id',v_new_profile_id,
    'version_no',v_version_no,
    'batch_status','validating'
  )
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select
    v_new_profile_id,v_version_no,'validating'::public.batch_status,false;
end
$$;

revoke all on function confirm_labour_mapping(uuid,text,text,uuid,jsonb,text)
  from public;
grant execute on function confirm_labour_mapping(uuid,text,text,uuid,jsonb,text)
  to restaurant_app;


create or replace function _commit_labour_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null,
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
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_batch public.import_batch%rowtype;
  v_existing jsonb;
  v_operation text := 'import.commit.labour:'||p_batch_id::text;
  v_period_month text;
  v_fact_count bigint := 0;
  v_hash text;
  v_summary jsonb;
  v_actual_total numeric(20,4);
  v_comparator_total numeric(20,4);
  v_pnl_actual numeric(20,4);
  v_pnl_comparator numeric(20,4);
  v_comparator_scenario public.scenario_code;
  v_actual_diff numeric;
  v_comparator_diff numeric;
  v_ready_status text := 'partial';
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;
  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;
  if p_fault_after_step is not null
     and (p_fault_after_step<1 or p_fault_after_step>8) then
    raise exception 'fault injection step must be between 1 and 8'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_batch from public.import_batch where id=p_batch_id for update;
  if v_batch.id is null then
    raise exception 'import batch not found' using errcode='no_data_found';
  end if;
  if not public.has_org_role(
       v_batch.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_batch.organisation_id,v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode='insufficient_privilege';
  end if;
  if v_batch.template_code<>'T5' then
    raise exception 'Labour commit supports T5 only'
      using errcode='feature_not_supported';
  end if;
  if v_batch.scenario<>'actual' then
    raise exception 'T5 canonical Labour inputs use actual scenario'
      using errcode='check_violation';
  end if;
  if p_fault_after_step=1 then raise exception 'FAULT_STEP_1'; end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'committed_batch_id',false) then
    return query select
      (v_existing->>'committed_batch_id')::uuid,
      (v_existing->>'commit_status')::public.batch_status,
      (v_existing->>'fact_count')::bigint,
      v_existing->>'commit_hash',
      true;
    return;
  end if;

  if v_batch.status='committed' then
    select count(*) into v_fact_count
    from public.labour_fact where batch_id=v_batch.id;

    update public.request_idempotency
    set response_json=jsonb_build_object(
      'committed_batch_id',v_batch.id,
      'commit_status','committed',
      'fact_count',v_fact_count,
      'commit_hash',v_batch.canonical_commit_hash
    )
    where user_id=v_user_id and operation=v_operation
      and idempotency_key=p_idempotency_key;

    return query select
      v_batch.id,'committed'::public.batch_status,v_fact_count,
      v_batch.canonical_commit_hash,true;
    return;
  end if;

  if v_batch.status not in ('ready','warning') then
    raise exception 'batch status % is not committable',v_batch.status
      using errcode='check_violation';
  end if;
  if public.batch_has_unresolved_blocks(v_batch.id) then
    raise exception 'batch has unresolved block validations'
      using errcode='check_violation';
  end if;
  if p_fault_after_step=2 then raise exception 'FAULT_STEP_2'; end if;

  if v_batch.period_id is null or v_batch.profile_version_id is null then
    raise exception 'batch requires reporting period and profile version before commit'
      using errcode='check_violation';
  end if;
  if not exists(
    select 1 from public.profile_version pv
    where pv.id=v_batch.profile_version_id
      and pv.organisation_id=v_batch.organisation_id
      and pv.outlet_id=v_batch.outlet_id
      and pv.status='approved' and pv.approved_at is not null
  ) then
    raise exception 'batch profile version is not approved'
      using errcode='check_violation';
  end if;

  select to_char(period_start,'YYYY-MM') into v_period_month
  from public.reporting_period
  where id=v_batch.period_id
    and organisation_id=v_batch.organisation_id
    and outlet_id=v_batch.outlet_id;

  if v_period_month is null then
    raise exception 'batch reporting period is not available'
      using errcode='check_violation';
  end if;
  if not exists(select 1 from public.staging_row where batch_id=v_batch.id) then
    raise exception 'batch has no staging rows'
      using errcode='check_violation';
  end if;
  if exists(
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id
      and (
        s.parsed_jsonb is null
        or s.parsed_jsonb->>'period' is distinct from v_period_month
      )
  ) then
    raise exception 'Labour staging rows are not bound to the batch reporting period'
      using errcode='check_violation';
  end if;
  if p_fault_after_step=3 then raise exception 'FAULT_STEP_3'; end if;

  if exists(
    select 1
    from public.staging_row s
    left join public.value_mapping vm
      on vm.profile_version_id=v_batch.profile_version_id
     and lower(btrim(vm.field_name))='labour_activity_basis'
     and lower(btrim(vm.source_value))=
         lower(btrim(s.parsed_jsonb->>'role_group'))
    where s.batch_id=v_batch.id
      and (
        nullif(btrim(coalesce(s.parsed_jsonb->>'role_group','')),'') is null
        or nullif(s.parsed_jsonb->>'actual_hours','') is null
        or (s.parsed_jsonb->>'actual_hours')::numeric < 0
        or nullif(s.parsed_jsonb->>'actual_cost','') is null
        or (
          s.parsed_jsonb ? 'activity_units'
          and nullif(btrim(coalesce(s.parsed_jsonb->>'activity_basis',vm.canonical_value,'')),'') is null
        )
      )
  ) then
    raise exception 'T5 staging contains an invalid role/hours/cost/activity-basis row'
      using errcode='check_violation';
  end if;

  insert into public.labour_fact(
    organisation_id,outlet_id,period_id,role_group,
    actual_hours,comparator_hours,actual_cost,comparator_cost,
    scheduled_hours,overtime_hours,activity_units,activity_basis,
    comparator_scenario,notes,
    batch_id,profile_version_id,staging_row_id
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_batch.period_id,
    btrim(s.parsed_jsonb->>'role_group'),
    (s.parsed_jsonb->>'actual_hours')::numeric,
    nullif(s.parsed_jsonb->>'comparator_hours','')::numeric,
    (s.parsed_jsonb->>'actual_cost')::numeric,
    nullif(s.parsed_jsonb->>'comparator_cost','')::numeric,
    nullif(s.parsed_jsonb->>'scheduled_hours','')::numeric,
    nullif(s.parsed_jsonb->>'overtime_hours','')::numeric,
    nullif(s.parsed_jsonb->>'activity_units','')::numeric,
    coalesce(
      nullif(btrim(s.parsed_jsonb->>'activity_basis'),''),
      nullif(btrim(vm.canonical_value),'')
    ),
    nullif(s.parsed_jsonb->>'comparator_scenario','')::public.scenario_code,
    nullif(btrim(s.parsed_jsonb->>'notes'),''),
    v_batch.id,v_batch.profile_version_id,s.id
  from public.staging_row s
  left join public.value_mapping vm
    on vm.profile_version_id=v_batch.profile_version_id
   and lower(btrim(vm.field_name))='labour_activity_basis'
   and lower(btrim(vm.source_value))=
       lower(btrim(s.parsed_jsonb->>'role_group'))
  where s.batch_id=v_batch.id
  order by s.source_row_no
  on conflict(batch_id,staging_row_id) do nothing;

  select count(*) into v_fact_count
  from public.labour_fact where batch_id=v_batch.id;
  if v_fact_count=0 then
    raise exception 'Labour commit produced zero canonical facts'
      using errcode='check_violation';
  end if;
  if p_fault_after_step=4 then raise exception 'FAULT_STEP_4'; end if;

  if (
    select count(distinct comparator_scenario)
    from public.labour_fact
    where batch_id=v_batch.id and comparator_scenario is not null
  ) > 1 then
    raise exception 'T5 batch contains more than one comparator scenario'
      using errcode='check_violation';
  end if;

  select
    sum(actual_cost),
    sum(comparator_cost),
    max(comparator_scenario::text)::public.scenario_code
  into v_actual_total,v_comparator_total,v_comparator_scenario
  from public.labour_fact
  where batch_id=v_batch.id;

  select jsonb_build_object(
    'fact_count',count(*),
    'actual_hours_total',sum(actual_hours),
    'actual_cost_total',sum(actual_cost),
    'comparator_hours_total',sum(comparator_hours),
    'comparator_cost_total',sum(comparator_cost),
    'activity_unit_rollup','PROHIBITED_ACROSS_ROLE_GROUPS'
  )
  into v_summary
  from public.labour_fact where batch_id=v_batch.id;

  if p_fault_after_step=5 then raise exception 'FAULT_STEP_5'; end if;

  select encode(public.digest(convert_to(string_agg(
    concat_ws('|',
      lower(btrim(f.role_group)),
      f.actual_hours::text,
      coalesce(f.comparator_hours::text,''),
      f.actual_cost::text,
      coalesce(f.comparator_cost::text,''),
      coalesce(f.scheduled_hours::text,''),
      coalesce(f.overtime_hours::text,''),
      coalesce(f.activity_units::text,''),
      coalesce(lower(btrim(f.activity_basis)),''),
      coalesce(f.comparator_scenario::text,''),
      f.profile_version_id::text,
      f.staging_row_id::text
    ),
    E'\n' order by s.source_row_no,f.id
  ),'UTF8'),'sha256'),'hex')
  into v_hash
  from public.labour_fact f
  join public.staging_row s on s.id=f.staging_row_id
  where f.batch_id=v_batch.id;

  if v_hash is null then
    raise exception 'canonical Labour checksum could not be produced'
      using errcode='check_violation';
  end if;
  if p_fault_after_step=6 then raise exception 'FAULT_STEP_6'; end if;

  update public.import_batch
  set status='committed',
      committed_by=v_user_id,
      committed_at=now(),
      canonical_commit_hash=v_hash,
      canonical_commit_summary=v_summary
  where id=v_batch.id;

  if p_fault_after_step=7 then raise exception 'FAULT_STEP_7'; end if;

  select sum(ff.amount) into v_pnl_actual
  from public.financial_fact ff
  join public.import_batch b on b.id=ff.batch_id
  join public.ladder_line ll on ll.id=ff.ladder_line_id
  where ff.organisation_id=v_batch.organisation_id
    and ff.outlet_id=v_batch.outlet_id
    and ff.period_id=v_batch.period_id
    and b.template_code='T1'
    and b.scenario='actual'
    and b.status='committed'
    and ll.code='DIRECT_LABOUR';

  if v_comparator_scenario is not null then
    select sum(ff.amount) into v_pnl_comparator
    from public.financial_fact ff
    join public.import_batch b on b.id=ff.batch_id
    join public.ladder_line ll on ll.id=ff.ladder_line_id
    where ff.organisation_id=v_batch.organisation_id
      and ff.outlet_id=v_batch.outlet_id
      and ff.period_id=v_batch.period_id
      and b.template_code='T6'
      and b.scenario=v_comparator_scenario
      and b.status='committed'
      and ll.code='DIRECT_LABOUR';
  end if;

  if v_pnl_actual is not null and v_pnl_actual<>0 then
    v_actual_diff := abs(v_actual_total-v_pnl_actual)/abs(v_pnl_actual);
  elsif v_pnl_actual=0 then
    v_actual_diff := case when coalesce(v_actual_total,0)=0 then 0 else null end;
  end if;

  if v_pnl_comparator is not null and v_pnl_comparator<>0
     and v_comparator_total is not null then
    v_comparator_diff :=
      abs(v_comparator_total-v_pnl_comparator)/abs(v_pnl_comparator);
  elsif v_pnl_comparator=0 and v_comparator_total is not null then
    v_comparator_diff :=
      case when v_comparator_total=0 then 0 else null end;
  end if;

  if v_pnl_actual is null then
    v_ready_status := 'partial';
  elsif v_actual_diff is null or v_actual_diff>0.005 then
    v_ready_status := 'not_reconciled';
  elsif v_comparator_total is null then
    v_ready_status := 'ready';
  elsif v_comparator_scenario is null or v_pnl_comparator is null then
    v_ready_status := 'partial';
  elsif v_comparator_diff is not null and v_comparator_diff<=0.005 then
    v_ready_status := 'ready';
  else
    v_ready_status := 'not_reconciled';
  end if;

  insert into public.data_readiness(
    organisation_id,outlet_id,period_id,capability_code,
    status,latest_batch_id,details_json
  )
  values(
    v_batch.organisation_id,v_batch.outlet_id,v_batch.period_id,
    'labour_inputs',v_ready_status,v_batch.id,
    jsonb_build_object(
      't5_committed',true,
      'pnl_direct_labour',v_pnl_actual,
      't5_actual_labour_cost',v_actual_total,
      'actual_pnl_relative_difference',v_actual_diff,
      'comparator_scenario',v_comparator_scenario,
      'pnl_comparator_direct_labour',v_pnl_comparator,
      't5_comparator_labour_cost',v_comparator_total,
      'comparator_pnl_relative_difference',v_comparator_diff,
      'actual_pnl_tie',coalesce(v_actual_diff<=0.005,false),
      'comparator_pnl_tie',
        case
          when v_comparator_total is null then null
          else coalesce(v_comparator_diff<=0.005,false)
        end,
      'tolerance_ratio',0.005,
      'activity_unit_rollup','PROHIBITED_ACROSS_ROLE_GROUPS'
    )
  )
  on conflict(organisation_id,outlet_id,period_id,capability_code)
  do update set
    status=excluded.status,
    latest_batch_id=excluded.latest_batch_id,
    details_json=excluded.details_json,
    updated_at=now();

  if p_fault_after_step=8 then raise exception 'FAULT_STEP_8'; end if;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,after_hash,correlation_id
  )
  values(
    v_user_id,v_batch.organisation_id,v_batch.outlet_id,
    'LABOUR_IMPORT_BATCH_COMMITTED','import_batch',
    v_batch.id::text,v_hash,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'committed_batch_id',v_batch.id,
    'commit_status','committed',
    'fact_count',v_fact_count,
    'commit_hash',v_hash
  )
  where user_id=v_user_id and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select
    v_batch.id,'committed'::public.batch_status,v_fact_count,v_hash,false;
end
$$;


create or replace function commit_labour_import_batch(
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
language plpgsql
security definer
set search_path=''
as $$
begin
  if p_queue_calc then
    raise exception 'Labour/Other Cost calculation queueing is introduced in S7-3'
      using errcode='check_violation';
  end if;

  return query
  select * from public._commit_labour_import_batch(
    p_batch_id,p_idempotency_key,p_correlation_id,null
  );
end
$$;

revoke all on function _commit_labour_import_batch(uuid,text,text,integer)
  from public;
revoke all on function commit_labour_import_batch(uuid,text,text,boolean)
  from public;
grant execute on function commit_labour_import_batch(uuid,text,text,boolean)
  to restaurant_app;
