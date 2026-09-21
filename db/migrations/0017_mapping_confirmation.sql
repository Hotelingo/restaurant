-- 0017 · First-run and drift mapping confirmation for T1/T6
-- Forward-fix mapping triggers so they remain safe when invoked from a
-- SECURITY DEFINER function whose search_path is intentionally empty.
create or replace function ensure_active_profile_version_approved()
returns trigger
language plpgsql
as $$
begin
  if new.active_profile_version_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from public.profile_version pv
    where pv.id = new.active_profile_version_id
      and pv.organisation_id = new.organisation_id
      and pv.outlet_id = new.outlet_id
      and pv.source_profile_id = new.id
      and pv.status = 'approved'
      and pv.approved_at is not null
  ) then
    raise exception 'active profile version must be an approved version of the same source profile'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create or replace function forbid_mapping_mutation_when_profile_approved()
returns trigger
language plpgsql
as $$
declare
  target_profile_version_id uuid;
begin
  if tg_op = 'DELETE' then
    target_profile_version_id := old.profile_version_id;
  else
    target_profile_version_id := new.profile_version_id;
  end if;

  if exists (
    select 1
    from public.profile_version pv
    where pv.id = target_profile_version_id
      and pv.approved_at is not null
  ) then
    raise exception
      'mapping is immutable because profile version % is approved',
      target_profile_version_id
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

-- Creates a new immutable profile version, optionally cloning identity mappings
-- from an approved base version. Amounts never participate in mapping decisions.

create or replace function confirm_financial_mapping(
  p_batch_id uuid,
  p_idempotency_key text,
  p_source_label text default null,
  p_base_profile_version_id uuid default null,
  p_account_mappings jsonb default '[]'::jsonb,
  p_management_line_mappings jsonb default '[]'::jsonb,
  p_correlation_id text default null
)
returns table (
  profile_version_id uuid,
  version_no integer,
  batch_status public.batch_status,
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
  v_operation text := 'import.mapping.confirm:' || p_batch_id::text;
  v_base_profile_id uuid;
  v_source_profile_id uuid;
  v_new_profile_id uuid;
  v_version_no integer;
  v_layout jsonb;
  v_components jsonb;
  v_transform_config jsonb := '[]'::jsonb;
  v_ladder_grain_t6 boolean := false;
  v_source_label text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(coalesce(p_account_mappings,'[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_management_line_mappings,'[]'::jsonb)) <> 'array' then
    raise exception 'mapping payloads must be JSON arrays'
      using errcode = 'invalid_parameter_value';
  end if;

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
     or not public.has_outlet_access(v_batch.organisation_id,v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
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

  if coalesce(v_existing ? 'profile_version_id',false) then
    return query
      select
        (v_existing->>'profile_version_id')::uuid,
        (v_existing->>'version_no')::integer,
        (v_existing->>'batch_status')::public.batch_status,
        true;
    return;
  end if;

  if v_batch.status <> 'needs_mapping' then
    raise exception 'batch status % does not accept mapping confirmation',v_batch.status
      using errcode = 'check_violation';
  end if;

  if v_batch.template_code not in ('T1','T6') then
    raise exception 'financial mapping confirmation supports T1 and T6 only'
      using errcode = 'feature_not_supported';
  end if;

  if v_batch.detected_fingerprint is null
     or v_batch.parse_completed_at is null
     or v_batch.parse_metadata_json = '{}'::jsonb then
    raise exception 'batch must be parsed and fingerprinted before mapping confirmation'
      using errcode = 'check_violation';
  end if;

  if exists (
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id
      and jsonb_array_length(s.parse_errors)>0
  ) then
    raise exception 'parse errors must be corrected before mapping confirmation'
      using errcode = 'check_violation';
  end if;

  v_base_profile_id := coalesce(
    p_base_profile_version_id,
    v_batch.candidate_profile_version_id
  );

  if v_base_profile_id is not null then
    select pv.source_profile_id
      into v_source_profile_id
    from public.profile_version pv
    join public.source_profile sp on sp.id=pv.source_profile_id
    where pv.id=v_base_profile_id
      and pv.organisation_id=v_batch.organisation_id
      and pv.outlet_id=v_batch.outlet_id
      and pv.status='approved'
      and pv.approved_at is not null
      and sp.template_code=v_batch.template_code;

    if v_source_profile_id is null then
      raise exception 'base profile version is not an approved profile in this import scope'
        using errcode = 'check_violation';
    end if;
  else
    v_source_label := nullif(btrim(p_source_label),'');
    if v_source_label is null then
      raise exception 'source_label is required when no base profile is selected'
        using errcode = 'check_violation';
    end if;

    select sp.id into v_source_profile_id
    from public.source_profile sp
    where sp.organisation_id=v_batch.organisation_id
      and sp.outlet_id=v_batch.outlet_id
      and sp.template_code=v_batch.template_code
      and sp.source_label=v_source_label
    for update;

    if v_source_profile_id is null then
      insert into public.source_profile(
        organisation_id,outlet_id,template_code,source_label
      )
      values (
        v_batch.organisation_id,
        v_batch.outlet_id,
        v_batch.template_code,
        v_source_label
      )
      returning id into v_source_profile_id;
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_source_profile_id::text,1903)
  );

  select coalesce(max(pv.version_no),0)+1
    into v_version_no
  from public.profile_version pv
  where pv.source_profile_id=v_source_profile_id;

  v_components := v_batch.parse_metadata_json->'fingerprint_components';
  if jsonb_typeof(v_components) <> 'object' then
    raise exception 'batch fingerprint components are missing'
      using errcode = 'check_violation';
  end if;

  v_layout := jsonb_build_object(
    'headers',coalesce(v_batch.parse_metadata_json->'headers','[]'::jsonb),
    'sheet_name',v_batch.parse_metadata_json->>'selected_sheet_name',
    'field_map',coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb),
    'month_columns',coalesce(v_batch.parse_metadata_json->'month_columns','[]'::jsonb),
    'target_period',v_batch.parse_metadata_json->>'target_period'
  );

  if jsonb_array_length(
       coalesce(v_batch.parse_metadata_json->'month_columns','[]'::jsonb)
     ) > 0 then
    v_transform_config := jsonb_build_array(
      jsonb_build_object(
        'code','unpivot_month_columns',
        'params',jsonb_build_object(
          'month_columns',v_batch.parse_metadata_json->'month_columns'
        )
      )
    );
  end if;

  insert into public.profile_version(
    organisation_id,outlet_id,source_profile_id,version_no,
    layout_json,fingerprint_hash,fingerprint_components_json,
    transform_config_json,status,supersedes_profile_version_id
  )
  values (
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_source_profile_id,
    v_version_no,
    v_layout,
    v_batch.detected_fingerprint,
    v_components,
    v_transform_config,
    'draft',
    case when v_base_profile_id is not null then v_base_profile_id else null end
  )
  returning id into v_new_profile_id;

  insert into public.column_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_column,canonical_field,required
  )
  select
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_new_profile_id,
    field.key,
    field.value,
    field.value in ('account_name','management_line','period','amount')
  from jsonb_each_text(
    coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb)
  ) field;

  if jsonb_array_length(
       coalesce(v_batch.parse_metadata_json->'month_columns','[]'::jsonb)
     ) > 0 then
    insert into public.transform_rule(
      organisation_id,outlet_id,profile_version_id,
      sequence_no,transform_code,target_field,params_json
    )
    values (
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_new_profile_id,
      1,
      'unpivot_month_columns',
      'amount',
      jsonb_build_object(
        'month_columns',v_batch.parse_metadata_json->'month_columns',
        'period_field','period',
        'value_field','amount'
      )
    );
  end if;

  if v_base_profile_id is not null then
    insert into public.account_mapping(
      organisation_id,outlet_id,profile_version_id,
      source_account_code,source_account_name,ladder_line_id,
      mapping_basis,approved_by
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_new_profile_id,
      am.source_account_code,
      am.source_account_name,
      am.ladder_line_id,
      'confirmed',
      v_user_id
    from public.account_mapping am
    where am.profile_version_id=v_base_profile_id;

    insert into public.value_mapping(
      organisation_id,outlet_id,profile_version_id,
      field_name,source_value,canonical_value
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_new_profile_id,
      vm.field_name,
      vm.source_value,
      vm.canonical_value
    from public.value_mapping vm
    where vm.profile_version_id=v_base_profile_id;
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_account_mappings,'[]'::jsonb)) item
    where nullif(btrim(item->>'source_account_name'),'') is null
       or not exists (
         select 1 from public.ladder_line ll
         where ll.code=item->>'ladder_line_code'
           and not ll.is_calculated
       )
  ) then
    raise exception 'account mapping contains a blank identity or invalid/calculated ladder line'
      using errcode = 'check_violation';
  end if;

  insert into public.account_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_account_code,source_account_name,ladder_line_id,
    mapping_basis,approved_by
  )
  select
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_new_profile_id,
    nullif(btrim(item->>'source_account_code'),''),
    btrim(item->>'source_account_name'),
    ll.id,
    'confirmed',
    v_user_id
  from jsonb_array_elements(coalesce(p_account_mappings,'[]'::jsonb)) item
  join public.ladder_line ll
    on ll.code=item->>'ladder_line_code'
   and not ll.is_calculated
  on conflict (profile_version_id,source_identity_key)
  do update set
    source_account_code=excluded.source_account_code,
    source_account_name=excluded.source_account_name,
    ladder_line_id=excluded.ladder_line_id,
    mapping_basis='confirmed',
    approved_by=v_user_id;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_management_line_mappings,'[]'::jsonb)) item
    where nullif(btrim(item->>'source_value'),'') is null
       or not exists (
         select 1 from public.ladder_line ll
         where ll.code=item->>'ladder_line_code'
           and not ll.is_calculated
       )
  ) then
    raise exception 'management-line mapping contains a blank identity or invalid/calculated ladder line'
      using errcode = 'check_violation';
  end if;

  insert into public.value_mapping(
    organisation_id,outlet_id,profile_version_id,
    field_name,source_value,canonical_value
  )
  select
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_new_profile_id,
    'management_line',
    btrim(item->>'source_value'),
    item->>'ladder_line_code'
  from jsonb_array_elements(coalesce(p_management_line_mappings,'[]'::jsonb)) item
  on conflict (profile_version_id,field_name,source_value)
  do update set canonical_value=excluded.canonical_value;

  if v_batch.template_code='T6' then
    select exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'management_line'),'') is not null
    ) into v_ladder_grain_t6;

    if v_ladder_grain_t6 and exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'management_line'),'') is null
    ) then
      raise exception 'T6 cannot mix account-grain and ladder-grain rows'
        using errcode = 'check_violation';
    end if;
  end if;

  if v_batch.template_code='T1'
     or (v_batch.template_code='T6' and not v_ladder_grain_t6) then
    if exists (
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists (
          select 1
          from public.account_mapping am
          join public.ladder_line ll
            on ll.id=am.ladder_line_id and not ll.is_calculated
          where am.profile_version_id=v_new_profile_id
            and am.source_identity_key=(
              case
                when nullif(btrim(s.parsed_jsonb->>'account_code'),'') is not null
                  then 'code:'||lower(btrim(s.parsed_jsonb->>'account_code'))
                else 'name:'||lower(btrim(s.parsed_jsonb->>'account_name'))
              end
            )
        )
    ) then
      raise exception 'not every staged account identity has a confirmed mapping'
        using errcode = 'check_violation';
    end if;
  else
    if exists (
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists (
          select 1
          from public.value_mapping vm
          join public.ladder_line ll
            on ll.code=vm.canonical_value and not ll.is_calculated
          where vm.profile_version_id=v_new_profile_id
            and lower(btrim(vm.field_name))='management_line'
            and lower(btrim(vm.source_value))=
                lower(btrim(s.parsed_jsonb->>'management_line'))
        )
    ) then
      raise exception 'not every staged management line has a confirmed mapping'
        using errcode = 'check_violation';
    end if;
  end if;

  update public.profile_version
  set status='approved',
      approved_by=v_user_id,
      approved_at=now()
  where id=v_new_profile_id;

  update public.source_profile
  set active_profile_version_id=v_new_profile_id
  where id=v_source_profile_id;

  update public.import_batch
  set profile_version_id=v_new_profile_id,
      status='validating'
  where id=v_batch.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values (
    v_user_id,
    v_batch.organisation_id,
    v_batch.outlet_id,
    'IMPORT_MAPPING_CONFIRMED',
    'profile_version',
    v_new_profile_id::text,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'profile_version_id',v_new_profile_id,
    'version_no',v_version_no,
    'batch_status','validating'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query
    select
      v_new_profile_id,
      v_version_no,
      'validating'::public.batch_status,
      false;
end
$$;

revoke all on function confirm_financial_mapping(
  uuid,text,text,uuid,jsonb,jsonb,text
) from public;

grant execute on function confirm_financial_mapping(
  uuid,text,text,uuid,jsonb,jsonb,text
) to restaurant_app;
