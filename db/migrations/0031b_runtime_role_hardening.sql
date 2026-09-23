-- 0031 · Runtime application-role hardening
-- The restaurant_app runtime role must never inherit Neon owner/superuser-style
-- privileges or bypass RLS. Canonical writes remain available only through
-- explicitly granted SECURITY DEFINER workflow functions.

do $$
declare
  v_has_neon_superuser boolean;
  v_is_member boolean;
begin
  if not exists (
    select 1 from pg_catalog.pg_roles where rolname='restaurant_app'
  ) then
    raise exception 'restaurant_app role is required before migrations run';
  end if;

  execute
    'alter role restaurant_app '||
    'nosuperuser nocreatedb nocreaterole noreplication '||
    'nobypassrls noinherit';

  select exists(
    select 1 from pg_catalog.pg_roles where rolname='neon_superuser'
  ) into v_has_neon_superuser;

  if v_has_neon_superuser then
    select pg_catalog.pg_has_role(
      'restaurant_app',
      'neon_superuser',
      'member'
    ) into v_is_member;

    if v_is_member then
      execute 'revoke neon_superuser from restaurant_app';
    end if;
  end if;
end
$$;


-- Fail the migration rather than silently accepting an unsafe runtime role.
do $$
declare
  v_role record;
begin
  select
    rolsuper,rolcreatedb,rolcreaterole,rolreplication,rolbypassrls,rolinherit
  into v_role
  from pg_catalog.pg_roles
  where rolname='restaurant_app';

  if v_role.rolsuper
     or v_role.rolcreatedb
     or v_role.rolcreaterole
     or v_role.rolreplication
     or v_role.rolbypassrls
     or v_role.rolinherit then
    raise exception
      'restaurant_app must be NOINHERIT/NOBYPASSRLS and hold no administrative role attributes';
  end if;

  if exists(
    select 1
    from pg_catalog.pg_roles
    where rolname='neon_superuser'
  ) and pg_catalog.pg_has_role(
    'restaurant_app',
    'neon_superuser',
    'member'
  ) then
    raise exception 'restaurant_app must not be a member of neon_superuser';
  end if;
end
$$;
