-- 0003 · Context, settings, materiality and audit
create table restaurant_context (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  version_no int not null,
  service_style text,
  capacity_json jsonb not null default '{}'::jsonb,
  meal_periods_json jsonb not null default '[]'::jsonb,
  business_formats_json jsonb not null default '[]'::jsonb,
  customer_sources_json jsonb not null default '[]'::jsonb,
  recipe_costing_status text,
  labour_recording_basis text,
  source_tracking_quality text,
  evidence_maturity text,
  effective_from date not null,
  effective_to date,
  created_by uuid references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (outlet_id, version_no),
  unique (organisation_id, id),
  check (effective_to is null or effective_to >= effective_from)
);

create table setting (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  key text not null,
  value_json jsonb not null,
  updated_by uuid references neon_auth."user"(id),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (outlet_id, key)
);

create table materiality_setting (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  scope_type materiality_scope not null,
  absolute_threshold numeric(20,4),
  percent_threshold numeric(9,6),
  source_kind materiality_source not null default 'product_default',
  proposal_basis jsonb not null default '{}'::jsonb,
  recurrence_rule jsonb not null default '{}'::jsonb,
  risk_override_enabled boolean not null default false,
  effective_from date not null,
  effective_to date,
  approved_by uuid references neon_auth."user"(id),
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (organisation_id, id),
  check (effective_to is null or effective_to >= effective_from),
  check (absolute_threshold is null or absolute_threshold > 0),
  check (percent_threshold is null or (percent_threshold > 0 and percent_threshold <= 1)),
  check (absolute_threshold is not null or percent_threshold is not null),
  check (
    (approved_at is null and approved_by is null)
    or (approved_at is not null and approved_by is not null)
  )
);
create index materiality_setting_lookup_idx
  on materiality_setting (outlet_id, scope_type, effective_from desc);

create table audit_log (
  id bigserial primary key,
  actor_user_id uuid references neon_auth."user"(id),
  organisation_id uuid,
  outlet_id uuid,
  action_code text not null,
  object_type text not null,
  object_id text,
  before_hash text,
  after_hash text,
  correlation_id text,
  occurred_at timestamptz not null default now()
);
create index audit_log_org_idx on audit_log (organisation_id, occurred_at desc);
create index audit_log_actor_idx on audit_log (actor_user_id, occurred_at desc);
