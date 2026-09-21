-- 0011 · Slice 2 mapping persistence
-- Source profiles and their mappings are versioned. An approved profile version
-- and every child mapping attached to it are immutable. Amounts are deliberately
-- absent from identity/mapping tables: source identities are account/item
-- code first, normalised name fallback.

create table source_profile (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  template_code text not null,
  source_label text not null,
  active_profile_version_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (organisation_id, outlet_id, id),
  unique (organisation_id, outlet_id, template_code, source_label),
  check (length(btrim(template_code)) > 0),
  check (length(btrim(source_label)) > 0)
);
create index source_profile_match_idx
  on source_profile (organisation_id, outlet_id, template_code);

create table profile_version (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  source_profile_id uuid not null,
  version_no int not null check (version_no > 0),
  layout_json jsonb not null default '{}'::jsonb
    check (jsonb_typeof(layout_json) = 'object'),
  fingerprint_hash text not null
    check (fingerprint_hash ~ '^[0-9a-f]{64}$'),
  fingerprint_components_json jsonb not null default '{}'::jsonb
    check (jsonb_typeof(fingerprint_components_json) = 'object'),
  transform_config_json jsonb not null default '[]'::jsonb
    check (jsonb_typeof(transform_config_json) = 'array'),
  status text not null default 'draft'
    check (status in ('draft','approved')),
  approved_by uuid references neon_auth."user"(id),
  approved_at timestamptz,
  supersedes_profile_version_id uuid,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, source_profile_id)
    references source_profile(organisation_id, outlet_id, id),
  unique (source_profile_id, version_no),
  unique (organisation_id, outlet_id, id),
  unique (organisation_id, outlet_id, source_profile_id, id),
  check (
    (status = 'draft' and approved_by is null and approved_at is null)
    or
    (status = 'approved' and approved_by is not null and approved_at is not null)
  )
);
create index profile_version_profile_idx
  on profile_version (source_profile_id, version_no desc);

alter table profile_version
  add constraint profile_version_supersedes_same_profile_fk
  foreign key (
    organisation_id, outlet_id, source_profile_id, supersedes_profile_version_id
  )
  references profile_version(
    organisation_id, outlet_id, source_profile_id, id
  );

alter table source_profile
  add constraint source_profile_active_version_same_profile_fk
  foreign key (
    organisation_id, outlet_id, id, active_profile_version_id
  )
  references profile_version(
    organisation_id, outlet_id, source_profile_id, id
  );

create table column_mapping (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  profile_version_id uuid not null,
  source_column text not null,
  canonical_field text not null,
  required boolean not null default false,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  unique (profile_version_id, source_column),
  check (length(btrim(source_column)) > 0),
  check (length(btrim(canonical_field)) > 0)
);
create index column_mapping_profile_idx on column_mapping (profile_version_id);

create table account_mapping (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  profile_version_id uuid not null,
  source_account_code text,
  source_account_name text not null,
  source_identity_key text generated always as (
    case
      when source_account_code is not null
        then 'code:' || lower(btrim(source_account_code))
      else 'name:' || lower(btrim(source_account_name))
    end
  ) stored,
  ladder_line_id uuid not null references ladder_line(id),
  mapping_basis text not null
    check (mapping_basis in ('confirmed','suggested_then_confirmed')),
  approved_by uuid references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  unique nulls not distinct (
    profile_version_id, source_account_code, source_account_name
  ),
  unique (profile_version_id, source_identity_key),
  check (
    source_account_code is null
    or length(btrim(source_account_code)) > 0
  ),
  check (length(btrim(source_account_name)) > 0)
);
create index account_mapping_profile_idx on account_mapping (profile_version_id);

create table item_mapping (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  profile_version_id uuid not null,
  source_item_code text,
  source_item_name text not null,
  source_identity_key text generated always as (
    case
      when source_item_code is not null
        then 'code:' || lower(btrim(source_item_code))
      else 'name:' || lower(btrim(source_item_name))
    end
  ) stored,
  -- The canonical item dimension is deliberately Slice 5. Until then, this
  -- stable key is the canonical item identity carried by profile mappings.
  -- Slice 5 will add item_id and backfill it without rewriting approved history.
  canonical_item_key text not null,
  mapping_basis text not null
    check (mapping_basis in ('confirmed','suggested_then_confirmed')),
  approved_by uuid references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  unique nulls not distinct (
    profile_version_id, source_item_code, source_item_name
  ),
  unique (profile_version_id, source_identity_key),
  check (
    source_item_code is null
    or length(btrim(source_item_code)) > 0
  ),
  check (length(btrim(source_item_name)) > 0),
  check (length(btrim(canonical_item_key)) > 0)
);
create index item_mapping_profile_idx on item_mapping (profile_version_id);

create table value_mapping (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  profile_version_id uuid not null,
  field_name text not null,
  source_value text not null,
  canonical_value text not null,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  unique (profile_version_id, field_name, source_value),
  check (length(btrim(field_name)) > 0)
);
create index value_mapping_profile_idx on value_mapping (profile_version_id);

create table transform_rule (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  profile_version_id uuid not null,
  sequence_no int not null check (sequence_no > 0),
  transform_code text not null
    check (transform_code in (
      'trim_whitespace',
      'case_normalization',
      'remove_thousands_separators',
      'sign_flip',
      'fixed_factor',
      'tax_strip',
      'parse_date',
      'parse_month_label',
      'unpivot_month_columns',
      'split_delimited',
      'fixed_value',
      'controlled_value_map',
      'controlled_uom_conversion'
    )),
  target_field text,
  params_json jsonb not null default '{}'::jsonb
    check (jsonb_typeof(params_json) = 'object'),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  unique (profile_version_id, sequence_no)
);
create index transform_rule_profile_idx
  on transform_rule (profile_version_id, sequence_no);

create or replace function ensure_active_profile_version_approved()
returns trigger
language plpgsql
as $$
begin
  if new.active_profile_version_id is null then
    return new;
  end if;

  if not exists (
    select 1
    from profile_version pv
    where pv.id = new.active_profile_version_id
      and pv.organisation_id = new.organisation_id
      and pv.outlet_id = new.outlet_id
      and pv.source_profile_id = new.id
      and pv.status = 'approved'
      and pv.approved_at is not null
  ) then
    raise exception 'active profile version must be an approved version of the same source profile'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger source_profile_active_version_guard
  before insert or update of active_profile_version_id on source_profile
  for each row execute function ensure_active_profile_version_approved();

create trigger source_profile_updated_at
  before update on source_profile
  for each row execute function set_updated_at();

create trigger profile_version_immutable_when_approved
  before update or delete on profile_version
  for each row execute function forbid_mutation_when_approved();

create or replace function forbid_mapping_mutation_when_profile_approved()
returns trigger
language plpgsql
as $$
declare
  target_profile_version_id uuid;
begin
  if tg_op = 'DELETE' then
    target_profile_version_id := old.profile_version_id;
  else
    target_profile_version_id := new.profile_version_id;
  end if;

  if exists (
    select 1
    from profile_version pv
    where pv.id = target_profile_version_id
      and pv.approved_at is not null
  ) then
    raise exception
      'mapping is immutable because profile version % is approved',
      target_profile_version_id
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end
$$;

create trigger column_mapping_profile_immutability
  before insert or update or delete on column_mapping
  for each row execute function forbid_mapping_mutation_when_profile_approved();

create trigger account_mapping_profile_immutability
  before insert or update or delete on account_mapping
  for each row execute function forbid_mapping_mutation_when_profile_approved();

create trigger item_mapping_profile_immutability
  before insert or update or delete on item_mapping
  for each row execute function forbid_mapping_mutation_when_profile_approved();

create trigger value_mapping_profile_immutability
  before insert or update or delete on value_mapping
  for each row execute function forbid_mapping_mutation_when_profile_approved();

create trigger transform_rule_profile_immutability
  before insert or update or delete on transform_rule
  for each row execute function forbid_mapping_mutation_when_profile_approved();

alter table source_profile enable row level security;
alter table profile_version enable row level security;
alter table column_mapping enable row level security;
alter table account_mapping enable row level security;
alter table item_mapping enable row level security;
alter table value_mapping enable row level security;
alter table transform_rule enable row level security;

create policy source_profile_read on source_profile
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy source_profile_write on source_profile
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy profile_version_read on profile_version
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy profile_version_write on profile_version
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy column_mapping_read on column_mapping
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy column_mapping_write on column_mapping
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy account_mapping_read on account_mapping
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy account_mapping_write on account_mapping
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy item_mapping_read on item_mapping
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy item_mapping_write on item_mapping
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy value_mapping_read on value_mapping
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy value_mapping_write on value_mapping
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy transform_rule_read on transform_rule
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy transform_rule_write on transform_rule
  for all to restaurant_app
  using (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  )
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

grant select, insert, update, delete on
  source_profile, profile_version, column_mapping, account_mapping,
  item_mapping, value_mapping, transform_rule
to restaurant_app;

-- Rollback / forward-fix note:
-- This migration is additive. Before production data exists it may be reverted
-- by dropping the seven tables, their policies/triggers and the two helper
-- functions. After approved profile history exists, use a forward migration;
-- never drop or rewrite approved profile versions or mappings.
