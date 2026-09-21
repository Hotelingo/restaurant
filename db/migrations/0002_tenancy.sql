-- 0002 · Neon-native tenancy core
-- Identity FKs point at Managed Better Auth's neon_auth."user".
create table organisation (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status text not null default 'active' check (status in ('active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table outlet (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  name text not null,
  code text,
  currency_code char(3) not null,
  timezone text not null default 'UTC',
  fiscal_year_start_month smallint not null default 1
    check (fiscal_year_start_month between 1 and 12),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (organisation_id, code),
  unique (organisation_id, id)
);
create index outlet_org_idx on outlet (organisation_id) where active;

create table membership (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  user_id uuid not null references neon_auth."user"(id),
  role app_role not null,
  outlet_scope_mode membership_scope_mode not null default 'all_outlets',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organisation_id, user_id, role),
  unique (organisation_id, id)
);
create index membership_user_idx on membership (user_id) where active;

create table membership_outlet (
  membership_id uuid not null,
  organisation_id uuid not null,
  outlet_id uuid not null,
  primary key (membership_id, outlet_id),
  foreign key (organisation_id, membership_id)
    references membership(organisation_id, id) on delete cascade,
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id) on delete cascade
);
create index membership_outlet_lookup_idx
  on membership_outlet (organisation_id, outlet_id, membership_id);

create table staff_assignment (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  user_id uuid not null references neon_auth."user"(id),
  outlet_id uuid,
  starts_at timestamptz not null default now(),
  expires_at timestamptz not null,
  reason text not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  check (expires_at > starts_at)
);
create index staff_assignment_active_idx
  on staff_assignment (user_id, organisation_id) where active;

create table reporting_period (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_start date not null,
  period_end date not null,
  label text not null,
  close_status text not null default 'open' check (close_status in ('open','closed')),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (organisation_id, id),
  check (period_end >= period_start),
  exclude using gist (
    outlet_id with =,
    daterange(period_start, period_end, '[]') with &&
  )
);
create index reporting_period_outlet_idx
  on reporting_period (outlet_id, period_start desc);

create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger organisation_updated_at
  before update on organisation
  for each row execute function set_updated_at();

create trigger outlet_updated_at
  before update on outlet
  for each row execute function set_updated_at();
