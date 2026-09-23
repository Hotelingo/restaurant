-- 0018 · Immutable calculation run persistence
-- Slice 3 persistence foundation for server/worker-authored calculation snapshots.
-- The review table is introduced in Slice 4; review_id is intentionally added then,
-- with a real FK, rather than storing an unconstrained placeholder now.

alter table calculation_request_queue
  add constraint calculation_request_queue_tenant_id_unique
  unique (organisation_id, outlet_id, id);

create table calc_run (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  request_id uuid,
  engine_version text not null,
  settings_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(settings_snapshot) = 'object'),
  comparator_scenario scenario_code,
  status text not null default 'queued'
    check (status in ('queued','running','completed','failed')),
  started_at timestamptz,
  completed_at timestamptz,
  result_hash text,
  error_code text,
  error_message text,
  supersedes_calc_run_id uuid,
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, request_id)
    references calculation_request_queue(organisation_id, outlet_id, id),

  unique (organisation_id, outlet_id, id),

  check (length(btrim(engine_version)) > 0),
  check (comparator_scenario is null or comparator_scenario <> 'actual'),
  check (result_hash is null or result_hash ~ '^[0-9a-f]{64}$'),
  check (
    (status = 'queued'
      and started_at is null
      and completed_at is null
      and result_hash is null
      and error_code is null
      and error_message is null)
    or
    (status = 'running'
      and started_at is not null
      and completed_at is null
      and result_hash is null
      and error_code is null
      and error_message is null)
    or
    (status = 'completed'
      and started_at is not null
      and completed_at is not null
      and result_hash is not null
      and error_code is null
      and error_message is null)
    or
    (status = 'failed'
      and started_at is not null
      and completed_at is not null
      and result_hash is null
      and error_message is not null
      and length(btrim(error_message)) > 0)
  )
);

alter table calc_run
  add constraint calc_run_supersedes_same_tenant_fk
  foreign key (organisation_id, outlet_id, supersedes_calc_run_id)
  references calc_run(organisation_id, outlet_id, id);

create unique index calc_run_request_unique_idx
  on calc_run(request_id)
  where request_id is not null;

create index calc_run_outlet_period_idx
  on calc_run(outlet_id, period_id, created_at desc);

create index calc_run_status_idx
  on calc_run(status, created_at)
  where status in ('queued','running');

create table calc_run_input (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  run_id uuid not null,
  batch_id uuid not null,
  profile_version_id uuid not null,
  input_role text not null,
  scenario scenario_code not null,
  canonical_commit_hash text not null,
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, run_id)
    references calc_run(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, batch_id)
    references import_batch(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),

  unique (run_id, batch_id),
  unique (organisation_id, outlet_id, id),

  check (length(btrim(input_role)) > 0),
  check (canonical_commit_hash ~ '^[0-9a-f]{64}$')
);

create index calc_run_input_run_idx
  on calc_run_input(run_id, input_role);

create index calc_run_input_batch_idx
  on calc_run_input(batch_id);

create table calc_result (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  run_id uuid not null,
  calc_id text not null,
  grain_type text not null,
  grain_key jsonb not null
    check (jsonb_typeof(grain_key) = 'object'),
  value_numeric numeric(20,4),
  value_text text,
  unit text not null,
  currency_code char(3),
  calculation_status text not null
    check (calculation_status in ('CALCULATED','NOT_CALCULATED')),
  evidence_status text not null,
  explanation_code text,
  result_metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(result_metadata) = 'object'),
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, run_id)
    references calc_run(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, currency_code)
    references outlet(organisation_id, id, currency_code),

  unique (run_id, calc_id, grain_key),
  unique (organisation_id, outlet_id, run_id, id),

  check (length(btrim(calc_id)) > 0),
  check (length(btrim(grain_type)) > 0),
  check (length(btrim(unit)) > 0),
  check (length(btrim(evidence_status)) > 0),
  check (currency_code is null or currency_code = upper(currency_code)),
  check (
    (
      calculation_status = 'CALCULATED'
      and num_nonnulls(value_numeric, value_text) = 1
      and explanation_code is null
    )
    or
    (
      calculation_status = 'NOT_CALCULATED'
      and value_numeric is null
      and value_text is null
      and explanation_code is not null
      and length(btrim(explanation_code)) > 0
    )
  )
);

create index calc_result_run_calc_idx
  on calc_result(run_id, calc_id);

create index calc_result_run_grain_idx
  on calc_result(run_id, grain_type);

create table calc_dependency (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  run_id uuid not null,
  parent_result_id uuid not null,
  child_result_id uuid not null,
  dependency_role text not null,
  created_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, run_id, parent_result_id)
    references calc_result(organisation_id, outlet_id, run_id, id),

  foreign key (organisation_id, outlet_id, run_id, child_result_id)
    references calc_result(organisation_id, outlet_id, run_id, id),

  unique (run_id, parent_result_id, child_result_id, dependency_role),

  check (parent_result_id <> child_result_id),
  check (length(btrim(dependency_role)) > 0)
);

create index calc_dependency_parent_idx
  on calc_dependency(run_id, parent_result_id);

create index calc_dependency_child_idx
  on calc_dependency(run_id, child_result_id);


-- Lifecycle: a calc run is append-only except for the two controlled status
-- transitions needed by the worker. Terminal runs cannot be edited or deleted.
create or replace function guard_calc_run_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'calculation runs are retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.status in ('completed','failed') then
    raise exception 'terminal calculation run is immutable'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'queued'
     and new.status = 'running'
     and new.started_at is not null
     and new.completed_at is null
     and (
       to_jsonb(new) - array['status','started_at']
     ) = (
       to_jsonb(old) - array['status','started_at']
     ) then
    return new;
  end if;

  if old.status = 'running'
     and new.status = 'completed'
     and new.completed_at is not null
     and new.result_hash is not null
     and (
       to_jsonb(new) - array['status','completed_at','result_hash']
     ) = (
       to_jsonb(old) - array['status','completed_at','result_hash']
     ) then
    return new;
  end if;

  if old.status = 'running'
     and new.status = 'failed'
     and new.completed_at is not null
     and new.error_message is not null
     and length(btrim(new.error_message)) > 0
     and (
       to_jsonb(new) - array['status','completed_at','error_code','error_message']
     ) = (
       to_jsonb(old) - array['status','completed_at','error_code','error_message']
     ) then
    return new;
  end if;

  raise exception 'invalid or mutating calculation-run transition % -> %',
    old.status, new.status
    using errcode = 'restrict_violation';
end
$$;

create trigger calc_run_mutation_guard
  before update or delete on calc_run
  for each row execute function guard_calc_run_mutation();


create or replace function guard_calc_run_input_insert()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
  v_batch public.import_batch%rowtype;
begin
  select * into v_run
  from public.calc_run
  where id = new.run_id;

  if v_run.id is null
     or v_run.organisation_id <> new.organisation_id
     or v_run.outlet_id <> new.outlet_id
     or v_run.status not in ('queued','running') then
    raise exception 'calculation run does not accept inputs'
      using errcode = 'check_violation';
  end if;

  select * into v_batch
  from public.import_batch
  where id = new.batch_id;

  if v_batch.id is null
     or v_batch.organisation_id <> new.organisation_id
     or v_batch.outlet_id <> new.outlet_id
     or v_batch.period_id is distinct from v_run.period_id
     or v_batch.status <> 'committed'
     or v_batch.profile_version_id is distinct from new.profile_version_id
     or v_batch.scenario <> new.scenario
     or v_batch.canonical_commit_hash is distinct from new.canonical_commit_hash
     or not exists (
       select 1
       from public.financial_fact ff
       where ff.batch_id = v_batch.id
     ) then
    raise exception 'calc input must reference a committed canonical batch in the run context'
      using errcode = 'check_violation';
  end if;

  if new.input_role = 'actual' and new.scenario <> 'actual' then
    raise exception 'actual calc input must use actual scenario'
      using errcode = 'check_violation';
  end if;

  if new.input_role = 'comparator'
     and (
       v_run.comparator_scenario is null
       or new.scenario <> v_run.comparator_scenario
     ) then
    raise exception 'comparator calc input must match run comparator scenario'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger calc_run_input_insert_guard
  before insert on calc_run_input
  for each row execute function guard_calc_run_input_insert();

create trigger calc_run_input_immutable
  before update or delete on calc_run_input
  for each row execute function forbid_mutation();


create or replace function guard_calc_result_insert()
returns trigger
language plpgsql
as $$
begin
  if not exists (
    select 1
    from public.calc_run r
    where r.id = new.run_id
      and r.organisation_id = new.organisation_id
      and r.outlet_id = new.outlet_id
      and r.status = 'running'
  ) then
    raise exception 'calculation results may only be inserted into a running calc run'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger calc_result_insert_guard
  before insert on calc_result
  for each row execute function guard_calc_result_insert();

create trigger calc_result_immutable
  before update or delete on calc_result
  for each row execute function forbid_mutation();


create or replace function guard_calc_dependency_insert()
returns trigger
language plpgsql
as $$
begin
  if not exists (
    select 1
    from public.calc_run r
    where r.id = new.run_id
      and r.organisation_id = new.organisation_id
      and r.outlet_id = new.outlet_id
      and r.status = 'running'
  ) then
    raise exception 'calculation dependencies may only be inserted into a running calc run'
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger calc_dependency_insert_guard
  before insert on calc_dependency
  for each row execute function guard_calc_dependency_insert();

create trigger calc_dependency_immutable
  before update or delete on calc_dependency
  for each row execute function forbid_mutation();


alter table calc_run enable row level security;
alter table calc_run_input enable row level security;
alter table calc_result enable row level security;
alter table calc_dependency enable row level security;

create policy calc_run_read on calc_run
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy calc_run_input_read on calc_run_input
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy calc_result_read on calc_result
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy calc_dependency_read on calc_dependency
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on calc_run, calc_run_input, calc_result, calc_dependency
  to restaurant_app;


-- Seed the accepted PL v1 definitions. Stable calc ids are separate from
-- canonical ladder codes where the product terminology differs.
insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values
  ('PL.NET_SALES','v1','PL','Net Sales','currency','sum:NET_SALES',true),
  ('PL.PRODUCT_COST','v1','PL','Product Cost','currency','sum:PRODUCT_COST',true),
  ('PL.PRODUCT_MARGIN','v1','PL','Product Margin','currency','NET_SALES-PRODUCT_COST',true),
  ('PL.CHANNEL_COST','v1','PL','Acquisition / Channel Cost','currency','sum:CHANNEL_COST',true),
  ('PL.DIRECT_LABOUR','v1','PL','Direct Labour','currency','sum:DIRECT_LABOUR',true),
  ('PL.OTHER_DIRECT_OPERATING','v1','PL','Other Direct Operating Cost','currency','sum:OTHER_DIRECT_OPERATING',true),
  ('PL.CONTRIBUTION','v1','PL','Contribution','currency','PRODUCT_MARGIN-CHANNEL_COST-DIRECT_LABOUR-OTHER_DIRECT_OPERATING',true),
  ('PL.SHARED_COST','v1','PL','Shared Restaurant Costs','currency','sum:SHARED_RESTAURANT_COST',true),
  ('PL.OPERATING_PROFIT','v1','PL','Restaurant Operating Profit','currency','CONTRIBUTION-SHARED_RESTAURANT_COST',true),
  ('PL.OWNER_STRUCTURAL_COST','v1','PL','Owner / Structural Costs','currency','sum:OWNER_STRUCTURAL_COST',true),
  ('PL.OWNER_RESULT','v1','PL','Owner Result','currency','OPERATING_PROFIT-OWNER_STRUCTURAL_COST',true),
  ('PL.VAR.NET_SALES','v1','PL','Net Sales variance','currency','variance:NET_SALES',true),
  ('PL.VAR.PRODUCT_COST','v1','PL','Product Cost variance','currency','variance:PRODUCT_COST',true),
  ('PL.VAR.PRODUCT_MARGIN','v1','PL','Product Margin variance','currency','variance:PRODUCT_MARGIN',true),
  ('PL.VAR.CHANNEL_COST','v1','PL','Channel Cost variance','currency','variance:CHANNEL_COST',true),
  ('PL.VAR.DIRECT_LABOUR','v1','PL','Direct Labour variance','currency','variance:DIRECT_LABOUR',true),
  ('PL.VAR.OTHER_DIRECT_OPERATING','v1','PL','Other Direct Operating variance','currency','variance:OTHER_DIRECT_OPERATING',true),
  ('PL.VAR.CONTRIBUTION','v1','PL','Contribution variance','currency','variance:CONTRIBUTION',true),
  ('PL.VAR.SHARED_RESTAURANT_COST','v1','PL','Shared Restaurant Cost variance','currency','variance:SHARED_RESTAURANT_COST',true),
  ('PL.VAR.OPERATING_PROFIT','v1','PL','Operating Profit variance','currency','variance:OPERATING_PROFIT',true),
  ('PL.VAR.OWNER_STRUCTURAL_COST','v1','PL','Owner / Structural Cost variance','currency','variance:OWNER_STRUCTURAL_COST',true),
  ('PL.VAR.OWNER_RESULT','v1','PL','Owner Result variance','currency','variance:OWNER_RESULT',true)
on conflict (calc_id,definition_version) do nothing;

-- Additive/forward-fix-only migration. Historical calc snapshots are never
-- rewritten or deleted once persisted.
