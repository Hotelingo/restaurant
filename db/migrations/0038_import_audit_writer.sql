-- 0038 · Import audit writer
--
-- Two API routes -- POST /imports/upload and POST /imports/{batch_id}/parse --
-- inserted into audit_log directly. audit_log is append-only and deliberately
-- has no INSERT policy for restaurant_app: every other audit event in the
-- schema is written inside a SECURITY DEFINER workflow function that derives
-- the actor from current_app_user_id(). Under the hardened runtime role both
-- routes therefore failed with "new row violates row-level security policy for
-- table audit_log", so no file could be uploaded or parsed.
--
-- CI did not catch it because the API is never exercised over HTTP against a
-- real database as restaurant_app; the API unit tests mock the connection.
--
-- This function is the narrow, sanctioned path for those two events. It:
--   * takes the actor from the transaction-local verified user, never a parameter;
--   * resolves organisation and outlet from the batch, never from the caller;
--   * applies the same authorisation the import routes apply;
--   * accepts only the two import action codes, so it cannot forge other events.

create or replace function record_import_audit_event(
  p_batch_id       uuid,
  p_action_code    text,
  p_object_type    text,
  p_object_id      text,
  p_after_hash     text default null,
  p_correlation_id text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id   uuid := public.current_app_user_id();
  v_org_id    uuid;
  v_outlet_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_action_code not in ('IMPORT_FILE_UPLOADED', 'IMPORT_BATCH_PARSED') then
    raise exception 'unsupported import audit action: %', p_action_code
      using errcode = 'invalid_parameter_value';
  end if;

  if p_object_type not in ('source_file', 'import_batch') then
    raise exception 'unsupported import audit object type: %', p_object_type
      using errcode = 'invalid_parameter_value';
  end if;

  select b.organisation_id, b.outlet_id
    into v_org_id, v_outlet_id
    from public.import_batch b
   where b.id = p_batch_id;

  -- Same neutral treatment for "missing" and "not yours": no enumeration.
  if v_org_id is null
     or not public.has_outlet_access(v_org_id, v_outlet_id)
     or not public.has_org_role(
          v_org_id, array['admin','editor','setup_analyst']::public.app_role[]) then
    raise exception 'import batch is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, after_hash, correlation_id
  ) values (
    v_user_id, v_org_id, v_outlet_id,
    p_action_code, p_object_type, p_object_id, p_after_hash, p_correlation_id
  );
end
$$;

revoke all on function record_import_audit_event(uuid,text,text,text,text,text) from public;
grant execute on function record_import_audit_event(uuid,text,text,text,text,text) to restaurant_app;
