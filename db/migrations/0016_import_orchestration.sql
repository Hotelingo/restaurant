-- 0016 · Import orchestration metadata and profile-match settings
-- Keeps parser/fingerprint logic pure while persisting the selected period,
-- fingerprint evidence and matching decision needed by the API workflow.

alter table import_batch
  add column parse_metadata_json jsonb not null default '{}'::jsonb,
  add column profile_match_tier text,
  add column profile_match_message text,
  add column candidate_profile_version_id uuid,
  add column parse_completed_at timestamptz;

alter table import_batch
  add constraint import_batch_parse_metadata_object_check
    check (jsonb_typeof(parse_metadata_json) = 'object'),
  add constraint import_batch_profile_match_tier_check
    check (
      profile_match_tier is null
      or profile_match_tier in (
        'exact',
        'new_rows_only',
        'renamed_moved_columns',
        'different_layout',
        'manual_resolution'
      )
    ),
  add constraint import_batch_profile_match_message_check
    check (
      profile_match_message is null
      or length(btrim(profile_match_message)) > 0
    ),
  add constraint import_batch_candidate_profile_same_tenant_fk
    foreign key (
      organisation_id, outlet_id, candidate_profile_version_id
    )
    references profile_version(
      organisation_id, outlet_id, id
    );

-- Profile matching thresholds are outlet settings, not hidden code constants.
alter table setting
  drop constraint setting_supported_key_check;

alter table setting
  add constraint setting_supported_key_check
  check (
    key in (
      'primary_comparator',
      'tax_basis',
      'sign_convention',
      'popularity_factor',
      'reconciliation_pos_to_pl_pct',
      'reconciliation_purchases_to_pl_pct',
      'reconciliation_pos_item_to_ledger_pct',
      'food_benchmark_pct',
      'beverage_benchmark_pct',
      'gap_benchmark',
      'reporting_calendar',
      'display_preferences',
      'import_profile_match_high',
      'import_profile_match_review',
      'import_header_aliases'
    )
  );

create or replace function seed_import_profile_settings()
returns trigger
language plpgsql
as $$
begin
  insert into setting(
    organisation_id,outlet_id,key,value_json,updated_by
  )
  values
    (new.organisation_id,new.id,'import_profile_match_high','0.92'::jsonb,null),
    (new.organisation_id,new.id,'import_profile_match_review','0.75'::jsonb,null),
    (new.organisation_id,new.id,'import_header_aliases','{}'::jsonb,null)
  on conflict (outlet_id,key) do nothing;

  return new;
end
$$;

create trigger outlet_seed_import_profile_settings
  after insert on outlet
  for each row execute function seed_import_profile_settings();

insert into setting(
  organisation_id,outlet_id,key,value_json,updated_by
)
select
  o.organisation_id,
  o.id,
  defaults.key,
  defaults.value_json,
  null
from outlet o
cross join (
  values
    ('import_profile_match_high'::text,'0.92'::jsonb),
    ('import_profile_match_review'::text,'0.75'::jsonb),
    ('import_header_aliases'::text,'{}'::jsonb)
) as defaults(key,value_json)
on conflict (outlet_id,key) do nothing;

create or replace function put_outlet_setting(
  p_outlet_id uuid,
  p_key text,
  p_value_json jsonb,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (setting_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_org_id uuid;
  v_setting_id uuid;
  v_before jsonb;
  v_after jsonb;
  v_existing jsonb;
  v_operation text := 'setting.put:' || p_outlet_id::text || ':' || p_key;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select o.organisation_id into v_org_id
  from public.outlet o
  where o.id = p_outlet_id;

  if v_org_id is null
     or not public.has_org_role(v_org_id, array['admin']::public.app_role[])
     or not public.has_outlet_access(v_org_id, p_outlet_id) then
    raise exception 'outlet is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_key not in (
    'primary_comparator',
    'tax_basis',
    'sign_convention',
    'popularity_factor',
    'reconciliation_pos_to_pl_pct',
    'reconciliation_purchases_to_pl_pct',
    'reconciliation_pos_item_to_ledger_pct',
    'food_benchmark_pct',
    'beverage_benchmark_pct',
    'gap_benchmark',
    'reporting_calendar',
    'display_preferences',
    'import_profile_match_high',
    'import_profile_match_review',
    'import_header_aliases'
  ) then
    raise exception 'unsupported setting key: %', p_key
      using errcode = 'invalid_parameter_value';
  end if;

  if p_idempotency_key is null or length(trim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.request_idempotency (user_id, operation, idempotency_key)
  values (v_user_id, v_operation, p_idempotency_key)
  on conflict (user_id, operation, idempotency_key) do nothing;

  select r.response_json into v_existing
  from public.request_idempotency r
  where r.user_id = v_user_id
    and r.operation = v_operation
    and r.idempotency_key = p_idempotency_key;

  if coalesce(v_existing ? 'setting_id', false) then
    return query select (v_existing->>'setting_id')::uuid;
    return;
  end if;

  select to_jsonb(s) into v_before
  from public.setting s
  where s.outlet_id = p_outlet_id and s.key = p_key
  for update;

  insert into public.setting (
    organisation_id, outlet_id, key, value_json, updated_by
  )
  values (
    v_org_id, p_outlet_id, p_key, p_value_json, v_user_id
  )
  on conflict (outlet_id, key) do update
    set value_json = excluded.value_json,
        updated_by = excluded.updated_by,
        updated_at = now()
  returning id into v_setting_id;

  select to_jsonb(s) into v_after
  from public.setting s
  where s.id = v_setting_id;

  update public.request_idempotency
  set response_json = jsonb_build_object('setting_id', v_setting_id)
  where user_id = v_user_id
    and operation = v_operation
    and idempotency_key = p_idempotency_key;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id,
    before_hash, after_hash, correlation_id
  )
  values (
    v_user_id, v_org_id, p_outlet_id,
    'SETTING_UPSERTED', 'setting', v_setting_id::text,
    case when v_before is null then null
         else encode(public.digest(convert_to(v_before::text,'UTF8'),'sha256'),'hex') end,
    encode(public.digest(convert_to(v_after::text,'UTF8'),'sha256'),'hex'),
    p_correlation_id
  );

  return query select v_setting_id;
end
$$;

revoke all on function put_outlet_setting(uuid,text,jsonb,text,text) from public;
grant execute on function put_outlet_setting(uuid,text,jsonb,text,text)
  to restaurant_app;

-- Forward-fix only after ingestion batches exist. parse_metadata_json and
-- profile-match history are part of the traceability record.
