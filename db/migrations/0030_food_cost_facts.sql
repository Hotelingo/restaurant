-- 0030 · Canonical Food Cost inputs (T2 / T3 / T4A)
-- Slice 5 / S5-2. Adds immutable item, item-sales, stock and approved item-cost
-- facts with source->staging->profile lineage and an atomic/idempotent commit
-- path. T3 Expected_Usage is deliberately not a canonical field and any
-- attempt to place expected_usage in parsed staging data blocks commit.

create table item (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  canonical_item_key text not null,
  item_code text,
  item_name text not null,
  product_group text,
  population text,
  active_from date,
  active_to date,
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id)
    references outlet(organisation_id,id),
  unique (organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,canonical_item_key),
  check (length(btrim(canonical_item_key)) > 0),
  check (length(btrim(item_name)) > 0),
  check (item_code is null or length(btrim(item_code)) > 0),
  check (product_group is null or length(btrim(product_group)) > 0),
  check (population is null or length(btrim(population)) > 0),
  check (active_to is null or active_from is null or active_to >= active_from)
);
create index item_outlet_key_idx
  on item(organisation_id,outlet_id,canonical_item_key);

create trigger item_immutable
  before update or delete on item
  for each row execute function forbid_mutation();

-- Backfill any pre-Slice-5 item mappings without rewriting the immutable mapping.
insert into item(
  organisation_id,outlet_id,canonical_item_key,item_code,item_name
)
select distinct on (
  im.organisation_id,im.outlet_id,lower(btrim(im.canonical_item_key))
)
  im.organisation_id,
  im.outlet_id,
  lower(btrim(im.canonical_item_key)),
  nullif(btrim(im.source_item_code),''),
  btrim(im.source_item_name)
from item_mapping im
order by
  im.organisation_id,im.outlet_id,lower(btrim(im.canonical_item_key)),im.created_at,im.id
on conflict (organisation_id,outlet_id,canonical_item_key) do nothing;

alter table item_mapping
  add column item_id uuid;

-- Migration-only linkage backfill. Approved mapping identity/history is not
-- changed; only the newly introduced canonical item FK is populated.
alter table item_mapping
  disable trigger item_mapping_profile_immutability;

update item_mapping im
set item_id=i.id
from item i
where i.organisation_id=im.organisation_id
  and i.outlet_id=im.outlet_id
  and i.canonical_item_key=lower(btrim(im.canonical_item_key));

alter table item_mapping
  enable trigger item_mapping_profile_immutability;

alter table item_mapping
  add constraint item_mapping_item_same_tenant_fk
  foreign key (organisation_id,outlet_id,item_id)
  references item(organisation_id,outlet_id,id);


create table item_sales_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  item_id uuid not null,
  product_group text,
  population text,
  units_sold numeric(20,4) not null check (units_sold >= 0),
  net_revenue numeric(20,4) not null,
  gross_revenue numeric(20,4),
  discount numeric(20,4),
  meal_period text,
  channel text,
  batch_id uuid not null,
  profile_version_id uuid not null,
  staging_row_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,period_id)
    references reporting_period(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,item_id)
    references item(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,batch_id)
    references import_batch(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,profile_version_id)
    references profile_version(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,staging_row_id)
    references staging_row(organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,id),
  unique (batch_id,staging_row_id),
  check (product_group is null or length(btrim(product_group)) > 0)
);
create index item_sales_fact_period_group_idx
  on item_sales_fact(outlet_id,period_id,product_group,item_id);


create table stock_fact (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  product_group text not null,
  category text,
  opening_inventory numeric(20,4) not null check (opening_inventory >= 0),
  purchases numeric(20,4) not null check (purchases >= 0),
  closing_inventory numeric(20,4) not null check (closing_inventory >= 0),
  external_inbound_transfer numeric(20,4),
  external_outbound_transfer numeric(20,4),
  non_revenue_use numeric(20,4),
  inventory_location text,
  valuation_basis text,
  source_product_revenue numeric(20,4),
  source_budget_cost_pct numeric(20,8)
    check (source_budget_cost_pct is null or source_budget_cost_pct >= 0),
  batch_id uuid not null,
  profile_version_id uuid not null,
  staging_row_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,period_id)
    references reporting_period(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,batch_id)
    references import_batch(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,profile_version_id)
    references profile_version(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,staging_row_id)
    references staging_row(organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,id),
  unique (batch_id,staging_row_id),
  check (length(btrim(product_group)) > 0)
);
create index stock_fact_period_group_idx
  on stock_fact(outlet_id,period_id,product_group,category);


create table item_cost_snapshot (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  period_id uuid not null,
  item_id uuid not null,
  effective_from date not null,
  approved_cost_per_unit numeric(20,6) not null
    check (approved_cost_per_unit >= 0),
  recipe_version text,
  approved_portion numeric(20,6),
  yield_factor numeric(20,8),
  uom text,
  source_status text,
  effective_from_basis text not null default 'source'
    check (effective_from_basis in ('source','fixed_default')),
  batch_id uuid not null,
  profile_version_id uuid not null,
  staging_row_id uuid not null,
  created_at timestamptz not null default now(),
  foreign key (organisation_id,outlet_id,period_id)
    references reporting_period(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,item_id)
    references item(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,batch_id)
    references import_batch(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,profile_version_id)
    references profile_version(organisation_id,outlet_id,id),
  foreign key (organisation_id,outlet_id,staging_row_id)
    references staging_row(organisation_id,outlet_id,id),
  unique (organisation_id,outlet_id,id),
  unique (batch_id,staging_row_id),
  check (approved_portion is null or approved_portion >= 0),
  check (yield_factor is null or yield_factor > 0)
);
create index item_cost_snapshot_effective_idx
  on item_cost_snapshot(outlet_id,item_id,effective_from desc);


-- Canonical dimensions/facts cannot be rewritten by a browser or after commit.
create trigger item_sales_fact_immutable
  before update or delete on item_sales_fact
  for each row execute function forbid_mutation();
create trigger stock_fact_immutable
  before update or delete on stock_fact
  for each row execute function forbid_mutation();
create trigger item_cost_snapshot_immutable
  before update or delete on item_cost_snapshot
  for each row execute function forbid_mutation();

alter table item enable row level security;
alter table item_sales_fact enable row level security;
alter table stock_fact enable row level security;
alter table item_cost_snapshot enable row level security;

create policy item_read on item
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );
create policy item_sales_fact_read on item_sales_fact
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );
create policy stock_fact_read on stock_fact
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );
create policy item_cost_snapshot_read on item_cost_snapshot
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on item,item_sales_fact,stock_fact,item_cost_snapshot
  to restaurant_app;


-- Generalise the existing commit-state trigger so each supported template must
-- have the correct canonical fact family before status may become committed.
create or replace function guard_import_batch_mutation()
returns trigger
language plpgsql
as $$
declare
  v_has_canonical boolean := false;
begin
  if tg_op = 'DELETE' then
    raise exception 'import batches are retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'superseded' then
    raise exception 'superseded import batch is immutable'
      using errcode = 'restrict_violation';
  end if;

  if old.status = 'committed' then
    if new.status = 'superseded'
       and new.superseded_by_batch_id is not null
       and new.superseded_at is not null
       and (to_jsonb(new) - array[
         'status','superseded_by_batch_id','superseded_at'
       ]) = (to_jsonb(old) - array[
         'status','superseded_by_batch_id','superseded_at'
       ]) then
      return new;
    end if;

    raise exception
      'committed import batch is immutable except controlled supersede'
      using errcode = 'restrict_violation';
  end if;

  if new.status = 'committed' and old.status <> 'committed' then
    if new.committed_by is null
       or new.committed_at is null
       or new.canonical_commit_hash is null
       or new.period_id is null
       or new.profile_version_id is null then
      raise exception 'committed batch requires complete commit metadata'
        using errcode = 'check_violation';
    end if;

    if public.batch_has_unresolved_blocks(new.id) then
      raise exception 'batch has unresolved block validations'
        using errcode = 'check_violation';
    end if;

    if new.template_code in ('T1','T6') then
      select exists(
        select 1 from public.financial_fact where batch_id=new.id
      ) into v_has_canonical;
    elsif new.template_code='T2' then
      select exists(
        select 1 from public.item_sales_fact where batch_id=new.id
      ) into v_has_canonical;
    elsif new.template_code='T3' then
      select exists(
        select 1 from public.stock_fact where batch_id=new.id
      ) into v_has_canonical;
    elsif new.template_code='T4A' then
      select exists(
        select 1 from public.item_cost_snapshot where batch_id=new.id
      ) into v_has_canonical;
    else
      v_has_canonical := false;
    end if;

    if not v_has_canonical then
      raise exception 'batch cannot be committed without canonical facts for template %',
        new.template_code
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;


create or replace function _commit_food_cost_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null,
  p_fault_after_step integer default null
)
returns table (
  committed_batch_id uuid,
  commit_status public.batch_status,
  fact_count bigint,
  commit_hash text,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_batch public.import_batch%rowtype;
  v_existing jsonb;
  v_operation text := 'import.commit.food_cost:'||p_batch_id::text;
  v_period_month text;
  v_fact_count bigint := 0;
  v_hash text;
  v_summary jsonb;
  v_ready_status text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if p_fault_after_step is not null
     and (p_fault_after_step<1 or p_fault_after_step>8) then
    raise exception 'fault injection step must be between 1 and 8'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_batch
  from public.import_batch
  where id=p_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'import batch not found'
      using errcode='no_data_found';
  end if;

  if not public.has_org_role(
       v_batch.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_batch.organisation_id,v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode='insufficient_privilege';
  end if;

  if v_batch.template_code not in ('T2','T3','T4A') then
    raise exception 'food-cost commit supports T2, T3 and T4A only'
      using errcode='feature_not_supported';
  end if;

  if v_batch.scenario <> 'actual' then
    raise exception 'T2, T3 and T4A Slice 5 canonical inputs use actual scenario'
      using errcode='check_violation';
  end if;

  if p_fault_after_step=1 then raise exception 'FAULT_STEP_1'; end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'committed_batch_id',false) then
    return query select
      (v_existing->>'committed_batch_id')::uuid,
      (v_existing->>'commit_status')::public.batch_status,
      (v_existing->>'fact_count')::bigint,
      v_existing->>'commit_hash',
      true;
    return;
  end if;

  if v_batch.status='committed' then
    if v_batch.template_code='T2' then
      select count(*) into v_fact_count from public.item_sales_fact
      where batch_id=v_batch.id;
    elsif v_batch.template_code='T3' then
      select count(*) into v_fact_count from public.stock_fact
      where batch_id=v_batch.id;
    else
      select count(*) into v_fact_count from public.item_cost_snapshot
      where batch_id=v_batch.id;
    end if;
    v_hash := v_batch.canonical_commit_hash;

    update public.request_idempotency
    set response_json=jsonb_build_object(
      'committed_batch_id',v_batch.id,
      'commit_status',v_batch.status::text,
      'fact_count',v_fact_count,
      'commit_hash',v_hash
    )
    where user_id=v_user_id
      and operation=v_operation
      and idempotency_key=p_idempotency_key;

    return query select v_batch.id,v_batch.status,v_fact_count,v_hash,true;
    return;
  end if;

  if v_batch.status not in ('ready','warning') then
    raise exception 'batch status % is not committable',v_batch.status
      using errcode='check_violation';
  end if;

  if public.batch_has_unresolved_blocks(v_batch.id) then
    raise exception 'batch has unresolved block validations'
      using errcode='check_violation';
  end if;

  if p_fault_after_step=2 then raise exception 'FAULT_STEP_2'; end if;

  if v_batch.period_id is null or v_batch.profile_version_id is null then
    raise exception 'batch requires reporting period and profile version before commit'
      using errcode='check_violation';
  end if;

  if not exists (
    select 1
    from public.profile_version pv
    where pv.id=v_batch.profile_version_id
      and pv.organisation_id=v_batch.organisation_id
      and pv.outlet_id=v_batch.outlet_id
      and pv.status='approved'
      and pv.approved_at is not null
  ) then
    raise exception 'batch profile version is not approved'
      using errcode='check_violation';
  end if;

  select to_char(period_start,'YYYY-MM')
  into v_period_month
  from public.reporting_period
  where id=v_batch.period_id
    and organisation_id=v_batch.organisation_id
    and outlet_id=v_batch.outlet_id;

  if v_period_month is null then
    raise exception 'batch reporting period is not available'
      using errcode='check_violation';
  end if;

  if not exists (
    select 1 from public.staging_row where batch_id=v_batch.id
  ) then
    raise exception 'batch has no staging rows'
      using errcode='check_violation';
  end if;

  if exists (
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id
      and (
        s.parsed_jsonb is null
        or s.parsed_jsonb->>'period' is distinct from v_period_month
      )
  ) then
    raise exception 'food-cost staging rows are not bound to the batch reporting period'
      using errcode='check_violation';
  end if;

  if v_batch.template_code='T3' and exists (
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id
      and s.parsed_jsonb ? 'expected_usage'
  ) then
    raise exception 'T3 expected_usage is not a canonical input; derive FC.EXPECTED_USAGE from T2 x T4A'
      using errcode='check_violation';
  end if;

  if p_fault_after_step=3 then raise exception 'FAULT_STEP_3'; end if;

  if v_batch.template_code in ('T2','T4A') then
    if exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and nullif(btrim(coalesce(s.parsed_jsonb->>'item_code','')),'') is null
        and nullif(btrim(coalesce(s.parsed_jsonb->>'item_name','')),'') is null
    ) then
      raise exception '% staging contains a row without item identity',v_batch.template_code
        using errcode='check_violation';
    end if;

    if exists (
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists (
          select 1
          from public.item_mapping im
          where im.profile_version_id=v_batch.profile_version_id
            and im.source_identity_key=(
              case
                when nullif(btrim(s.parsed_jsonb->>'item_code'),'') is not null
                  then 'code:'||lower(btrim(s.parsed_jsonb->>'item_code'))
                else 'name:'||lower(btrim(s.parsed_jsonb->>'item_name'))
              end
            )
        )
    ) then
      raise exception '% contains an unmapped item',v_batch.template_code
        using errcode='check_violation';
    end if;

    insert into public.item(
      organisation_id,outlet_id,canonical_item_key,item_code,item_name,
      product_group,population
    )
    select distinct on (lower(btrim(im.canonical_item_key)))
      v_batch.organisation_id,
      v_batch.outlet_id,
      lower(btrim(im.canonical_item_key)),
      nullif(btrim(s.parsed_jsonb->>'item_code'),''),
      coalesce(
        nullif(btrim(s.parsed_jsonb->>'item_name'),''),
        btrim(im.source_item_name)
      ),
      nullif(lower(btrim(s.parsed_jsonb->>'product_group')),''),
      nullif(btrim(s.parsed_jsonb->>'population'),'')
    from public.staging_row s
    join public.item_mapping im
      on im.profile_version_id=v_batch.profile_version_id
     and im.source_identity_key=(
       case
         when nullif(btrim(s.parsed_jsonb->>'item_code'),'') is not null
           then 'code:'||lower(btrim(s.parsed_jsonb->>'item_code'))
         else 'name:'||lower(btrim(s.parsed_jsonb->>'item_name'))
       end
     )
    where s.batch_id=v_batch.id
    order by lower(btrim(im.canonical_item_key)),s.source_row_no
    on conflict (organisation_id,outlet_id,canonical_item_key) do nothing;
  else
    if exists (
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and nullif(btrim(s.parsed_jsonb->>'product_group'),'') is null
    ) then
      raise exception 'T3 staging row is missing product_group'
        using errcode='check_violation';
    end if;

    if exists (
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists (
          select 1 from public.value_mapping vm
          where vm.profile_version_id=v_batch.profile_version_id
            and lower(btrim(vm.field_name))='product_group'
            and lower(btrim(vm.source_value))=
                lower(btrim(s.parsed_jsonb->>'product_group'))
        )
    ) then
      raise exception 'T3 contains an unmapped product_group'
        using errcode='check_violation';
    end if;
  end if;

  if p_fault_after_step=4 then raise exception 'FAULT_STEP_4'; end if;

  if v_batch.template_code='T2' then
    if exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and (
          nullif(btrim(s.parsed_jsonb->>'units_sold'),'') is null
          or nullif(btrim(s.parsed_jsonb->>'net_revenue'),'') is null
          or (s.parsed_jsonb->>'units_sold')::numeric < 0
        )
    ) then
      raise exception 'T2 requires non-negative units_sold and numeric net_revenue'
        using errcode='check_violation';
    end if;

    insert into public.item_sales_fact(
      organisation_id,outlet_id,period_id,item_id,
      product_group,population,units_sold,net_revenue,gross_revenue,discount,
      meal_period,channel,batch_id,profile_version_id,staging_row_id
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      i.id,
      nullif(lower(btrim(s.parsed_jsonb->>'product_group')),''),
      nullif(btrim(s.parsed_jsonb->>'population'),''),
      (s.parsed_jsonb->>'units_sold')::numeric(20,4),
      (s.parsed_jsonb->>'net_revenue')::numeric(20,4),
      nullif(s.parsed_jsonb->>'gross_revenue','')::numeric(20,4),
      nullif(s.parsed_jsonb->>'discount','')::numeric(20,4),
      nullif(btrim(s.parsed_jsonb->>'meal_period'),''),
      nullif(btrim(s.parsed_jsonb->>'channel'),''),
      v_batch.id,
      v_batch.profile_version_id,
      s.id
    from public.staging_row s
    join public.item_mapping im
      on im.profile_version_id=v_batch.profile_version_id
     and im.source_identity_key=(
       case
         when nullif(btrim(s.parsed_jsonb->>'item_code'),'') is not null
           then 'code:'||lower(btrim(s.parsed_jsonb->>'item_code'))
         else 'name:'||lower(btrim(s.parsed_jsonb->>'item_name'))
       end
     )
    join public.item i
      on i.organisation_id=v_batch.organisation_id
     and i.outlet_id=v_batch.outlet_id
     and i.canonical_item_key=lower(btrim(im.canonical_item_key))
    where s.batch_id=v_batch.id;

  elsif v_batch.template_code='T3' then
    if exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and (
          nullif(btrim(s.parsed_jsonb->>'opening_inventory'),'') is null
          or nullif(btrim(s.parsed_jsonb->>'purchases'),'') is null
          or nullif(btrim(s.parsed_jsonb->>'closing_inventory'),'') is null
          or (s.parsed_jsonb->>'opening_inventory')::numeric < 0
          or (s.parsed_jsonb->>'purchases')::numeric < 0
          or (s.parsed_jsonb->>'closing_inventory')::numeric < 0
        )
    ) then
      raise exception 'T3 requires non-negative opening inventory, purchases and closing inventory'
        using errcode='check_violation';
    end if;

    insert into public.stock_fact(
      organisation_id,outlet_id,period_id,product_group,category,
      opening_inventory,purchases,closing_inventory,
      external_inbound_transfer,external_outbound_transfer,non_revenue_use,
      inventory_location,valuation_basis,
      source_product_revenue,source_budget_cost_pct,
      batch_id,profile_version_id,staging_row_id
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      lower(btrim(vm.canonical_value)),
      nullif(btrim(s.parsed_jsonb->>'category'),''),
      (s.parsed_jsonb->>'opening_inventory')::numeric(20,4),
      (s.parsed_jsonb->>'purchases')::numeric(20,4),
      (s.parsed_jsonb->>'closing_inventory')::numeric(20,4),
      nullif(s.parsed_jsonb->>'external_inbound_transfer','')::numeric(20,4),
      nullif(s.parsed_jsonb->>'external_outbound_transfer','')::numeric(20,4),
      nullif(s.parsed_jsonb->>'non_revenue_use','')::numeric(20,4),
      nullif(btrim(s.parsed_jsonb->>'inventory_location'),''),
      nullif(btrim(s.parsed_jsonb->>'valuation_basis'),''),
      nullif(s.parsed_jsonb->>'source_product_revenue','')::numeric(20,4),
      nullif(s.parsed_jsonb->>'source_budget_cost_pct','')::numeric(20,8),
      v_batch.id,
      v_batch.profile_version_id,
      s.id
    from public.staging_row s
    join public.value_mapping vm
      on vm.profile_version_id=v_batch.profile_version_id
     and lower(btrim(vm.field_name))='product_group'
     and lower(btrim(vm.source_value))=
         lower(btrim(s.parsed_jsonb->>'product_group'))
    where s.batch_id=v_batch.id;

  else
    if exists (
      select 1 from public.staging_row s
      where s.batch_id=v_batch.id
        and (
          nullif(btrim(s.parsed_jsonb->>'effective_from'),'') is null
          or nullif(btrim(s.parsed_jsonb->>'approved_cost_per_unit'),'') is null
          or (s.parsed_jsonb->>'approved_cost_per_unit')::numeric < 0
        )
    ) then
      raise exception 'T4A requires effective_from and non-negative approved_cost_per_unit'
        using errcode='check_violation';
    end if;

    insert into public.item_cost_snapshot(
      organisation_id,outlet_id,period_id,item_id,effective_from,
      approved_cost_per_unit,recipe_version,approved_portion,yield_factor,uom,
      source_status,effective_from_basis,
      batch_id,profile_version_id,staging_row_id
    )
    select
      v_batch.organisation_id,
      v_batch.outlet_id,
      v_batch.period_id,
      i.id,
      (s.parsed_jsonb->>'effective_from')::date,
      (s.parsed_jsonb->>'approved_cost_per_unit')::numeric(20,6),
      nullif(btrim(s.parsed_jsonb->>'recipe_version'),''),
      nullif(s.parsed_jsonb->>'approved_portion','')::numeric(20,6),
      nullif(s.parsed_jsonb->>'yield_factor','')::numeric(20,8),
      nullif(btrim(s.parsed_jsonb->>'uom'),''),
      nullif(btrim(s.parsed_jsonb->>'source_status'),''),
      coalesce(nullif(btrim(s.parsed_jsonb->>'effective_from_basis'),''),'source'),
      v_batch.id,
      v_batch.profile_version_id,
      s.id
    from public.staging_row s
    join public.item_mapping im
      on im.profile_version_id=v_batch.profile_version_id
     and im.source_identity_key=(
       case
         when nullif(btrim(s.parsed_jsonb->>'item_code'),'') is not null
           then 'code:'||lower(btrim(s.parsed_jsonb->>'item_code'))
         else 'name:'||lower(btrim(s.parsed_jsonb->>'item_name'))
       end
     )
    join public.item i
      on i.organisation_id=v_batch.organisation_id
     and i.outlet_id=v_batch.outlet_id
     and i.canonical_item_key=lower(btrim(im.canonical_item_key))
    where s.batch_id=v_batch.id;
  end if;

  get diagnostics v_fact_count=row_count;
  if v_fact_count=0 then
    raise exception 'canonical food-cost commit produced zero facts'
      using errcode='check_violation';
  end if;

  if p_fault_after_step=5 then raise exception 'FAULT_STEP_5'; end if;

  if v_batch.template_code='T2' then
    select
      encode(public.digest(convert_to(string_agg(
        concat_ws('|',i.canonical_item_key,coalesce(f.product_group,''),
          f.units_sold::text,f.net_revenue::text,coalesce(f.meal_period,''),
          coalesce(f.channel,'')),
        E'\n' order by i.canonical_item_key,f.staging_row_id
      ),'UTF8'),'sha256'),'hex'),
      jsonb_build_object(
        'fact_count',count(*)::bigint,
        'units_total',sum(f.units_sold)::text,
        'net_revenue_total',sum(f.net_revenue)::text
      )
    into v_hash,v_summary
    from public.item_sales_fact f
    join public.item i on i.id=f.item_id
    where f.batch_id=v_batch.id;
  elsif v_batch.template_code='T3' then
    select
      encode(public.digest(convert_to(string_agg(
        concat_ws('|',f.product_group,coalesce(f.category,''),
          f.opening_inventory::text,f.purchases::text,f.closing_inventory::text,
          coalesce(f.source_product_revenue::text,''),
          coalesce(f.source_budget_cost_pct::text,'')),
        E'\n' order by f.product_group,coalesce(f.category,''),f.staging_row_id
      ),'UTF8'),'sha256'),'hex'),
      jsonb_build_object(
        'fact_count',count(*)::bigint,
        'purchases_total',sum(f.purchases)::text
      )
    into v_hash,v_summary
    from public.stock_fact f
    where f.batch_id=v_batch.id;
  else
    select
      encode(public.digest(convert_to(string_agg(
        concat_ws('|',i.canonical_item_key,f.effective_from::text,
          f.approved_cost_per_unit::text,coalesce(f.recipe_version,'')),
        E'\n' order by i.canonical_item_key,f.effective_from,f.staging_row_id
      ),'UTF8'),'sha256'),'hex'),
      jsonb_build_object(
        'fact_count',count(*)::bigint
      )
    into v_hash,v_summary
    from public.item_cost_snapshot f
    join public.item i on i.id=f.item_id
    where f.batch_id=v_batch.id;
  end if;

  if v_hash is null then
    raise exception 'canonical food-cost checksum could not be produced'
      using errcode='check_violation';
  end if;

  if p_fault_after_step=6 then raise exception 'FAULT_STEP_6'; end if;

  update public.import_batch
  set status='committed',
      committed_by=v_user_id,
      committed_at=now(),
      canonical_commit_hash=v_hash,
      canonical_commit_summary=v_summary
  where id=v_batch.id;

  v_batch.status := 'committed';
  v_batch.canonical_commit_hash := v_hash;

  if p_fault_after_step=7 then raise exception 'FAULT_STEP_7'; end if;

  if exists (
    select 1 from public.import_batch b
    where b.organisation_id=v_batch.organisation_id
      and b.outlet_id=v_batch.outlet_id
      and b.period_id=v_batch.period_id
      and b.template_code='T2'
      and b.status='committed'
  ) and exists (
    select 1 from public.import_batch b
    where b.organisation_id=v_batch.organisation_id
      and b.outlet_id=v_batch.outlet_id
      and b.period_id=v_batch.period_id
      and b.template_code='T3'
      and b.status='committed'
  ) and exists (
    select 1 from public.import_batch b
    where b.organisation_id=v_batch.organisation_id
      and b.outlet_id=v_batch.outlet_id
      and b.period_id=v_batch.period_id
      and b.template_code='T4A'
      and b.status='committed'
  ) then
    v_ready_status := 'ready';
  else
    v_ready_status := 'partial';
  end if;

  insert into public.data_readiness(
    organisation_id,outlet_id,period_id,capability_code,
    status,latest_batch_id,details_json
  )
  values(
    v_batch.organisation_id,
    v_batch.outlet_id,
    v_batch.period_id,
    'food_cost_inputs',
    v_ready_status,
    v_batch.id,
    jsonb_build_object(
      't2_item_sales_committed',exists(
        select 1 from public.import_batch b
        where b.outlet_id=v_batch.outlet_id
          and b.period_id=v_batch.period_id
          and b.template_code='T2' and b.status='committed'
      ),
      't3_stock_committed',exists(
        select 1 from public.import_batch b
        where b.outlet_id=v_batch.outlet_id
          and b.period_id=v_batch.period_id
          and b.template_code='T3' and b.status='committed'
      ),
      't4a_item_cost_committed',exists(
        select 1 from public.import_batch b
        where b.outlet_id=v_batch.outlet_id
          and b.period_id=v_batch.period_id
          and b.template_code='T4A' and b.status='committed'
      ),
      'expected_usage_source','DERIVED_T2_X_T4A'
    )
  )
  on conflict(organisation_id,outlet_id,period_id,capability_code)
  do update set
    status=excluded.status,
    latest_batch_id=excluded.latest_batch_id,
    details_json=excluded.details_json,
    updated_at=now();

  if p_fault_after_step=8 then raise exception 'FAULT_STEP_8'; end if;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,after_hash,correlation_id
  )
  values(
    v_user_id,v_batch.organisation_id,v_batch.outlet_id,
    'FOOD_COST_IMPORT_BATCH_COMMITTED','import_batch',v_batch.id::text,
    v_hash,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'committed_batch_id',v_batch.id,
    'commit_status','committed',
    'fact_count',v_fact_count,
    'commit_hash',v_hash
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select
    v_batch.id,'committed'::public.batch_status,v_fact_count,v_hash,false;
end
$$;


create or replace function commit_food_cost_import_batch(
  p_batch_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  committed_batch_id uuid,
  commit_status public.batch_status,
  fact_count bigint,
  commit_hash text,
  reused boolean
)
language sql
security definer
set search_path=''
as $$
  select *
  from public._commit_food_cost_import_batch(
    p_batch_id,p_idempotency_key,p_correlation_id,null
  )
$$;

revoke all on function _commit_food_cost_import_batch(uuid,text,text,integer)
  from public;
revoke all on function commit_food_cost_import_batch(uuid,text,text)
  from public;
grant execute on function commit_food_cost_import_batch(uuid,text,text)
  to restaurant_app;



-- First-run/drift confirmation for T2/T3/T4A. This mirrors the existing
-- financial profile workflow while using item identities and controlled
-- product-group values. Canonical item rows are created while the new profile
-- is still draft so item_mapping can carry a same-tenant item_id before the
-- profile becomes immutable.
create or replace function confirm_food_cost_mapping(
  p_batch_id uuid,
  p_idempotency_key text,
  p_source_label text default null,
  p_base_profile_version_id uuid default null,
  p_item_mappings jsonb default '[]'::jsonb,
  p_product_group_mappings jsonb default '[]'::jsonb,
  p_correlation_id text default null
)
returns table (
  confirmed_profile_version_id uuid,
  confirmed_version_no integer,
  confirmed_batch_status public.batch_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_batch public.import_batch%rowtype;
  v_existing jsonb;
  v_operation text := 'import.mapping.confirm.food_cost:'||p_batch_id::text;
  v_base_profile_id uuid;
  v_source_profile_id uuid;
  v_new_profile_id uuid;
  v_version_no integer;
  v_layout jsonb;
  v_components jsonb;
  v_transform_config jsonb := '[]'::jsonb;
  v_source_label text;
  v_required_fields text[];
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if jsonb_typeof(coalesce(p_item_mappings,'[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_product_group_mappings,'[]'::jsonb))<>'array' then
    raise exception 'mapping payloads must be JSON arrays'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_batch
  from public.import_batch
  where id=p_batch_id
  for update;

  if v_batch.id is null then
    raise exception 'import batch not found'
      using errcode='no_data_found';
  end if;

  if not public.has_org_role(
       v_batch.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_batch.organisation_id,v_batch.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode='insufficient_privilege';
  end if;

  if v_batch.template_code not in ('T2','T3','T4A') then
    raise exception 'food-cost mapping confirmation supports T2, T3 and T4A only'
      using errcode='feature_not_supported';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'profile_version_id',false) then
    return query select
      (v_existing->>'profile_version_id')::uuid,
      (v_existing->>'version_no')::integer,
      (v_existing->>'batch_status')::public.batch_status,
      true;
    return;
  end if;

  if v_batch.status<>'needs_mapping' then
    raise exception 'batch status % does not accept mapping confirmation',v_batch.status
      using errcode='check_violation';
  end if;

  if v_batch.detected_fingerprint is null
     or v_batch.parse_completed_at is null
     or v_batch.parse_metadata_json='{}'::jsonb then
    raise exception 'batch must be parsed and fingerprinted before mapping confirmation'
      using errcode='check_violation';
  end if;

  if exists(
    select 1 from public.staging_row s
    where s.batch_id=v_batch.id
      and jsonb_array_length(s.parse_errors)>0
  ) then
    raise exception 'parse errors must be corrected before mapping confirmation'
      using errcode='check_violation';
  end if;

  v_base_profile_id := coalesce(
    p_base_profile_version_id,
    v_batch.candidate_profile_version_id
  );

  if v_base_profile_id is not null then
    select pv.source_profile_id into v_source_profile_id
    from public.profile_version pv
    join public.source_profile sp on sp.id=pv.source_profile_id
    where pv.id=v_base_profile_id
      and pv.organisation_id=v_batch.organisation_id
      and pv.outlet_id=v_batch.outlet_id
      and pv.status='approved'
      and pv.approved_at is not null
      and sp.template_code=v_batch.template_code;

    if v_source_profile_id is null then
      raise exception 'base profile version is not an approved profile in this import scope'
        using errcode='check_violation';
    end if;
  else
    v_source_label := nullif(btrim(p_source_label),'');
    if v_source_label is null then
      raise exception 'source_label is required when no base profile is selected'
        using errcode='check_violation';
    end if;

    select id into v_source_profile_id
    from public.source_profile
    where organisation_id=v_batch.organisation_id
      and outlet_id=v_batch.outlet_id
      and template_code=v_batch.template_code
      and source_label=v_source_label
    for update;

    if v_source_profile_id is null then
      insert into public.source_profile(
        organisation_id,outlet_id,template_code,source_label
      )
      values(
        v_batch.organisation_id,v_batch.outlet_id,
        v_batch.template_code,v_source_label
      )
      returning id into v_source_profile_id;
    end if;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_source_profile_id::text,5030)
  );

  select coalesce(max(version_no),0)+1 into v_version_no
  from public.profile_version
  where source_profile_id=v_source_profile_id;

  v_components := v_batch.parse_metadata_json->'fingerprint_components';
  if jsonb_typeof(v_components)<>'object' then
    raise exception 'batch fingerprint components are missing'
      using errcode='check_violation';
  end if;

  v_layout := jsonb_build_object(
    'headers',coalesce(v_batch.parse_metadata_json->'headers','[]'::jsonb),
    'sheet_name',v_batch.parse_metadata_json->>'selected_sheet_name',
    'field_map',coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb),
    'target_period',v_batch.parse_metadata_json->>'target_period',
    'ignored_source_fields',
      coalesce(v_batch.parse_metadata_json->'ignored_source_fields','[]'::jsonb),
    'effective_from_default',
      v_batch.parse_metadata_json->>'effective_from_default'
  );

  if v_batch.template_code='T4A'
     and nullif(v_batch.parse_metadata_json->>'effective_from_default','') is not null then
    v_transform_config := jsonb_build_array(
      jsonb_build_object(
        'code','fixed_value',
        'target_field','effective_from',
        'params',jsonb_build_object(
          'value',v_batch.parse_metadata_json->>'effective_from_default',
          'basis','explicit_import_request'
        )
      )
    );
  end if;

  insert into public.profile_version(
    organisation_id,outlet_id,source_profile_id,version_no,
    layout_json,fingerprint_hash,fingerprint_components_json,
    transform_config_json,status,supersedes_profile_version_id
  )
  values(
    v_batch.organisation_id,v_batch.outlet_id,v_source_profile_id,v_version_no,
    v_layout,v_batch.detected_fingerprint,v_components,
    v_transform_config,'draft',
    case when v_base_profile_id is null then null else v_base_profile_id end
  )
  returning id into v_new_profile_id;

  if v_batch.template_code='T2' then
    v_required_fields := array['units_sold','net_revenue'];
  elsif v_batch.template_code='T3' then
    v_required_fields := array[
      'product_group','opening_inventory','purchases','closing_inventory'
    ];
  else
    v_required_fields := array['approved_cost_per_unit'];
  end if;

  insert into public.column_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_column,canonical_field,required
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
    field.key,field.value,
    field.value=any(v_required_fields)
  from jsonb_each_text(
    coalesce(v_batch.parse_metadata_json->'field_map','{}'::jsonb)
  ) field
  where field.value<>'expected_usage';

  if v_batch.template_code='T4A'
     and nullif(v_batch.parse_metadata_json->>'effective_from_default','') is not null then
    insert into public.transform_rule(
      organisation_id,outlet_id,profile_version_id,
      sequence_no,transform_code,target_field,params_json
    )
    values(
      v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
      1,'fixed_value','effective_from',
      jsonb_build_object(
        'value',v_batch.parse_metadata_json->>'effective_from_default',
        'basis','explicit_import_request'
      )
    );
  end if;

  if v_base_profile_id is not null then
    insert into public.item_mapping(
      organisation_id,outlet_id,profile_version_id,
      source_item_code,source_item_name,canonical_item_key,
      mapping_basis,approved_by,item_id
    )
    select
      v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
      im.source_item_code,im.source_item_name,im.canonical_item_key,
      'confirmed',v_user_id,im.item_id
    from public.item_mapping im
    where im.profile_version_id=v_base_profile_id;

    insert into public.value_mapping(
      organisation_id,outlet_id,profile_version_id,
      field_name,source_value,canonical_value
    )
    select
      v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
      vm.field_name,vm.source_value,vm.canonical_value
    from public.value_mapping vm
    where vm.profile_version_id=v_base_profile_id;
  end if;

  if exists(
    select 1
    from jsonb_array_elements(coalesce(p_item_mappings,'[]'::jsonb)) m
    where (
      nullif(btrim(m->>'source_item_code'),'') is null
      and nullif(btrim(m->>'source_item_name'),'') is null
    )
    or nullif(btrim(m->>'canonical_item_key'),'') is null
  ) then
    raise exception 'item mapping contains a blank source or canonical identity'
      using errcode='check_violation';
  end if;

  insert into public.item(
    organisation_id,outlet_id,canonical_item_key,item_code,item_name
  )
  select distinct on (lower(btrim(m->>'canonical_item_key')))
    v_batch.organisation_id,
    v_batch.outlet_id,
    lower(btrim(m->>'canonical_item_key')),
    nullif(btrim(m->>'source_item_code'),''),
    coalesce(
      nullif(btrim(m->>'source_item_name'),''),
      lower(btrim(m->>'canonical_item_key'))
    )
  from jsonb_array_elements(coalesce(p_item_mappings,'[]'::jsonb)) m
  order by lower(btrim(m->>'canonical_item_key'))
  on conflict(organisation_id,outlet_id,canonical_item_key) do nothing;

  insert into public.item_mapping(
    organisation_id,outlet_id,profile_version_id,
    source_item_code,source_item_name,canonical_item_key,
    mapping_basis,approved_by,item_id
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
    nullif(btrim(m->>'source_item_code'),''),
    coalesce(
      nullif(btrim(m->>'source_item_name'),''),
      lower(btrim(m->>'canonical_item_key'))
    ),
    lower(btrim(m->>'canonical_item_key')),
    'confirmed',v_user_id,i.id
  from jsonb_array_elements(coalesce(p_item_mappings,'[]'::jsonb)) m
  join public.item i
    on i.organisation_id=v_batch.organisation_id
   and i.outlet_id=v_batch.outlet_id
   and i.canonical_item_key=lower(btrim(m->>'canonical_item_key'))
  on conflict(profile_version_id,source_identity_key)
  do update set
    source_item_code=excluded.source_item_code,
    source_item_name=excluded.source_item_name,
    canonical_item_key=excluded.canonical_item_key,
    mapping_basis='confirmed',
    approved_by=v_user_id,
    item_id=excluded.item_id;

  if exists(
    select 1
    from jsonb_array_elements(coalesce(p_product_group_mappings,'[]'::jsonb)) m
    where nullif(btrim(m->>'source_value'),'') is null
       or lower(btrim(coalesce(m->>'canonical_value',''))) not in ('food','beverage')
  ) then
    raise exception 'product-group mapping must map a source value to food or beverage'
      using errcode='check_violation';
  end if;

  insert into public.value_mapping(
    organisation_id,outlet_id,profile_version_id,
    field_name,source_value,canonical_value
  )
  select
    v_batch.organisation_id,v_batch.outlet_id,v_new_profile_id,
    'product_group',
    btrim(m->>'source_value'),
    lower(btrim(m->>'canonical_value'))
  from jsonb_array_elements(coalesce(p_product_group_mappings,'[]'::jsonb)) m
  on conflict(profile_version_id,field_name,source_value)
  do update set canonical_value=excluded.canonical_value;

  if v_batch.template_code in ('T2','T4A') then
    if exists(
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists(
          select 1 from public.item_mapping im
          where im.profile_version_id=v_new_profile_id
            and im.source_identity_key=(
              case
                when nullif(btrim(s.parsed_jsonb->>'item_code'),'') is not null
                  then 'code:'||lower(btrim(s.parsed_jsonb->>'item_code'))
                else 'name:'||lower(btrim(s.parsed_jsonb->>'item_name'))
              end
            )
            and im.item_id is not null
        )
    ) then
      raise exception 'not every staged item identity has a confirmed canonical item mapping'
        using errcode='check_violation';
    end if;
  else
    if exists(
      select 1
      from public.staging_row s
      where s.batch_id=v_batch.id
        and not exists(
          select 1 from public.value_mapping vm
          where vm.profile_version_id=v_new_profile_id
            and lower(btrim(vm.field_name))='product_group'
            and lower(btrim(vm.source_value))=
                lower(btrim(s.parsed_jsonb->>'product_group'))
            and lower(btrim(vm.canonical_value)) in ('food','beverage')
        )
    ) then
      raise exception 'not every staged T3 product group has a confirmed mapping'
        using errcode='check_violation';
    end if;
  end if;

  update public.profile_version
  set status='approved',approved_by=v_user_id,approved_at=now()
  where id=v_new_profile_id;

  update public.source_profile
  set active_profile_version_id=v_new_profile_id
  where id=v_source_profile_id;

  update public.import_batch
  set profile_version_id=v_new_profile_id,status='validating'
  where id=v_batch.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_batch.organisation_id,v_batch.outlet_id,
    'FOOD_COST_MAPPING_CONFIRMED','profile_version',
    v_new_profile_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'profile_version_id',v_new_profile_id,
    'version_no',v_version_no,
    'batch_status','validating'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select
    v_new_profile_id,v_version_no,'validating'::public.batch_status,false;
end
$$;

revoke all on function confirm_food_cost_mapping(
  uuid,text,text,uuid,jsonb,jsonb,text
) from public;
grant execute on function confirm_food_cost_mapping(
  uuid,text,text,uuid,jsonb,jsonb,text
) to restaurant_app;
