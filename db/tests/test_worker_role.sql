-- restaurant_worker (migration 0041) holds only what the calculation worker uses.
\set ON_ERROR_STOP on

do $$
declare
  queue_fns constant text[] := array[
    'claim_calculation_request(text,integer,integer)',
    'heartbeat_calculation_request(uuid,text,integer)',
    'complete_calculation_request(uuid,text,uuid)',
    'fail_calculation_request(uuid,text,text,boolean,integer,integer)'
  ];
  f text;
  n int := 0;
begin
  if (select rolsuper or rolbypassrls or rolcreaterole or rolcreatedb from pg_roles where rolname = 'restaurant_worker') then
    raise exception 'FAIL: restaurant_worker must not be superuser, bypass RLS, or create roles/databases';
  end if;
  n := n + 1;

  if exists (
    select 1 from pg_auth_members m join pg_roles r on r.oid = m.roleid
    where m.member = 'restaurant_worker'::regrole
  ) then
    raise exception 'FAIL: restaurant_worker must not be a member of any role';
  end if;
  n := n + 1;

  foreach f in array queue_fns loop
    if not has_function_privilege('restaurant_worker', f, 'execute') then
      raise exception 'FAIL: restaurant_worker needs EXECUTE on %', f;
    end if;
    n := n + 1;
  end loop;

  -- Functions belonging to users' workflows stay out of reach.
  if has_function_privilege('restaurant_worker', 'create_pack_version(uuid,text,text)', 'execute')
     or has_function_privilege('restaurant_worker', 'record_pack_signoff(uuid,text,text,text[],text[],jsonb,text,text)', 'execute') then
    raise exception 'FAIL: restaurant_worker must not execute review or pack functions';
  end if;
  n := n + 1;

  if has_schema_privilege('restaurant_worker', 'public', 'create') then
    raise exception 'FAIL: restaurant_worker must not create objects in public';
  end if;
  n := n + 1;

  if has_table_privilege('restaurant_worker', 'public.calculation_request_queue', 'select')
     or has_table_privilege('restaurant_worker', 'public.calculation_request_queue', 'update') then
    raise exception 'FAIL: the queue is reachable only through its functions';
  end if;
  n := n + 1;

  -- Facts are read-only to the worker; snapshots are append-only apart from calc_run status.
  if has_table_privilege('restaurant_worker', 'public.financial_fact', 'insert')
     or has_table_privilege('restaurant_worker', 'public.financial_fact', 'update')
     or has_table_privilege('restaurant_worker', 'public.financial_fact', 'delete')
     or has_table_privilege('restaurant_worker', 'public.calc_result', 'update')
     or has_table_privilege('restaurant_worker', 'public.calc_result', 'delete')
     or has_table_privilege('restaurant_worker', 'public.calc_run', 'delete') then
    raise exception 'FAIL: restaurant_worker may not change facts or rewrite/delete results';
  end if;
  n := n + 1;

  -- Nothing about people, access or audit.
  if has_table_privilege('restaurant_worker', 'neon_auth."user"', 'select')
     or has_table_privilege('restaurant_worker', 'public.membership', 'select')
     or has_table_privilege('restaurant_worker', 'public.member_invitation', 'select')
     or has_table_privilege('restaurant_worker', 'public.audit_log', 'select')
     or has_table_privilege('restaurant_worker', 'public.source_file', 'select') then
    raise exception 'FAIL: restaurant_worker must not read users, memberships, invitations, audit or source files';
  end if;
  n := n + 1;

  -- The worker policies are scoped to the worker: the app role gains nothing.
  if exists (
    select 1 from pg_policies
    where policyname in ('worker_read', 'worker_insert', 'worker_update')
      and roles <> array['restaurant_worker']::name[]
  ) then
    raise exception 'FAIL: worker policies must apply to restaurant_worker only';
  end if;
  if has_table_privilege('restaurant_app', 'public.calc_result', 'insert') then
    raise exception 'FAIL: restaurant_app must still not write calculation results';
  end if;
  n := n + 1;

  raise notice 'PASS: restaurant_worker privilege model (% checks)', n;
end
$$;

-- Behaviour: as the worker, a fact cannot be rewritten even if a row is visible.
begin;
set local role restaurant_worker;
do $$
begin
  update public.financial_fact set amount = amount where false;
  raise exception 'FAIL: restaurant_worker updated financial_fact';
exception when insufficient_privilege then
  raise notice 'PASS: restaurant_worker cannot update facts';
end
$$;
rollback;
