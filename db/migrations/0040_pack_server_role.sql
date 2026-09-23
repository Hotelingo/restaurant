-- Trusted server path for the two server-only Owner Pack writes.
--
-- 0028 and 0029 deliberately left record_pack_signoff() and
-- attach_pack_artifact() without a grant to restaurant_app ("server-only"),
-- expecting a separate API database role. The API, however, connects only as
-- restaurant_app (api/README.md), so POST /packs/{id}/render and
-- POST /packs/{id}/signoff always failed with "permission denied": no Owner
-- Pack could be rendered or signed through the API. The DB tests did not show
-- it because they call both functions as the database owner.
--
-- Rather than grant them to restaurant_app outright, this adds a NOLOGIN role
-- that holds only those two EXECUTE rights. restaurant_app may SET ROLE to it
-- but does not inherit it, so the privilege is never ambient: each route
-- switches role explicitly for its one call (the render route after writing
-- the object; the sign-off route after evaluating the review gate) and
-- switches back. Both functions still enforce user context, role, outlet
-- access, idempotency and their own invariants.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'restaurant_pack_server') then
    create role restaurant_pack_server nologin;
  end if;
end
$$;

grant execute on function attach_pack_artifact(
  uuid,text,text,text,text,text,text,text,text
) to restaurant_pack_server;

grant execute on function record_pack_signoff(
  uuid,text,text,text[],text[],jsonb,text,text
) to restaurant_pack_server;

-- restaurant_app is provisioned outside migrations (see api/README.md). Grant
-- membership only where it exists, and never with inherited privileges.
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'restaurant_app') then
    execute 'grant restaurant_pack_server to restaurant_app with inherit false, set true';
  end if;
end
$$;
