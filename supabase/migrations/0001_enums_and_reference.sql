-- 0001 · Enums and platform reference tables
--
-- ACCEPTED FOR SLICE 1 on 2026-09-21 after OD-01 to OD-12 were resolved.
-- See supabase/migrations/README.md for every deviation from the source draft.
--
-- Reference tables are platform-owned: no organisation_id, no customer data,
-- readable by every authenticated user, writable only by the service role.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- enums

create type app_role            as enum ('admin','editor','viewer','reviewer','setup_analyst');
create type scenario_code       as enum ('actual','budget','forecast','prior_year');
create type batch_status        as enum ('uploaded','parsing','needs_mapping','validating',
                                         'blocked','warning','ready','committed','superseded','rejected');
create type validation_severity as enum ('block','warn','info');
create type calculation_status  as enum ('calculated','not_calculated','error');
create type evidence_status     as enum ('validated','supported','partly_supported',
                                         'evidence_required','not_reconciled','not_applicable');
create type review_status       as enum ('draft','in_review','changes_requested','signed','released','closed');
create type issue_disposition   as enum ('act','monitor_with_trigger','investigate','escalate','close_no_action');
create type claim_status        as enum ('draft','accepted','edited','rejected');

-- G-10: the architecture document defines template_code as an enum; the draft used text.
create type template_code as enum ('T1','T1B','T2','T3','T4A','T4B','T5','T6','T7','T8',
                                   'M1','M2','M3','M4');

create type materiality_scope     as enum ('general','food','beverage','labour','other_cost','menu');
create type membership_scope_mode as enum ('all_outlets','selected_outlets');
create type materiality_source    as enum ('product_default','user_confirmed','user_modified');

-- ---------------------------------------------------------------- reference

create table ladder_framework (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table ladder_line (
  id            uuid primary key default gen_random_uuid(),
  framework_id  uuid not null references ladder_framework(id),
  code          text not null unique,
  name          text not null,
  kind          text not null check (kind in ('revenue','cost','subtotal','profit')),
  display_order int  not null,
  is_calculated boolean not null default false,
  unique (framework_id, display_order)
);

create table driver_taxonomy (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,
  name       text not null,
  domain     text not null,
  active     boolean not null default true
);

-- G-09: absent from the draft. The calc engine resolves formulas by calc_id and
-- definition_version; without this table the engine version is unpinnable.
create table calc_definition (
  id                 uuid primary key default gen_random_uuid(),
  calc_id            text not null,
  definition_version text not null,
  module             text not null,
  name               text not null,
  unit               text not null,
  formula_key        text not null,
  active             boolean not null default true,
  unique (calc_id, definition_version)
);

create table template_definition (
  id                  uuid primary key default gen_random_uuid(),
  code                template_code not null,
  version             text not null,
  canonical_grain     text not null,
  required_fields     jsonb not null default '[]'::jsonb,
  optional_fields     jsonb not null default '[]'::jsonb,
  validation_profile  jsonb not null default '{}'::jsonb,
  min_app_version     text,
  release             text,
  unique (code, version)
);

-- Reference tables are readable by all authenticated users.
alter table ladder_framework    enable row level security;
alter table ladder_line         enable row level security;
alter table driver_taxonomy     enable row level security;
alter table calc_definition     enable row level security;
alter table template_definition enable row level security;

create policy ref_read on ladder_framework    for select to authenticated using (true);
create policy ref_read on ladder_line         for select to authenticated using (true);
create policy ref_read on driver_taxonomy     for select to authenticated using (true);
create policy ref_read on calc_definition     for select to authenticated using (true);
create policy ref_read on template_definition for select to authenticated using (true);
