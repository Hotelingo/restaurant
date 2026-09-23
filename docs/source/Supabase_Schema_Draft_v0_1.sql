-- Restaurant Performance Review — Supabase schema draft v0.1
-- DESIGN DRAFT ONLY. Do not run against production without review.

create extension if not exists pgcrypto;

create type app_role as enum ('admin','editor','viewer','reviewer','setup_analyst');
create type scenario_code as enum ('actual','budget','forecast','prior_year');
create type batch_status as enum ('uploaded','parsing','needs_mapping','validating','blocked','warning','ready','committed','superseded','rejected');
create type validation_severity as enum ('block','warn','info');
create type calculation_status as enum ('calculated','not_calculated','error');
create type evidence_status as enum ('validated','supported','partly_supported','evidence_required','not_reconciled','not_applicable');
create type review_status as enum ('draft','in_review','changes_requested','signed','released','closed');
create type issue_disposition as enum ('act','monitor_with_trigger','investigate','escalate','close_no_action');

create table organisation (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  status text not null default 'active',
  created_at timestamptz not null default now()
);

create table outlet (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  name text not null,
  code text,
  currency_code char(3) not null,
  timezone text,
  fiscal_year_start_month smallint check (fiscal_year_start_month between 1 and 12),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organisation_id, code)
);

create table membership (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  user_id uuid not null references auth.users(id),
  role app_role not null,
  outlet_scope uuid[],
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (organisation_id, user_id, role)
);

create table reporting_period (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  period_start date not null,
  period_end date not null,
  label text not null,
  close_status text not null default 'open',
  unique (outlet_id, period_start, period_end)
);

create table ladder_framework (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null
);

create table ladder_line (
  id uuid primary key default gen_random_uuid(),
  framework_id uuid not null references ladder_framework(id),
  code text not null unique,
  name text not null,
  kind text not null,
  display_order int not null,
  is_calculated boolean not null default false
);

create table source_file (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  template_code text,
  storage_bucket text not null,
  storage_path text not null,
  original_filename text not null,
  sha256 text not null,
  content_type text,
  size_bytes bigint,
  uploaded_by uuid references auth.users(id),
  uploaded_at timestamptz not null default now()
);

create table source_profile (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  template_code text not null,
  source_label text not null,
  active_profile_version_id uuid,
  created_at timestamptz not null default now()
);

create table profile_version (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  source_profile_id uuid not null references source_profile(id),
  version_no int not null,
  layout_json jsonb not null default '{}'::jsonb,
  fingerprint_hash text not null,
  fingerprint_components_json jsonb not null default '{}'::jsonb,
  transform_config_json jsonb not null default '[]'::jsonb,
  status text not null default 'draft',
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  supersedes_profile_version_id uuid references profile_version(id),
  unique (source_profile_id, version_no)
);

alter table source_profile
  add constraint fk_source_profile_active_version
  foreign key (active_profile_version_id) references profile_version(id);

create table account_mapping (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  profile_version_id uuid not null references profile_version(id),
  source_account_code text,
  source_account_name text not null,
  ladder_line_id uuid not null references ladder_line(id),
  mapping_basis text not null,
  approved_by uuid references auth.users(id),
  unique (profile_version_id, source_account_code, source_account_name)
);

create table import_batch (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  source_file_id uuid not null references source_file(id),
  profile_version_id uuid references profile_version(id),
  period_id uuid references reporting_period(id),
  scenario scenario_code not null default 'actual',
  status batch_status not null default 'uploaded',
  detected_fingerprint text,
  supersedes_batch_id uuid references import_batch(id),
  committed_by uuid references auth.users(id),
  committed_at timestamptz,
  canonical_commit_hash text,
  created_at timestamptz not null default now()
);

create table staging_row (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  batch_id uuid not null references import_batch(id),
  source_row_no int not null,
  raw_jsonb jsonb not null,
  parsed_jsonb jsonb,
  row_status text,
  parse_errors jsonb not null default '[]'::jsonb,
  unique (batch_id, source_row_no)
);

create table validation_result (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  batch_id uuid not null references import_batch(id),
  staging_row_id uuid references staging_row(id),
  rule_code text not null,
  severity validation_severity not null,
  field_name text,
  message text not null,
  expected_json jsonb,
  actual_json jsonb,
  resolved boolean not null default false,
  resolution_note text
);

create table account (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  account_code text,
  account_name text not null,
  account_section text,
  active boolean not null default true,
  unique (outlet_id, account_code, account_name)
);

create table financial_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  period_id uuid not null references reporting_period(id),
  scenario scenario_code not null,
  account_id uuid not null references account(id),
  ladder_line_id uuid not null references ladder_line(id),
  amount numeric(20,4) not null,
  currency_code char(3) not null,
  batch_id uuid not null references import_batch(id),
  profile_version_id uuid not null references profile_version(id),
  staging_row_id uuid references staging_row(id),
  created_at timestamptz not null default now()
);

create table stock_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  period_id uuid not null references reporting_period(id),
  product_group text not null,
  category text,
  opening_inventory numeric(20,4),
  purchases numeric(20,4),
  closing_inventory numeric(20,4),
  external_transfer_adjustment numeric(20,4),
  recorded_nonrevenue_use numeric(20,4),
  valuation_basis text,
  batch_id uuid not null references import_batch(id),
  profile_version_id uuid not null references profile_version(id),
  staging_row_id uuid references staging_row(id)
);

create table review (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  outlet_id uuid not null references outlet(id),
  period_id uuid not null references reporting_period(id),
  status review_status not null default 'draft',
  comparator_scenario scenario_code not null default 'budget',
  materiality_snapshot jsonb not null default '{}'::jsonb,
  active_calc_run_id uuid,
  review_leader uuid references auth.users(id),
  started_at timestamptz not null default now(),
  closed_at timestamptz
);

create table calc_run (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  review_id uuid not null references review(id),
  engine_version text not null,
  settings_snapshot jsonb not null,
  status text not null default 'running',
  supersedes_calc_run_id uuid references calc_run(id),
  started_at timestamptz not null default now(),
  completed_at timestamptz
);

alter table review
  add constraint fk_review_active_calc_run
  foreign key (active_calc_run_id) references calc_run(id);

create table calc_run_input (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  run_id uuid not null references calc_run(id),
  batch_id uuid not null references import_batch(id),
  unique (run_id, batch_id)
);

create table calc_result (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  run_id uuid not null references calc_run(id),
  calc_id text not null,
  grain_type text not null,
  grain_key jsonb not null default '{}'::jsonb,
  value_numeric numeric(20,4),
  value_text text,
  unit text,
  currency_code char(3),
  calculation_status calculation_status not null,
  evidence_status evidence_status not null,
  explanation_code text,
  result_metadata jsonb not null default '{}'::jsonb
);

create table review_issue (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  review_id uuid not null references review(id),
  title text not null,
  source_calc_result_id uuid references calc_result(id),
  movement_amount numeric(20,4),
  movement_rate numeric(20,8),
  materiality_reason text,
  shortlist_order int,
  evidence_status evidence_status not null,
  issue_status text not null default 'open'
);

create table decision (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  review_issue_id uuid not null unique references review_issue(id),
  disposition issue_disposition not null,
  decision_text text,
  decided_by uuid references auth.users(id),
  decided_at timestamptz
);

create table action (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  decision_id uuid not null references decision(id),
  owner_user_id uuid references auth.users(id),
  lever text,
  guardrail text,
  metric text,
  trigger_text text,
  due_date date,
  cadence text,
  status text not null default 'open'
);

create table pack_version (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  review_id uuid not null references review(id),
  version_no int not null,
  calc_run_id uuid not null references calc_run(id),
  status text not null default 'draft',
  artifact_storage_path text,
  artifact_sha256 text,
  created_at timestamptz not null default now(),
  unique (review_id, version_no)
);

create table signoff (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null references organisation(id),
  pack_version_id uuid not null references pack_version(id),
  reviewer_user_id uuid not null references auth.users(id),
  decision text not null check (decision in ('signed','changes_requested')),
  caveat text,
  created_at timestamptz not null default now()
);

-- Additional canonical/menu/review tables are specified in the architecture document
-- and should be added in phased migrations rather than one migration.

-- RLS helper concept:
-- create function has_org_access(target_org uuid) returns boolean security definer ...
-- Every tenant table: enable row level security; SELECT only where membership/staff assignment permits.
-- Canonical fact and calc-result INSERT/UPDATE should be server-only.