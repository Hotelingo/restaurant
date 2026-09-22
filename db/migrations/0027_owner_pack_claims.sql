-- 0027 · Owner Pack versions, claims, citations and server-side claim checks
-- Slice 4 / SC14-SC15 foundation. A pack pins exactly one completed calc run.
-- Claims cite immutable calc results from that same run. Numeric prose checks
-- compare claim figures with cited engine output and reject the wireframe's
-- banned accusation/absolute wording before reviewer acceptance.

create type pack_status as enum (
  'draft',
  'in_review',
  'changes_requested',
  'signed',
  'superseded'
);

create type claim_status as enum (
  'draft',
  'edited',
  'accepted',
  'rejected'
);


create table pack_version (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  version_no integer not null check (version_no > 0),
  calc_run_id uuid not null,
  status pack_status not null default 'draft',
  supersedes_pack_version_id uuid,

  generated_at timestamptz not null default now(),

  artifact_bucket text,
  artifact_path text,
  artifact_sha256 text,
  renderer_version text,
  template_version text,

  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),

  foreign key (organisation_id,outlet_id,calc_run_id)
    references calc_run(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),
  unique (review_id,version_no),

  check (
    artifact_sha256 is null
    or artifact_sha256 ~ '^[0-9a-f]{64}$'
  ),
  check (
    (
      artifact_path is null
      and artifact_bucket is null
      and artifact_sha256 is null
      and renderer_version is null
      and template_version is null
    )
    or
    (
      nullif(btrim(artifact_path),'') is not null
      and nullif(btrim(artifact_bucket),'') is not null
      and artifact_sha256 is not null
      and nullif(btrim(renderer_version),'') is not null
      and nullif(btrim(template_version),'') is not null
    )
  ),
  check (
    status <> 'signed'
    or (
      nullif(btrim(artifact_path),'') is not null
      and nullif(btrim(artifact_bucket),'') is not null
      and artifact_sha256 is not null
      and nullif(btrim(renderer_version),'') is not null
      and nullif(btrim(template_version),'') is not null
    )
  )
);

alter table pack_version
  add constraint pack_supersedes_same_tenant_fk
  foreign key (organisation_id,outlet_id,supersedes_pack_version_id)
  references pack_version(organisation_id,outlet_id,id);

create unique index pack_version_one_live_idx
  on pack_version(review_id)
  where status in ('draft','in_review','changes_requested');


create table claim (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  pack_version_id uuid not null,
  section_code text not null,
  claim_text text not null,
  claim_status claim_status not null default 'draft',
  evidence_status text not null,
  edited_by uuid references neon_auth."user"(id),
  edited_at timestamptz,
  reviewed_by uuid references neon_auth."user"(id),
  reviewed_at timestamptz,
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,pack_version_id)
    references pack_version(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,pack_version_id,id),

  check (length(btrim(section_code)) > 0),
  check (length(btrim(claim_text)) > 0),
  check (
    evidence_status in (
      'validated',
      'supported',
      'partly_supported',
      'evidence_required',
      'not_reconciled',
      'not_applicable'
    )
  ),
  check (
    (claim_status='edited' and edited_by is not null and edited_at is not null)
    or claim_status<>'edited'
  ),
  check (
    (
      claim_status in ('accepted','rejected')
      and reviewed_by is not null
      and reviewed_at is not null
    )
    or claim_status not in ('accepted','rejected')
  )
);

create index claim_pack_idx
  on claim(pack_version_id,section_code,created_at,id);


create table claim_citation (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  pack_version_id uuid not null,
  claim_id uuid not null,
  calc_run_id uuid not null,
  calc_result_id uuid not null,
  citation_role text not null default 'support',
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),

  foreign key (
    organisation_id,outlet_id,pack_version_id,claim_id
  )
    references claim(
      organisation_id,outlet_id,pack_version_id,id
    ),

  foreign key (
    organisation_id,outlet_id,calc_run_id,calc_result_id
  )
    references calc_result(
      organisation_id,outlet_id,run_id,id
    ),

  constraint claim_citation_identity_unique
    unique (claim_id,calc_result_id,citation_role),

  check (length(btrim(citation_role)) > 0)
);

create index claim_citation_claim_idx
  on claim_citation(claim_id,created_at,id);


create or replace function guard_pack_version_context()
returns trigger
language plpgsql
as $$
declare
  v_review public.review%rowtype;
  v_run public.calc_run%rowtype;
  v_previous public.pack_version%rowtype;
begin
  select * into v_review
  from public.review
  where id=new.review_id;

  select * into v_run
  from public.calc_run
  where id=new.calc_run_id;

  if v_review.id is null
     or v_run.id is null
     or v_review.organisation_id <> new.organisation_id
     or v_review.outlet_id <> new.outlet_id
     or v_run.organisation_id <> new.organisation_id
     or v_run.outlet_id <> new.outlet_id
     or v_run.period_id <> v_review.period_id
     or v_run.status <> 'completed'
     or v_review.active_calc_run_id is distinct from v_run.id then
    raise exception 'pack version must pin the review active completed calc run'
      using errcode='check_violation';
  end if;

  if new.version_no = 1 and new.supersedes_pack_version_id is not null then
    raise exception 'pack version 1 cannot supersede another pack'
      using errcode='check_violation';
  end if;

  if new.version_no > 1 then
    if new.supersedes_pack_version_id is null then
      raise exception 'later pack version must identify the version it supersedes'
        using errcode='check_violation';
    end if;

    select * into v_previous
    from public.pack_version
    where id=new.supersedes_pack_version_id;

    if v_previous.id is null
       or v_previous.review_id <> new.review_id
       or v_previous.organisation_id <> new.organisation_id
       or v_previous.outlet_id <> new.outlet_id
       or v_previous.version_no <> new.version_no - 1
       or v_previous.status <> 'signed' then
      raise exception 'new pack version must supersede the immediately prior signed version'
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;

create trigger pack_version_context_guard
  before insert on pack_version
  for each row execute function guard_pack_version_context();


create or replace function guard_pack_version_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op='DELETE' then
    raise exception 'pack versions are retained; delete is not permitted'
      using errcode='restrict_violation';
  end if;

  if old.status='signed' then
    raise exception 'signed pack version is immutable'
      using errcode='restrict_violation';
  end if;

  -- Pack content identity is frozen at creation. Later controlled functions may
  -- only advance status and attach the final immutable artefact metadata.
  if (
    to_jsonb(new) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'renderer_version','template_version',
      'updated_at'
    ]
  ) <> (
    to_jsonb(old) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'renderer_version','template_version',
      'updated_at'
    ]
  ) then
    raise exception 'pack version identity and calc snapshot are immutable'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;

create trigger pack_version_mutation_guard
  before update or delete on pack_version
  for each row execute function guard_pack_version_mutation();


create or replace function guard_claim_mutation()
returns trigger
language plpgsql
as $$
declare
  v_pack_id uuid;
begin
  if tg_op='DELETE' then
    raise exception 'claims are retained; reject instead of deleting'
      using errcode='restrict_violation';
  end if;

  v_pack_id := old.pack_version_id;

  if exists (
    select 1 from public.pack_version p
    where p.id=v_pack_id and p.status='signed'
  ) then
    raise exception 'claim is immutable because its pack is signed'
      using errcode='restrict_violation';
  end if;

  if new.organisation_id <> old.organisation_id
     or new.outlet_id <> old.outlet_id
     or new.pack_version_id <> old.pack_version_id
     or new.section_code <> old.section_code
     or new.evidence_status <> old.evidence_status
     or new.created_by <> old.created_by
     or new.created_at <> old.created_at then
    raise exception 'claim provenance fields are immutable'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;

create trigger claim_mutation_guard
  before update or delete on claim
  for each row execute function guard_claim_mutation();

create trigger claim_citation_immutable
  before update or delete on claim_citation
  for each row execute function forbid_mutation();


create or replace function guard_claim_citation_insert()
returns trigger
language plpgsql
as $$
declare
  v_pack public.pack_version%rowtype;
  v_claim public.claim%rowtype;
begin
  select * into v_pack
  from public.pack_version
  where id=new.pack_version_id;

  select * into v_claim
  from public.claim
  where id=new.claim_id;

  if v_pack.id is null
     or v_claim.id is null
     or v_pack.status='signed'
     or v_claim.pack_version_id <> v_pack.id
     or new.calc_run_id <> v_pack.calc_run_id then
    raise exception 'claim citation must use a calc result from the claim pack run'
      using errcode='check_violation';
  end if;

  return new;
end
$$;

create trigger claim_citation_insert_guard
  before insert on claim_citation
  for each row execute function guard_claim_citation_insert();


alter table pack_version enable row level security;
alter table claim enable row level security;
alter table claim_citation enable row level security;

create policy pack_version_read on pack_version
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy claim_read on claim
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy claim_citation_read on claim_citation
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on pack_version,claim,claim_citation to restaurant_app;


create or replace function create_pack_version(
  p_review_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  pack_version_id uuid,
  version_no integer,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_existing jsonb;
  v_operation text := 'pack.create:'||p_review_id::text;
  v_next_version integer;
  v_previous public.pack_version%rowtype;
  v_pack_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_review
  from public.review
  where id=p_review_id
  for update;

  if v_review.id is null
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_review.organisation_id,v_review.outlet_id) then
    raise exception 'review is not available in the current context'
      using errcode='insufficient_privilege';
  end if;

  if v_review.active_calc_run_id is null
     or v_review.frame_confirmed_at is null then
    raise exception 'Owner Pack requires a confirmed FRAME and pinned calc run'
      using errcode='check_violation';
  end if;

  if not exists (
    select 1 from public.calc_run r
    where r.id=v_review.active_calc_run_id
      and r.organisation_id=v_review.organisation_id
      and r.outlet_id=v_review.outlet_id
      and r.period_id=v_review.period_id
      and r.status='completed'
  ) then
    raise exception 'Owner Pack requires the review completed calc run'
      using errcode='check_violation';
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

  if coalesce(v_existing ? 'pack_version_id',false) then
    return query select
      (v_existing->>'pack_version_id')::uuid,
      (v_existing->>'version_no')::integer,
      true;
    return;
  end if;

  if exists (
    select 1 from public.pack_version p
    where p.review_id=v_review.id
      and p.status in ('draft','in_review','changes_requested')
  ) then
    raise exception 'review already has an active unsigned pack version'
      using errcode='unique_violation';
  end if;

  select *
  into v_previous
  from public.pack_version p
  where p.review_id=v_review.id
  order by p.version_no desc
  limit 1;

  if v_previous.id is null then
    v_next_version := 1;
  else
    if v_previous.status <> 'signed' then
      raise exception 'only a signed previous version can be superseded'
        using errcode='check_violation';
    end if;
    v_next_version := v_previous.version_no+1;
  end if;

  insert into public.pack_version(
    organisation_id,outlet_id,review_id,version_no,calc_run_id,
    status,supersedes_pack_version_id,created_by
  )
  values(
    v_review.organisation_id,
    v_review.outlet_id,
    v_review.id,
    v_next_version,
    v_review.active_calc_run_id,
    'draft',
    case when v_previous.id is null then null else v_previous.id end,
    v_user_id
  )
  returning id into v_pack_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'PACK_VERSION_CREATED','pack_version',v_pack_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'pack_version_id',v_pack_id,
    'version_no',v_next_version
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_pack_id,v_next_version,false;
end
$$;


create or replace function create_pack_claim(
  p_pack_version_id uuid,
  p_section_code text,
  p_claim_text text,
  p_evidence_status text,
  p_calc_result_ids uuid[],
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  claim_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_pack public.pack_version%rowtype;
  v_existing jsonb;
  v_operation text := 'pack.claim.create:'||p_pack_version_id::text;
  v_claim_id uuid;
  v_calc_result_id uuid;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_pack
  from public.pack_version
  where id=p_pack_version_id
  for update;

  if v_pack.id is null
     or not public.has_org_role(
       v_pack.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_pack.organisation_id,v_pack.outlet_id) then
    raise exception 'pack is not available in the current context'
      using errcode='insufficient_privilege';
  end if;

  if v_pack.status not in ('draft','in_review','changes_requested') then
    raise exception 'claims cannot be added to a signed or superseded pack'
      using errcode='restrict_violation';
  end if;

  if nullif(btrim(p_section_code),'') is null
     or nullif(btrim(p_claim_text),'') is null then
    raise exception 'claim section and text are required'
      using errcode='check_violation';
  end if;

  if p_evidence_status not in (
    'validated','supported','partly_supported',
    'evidence_required','not_reconciled','not_applicable'
  ) then
    raise exception 'unsupported claim evidence status'
      using errcode='invalid_parameter_value';
  end if;

  if p_calc_result_ids is null
     or coalesce(array_length(p_calc_result_ids,1),0)=0 then
    raise exception 'claim requires at least one calc_result citation'
      using errcode='check_violation';
  end if;

  if exists (
    select 1
    from unnest(p_calc_result_ids) x(id)
    where not exists (
      select 1 from public.calc_result cr
      where cr.id=x.id
        and cr.organisation_id=v_pack.organisation_id
        and cr.outlet_id=v_pack.outlet_id
        and cr.run_id=v_pack.calc_run_id
    )
  ) then
    raise exception 'every claim citation must belong to the pack calc run'
      using errcode='check_violation';
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

  if coalesce(v_existing ? 'claim_id',false) then
    return query select
      (v_existing->>'claim_id')::uuid,
      true;
    return;
  end if;

  insert into public.claim(
    organisation_id,outlet_id,pack_version_id,
    section_code,claim_text,evidence_status,created_by
  )
  values(
    v_pack.organisation_id,v_pack.outlet_id,v_pack.id,
    btrim(p_section_code),btrim(p_claim_text),p_evidence_status,v_user_id
  )
  returning id into v_claim_id;

  foreach v_calc_result_id in array p_calc_result_ids loop
    insert into public.claim_citation(
      organisation_id,outlet_id,pack_version_id,claim_id,
      calc_run_id,calc_result_id,citation_role,created_by
    )
    values(
      v_pack.organisation_id,v_pack.outlet_id,v_pack.id,v_claim_id,
      v_pack.calc_run_id,v_calc_result_id,'support',v_user_id
    )
    on conflict on constraint claim_citation_identity_unique do nothing;
  end loop;

  update public.request_idempotency
  set response_json=jsonb_build_object('claim_id',v_claim_id)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_claim_id,false;
end
$$;


create or replace function claim_check(
  p_claim_id uuid
)
returns jsonb
language plpgsql
security definer
stable
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_claim public.claim%rowtype;
  v_pack public.pack_version%rowtype;
  v_has_citation boolean;
  v_banned text[];
  v_numbers numeric[];
  v_allowed numeric[];
  v_unmatched numeric[];
  v_passed boolean;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  select * into v_claim
  from public.claim
  where id=p_claim_id;

  if v_claim.id is null
     or not (
       (
         public.has_org_access(v_claim.organisation_id)
         and public.has_outlet_access(v_claim.organisation_id,v_claim.outlet_id)
       )
       or public.has_staff_outlet_access(v_claim.organisation_id,v_claim.outlet_id)
     ) then
    raise exception 'claim is not available in the current context'
      using errcode='insufficient_privilege';
  end if;

  select * into v_pack
  from public.pack_version
  where id=v_claim.pack_version_id;

  select exists(
    select 1 from public.claim_citation cc
    where cc.claim_id=v_claim.id
  ) into v_has_citation;

  select coalesce(array_agg(distinct lower(m[1])),array[]::text[])
  into v_banned
  from regexp_matches(
    v_claim.claim_text,
    '\m(theft|steal|stealing|fraud|guarantee|always|never)\M',
    'gi'
  ) m;

  select coalesce(
    array_agg(
      abs(
        replace(
          replace(
            replace(m[1],'−','-'),
            ',',''
          ),
          '%',''
        )::numeric
      )
    ),
    array[]::numeric[]
  )
  into v_numbers
  from regexp_matches(
    v_claim.claim_text,
    '([+-−]?[0-9][0-9,]*(?:\.[0-9]+)?%?)',
    'g'
  ) m;

  select coalesce(
    array_agg(distinct candidate),
    array[]::numeric[]
  )
  into v_allowed
  from (
    select abs(cr.value_numeric) as candidate
    from public.claim_citation cc
    join public.calc_result cr
      on cr.id=cc.calc_result_id
     and cr.run_id=cc.calc_run_id
    where cc.claim_id=v_claim.id
      and cr.value_numeric is not null

    union all

    select abs(cr.value_numeric*100) as candidate
    from public.claim_citation cc
    join public.calc_result cr
      on cr.id=cc.calc_result_id
     and cr.run_id=cc.calc_run_id
    where cc.claim_id=v_claim.id
      and cr.value_numeric is not null
      and cr.unit in ('ratio','percent')
  ) allowed_values
  where candidate is not null;

  select coalesce(array_agg(x),array[]::numeric[])
  into v_unmatched
  from unnest(v_numbers) x
  where not exists (
    select 1
    from unnest(v_allowed) a
    where abs(a-x) <= 0.0001
  );

  v_passed :=
    v_has_citation
    and coalesce(array_length(v_banned,1),0)=0
    and coalesce(array_length(v_unmatched,1),0)=0;

  return jsonb_build_object(
    'passed',v_passed,
    'number_match',coalesce(array_length(v_unmatched,1),0)=0,
    'citation_present',v_has_citation,
    'banned_wording',coalesce(array_length(v_banned,1),0)>0,
    'unmatched_numbers',to_jsonb(v_unmatched),
    'banned_terms',to_jsonb(v_banned),
    'status_echo','manual_review_required',
    'direction','manual_review_required',
    'scope','manual_review_required',
    'pack_calc_run_id',v_pack.calc_run_id
  );
end
$$;


create or replace function edit_pack_claim(
  p_claim_id uuid,
  p_claim_text text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  claim_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_claim public.claim%rowtype;
  v_pack public.pack_version%rowtype;
  v_existing jsonb;
  v_operation text := 'pack.claim.edit:'||p_claim_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_claim
  from public.claim
  where id=p_claim_id
  for update;

  if v_claim.id is null then
    raise exception 'claim not found'
      using errcode='no_data_found';
  end if;

  select * into v_pack
  from public.pack_version
  where id=v_claim.pack_version_id
  for update;

  if v_pack.id is null
     or v_pack.status='signed'
     or not public.has_org_role(
       v_claim.organisation_id,
       array['reviewer']::public.app_role[]
     )
     or not public.has_outlet_access(v_claim.organisation_id,v_claim.outlet_id) then
    raise exception 'claim is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if nullif(btrim(p_claim_text),'') is null then
    raise exception 'claim text is required'
      using errcode='check_violation';
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

  if coalesce(v_existing ? 'claim_id',false) then
    return query select (v_existing->>'claim_id')::uuid,true;
    return;
  end if;

  update public.claim
  set claim_text=btrim(p_claim_text),
      claim_status='edited',
      edited_by=v_user_id,
      edited_at=now(),
      reviewed_by=null,
      reviewed_at=null
  where id=v_claim.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_claim.organisation_id,v_claim.outlet_id,
    'PACK_CLAIM_EDITED','claim',v_claim.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('claim_id',v_claim.id)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_claim.id,false;
end
$$;


create or replace function review_pack_claim(
  p_claim_id uuid,
  p_decision text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  claim_id uuid,
  claim_status claim_status,
  check_result jsonb,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_claim public.claim%rowtype;
  v_pack public.pack_version%rowtype;
  v_check jsonb;
  v_existing jsonb;
  v_operation text := 'pack.claim.review:'||p_claim_id::text;
  v_status public.claim_status;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if p_decision not in ('accept','reject') then
    raise exception 'claim review decision must be accept or reject'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_claim
  from public.claim
  where id=p_claim_id
  for update;

  if v_claim.id is null then
    raise exception 'claim not found'
      using errcode='no_data_found';
  end if;

  select * into v_pack
  from public.pack_version
  where id=v_claim.pack_version_id
  for update;

  if v_pack.id is null
     or v_pack.status='signed'
     or not public.has_org_role(
       v_claim.organisation_id,
       array['reviewer']::public.app_role[]
     )
     or not public.has_outlet_access(v_claim.organisation_id,v_claim.outlet_id) then
    raise exception 'claim is not reviewable in the current context'
      using errcode='insufficient_privilege';
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

  if coalesce(v_existing ? 'claim_id',false) then
    return query select
      (v_existing->>'claim_id')::uuid,
      (v_existing->>'claim_status')::public.claim_status,
      v_existing->'check_result',
      true;
    return;
  end if;

  v_check := public.claim_check(v_claim.id);

  if p_decision='accept' and not (v_check->>'passed')::boolean then
    raise exception 'claim failed server-side claimCheck'
      using errcode='check_violation';
  end if;

  v_status := case
    when p_decision='accept' then 'accepted'::public.claim_status
    else 'rejected'::public.claim_status
  end;

  update public.claim
  set claim_status=v_status,
      reviewed_by=v_user_id,
      reviewed_at=now()
  where id=v_claim.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_claim.organisation_id,v_claim.outlet_id,
    case when v_status='accepted'
      then 'PACK_CLAIM_ACCEPTED'
      else 'PACK_CLAIM_REJECTED'
    end,
    'claim',v_claim.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'claim_id',v_claim.id,
    'claim_status',v_status::text,
    'check_result',v_check
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_claim.id,v_status,v_check,false;
end
$$;


revoke all on function create_pack_version(uuid,text,text) from public;
revoke all on function create_pack_claim(uuid,text,text,text,uuid[],text,text) from public;
revoke all on function claim_check(uuid) from public;
revoke all on function edit_pack_claim(uuid,text,text,text) from public;
revoke all on function review_pack_claim(uuid,text,text,text) from public;

grant execute on function create_pack_version(uuid,text,text) to restaurant_app;
grant execute on function create_pack_claim(uuid,text,text,text,uuid[],text,text) to restaurant_app;
grant execute on function claim_check(uuid) to restaurant_app;
grant execute on function edit_pack_claim(uuid,text,text,text) to restaurant_app;
grant execute on function review_pack_claim(uuid,text,text,text) to restaurant_app;

-- Artefact rendering/sign-off are separate controlled steps. Once a pack
-- reaches signed, these guards already make the pack and its claims immutable.
