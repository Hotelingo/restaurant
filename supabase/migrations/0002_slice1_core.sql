-- 0002 · Slice 1 — tenancy, context, settings, materiality, audit
--
-- PROPOSED. Not accepted.
--
-- The central design change from the draft schema is G-02: composite tenancy
-- foreign keys. In the draft, outlet_id references outlet(id) alone, so a row
-- could carry organisation A's organisation_id and organisation B's outlet_id.
-- RLS filters on organisation_id and would then happily expose that row.
--
-- Here, every child reference is (organisation_id, outlet_id) -> outlet, which
-- makes a cross-tenant row UNREPRESENTABLE rather than merely unlikely. This is
-- the difference between a database that enforces tenancy and one that hopes
-- the application does.

-- ---------------------------------------------------------------- tenancy

create table organisation (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  slug       text not null unique,
  status     text not null default 'active' check (status in ('active','suspended','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table outlet (
  id                      uuid primary key default gen_random_uuid(),
  organisation_id         uuid not null references organisation(id),
  name                    text not null,
  code                    text,
  currency_code           char(3) not null,
  timezone                text not null default 'UTC',
  fiscal_year_start_month smallint not null default 1
                          check (fiscal_year_start_month between 1 and 12),
  active                  boolean not null default true,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),

  -- G-03: code is nullable and PostgreSQL treats NULLs as distinct, so the
  -- draft's unique(organisation_id, code) permitted unlimited code-less
  -- duplicates. NULLS NOT DISTINCT makes the constraint mean what it says.
  unique nulls not distinct (organisation_id, code),

  -- G-02: the target for composite foreign keys from every child table.
  unique (organisation_id, id)
);

create index outlet_org_idx on outlet (organisation_id) where active;

create table membership (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  user_id         uuid not null references auth.users(id),
  role            app_role not null,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  unique (organisation_id, user_id, role)
);

create index membership_user_idx on membership (user_id) where active;

-- G-11: the draft used membership.outlet_scope uuid[], which cannot carry a
-- foreign key. A deleted outlet left a dangling scope entry and access changed
-- silently. Absence of rows here means "all outlets in the organisation",
-- preserving the draft's NULL semantics without the integrity hole.
-- Pending OD-04.
create table membership_outlet (
  membership_id   uuid not null references membership(id) on delete cascade,
  organisation_id uuid not null,
  outlet_id       uuid not null,
  primary key (membership_id, outlet_id),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id)
);

create table staff_assignment (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  user_id         uuid not null references auth.users(id),
  outlet_id       uuid,
  starts_at       timestamptz not null default now(),
  expires_at      timestamptz not null,
  reason          text not null,
  active          boolean not null default true,
  created_at      timestamptz not null default now(),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id),
  check (expires_at > starts_at)
);

create index staff_assignment_active_idx
  on staff_assignment (user_id, organisation_id)
  where active;

-- ---------------------------------------------------------------- periods

create table reporting_period (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id       uuid not null,
  period_start    date not null,
  period_end      date not null,
  label           text not null,
  close_status    text not null default 'open' check (close_status in ('open','closed')),
  created_at      timestamptz not null default now(),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id),
  unique (outlet_id, period_start, period_end),
  unique (organisation_id, id),
  check (period_end >= period_start)
);

create index reporting_period_outlet_idx on reporting_period (outlet_id, period_start desc);

-- ---------------------------------------------------------------- context

-- Versioned. Editing creates a new version; prior versions are immutable
-- (enforced in 0003). A review records the context version it used.
create table restaurant_context (
  id                        uuid primary key default gen_random_uuid(),
  organisation_id           uuid not null,
  outlet_id                 uuid not null,
  version_no                int  not null,
  service_style             text,
  capacity_json             jsonb not null default '{}'::jsonb,
  meal_periods_json         jsonb not null default '[]'::jsonb,
  business_formats_json     jsonb not null default '[]'::jsonb,
  customer_sources_json     jsonb not null default '[]'::jsonb,
  recipe_costing_status     text,
  labour_recording_basis    text,
  source_tracking_quality   text,
  evidence_maturity         text,
  effective_from            date not null,
  effective_to              date,
  created_by                uuid references auth.users(id),
  created_at                timestamptz not null default now(),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id),
  unique (outlet_id, version_no),
  unique (organisation_id, id),
  check (effective_to is null or effective_to >= effective_from)
);

-- ---------------------------------------------------------------- settings

create table setting (
  id              uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id       uuid not null,
  key             text not null,
  value_json      jsonb not null,
  updated_by      uuid references auth.users(id),
  updated_at      timestamptz not null default now(),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id),
  unique (outlet_id, key)
);

-- G-09: absent from the draft, yet materiality is an input to
-- SEQ.FIRST_MATERIAL_MOVEMENT, which is acceptance criterion #7 of the first
-- vertical slice. Versioned and approved, never a constant in code.
create table materiality_setting (
  id                 uuid primary key default gen_random_uuid(),
  organisation_id    uuid not null,
  outlet_id          uuid not null,
  scope_type         materiality_scope not null,
  absolute_threshold numeric(20,4),
  percent_threshold  numeric(9,6),
  recurrence_rule    jsonb not null default '{}'::jsonb,
  risk_override_enabled boolean not null default false,
  effective_from     date not null,
  effective_to       date,
  approved_by        uuid references auth.users(id),
  approved_at        timestamptz,
  created_at         timestamptz not null default now(),
  foreign key (organisation_id, outlet_id) references outlet(organisation_id, id),
  unique (organisation_id, id),
  check (effective_to is null or effective_to >= effective_from),

  -- At least one test must exist, or the setting cannot make anything material.
  check (absolute_threshold is not null or percent_threshold is not null)
);

create index materiality_setting_lookup_idx
  on materiality_setting (outlet_id, scope_type, effective_from desc);

-- ---------------------------------------------------------------- audit

-- G-09: required by the architecture document's staff-access rule, absent from
-- the draft. Append-only, enforced in 0003.
create table audit_log (
  id              bigserial primary key,
  actor_user_id   uuid references auth.users(id),
  organisation_id uuid,
  outlet_id       uuid,
  action_code     text not null,
  object_type     text not null,
  object_id       text,
  before_hash     text,
  after_hash      text,
  correlation_id  text,
  occurred_at     timestamptz not null default now()
);

create index audit_log_org_idx on audit_log (organisation_id, occurred_at desc);
create index audit_log_actor_idx on audit_log (actor_user_id, occurred_at desc);

-- ---------------------------------------------------------------- updated_at

-- G-10: the draft had no updated_at anywhere.
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger organisation_updated_at before update on organisation
  for each row execute function set_updated_at();
create trigger outlet_updated_at before update on outlet
  for each row execute function set_updated_at();
