-- 0029 · Deterministic Owner Pack artefact attachment
-- Completes SC14's server-rendered private artefact path. The rendered file
-- carries both its byte SHA-256 and a SHA-256 of the authoritative pack source
-- snapshot so sign-off can reject a stale render after content changes.

alter table pack_version
  add column artifact_source_sha256 text
  check (
    artifact_source_sha256 is null
    or artifact_source_sha256 ~ '^[0-9a-f]{64}$'
  );

alter table pack_version
  add constraint pack_artifact_source_hash_complete_check
  check (
    (
      artifact_path is null
      and artifact_source_sha256 is null
    )
    or
    (
      artifact_path is not null
      and artifact_source_sha256 is not null
    )
  );

alter table pack_version
  add constraint pack_signed_has_source_hash_check
  check (
    status <> 'signed'
    or artifact_source_sha256 is not null
  );


create or replace function guard_pack_version_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op='DELETE' then
    raise exception 'pack versions are retained; delete is not permitted'
      using errcode='restrict_violation';
  end if;

  if old.status='signed' then
    raise exception 'signed pack version is immutable'
      using errcode='restrict_violation';
  end if;

  if (
    to_jsonb(new) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'artifact_source_sha256',
      'renderer_version','template_version',
      'updated_at'
    ]
  ) <> (
    to_jsonb(old) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'artifact_source_sha256',
      'renderer_version','template_version',
      'updated_at'
    ]
  ) then
    raise exception 'pack version identity and calc snapshot are immutable'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;


create or replace function attach_pack_artifact(
  p_pack_version_id uuid,
  p_artifact_bucket text,
  p_artifact_path text,
  p_artifact_sha256 text,
  p_artifact_source_sha256 text,
  p_renderer_version text,
  p_template_version text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  pack_version_id uuid,
  artifact_sha256 text,
  artifact_source_sha256 text,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_pack public.pack_version%rowtype;
  v_expected_prefix text;
  v_existing jsonb;
  v_operation text := 'pack.artifact.attach:'||p_pack_version_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if nullif(btrim(p_artifact_bucket),'') is null
     or nullif(btrim(p_artifact_path),'') is null
     or nullif(btrim(p_renderer_version),'') is null
     or nullif(btrim(p_template_version),'') is null
     or p_artifact_sha256 !~ '^[0-9a-f]{64}$'
     or p_artifact_source_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'complete valid Owner Pack artefact metadata is required'
      using errcode='check_violation';
  end if;

  select * into v_pack
  from public.pack_version
  where id=p_pack_version_id
  for update;

  if v_pack.id is null
     or v_pack.status='signed'
     or not public.has_org_role(
       v_pack.organisation_id,
       array['admin','editor','reviewer']::public.app_role[]
     )
     or not public.has_outlet_access(v_pack.organisation_id,v_pack.outlet_id) then
    raise exception 'pack artefact is not writable in the current context'
      using errcode='insufficient_privilege';
  end if;

  v_expected_prefix :=
    'org/'||v_pack.organisation_id::text||
    '/outlet/'||v_pack.outlet_id::text||
    '/packs/'||v_pack.id::text||'/';

  if left(p_artifact_path,length(v_expected_prefix)) <> v_expected_prefix then
    raise exception 'pack artefact path must start with %',v_expected_prefix
      using errcode='check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'pack_version_id',false) then
    return query select
      (v_existing->>'pack_version_id')::uuid,
      v_existing->>'artifact_sha256',
      v_existing->>'artifact_source_sha256',
      true;
    return;
  end if;

  update public.pack_version
  set artifact_bucket=btrim(p_artifact_bucket),
      artifact_path=btrim(p_artifact_path),
      artifact_sha256=p_artifact_sha256,
      artifact_source_sha256=p_artifact_source_sha256,
      renderer_version=btrim(p_renderer_version),
      template_version=btrim(p_template_version),
      updated_at=now()
  where id=v_pack.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,
    before_hash,after_hash,correlation_id
  )
  values(
    v_user_id,v_pack.organisation_id,v_pack.outlet_id,
    'PACK_ARTIFACT_RENDERED','pack_version',v_pack.id::text,
    v_pack.artifact_sha256,p_artifact_sha256,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'pack_version_id',v_pack.id,
    'artifact_sha256',p_artifact_sha256,
    'artifact_source_sha256',p_artifact_source_sha256
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select
    v_pack.id,
    p_artifact_sha256,
    p_artifact_source_sha256,
    false;
end
$$;


revoke all on function attach_pack_artifact(
  uuid,text,text,text,text,text,text,text,text
) from public;

-- Intentionally no grant to restaurant_app. Only the trusted server database
-- role may attach rendered artefact metadata after it has written the object.
