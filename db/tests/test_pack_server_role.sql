-- The two server-only Owner Pack writes (artefact attach, sign-off) run only
-- on the explicit trusted server path (migration 0040): restaurant_app may
-- SET ROLE to restaurant_pack_server but never holds either EXECUTE right
-- ambiently.
\set ON_ERROR_STOP on

do $$
declare
  fns constant text[] := array[
    'attach_pack_artifact(uuid,text,text,text,text,text,text,text,text)',
    'record_pack_signoff(uuid,text,text,text[],text[],jsonb,text,text)'
  ];
  fn text;
begin
  foreach fn in array fns loop
    if has_function_privilege('restaurant_app', fn, 'execute') then
      raise exception 'FAIL: restaurant_app must not inherit EXECUTE on %', fn;
    end if;
    if not has_function_privilege('restaurant_pack_server', fn, 'execute') then
      raise exception 'FAIL: restaurant_pack_server must hold EXECUTE on %', fn;
    end if;
  end loop;
  if not pg_has_role('restaurant_app', 'restaurant_pack_server', 'set') then
    raise exception 'FAIL: restaurant_app must be able to SET ROLE restaurant_pack_server';
  end if;
  if pg_has_role('restaurant_app', 'restaurant_pack_server', 'usage') then
    raise exception 'FAIL: restaurant_app must not inherit restaurant_pack_server privileges';
  end if;
  if (select rolcanlogin from pg_roles where rolname = 'restaurant_pack_server') then
    raise exception 'FAIL: restaurant_pack_server must be NOLOGIN';
  end if;
  if has_table_privilege('restaurant_pack_server', 'public.pack_version', 'select')
     or has_table_privilege('restaurant_pack_server', 'public.pack_version', 'update')
     or has_table_privilege('restaurant_pack_server', 'public.signoff', 'insert') then
    raise exception 'FAIL: restaurant_pack_server must hold no table privileges';
  end if;
  raise notice 'PASS: pack server privilege model (8 checks)';
end
$$;

-- Behaviour, not just catalogue: direct calls as restaurant_app are refused.
begin;
set local role restaurant_app;
do $$
begin
  perform attach_pack_artifact(
    gen_random_uuid(), 'uploads', 'x', repeat('a',64), repeat('b',64), 'r', 't', 'server-test-0001', null
  );
  raise exception 'FAIL: restaurant_app called attach_pack_artifact without switching role';
exception when insufficient_privilege then
  raise notice 'PASS: direct attach as restaurant_app is refused';
end
$$;
do $$
begin
  perform record_pack_signoff(
    gen_random_uuid(), 'signed', null, array[]::text[], array[]::text[], '{}'::jsonb, 'server-test-0002', null
  );
  raise exception 'FAIL: restaurant_app called record_pack_signoff without switching role';
exception when insufficient_privilege then
  raise notice 'PASS: direct sign-off as restaurant_app is refused';
end
$$;
rollback;

-- After SET ROLE both functions are reachable; their own checks then apply
-- (no user context here, so each refuses from inside, not with "permission denied").
begin;
set local role restaurant_app;
set local role restaurant_pack_server;
do $$
begin
  perform attach_pack_artifact(
    gen_random_uuid(), 'uploads', 'x', repeat('a',64), repeat('b',64), 'r', 't', 'server-test-0003', null
  );
  raise exception 'FAIL: attach without user context must be refused';
exception when insufficient_privilege then
  if sqlerrm like 'permission denied%' then
    raise exception 'FAIL: server role could not execute attach_pack_artifact: %', sqlerrm;
  end if;
  raise notice 'PASS: server role reaches attach_pack_artifact, which enforces user context';
end
$$;
do $$
begin
  perform record_pack_signoff(
    gen_random_uuid(), 'signed', null, array[]::text[], array[]::text[], '{}'::jsonb, 'server-test-0004', null
  );
  raise exception 'FAIL: sign-off without user context must be refused';
exception when insufficient_privilege then
  if sqlerrm like 'permission denied%' then
    raise exception 'FAIL: server role could not execute record_pack_signoff: %', sqlerrm;
  end if;
  raise notice 'PASS: server role reaches record_pack_signoff, which enforces user context';
end
$$;
rollback;
