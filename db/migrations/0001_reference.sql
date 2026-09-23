-- 0001 · Neon-native reference types and tables
-- Slice 1 foundation. PostgreSQL 18 / Neon.
create extension if not exists pgcrypto;
create extension if not exists btree_gist;

create type app_role as enum ('admin','editor','viewer','reviewer','setup_analyst');
create type membership_scope_mode as enum ('all_outlets','selected_outlets');
create type materiality_scope as enum ('general','food','beverage','labour','other_cost','menu');
create type materiality_source as enum ('product_default','user_confirmed','user_modified');

create table ladder_framework (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table ladder_line (
  id uuid primary key default gen_random_uuid(),
  framework_id uuid not null references ladder_framework(id),
  code text not null unique,
  name text not null,
  kind text not null check (kind in ('revenue','cost','subtotal','profit')),
  display_order int not null,
  is_calculated boolean not null default false,
  unique (framework_id, display_order)
);

create table driver_taxonomy (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  domain text not null,
  active boolean not null default true
);

create table calc_definition (
  id uuid primary key default gen_random_uuid(),
  calc_id text not null,
  definition_version text not null,
  module text not null,
  name text not null,
  unit text not null,
  formula_key text not null,
  active boolean not null default true,
  unique (calc_id, definition_version)
);

create table template_definition (
  id uuid primary key default gen_random_uuid(),
  code text not null,
  version text not null,
  canonical_grain text not null,
  required_fields jsonb not null default '[]'::jsonb,
  optional_fields jsonb not null default '[]'::jsonb,
  validation_profile jsonb not null default '{}'::jsonb,
  min_app_version text,
  release text,
  unique (code, version)
);

grant select on ladder_framework, ladder_line, driver_taxonomy, calc_definition, template_definition
  to restaurant_app;
