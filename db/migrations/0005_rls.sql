-- 0005 · RLS for server-authoritative FastAPI access
-- The API verifies the Neon Auth JWT, then sets app.user_id inside each DB
-- transaction. restaurant_app is a non-owner role, so PostgreSQL RLS applies.

create or replace function current_app_user_id()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('app.user_id', true), '')::uuid
$$;

create or replace function has_org_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = public.current_app_user_id()
      and m.active
  )
$$;

create or replace function has_outlet_access(target_org uuid, target_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = public.current_app_user_id()
      and m.active
      and (
        m.outlet_scope_mode = 'all_outlets'
        or (
          m.outlet_scope_mode = 'selected_outlets'
          and exists (
            select 1 from public.membership_outlet mo
            where mo.membership_id = m.id
              and mo.organisation_id = target_org
              and mo.outlet_id = target_outlet
          )
        )
      )
  )
$$;

create or replace function has_org_role(target_org uuid, roles app_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = public.current_app_user_id()
      and m.active
      and m.role = any (roles)
  )
$$;

create or replace function has_full_admin_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = public.current_app_user_id()
      and m.active
      and m.role = 'admin'
      and m.outlet_scope_mode = 'all_outlets'
  )
$$;

create or replace function has_staff_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff_assignment s
    where s.organisation_id = target_org
      and s.user_id = public.current_app_user_id()
      and s.active
      and now() between s.starts_at and s.expires_at
  )
$$;

create or replace function has_staff_outlet_access(target_org uuid, target_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.staff_assignment s
    where s.organisation_id = target_org
      and s.user_id = public.current_app_user_id()
      and s.active
      and now() between s.starts_at and s.expires_at
      and (s.outlet_id is null or s.outlet_id = target_outlet)
  )
$$;

alter table organisation enable row level security;
alter table outlet enable row level security;
alter table membership enable row level security;
alter table membership_outlet enable row level security;
alter table staff_assignment enable row level security;
alter table reporting_period enable row level security;
alter table restaurant_context enable row level security;
alter table setting enable row level security;
alter table materiality_setting enable row level security;
alter table request_idempotency enable row level security;
alter table audit_log enable row level security;

create policy organisation_read on organisation
  for select to restaurant_app
  using (has_org_access(id) or has_staff_access(id));

create policy organisation_admin_write on organisation
  for update to restaurant_app
  using (has_full_admin_access(id))
  with check (has_full_admin_access(id));

create policy outlet_read on outlet
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, id))
    or has_staff_outlet_access(organisation_id, id)
  );

create policy outlet_admin_insert on outlet
  for insert to restaurant_app
  with check (has_full_admin_access(organisation_id));

create policy outlet_admin_update on outlet
  for update to restaurant_app
  using (
    has_org_role(organisation_id, array['admin']::app_role[])
    and has_outlet_access(organisation_id, id)
  )
  with check (
    has_org_role(organisation_id, array['admin']::app_role[])
    and has_outlet_access(organisation_id, id)
  );

create policy outlet_admin_delete on outlet
  for delete to restaurant_app
  using (
    has_org_role(organisation_id, array['admin']::app_role[])
    and has_outlet_access(organisation_id, id)
  );

create policy membership_read on membership
  for select to restaurant_app
  using (
    user_id = current_app_user_id()
    or has_full_admin_access(organisation_id)
  );

create policy membership_admin_write on membership
  for all to restaurant_app
  using (has_full_admin_access(organisation_id))
  with check (has_full_admin_access(organisation_id));

create policy membership_outlet_read on membership_outlet
  for select to restaurant_app
  using (
    has_full_admin_access(organisation_id)
    or exists (
      select 1
      from public.membership m
      where m.id = membership_id
        and m.organisation_id = organisation_id
        and m.user_id = current_app_user_id()
        and m.active
    )
  );

create policy membership_outlet_admin_write on membership_outlet
  for all to restaurant_app
  using (has_full_admin_access(organisation_id))
  with check (has_full_admin_access(organisation_id));

create policy staff_assignment_read on staff_assignment
  for select to restaurant_app
  using (
    user_id = current_app_user_id()
    or has_full_admin_access(organisation_id)
  );

create policy reporting_period_read on reporting_period
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy reporting_period_write on reporting_period
  for all to restaurant_app
  using (
    has_org_role(organisation_id, array['admin','editor']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(organisation_id, array['admin','editor']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy restaurant_context_read on restaurant_context
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy restaurant_context_insert on restaurant_context
  for insert to restaurant_app
  with check (
    has_org_role(organisation_id, array['admin','editor']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy setting_read on setting
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy setting_write on setting
  for all to restaurant_app
  using (
    has_org_role(organisation_id, array['admin']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(organisation_id, array['admin']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy materiality_read on materiality_setting
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy materiality_insert on materiality_setting
  for insert to restaurant_app
  with check (
    has_org_role(organisation_id, array['admin','reviewer']::app_role[])
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy audit_log_read on audit_log
  for select to restaurant_app
  using (
    organisation_id is not null
    and has_full_admin_access(organisation_id)
  );

grant usage on schema public to restaurant_app;
grant select, insert, update, delete on
  organisation, outlet, membership, membership_outlet, staff_assignment,
  reporting_period, restaurant_context, setting, materiality_setting, audit_log
to restaurant_app;
grant usage, select on all sequences in schema public to restaurant_app;
