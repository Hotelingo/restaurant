-- 0009 · Membership administration and invitation workflow
-- Application roles/outlet scope remain authoritative in public.membership.
-- Invitations use opaque, high-entropy tokens whose SHA-256 hash alone is stored.

create type member_invitation_status as enum (
  'pending','accepted','declined','revoked'
);

create table member_invitation (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  email text not null,
  role app_role not null,
  outlet_scope_mode membership_scope_mode not null,
  token_hash char(64) not null unique,
  inviter_user_id uuid not null references neon_auth."user"(id),
  status member_invitation_status not null default 'pending',
  expires_at timestamptz not null,
  accepted_by uuid references neon_auth."user"(id),
  accepted_at timestamptz,
  created_at timestamptz not null default now(),
  check (length(trim(email)) > 3),
  check (role <> 'setup_analyst'),
  check (expires_at > created_at),
  check (
    (status = 'accepted' and accepted_by is not null and accepted_at is not null)
    or
    (status <> 'accepted' and accepted_by is null and accepted_at is null)
  )
);
create unique index member_invitation_pending_identity_idx
  on member_invitation (organisation_id, lower(email), role)
  where status = 'pending';
create index member_invitation_org_idx
  on member_invitation (organisation_id, created_at desc);

create table member_invitation_outlet (
  invitation_id uuid not null references member_invitation(id) on delete cascade,
  organisation_id uuid not null,
  outlet_id uuid not null,
  primary key (invitation_id, outlet_id),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id) on delete cascade
);
create index member_invitation_outlet_lookup_idx
  on member_invitation_outlet (organisation_id, outlet_id, invitation_id);

alter table member_invitation enable row level security;
alter table member_invitation_outlet enable row level security;

create policy member_invitation_admin_read on member_invitation
  for select to restaurant_app
  using (has_full_admin_access(organisation_id));

create policy member_invitation_outlet_admin_read on member_invitation_outlet
  for select to restaurant_app
  using (has_full_admin_access(organisation_id));

grant select on member_invitation, member_invitation_outlet to restaurant_app;


create or replace function lookup_user_identity(
  p_organisation_id uuid,
  p_user_id uuid
)
returns table (user_id uuid, display_name text, email text)
language sql
stable
security definer
set search_path = ''
as $$
  select u.id, u.name, u.email
  from neon_auth."user" u
  where u.id = p_user_id
    and (
      u.id = public.current_app_user_id()
      or public.has_full_admin_access(p_organisation_id)
    )
$$;

revoke all on function lookup_user_identity(uuid,uuid) from public;
grant execute on function lookup_user_identity(uuid,uuid) to restaurant_app;


create or replace function create_member_invitation(
  p_organisation_id uuid,
  p_email text,
  p_role public.app_role,
  p_scope_mode public.membership_scope_mode,
  p_outlet_ids uuid[],
  p_token_hash text,
  p_expires_at timestamptz,
  p_correlation_id text default null
)
returns table (invitation_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_invitation_id uuid;
  v_outlet_ids uuid[] := coalesce(p_outlet_ids, array[]::uuid[]);
begin
  if v_user_id is null or not public.has_full_admin_access(p_organisation_id) then
    raise exception 'organisation is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  if p_role = 'setup_analyst' then
    raise exception 'setup analyst access uses staff assignments, not customer membership invitations'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_email is null or length(trim(p_email)) < 4 then
    raise exception 'a valid invitation email is required'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_token_hash is null or length(p_token_hash) <> 64 then
    raise exception 'invitation token hash is invalid'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_expires_at <= now() then
    raise exception 'invitation expiry must be in the future'
      using errcode = 'invalid_parameter_value';
  end if;

  if p_scope_mode = 'selected_outlets' then
    if cardinality(v_outlet_ids) = 0 then
      raise exception 'selected-outlet invitations require at least one outlet'
        using errcode = 'invalid_parameter_value';
    end if;

    if (
      select count(distinct o.id)
      from public.outlet o
      where o.organisation_id = p_organisation_id
        and o.id = any(v_outlet_ids)
    ) <> cardinality(v_outlet_ids) then
      raise exception 'one or more selected outlets are not in the organisation'
        using errcode = 'invalid_parameter_value';
    end if;
  elsif cardinality(v_outlet_ids) <> 0 then
    raise exception 'all-outlets invitations must not carry selected outlet ids'
      using errcode = 'invalid_parameter_value';
  end if;

  -- Reissuing a role invitation revokes the prior pending token before a new token is written.
  update public.member_invitation
  set status = 'revoked'
  where organisation_id = p_organisation_id
    and lower(email) = lower(trim(p_email))
    and role = p_role
    and status = 'pending';

  insert into public.member_invitation (
    organisation_id, email, role, outlet_scope_mode,
    token_hash, inviter_user_id, expires_at
  )
  values (
    p_organisation_id, lower(trim(p_email)), p_role, p_scope_mode,
    p_token_hash, v_user_id, p_expires_at
  )
  returning id into v_invitation_id;

  if p_scope_mode = 'selected_outlets' then
    insert into public.member_invitation_outlet (
      invitation_id, organisation_id, outlet_id
    )
    select v_invitation_id, p_organisation_id, x.outlet_id
    from unnest(v_outlet_ids) as x(outlet_id);
  end if;

  insert into public.audit_log (
    actor_user_id, organisation_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, p_organisation_id,
    'MEMBER_INVITATION_CREATED', 'member_invitation',
    v_invitation_id::text, p_correlation_id
  );

  return query select v_invitation_id;
end
$$;

revoke all on function create_member_invitation(
  uuid,text,public.app_role,public.membership_scope_mode,uuid[],text,timestamptz,text
) from public;
grant execute on function create_member_invitation(
  uuid,text,public.app_role,public.membership_scope_mode,uuid[],text,timestamptz,text
) to restaurant_app;


create or replace function preview_member_invitation(
  p_token_hash text
)
returns table (
  invitation_id uuid,
  organisation_name text,
  role text,
  scope_mode text,
  outlet_names text[],
  inviter_name text,
  expires_at timestamptz,
  effective_status text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    i.id,
    o.name,
    i.role::text,
    i.outlet_scope_mode::text,
    coalesce(
      array_agg(outlet.name order by outlet.name)
        filter (where outlet.id is not null),
      array[]::text[]
    ) as outlet_names,
    inviter.name,
    i.expires_at,
    case
      when i.status::text <> 'pending' then i.status::text
      when i.expires_at <= now() then 'expired'
      else 'pending'
    end as effective_status
  from public.member_invitation i
  join public.organisation o on o.id = i.organisation_id
  left join public.member_invitation_outlet io on io.invitation_id = i.id
  left join public.outlet outlet on outlet.id = io.outlet_id
  left join neon_auth."user" inviter on inviter.id = i.inviter_user_id
  where i.token_hash = p_token_hash
  group by i.id,o.name,i.role,i.outlet_scope_mode,inviter.name,i.expires_at,i.status
$$;

revoke all on function preview_member_invitation(text) from public;
grant execute on function preview_member_invitation(text) to restaurant_app;


create or replace function accept_member_invitation(
  p_token_hash text,
  p_correlation_id text default null
)
returns table (organisation_id uuid, membership_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_user_email text;
  v_inv public.member_invitation%rowtype;
  v_membership_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select u.email into v_user_email
  from neon_auth."user" u
  where u.id = v_user_id;

  select * into v_inv
  from public.member_invitation i
  where i.token_hash = p_token_hash
  for update;

  if v_inv.id is null then
    raise exception 'invitation is not available'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_inv.status <> 'pending' or v_inv.expires_at <= now() then
    raise exception 'invitation is no longer pending'
      using errcode = 'invalid_parameter_value';
  end if;
  if v_user_email is null or lower(v_user_email) <> lower(v_inv.email) then
    raise exception 'signed-in account does not match invitation recipient'
      using errcode = 'insufficient_privilege';
  end if;

  insert into public.membership (
    organisation_id, user_id, role, outlet_scope_mode, active
  )
  values (
    v_inv.organisation_id, v_user_id, v_inv.role, v_inv.outlet_scope_mode, true
  )
  on conflict on constraint membership_organisation_id_user_id_role_key do update
    set outlet_scope_mode = excluded.outlet_scope_mode,
        active = true
  returning id into v_membership_id;

  delete from public.membership_outlet
  where membership_id = v_membership_id;

  if v_inv.outlet_scope_mode = 'selected_outlets' then
    insert into public.membership_outlet (
      membership_id, organisation_id, outlet_id
    )
    select
      v_membership_id, io.organisation_id, io.outlet_id
    from public.member_invitation_outlet io
    where io.invitation_id = v_inv.id;
  end if;

  update public.member_invitation
  set status='accepted', accepted_by=v_user_id, accepted_at=now()
  where id=v_inv.id;

  insert into public.audit_log (
    actor_user_id, organisation_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_inv.organisation_id,
    'MEMBER_INVITATION_ACCEPTED', 'membership',
    v_membership_id::text, p_correlation_id
  );

  return query select v_inv.organisation_id, v_membership_id;
end
$$;

revoke all on function accept_member_invitation(text,text) from public;
grant execute on function accept_member_invitation(text,text) to restaurant_app;


create or replace function decline_member_invitation(
  p_token_hash text,
  p_correlation_id text default null
)
returns table (invitation_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_user_email text;
  v_inv public.member_invitation%rowtype;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select u.email into v_user_email
  from neon_auth."user" u
  where u.id = v_user_id;

  select * into v_inv
  from public.member_invitation i
  where i.token_hash = p_token_hash
  for update;

  if v_inv.id is null
     or v_inv.status <> 'pending'
     or v_inv.expires_at <= now()
     or v_user_email is null
     or lower(v_user_email) <> lower(v_inv.email) then
    raise exception 'invitation is not available'
      using errcode = 'insufficient_privilege';
  end if;

  update public.member_invitation
  set status='declined'
  where id=v_inv.id;

  insert into public.audit_log (
    actor_user_id, organisation_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_inv.organisation_id,
    'MEMBER_INVITATION_DECLINED', 'member_invitation',
    v_inv.id::text, p_correlation_id
  );

  return query select v_inv.id;
end
$$;

revoke all on function decline_member_invitation(text,text) from public;
grant execute on function decline_member_invitation(text,text) to restaurant_app;


create or replace function set_membership_active(
  p_organisation_id uuid,
  p_membership_id uuid,
  p_active boolean,
  p_correlation_id text default null
)
returns table (membership_id uuid, active boolean)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_target public.membership%rowtype;
begin
  if v_user_id is null or not public.has_full_admin_access(p_organisation_id) then
    raise exception 'organisation is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_target
  from public.membership m
  where m.id=p_membership_id
    and m.organisation_id=p_organisation_id
  for update;

  if v_target.id is null then
    raise exception 'membership is not available'
      using errcode = 'invalid_parameter_value';
  end if;

  if not p_active
     and v_target.user_id = v_user_id
     and v_target.role = 'admin'
     and v_target.outlet_scope_mode = 'all_outlets'
     and not exists (
       select 1
       from public.membership other
       where other.organisation_id=p_organisation_id
         and other.active
         and other.role='admin'
         and other.outlet_scope_mode='all_outlets'
         and other.id <> v_target.id
     ) then
    raise exception 'cannot deactivate the last full-organisation admin'
      using errcode = 'check_violation';
  end if;

  update public.membership
  set active=p_active
  where id=v_target.id;

  insert into public.audit_log (
    actor_user_id, organisation_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, p_organisation_id,
    case when p_active then 'MEMBERSHIP_REACTIVATED' else 'MEMBERSHIP_DEACTIVATED' end,
    'membership', v_target.id::text, p_correlation_id
  );

  return query select v_target.id, p_active;
end
$$;

revoke all on function set_membership_active(uuid,uuid,boolean,text) from public;
grant execute on function set_membership_active(uuid,uuid,boolean,text) to restaurant_app;
