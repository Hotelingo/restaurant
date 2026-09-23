-- 0012 · Slice 2 ingestion persistence foundation
-- Raw file metadata, import-batch lifecycle, immutable staging rows and
-- structured validation results. This intentionally stops before canonical
-- fact insertion: the S2-6 commit transaction is completed when the first
-- canonical fact writer exists in Slice 3.

create type scenario_code as enum ('actual','budget','forecast','prior_year');
create type batch_status as enum (
  'uploaded','parsing','needs_mapping','validating','blocked',
  'warning','ready','committed','superseded','rejected'
);
create type validation_severity as enum ('block','warn','info');
create type reconciliation_status as enum ('reconciled','not_reconciled');

alter table reporting_period
  add constraint reporting_period_org_outlet_id_unique
  unique (organisation_id, outlet_id, id);

create table source_file (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  template_code text not null,
  storage_bucket text not null,
  storage_path text not null,
  original_filename text not null,
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  content_type text,
  size_bytes bigint not null check (size_bytes > 0),
  uploaded_by uuid not null references neon_auth."user"(id),
  uploaded_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id)
    references outlet(organisation_id, id),
  unique (organisation_id, outlet_id, id),
  unique (organisation_id, outlet_id, id, template_code),
  check (length(btrim(template_code)) > 0),
  check (length(btrim(storage_bucket)) > 0),
  check (length(btrim(storage_path)) > 0),
  check (length(btrim(original_filename)) > 0)
);
create index source_file_outlet_idx
  on source_file (organisation_id, outlet_id, uploaded_at desc);
create index source_file_sha_idx
  on source_file (organisation_id, outlet_id, sha256);

create or replace function validate_source_file_storage_path()
returns trigger
language plpgsql
as $$
declare
  expected_prefix text;
begin
  expected_prefix :=
    'org/' || new.organisation_id::text ||
    '/outlet/' || new.outlet_id::text ||
    '/source/' || new.id::text || '/';

  if left(new.storage_path, length(expected_prefix)) <> expected_prefix then
    raise exception
      'storage_path must start with %', expected_prefix
      using errcode = 'check_violation';
  end if;

  return new;
end
$$;

create trigger source_file_storage_path_guard
  before insert on source_file
  for each row execute function validate_source_file_storage_path();

create trigger source_file_immutable
  before update or delete on source_file
  for each row execute function forbid_mutation();

create table import_batch (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  source_file_id uuid not null,
  template_code text not null,
  profile_version_id uuid,
  period_id uuid,
  scenario scenario_code not null default 'actual',
  status batch_status not null default 'uploaded',
  detected_fingerprint text,
  supersedes_batch_id uuid,
  superseded_by_batch_id uuid,
  superseded_at timestamptz,
  committed_by uuid references neon_auth."user"(id),
  committed_at timestamptz,
  canonical_commit_hash text,
  canonical_commit_summary jsonb not null default '{}'::jsonb
    check (jsonb_typeof(canonical_commit_summary) = 'object'),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, source_file_id, template_code)
    references source_file(organisation_id, outlet_id, id, template_code),
  foreign key (organisation_id, outlet_id, profile_version_id)
    references profile_version(organisation_id, outlet_id, id),
  foreign key (organisation_id, outlet_id, period_id)
    references reporting_period(organisation_id, outlet_id, id),
  unique (organisation_id, outlet_id, id),
  check (
    detected_fingerprint is null
    or detected_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  check (
    canonical_commit_hash is null
    or canonical_commit_hash ~ '^[0-9a-f]{64}$'
  ),
  check (
    status not in ('committed','superseded')
    or (
      period_id is not null
      and profile_version_id is not null
      and committed_by is not null
      and committed_at is not null
      and canonical_commit_hash is not null
    )
  ),
  check (
    status <> 'superseded'
    or (
      superseded_by_batch_id is not null
      and superseded_at is not null
    )
  )
);

alter table import_batch
  add constraint import_batch_supersedes_same_tenant_fk
  foreign key (organisation_id, outlet_id, supersedes_batch_id)
  references import_batch(organisation_id, outlet_id, id);

alter table import_batch
  add constraint import_batch_superseded_by_same_tenant_fk
  foreign key (organisation_id, outlet_id, superseded_by_batch_id)
  references import_batch(organisation_id, outlet_id, id);

create index import_batch_outlet_idx
  on import_batch (organisation_id, outlet_id, created_at desc);
create index import_batch_status_idx
  on import_batch (outlet_id, status, created_at desc);
create unique index import_batch_one_committed_scope_idx
  on import_batch (outlet_id, period_id, scenario, template_code)
  where status = 'committed';

create or replace function guard_import_batch_mutation()
returns trigger
language plpgsql
as $$
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

  return new;
end
$$;

create trigger import_batch_mutation_guard
  before update or delete on import_batch
  for each row execute function guard_import_batch_mutation();

create table staging_row (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  batch_id uuid not null,
  source_row_no int not null check (source_row_no > 0),
  raw_jsonb jsonb not null
    check (jsonb_typeof(raw_jsonb) = 'object'),
  parsed_jsonb jsonb
    check (parsed_jsonb is null or jsonb_typeof(parsed_jsonb) = 'object'),
  row_status text,
  parse_errors jsonb not null default '[]'::jsonb
    check (jsonb_typeof(parse_errors) = 'array'),
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, batch_id)
    references import_batch(organisation_id, outlet_id, id),
  unique (batch_id, source_row_no),
  unique (organisation_id, outlet_id, id)
);
create index staging_row_batch_idx
  on staging_row (batch_id, source_row_no);

create trigger staging_row_immutable
  before update or delete on staging_row
  for each row execute function forbid_mutation();

create table validation_result (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  batch_id uuid not null,
  staging_row_id uuid,
  rule_code text not null,
  severity validation_severity not null,
  object_scope text not null,
  field_name text,
  actual_json jsonb,
  expected_json jsonb,
  tolerance_json jsonb,
  message text not null,
  remediation text not null,
  reconciliation_status reconciliation_status not null default 'reconciled',
  resolved boolean not null default false,
  resolution_note text,
  resolved_by uuid references neon_auth."user"(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (organisation_id, outlet_id, batch_id)
    references import_batch(organisation_id, outlet_id, id),
  foreign key (organisation_id, outlet_id, staging_row_id)
    references staging_row(organisation_id, outlet_id, id),
  check (length(btrim(rule_code)) > 0),
  check (length(btrim(object_scope)) > 0),
  check (length(btrim(message)) > 0),
  check (length(btrim(remediation)) > 0),
  check (
    (resolved = false and resolved_by is null and resolved_at is null)
    or
    (resolved = true and resolved_by is not null and resolved_at is not null
      and resolution_note is not null and length(btrim(resolution_note)) > 0)
  )
);
create index validation_result_batch_idx
  on validation_result (batch_id, severity, resolved);
create index validation_result_unresolved_block_idx
  on validation_result (batch_id)
  where severity = 'block' and resolved = false;

create or replace function guard_validation_resolution()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'validation results are retained; delete is not permitted'
      using errcode = 'restrict_violation';
  end if;

  if old.resolved then
    raise exception 'resolved validation result is immutable'
      using errcode = 'restrict_violation';
  end if;

  if new.resolved
     and (to_jsonb(new) - array[
       'resolved','resolution_note','resolved_by','resolved_at'
     ]) = (to_jsonb(old) - array[
       'resolved','resolution_note','resolved_by','resolved_at'
     ]) then
    return new;
  end if;

  raise exception
    'validation result may only transition from unresolved to resolved'
    using errcode = 'restrict_violation';
end
$$;

create trigger validation_result_resolution_guard
  before update or delete on validation_result
  for each row execute function guard_validation_resolution();

create or replace function batch_has_unresolved_blocks(p_batch_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.validation_result vr
    where vr.batch_id = p_batch_id
      and vr.severity = 'block'
      and not vr.resolved
  )
$$;

create or replace function supersede_import_batch(
  p_old_batch_id uuid,
  p_new_batch_id uuid,
  p_correlation_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_old public.import_batch%rowtype;
  v_new public.import_batch%rowtype;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_old
  from public.import_batch
  where id = p_old_batch_id
  for update;

  if v_old.id is null or v_old.status <> 'committed' then
    raise exception 'old batch must be an existing committed batch'
      using errcode = 'check_violation';
  end if;

  if not public.has_org_role(
       v_old.organisation_id,
       array['admin','editor','setup_analyst']::public.app_role[]
     )
     or not public.has_outlet_access(v_old.organisation_id, v_old.outlet_id) then
    raise exception 'batch is not available in the current access context'
      using errcode = 'insufficient_privilege';
  end if;

  select * into v_new
  from public.import_batch
  where id = p_new_batch_id
  for update;

  if v_new.id is null
     or v_new.organisation_id <> v_old.organisation_id
     or v_new.outlet_id <> v_old.outlet_id
     or v_new.period_id is distinct from v_old.period_id
     or v_new.scenario <> v_old.scenario
     or v_new.template_code <> v_old.template_code
     or v_new.supersedes_batch_id is distinct from v_old.id
     or v_new.status in ('committed','superseded','rejected') then
    raise exception 'new batch is not a valid explicit superseding batch for the same scope'
      using errcode = 'check_violation';
  end if;

  update public.import_batch
  set status = 'superseded',
      superseded_by_batch_id = v_new.id,
      superseded_at = now()
  where id = v_old.id;

  insert into public.audit_log (
    actor_user_id, organisation_id, outlet_id,
    action_code, object_type, object_id, correlation_id
  )
  values (
    v_user_id, v_old.organisation_id, v_old.outlet_id,
    'IMPORT_BATCH_SUPERSEDED', 'import_batch', v_old.id::text, p_correlation_id
  );

  return v_old.id;
end
$$;

revoke all on function batch_has_unresolved_blocks(uuid) from public;
revoke all on function supersede_import_batch(uuid,uuid,text) from public;
grant execute on function batch_has_unresolved_blocks(uuid) to restaurant_app;
grant execute on function supersede_import_batch(uuid,uuid,text) to restaurant_app;

alter table source_file enable row level security;
alter table import_batch enable row level security;
alter table staging_row enable row level security;
alter table validation_result enable row level security;

create policy source_file_read on source_file
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy source_file_insert on source_file
  for insert to restaurant_app
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy import_batch_read on import_batch
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy import_batch_insert on import_batch
  for insert to restaurant_app
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );
create policy import_batch_update on import_batch
  for update to restaurant_app
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

create policy staging_row_read on staging_row
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy staging_row_insert on staging_row
  for insert to restaurant_app
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );

create policy validation_result_read on validation_result
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id, outlet_id))
    or has_staff_outlet_access(organisation_id, outlet_id)
  );
create policy validation_result_insert on validation_result
  for insert to restaurant_app
  with check (
    has_org_role(
      organisation_id,
      array['admin','editor','setup_analyst']::app_role[]
    )
    and has_outlet_access(organisation_id, outlet_id)
  );
create policy validation_result_update on validation_result
  for update to restaurant_app
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

grant select, insert on source_file, staging_row to restaurant_app;
grant select, insert, update on import_batch, validation_result to restaurant_app;

-- Rollback / forward-fix:
-- additive migration. Before production ingestion data exists, the four tables,
-- policies, triggers, enum types and helper functions may be dropped in reverse
-- dependency order. Once source files or committed batches exist, use forward
-- migrations only; raw/staging history must not be rewritten.
