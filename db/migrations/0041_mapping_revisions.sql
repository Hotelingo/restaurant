-- 0041 · Mapping revisions from the Mappings page
-- A user can change how already-mapped source identities are classified for
-- FUTURE uploads. A revision never edits an approved version: it clones the
-- active approved version of a source profile into a new approved version with
-- the requested changes applied, and makes that the active version. Batches
-- already read keep the version they were read with, so committed facts keep
-- their exact mapping lineage.
--
-- Editable:
--   account_mapping.ladder_line_id                 (T1 / T6 account grain)
--   value_mapping 'management_line' -> ladder code (T6 ladder grain)
--   value_mapping 'product_group'   -> food|beverage (T3)
--   value_mapping 'labour_activity_basis' -> text  (T5)
-- Not editable here: item mappings (bound to the canonical item dimension),
-- column mappings and transforms (they describe the file layout). All of them
-- are carried into the new version unchanged.

create or replace function revise_profile_mappings(
  p_base_profile_version_id uuid,
  p_idempotency_key text,
  p_account_changes jsonb default '[]'::jsonb,
  p_value_changes jsonb default '[]'::jsonb,
  p_correlation_id text default null
)
returns table (
  revised_profile_version_id uuid,
  revised_version_no integer,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_base public.profile_version%rowtype;
  v_profile public.source_profile%rowtype;
  v_existing jsonb;
  v_operation text;
  v_new_profile_id uuid;
  v_version_no integer;
  v_effective_changes integer;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if jsonb_typeof(coalesce(p_account_changes,'[]'::jsonb)) <> 'array'
     or jsonb_typeof(coalesce(p_value_changes,'[]'::jsonb)) <> 'array' then
    raise exception 'mapping changes must be JSON arrays'
      using errcode = 'invalid_parameter_value';
  end if;

  select pv.* into v_base
  from public.profile_version pv
  where pv.id = p_base_profile_version_id;

  -- Same answer for "missing" and "not yours": never confirm another
  -- tenant's identifiers exist.
  if v_base.id is null
     or not public.has_org_role(
       v_base.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_base.organisation_id, v_base.outlet_id) then
    raise exception 'mapping version is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  select sp.* into v_profile
  from public.source_profile sp
  where sp.id = v_base.source_profile_id
  for update;

  v_operation := 'mapping.revise:' || v_profile.id::text;

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
        true;
    return;
  end if;

  if v_base.status <> 'approved' or v_base.approved_at is null then
    raise exception 'only an approved mapping version can be revised'
      using errcode = 'check_violation';
  end if;

  -- Optimistic concurrency: a revision is always made against the version the
  -- user was looking at. If anyone has changed it since, they must reload.
  if v_profile.active_profile_version_id is distinct from v_base.id then
    raise exception 'this mapping has changed since it was opened; reload and try again'
      using errcode = 'check_violation';
  end if;

  -- Account changes: each must name an identity already mapped in the base
  -- version, once, and move it to a non-calculated ladder line.
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_account_changes,'[]'::jsonb)) item
    where nullif(btrim(item->>'source_identity_key'),'') is null
       or not exists (
         select 1 from public.account_mapping am
         where am.profile_version_id = v_base.id
           and am.source_identity_key = item->>'source_identity_key'
       )
       or not exists (
         select 1 from public.ladder_line ll
         where ll.code = item->>'ladder_line_code'
           and not ll.is_calculated
       )
  ) then
    raise exception 'account change names an unknown account or an invalid/calculated P&L line'
      using errcode = 'check_violation';
  end if;

  if (
    select count(*) <> count(distinct item->>'source_identity_key')
    from jsonb_array_elements(coalesce(p_account_changes,'[]'::jsonb)) item
  ) then
    raise exception 'each account may be changed only once per revision'
      using errcode = 'check_violation';
  end if;

  -- Value changes: the (field, source value) must already exist in the base
  -- version and the new canonical value must be valid for that field.
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_value_changes,'[]'::jsonb)) item
    where item->>'field_name' not in
            ('management_line','product_group','labour_activity_basis')
       or item->>'field_name' is null
       or not exists (
         select 1 from public.value_mapping vm
         where vm.profile_version_id = v_base.id
           and vm.field_name = item->>'field_name'
           and vm.source_value = item->>'source_value'
       )
       or (
         item->>'field_name' = 'management_line'
         and not exists (
           select 1 from public.ladder_line ll
           where ll.code = item->>'canonical_value'
             and not ll.is_calculated
         )
       )
       or (
         item->>'field_name' = 'product_group'
         and lower(btrim(coalesce(item->>'canonical_value',''))) not in ('food','beverage')
       )
       or (
         item->>'field_name' = 'labour_activity_basis'
         and (
           nullif(btrim(item->>'canonical_value'),'') is null
           or length(btrim(item->>'canonical_value')) > 120
         )
       )
  ) then
    raise exception 'value change names an unknown source value or an invalid target'
      using errcode = 'check_violation';
  end if;

  if (
    select count(*) <> count(distinct (item->>'field_name', item->>'source_value'))
    from jsonb_array_elements(coalesce(p_value_changes,'[]'::jsonb)) item
  ) then
    raise exception 'each source value may be changed only once per revision'
      using errcode = 'check_violation';
  end if;

  select
    (
      select count(*)
      from jsonb_array_elements(coalesce(p_account_changes,'[]'::jsonb)) item
      join public.account_mapping am
        on am.profile_version_id = v_base.id
       and am.source_identity_key = item->>'source_identity_key'
      join public.ladder_line ll on ll.code = item->>'ladder_line_code'
      where ll.id <> am.ladder_line_id
    )
    +
    (
      select count(*)
      from jsonb_array_elements(coalesce(p_value_changes,'[]'::jsonb)) item
      join public.value_mapping vm
        on vm.profile_version_id = v_base.id
       and vm.field_name = item->>'field_name'
       and vm.source_value = item->>'source_value'
      where vm.canonical_value is distinct from (
        case when item->>'field_name' = 'product_group'
          then lower(btrim(item->>'canonical_value'))
          else btrim(item->>'canonical_value')
        end
      )
    )
  into v_effective_changes;

  if v_effective_changes = 0 then
    raise exception 'no mapping was changed'
      using errcode = 'check_violation';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_profile.id::text,1903)
  );

  select coalesce(max(pv.version_no),0)+1
    into v_version_no
  from public.profile_version pv
  where pv.source_profile_id = v_profile.id;

  insert into public.profile_version(
    organisation_id,outlet_id,source_profile_id,version_no,
    layout_json,fingerprint_hash,fingerprint_components_json,
    transform_config_json,status,supersedes_profile_version_id
  )
  values (
    v_base.organisation_id,
    v_base.outlet_id,
    v_profile.id,
    v_version_no,
    v_base.layout_json,
    v_base.fingerprint_hash,
    v_base.fingerprint_components_json,
    v_base.transform_config_json,
    'draft',
    v_base.id
  )
  returning id into v_new_profile_id;

  insert into public.column_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_column,canonical_field,required
  )
  select organisation_id,outlet_id,v_new_profile_id,
         source_column,canonical_field,required
  from public.column_mapping
  where profile_version_id = v_base.id;

  insert into public.transform_rule(
    organisation_id,outlet_id,profile_version_id,
    sequence_no,transform_code,target_field,params_json
  )
  select organisation_id,outlet_id,v_new_profile_id,
         sequence_no,transform_code,target_field,params_json
  from public.transform_rule
  where profile_version_id = v_base.id;

  insert into public.item_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_item_code,source_item_name,canonical_item_key,
    mapping_basis,approved_by,item_id
  )
  select organisation_id,outlet_id,v_new_profile_id,
         source_item_code,source_item_name,canonical_item_key,
         mapping_basis,approved_by,item_id
  from public.item_mapping
  where profile_version_id = v_base.id;

  -- Changed accounts are re-approved by the reviser; untouched accounts keep
  -- their original approval.
  insert into public.account_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_account_code,source_account_name,ladder_line_id,
    mapping_basis,approved_by
  )
  select
    am.organisation_id,am.outlet_id,v_new_profile_id,
    am.source_account_code,am.source_account_name,
    coalesce(ll.id, am.ladder_line_id),
    case when ll.id is not null and ll.id <> am.ladder_line_id
      then 'confirmed' else am.mapping_basis end,
    case when ll.id is not null and ll.id <> am.ladder_line_id
      then v_user_id else am.approved_by end
  from public.account_mapping am
  left join lateral (
    select item->>'ladder_line_code' as ladder_line_code
    from jsonb_array_elements(coalesce(p_account_changes,'[]'::jsonb)) item
    where item->>'source_identity_key' = am.source_identity_key
  ) change on true
  left join public.ladder_line ll on ll.code = change.ladder_line_code
  where am.profile_version_id = v_base.id;

  insert into public.value_mapping(
    organisation_id,outlet_id,profile_version_id,
    field_name,source_value,canonical_value
  )
  select
    vm.organisation_id,vm.outlet_id,v_new_profile_id,
    vm.field_name,vm.source_value,
    coalesce(
      case when vm.field_name = 'product_group'
        then lower(btrim(change.canonical_value))
        else btrim(change.canonical_value)
      end,
      vm.canonical_value
    )
  from public.value_mapping vm
  left join lateral (
    select item->>'canonical_value' as canonical_value
    from jsonb_array_elements(coalesce(p_value_changes,'[]'::jsonb)) item
    where item->>'field_name' = vm.field_name
      and item->>'source_value' = vm.source_value
  ) change on true
  where vm.profile_version_id = v_base.id;

  update public.profile_version
  set status='approved',
      approved_by=v_user_id,
      approved_at=now()
  where id = v_new_profile_id;

  update public.source_profile
  set active_profile_version_id = v_new_profile_id
  where id = v_profile.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values (
    v_user_id,
    v_base.organisation_id,
    v_base.outlet_id,
    'IMPORT_MAPPING_REVISED',
    'profile_version',
    v_new_profile_id::text,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json = jsonb_build_object(
    'profile_version_id',v_new_profile_id,
    'version_no',v_version_no
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_new_profile_id, v_version_no, false;
end
$$;

revoke all on function revise_profile_mappings(uuid,text,jsonb,jsonb,text) from public;
grant execute on function revise_profile_mappings(uuid,text,jsonb,jsonb,text)
  to restaurant_app;

-- Rollback / forward-fix note:
-- Additive: one function. Before any revision exists it can be dropped. After
-- revisions exist, their profile versions are ordinary approved versions with
-- lineage (supersedes_profile_version_id) and must never be deleted; forward-fix
-- the function instead.
