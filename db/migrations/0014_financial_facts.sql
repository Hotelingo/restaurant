-- 0014 · Canonical financial facts foundation
-- Introduces the first canonical fact family needed to finish S2-6 and begin
-- Slice 3. Implements OD-03: actuals are account-grain; comparator facts may
-- be account-grain or ladder-grain. Synthetic accounts are never required.

insert into ladder_framework (code, name)
values ('RPR_PL_V1', 'Restaurant Performance Review Management P&L v1')
on conflict (code) do nothing;

insert into ladder_line (
  framework_id, code, name, kind, display_order, is_calculated
)
select lf.id, seed.code, seed.name, seed.kind, seed.display_order, seed.is_calculated
from ladder_framework lf
cross join (
  values
    ('NET_SALES', 'Net Sales', 'revenue', 1, false),
    ('PRODUCT_COST', 'Product Cost', 'cost', 2, false),
    ('PRODUCT_MARGIN', 'Product Margin', 'subtotal', 3, true),
    ('CHANNEL_COST', 'Acquisition / Channel Cost', 'cost', 4, false),
    ('DIRECT_LABOUR', 'Direct Labour', 'cost', 5, false),
    ('OTHER_DIRECT_OPERATING', 'Other Direct Operating Cost', 'cost', 6, false),
    ('CONTRIBUTION', 'Contribution', 'subtotal', 7, true),
    ('SHARED_RESTAURANT_COST', 'Shared Restaurant Costs', 'cost', 8, false),
    ('OPERATING_PROFIT', 'Operating Profit', 'profit', 9, true),
    ('OWNER_STRUCTURAL_COST', 'Owner / Structural Costs', 'cost', 10, false),
    ('OWNER_RESULT', 'Owner Result', 'profit', 11, true)
) as seed(code, name, kind, display_order, is_calculated)
where lf.code = 'RPR_PL_V1'
on conflict (code) do nothing;

alter table outlet
  add constraint outlet_org_id_currency_unique
  unique (organisation_id, id, currency_code);

alter table import_batch
  add constraint import_batch_fact_context_unique
  unique (
    organisation_id, outlet_id, id, period_id, scenario, profile_version_id
  );

alter table staging_row
  add constraint staging_row_batch_lineage_unique
  unique (organisation_id, outlet_id, batch_id, id);

create table account (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  account_code text,
  account_name text not null,
  account_section text,
  source_identity_key text generated always as (
    case
      when account_code is not null
        then 'code:' || lower(btrim(account_code))
      else 'name:' || lower(btrim(account_name))
    end
  ) stored,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (organisation_id, outlet_id, id),
  unique nulls not distinct (outlet_id, account_code, account_name),
  unique (outlet_id, source_identity_key),
  check (account_code is null or length(btrim(account_code)) > 0),
  check (length(btrim(account_name)) > 0)
);
create index account_outlet_idx
  on account (organisation_id, outlet_id, active);

create table financial_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  scenario scenario_code not null,
  account_id uuid,
  ladder_line_id uuid not null references ladder_line(id),
  amount numeric(20,4) not null,
  currency_code char(3) not null,
  batch_id uuid not null,
  profile_version_id uuid not null,
  staging_row_id uuid,
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, currency_code)
    references outlet(organisation_id, id, currency_code),

  foreign key (organisation_id, outlet_id, account_id)
    references account(organisation_id, outlet_id, id),

  foreign key (
    organisation_id, outlet_id, batch_id,
    period_id, scenario, profile_version_id
  )
    references import_batch(
      organisation_id, outlet_id, id,
      period_id, scenario, profile_version_id
    ),

  foreign key (
    organisation_id, outlet_id, batch_id, staging_row_id
  )
    references staging_row(
      organisation_id, outlet_id, batch_id, id
    ),

  unique (organisation_id, outlet_id, id),

  check (currency_code = upper(currency_code)),
  check (
    (scenario = 'actual' and account_id is not null)
    or scenario <> 'actual'
  )
);

-- One canonical row per source account per committed batch.
create unique index financial_fact_account_grain_unique
  on financial_fact (batch_id, account_id)
  where account_id is not null;

-- Ladder-grain comparators (for example the Amberside T6 budget) have no
-- account_id and therefore need a separate uniqueness rule.
create unique index financial_fact_ladder_grain_unique
  on financial_fact (batch_id, ladder_line_id)
  where account_id is null;

create index financial_fact_outlet_period_scenario_idx
  on financial_fact (outlet_id, period_id, scenario, ladder_line_id);
create index financial_fact_batch_idx
  on financial_fact (batch_id);
create index financial_fact_profile_idx
  on financial_fact (profile_version_id);

create trigger account_immutable
  before update or delete on account
  for each row execute function forbid_mutation();

create trigger financial_fact_immutable
  before update or delete on financial_fact
  for each row execute function forbid_mutation();

alter table account enable row level security;
alter table financial_fact enable row level security;

create policy account_read on account
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

create policy financial_fact_read on financial_fact
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );

-- Deliberately SELECT only. Canonical account/fact writes are performed by the
-- tightly-scoped server commit function added with S2-6. A normal application
-- session has no INSERT/UPDATE/DELETE path to canonical facts.
grant select on account, financial_fact to restaurant_app;

-- Additive migration. Once canonical facts exist, account/fact history is
-- forward-fix only; never rewrite or drop historical facts.
