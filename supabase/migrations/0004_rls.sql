-- 0004 · Row-level security
--
-- ACCEPTED FOR SLICE 1 on 2026-09-21 after OD-01 to OD-12 were resolved.
--
-- G-01. The architecture document's rule 3 is "row-level security is enforced
-- in PostgreSQL, not only in application code". The draft schema contained zero
-- policies and one commented-out hint, so the rule was unimplemented.
--
-- Read this together with 0002's composite foreign keys. RLS alone is not
-- sufficient: these policies filter on organisation_id, so without the
-- composite keys a row carrying organisation A's organisation_id and
-- organisation B's outlet_id would pass every policy here. Tenancy needs both.

-- ---------------------------------------------------------------- helpers
--
-- security definer so they can read membership regardless of the caller's own
-- policies, with an empty search_path so they cannot be hijacked by a
-- search_path attack.

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
      and m.user_id = auth.uid()
      and m.active
  );
$$;

-- OD-04: outlet scope is explicit. all_outlets grants every outlet in the
-- organisation; selected_outlets requires a join row. selected_outlets with
-- zero rows therefore grants zero access (fail closed).
create or replace function has_outlet_access(target_org uuid, target_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $
  select exists (
    select 1
    from public.membership m
    where m.organisation_id = target_org
      and m.user_id = auth.uid()
      and m.active
      and (
        m.outlet_scope_mode = 'all_outlets'
        or (
          m.outlet_scope_mode = 'selected_outlets'
          and exists (
            select 1
            from public.membership_outlet mo
            where mo.membership_id = m.id
              and mo.organisation_id = target_org
              and mo.outlet_id = target_outlet
          )
        )
      )
  );
$;

create or replace function has_org_role(target_org uuid, roles app_role[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = auth.uid()
      and m.active
      and m.role = any (roles)
  );
$;

-- Organisation-level security administration is reserved for an admin whose
-- scope is the whole organisation. This prevents an outlet-scoped admin from
-- expanding their own scope through membership writes.
create or replace function has_full_admin_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $
  select exists (
    select 1 from public.membership m
    where m.organisation_id = target_org
      and m.user_id = auth.uid()
      and m.active
      and m.role = 'admin'
      and m.outlet_scope_mode = 'all_outlets'
  );
$;

-- Staff access requires an ACTIVE, UNEXPIRED assignment. Expiry is checked
-- here, not in application code, so a forgotten revocation still lapses.
create or replace function has_staff_access(target_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $
  select exists (
    select 1 from public.staff_assignment s
    where s.organisation_id = target_org
      and s.user_id = auth.uid()
      and s.active
      and now() between s.starts_at and s.expires_at
  );
$;

-- Outlet-specific staff assignments must not accidentally grant organisation-
-- wide outlet access. A NULL outlet_id means the assignment is organisation-wide.
create or replace function has_staff_outlet_access(target_org uuid, target_outlet uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $
  select exists (
    select 1 from public.staff_assignment s
    where s.organisation_id = target_org
      and s.user_id = auth.uid()
      and s.active
      and now() between s.starts_at and s.expires_at
      and (s.outlet_id is null or s.outlet_id = target_outlet)
  );
$;

-- ---------------------------------------------------------------- enable

alter table organisation        enable row level security;
alter table outlet              enable row level security;
alter table membership          enable row level security;
alter table membership_outlet   enable row level security;
alter table staff_assignment    enable row level security;
alter table reporting_period    enable row level security;
alter table restaurant_context  enable row level security;
alter table setting             enable row level security;
alter table materiality_setting enable row level security;
alter table audit_log           enable row level security;

-- ---------------------------------------------------------------- policies

create policy organisation_read on organisation
  for select to authenticated
  using (has_org_access(id) or has_staff_access(id));

create policy organisation_admin_write on organisation
  for update to authenticated
  using (has_full_admin_access(id))
  with check (has_full_admin_access(id));

create policy outlet_read on outlet
  for select to authenticated
  using ((has_org_access(organisation_id) and has_outlet_access(organisation_id, id))
         or has_staff_outlet_access(organisation_id, id));

create policy outlet_admin_insert on outlet
  for insert to authenticated
  with check (has_full_admin_access(organisation_id));

create policy outlet_admin_update on outlet
  for update to authenticated
  using (has_org_role(organisation_id, array['admin']::app_role[])
         and has_outlet_access(organisation_id, id))
  with check (has_org_role(organisation_id, array['admin']::app_role[])
              and has_outlet_access(organisation_id, id));

create policy outlet_admin_delete on outlet
  for delete to authenticated
  using (has_org_role(organisation_id, array['admin']::app_role[])
         and has_outlet_access(organisation_id, id));

create policy membership_read on membership
  for select to authenticated
  using (user_id = auth.uid() or has_full_admin_access(organisation_id));

create policy membership_admin_write on membership
  for all to authenticated
  using (has_full_admin_access(organisation_id))
  with check (has_full_admin_access(organisation_id));

create policy membership_outlet_read on membership_outlet
  for select to authenticated
  using (
    has_full_admin_access(organisation_id)
    or exists (
      select 1
      from public.membership m
      where m.id = membership_id
        and m.organisation_id = organisation_id
        and m.user_id = auth.uid()
        and m.active
    )
  );

create policy membership_outlet_admin_write on membership_outlet
  for all to authenticated
  using (has_full_admin_access(organisation_id))
  with check (has_full_admin_access(organisation_id));

-- Staff assignments are never self-granted from the client. Read-only here;
-- creation is a service-role operation.
create policy staff_assignment_read on staff_assignment
  for select to authenticated
  using (user_id = auth.uid() or has_full_admin_access(organisation_id));

create policy reporting_period_read on reporting_period
  for select to authenticated
  using ((has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
         or has_staff_outlet_access(organisation_id, outlet_id));

create policy reporting_period_write on reporting_period
  for all to authenticated
  using (has_org_role(organisation_id, array['admin','editor']::app_role[])
         and has_outlet_access(organisation_id, outlet_id))
  with check (has_org_role(organisation_id, array['admin','editor']::app_role[])
              and has_outlet_access(organisation_id, outlet_id));

create policy restaurant_context_read on restaurant_context
  for select to authenticated
  using ((has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
         or has_staff_outlet_access(organisation_id, outlet_id));

-- Insert only: 0003 forbids update and delete outright.
create policy restaurant_context_insert on restaurant_context
  for insert to authenticated
  with check (has_org_role(organisation_id, array['admin','editor']::app_role[])
              and has_outlet_access(organisation_id, outlet_id));

create policy setting_read on setting
  for select to authenticated
  using ((has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
         or has_staff_outlet_access(organisation_id, outlet_id));

create policy setting_write on setting
  for all to authenticated
  using (has_org_role(organisation_id, array['admin']::app_role[])
         and has_outlet_access(organisation_id, outlet_id))
  with check (has_org_role(organisation_id, array['admin']::app_role[])
              and has_outlet_access(organisation_id, outlet_id));

create policy materiality_read on materiality_setting
  for select to authenticated
  using ((has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
         or has_staff_outlet_access(organisation_id, outlet_id));

create policy materiality_insert on materiality_setting
  for insert to authenticated
  with check (has_org_role(organisation_id, array['admin','reviewer']::app_role[])
              and has_outlet_access(organisation_id, outlet_id));

-- Admins read their own organisation's audit trail. Nobody writes from a
-- client; the API service role appends.
create policy audit_log_read on audit_log
  for select to authenticated
  using (organisation_id is not null
         and has_org_role(organisation_id, array['admin']::app_role[]));

-- ---------------------------------------------------------------- notes
--
-- Canonical facts and calculation results, added in later slices, get SELECT
-- policies only. There is deliberately NO client INSERT or UPDATE path for
-- financial_fact, stock_fact, meal_period_fact, labour_fact, calc_run or
-- calc_result. Those writes happen through the API's service credentials or
-- tightly-scoped security-definer RPCs. This is the architecture document's
-- rule 13, enforced by the absence of a policy rather than by convention.
--
-- Required tests (S1-2), each from the perspective of a second tenant:
--   1. a user in org A reads zero rows from org B on every table above
--   2. selected_outlets membership reads only joined outlets
--   3. selected_outlets with zero join rows reads zero outlets
--   4. all_outlets membership reads every outlet in the organisation
--   5. an anonymous client reads nothing
--   6. expired or differently-scoped staff_assignment grants nothing extra
--   7. a client INSERT into financial_fact or calc_result fails under every role
--   8. a row combining org A's organisation_id with org B's outlet_id is
--      rejected by the foreign key -- the G-02 test, and the one most likely to
--      be forgotten because it passes trivially once the schema is right
