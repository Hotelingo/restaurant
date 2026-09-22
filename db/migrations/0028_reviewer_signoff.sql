-- 0028 · Reviewer comments, review gates and immutable sign-off history
-- Slice 4 / SC15 + SC26. Comments are threaded and retained. Sign-off is
-- server-only so the API must evaluate the pure RG engine before a pack can
-- reach signed. The database still enforces the non-negotiable provenance and
-- segregation invariants independently of the application layer.

alter table pack_version
  add column reconciliation_disclosure text
  check (
    reconciliation_disclosure is null
    or length(btrim(reconciliation_disclosure)) > 0
  );

alter table claim
  add column review_check_snapshot jsonb
  check (
    review_check_snapshot is null
    or jsonb_typeof(review_check_snapshot) = 'object'
  );


create table review_comment (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  parent_comment_id uuid,
  body text not null check (length(btrim(body)) > 0),
  author_user_id uuid not null references neon_auth."user"(id),
  author_role app_role not null,
  resolution_status text not null default 'open'
    check (resolution_status in ('open','resolved')),
  resolution_note text,
  resolved_by uuid references neon_auth."user"(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,review_id,id),

  foreign key (
    organisation_id,outlet_id,review_id,parent_comment_id
  )
    references review_comment(
      organisation_id,outlet_id,review_id,id
    ),

  check (
    (
      resolution_status='open'
      and resolved_by is null
      and resolved_at is null
    )
    or
    (
      resolution_status='resolved'
      and resolved_by is not null
      and resolved_at is not null
      and nullif(btrim(resolution_note),'') is not null
    )
  )
);

create index review_comment_review_thread_idx
  on review_comment(review_id,parent_comment_id,created_at,id);
create index review_comment_open_idx
  on review_comment(review_id,created_at,id)
  where resolution_status='open';


create type pack_signoff_decision as enum (
  'signed',
  'changes_requested'
);

create table signoff (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  pack_version_id uuid not null,
  calc_run_id uuid not null,
  reviewer_user_id uuid not null references neon_auth."user"(id),
  reviewer_role app_role not null,
  decision pack_signoff_decision not null,
  caveat text,
  scope_reviewed text[] not null default array[]::text[],
  scope_not_reviewed text[] not null default array[]::text[],
  gate_snapshot jsonb not null default '{}'::jsonb
    check (jsonb_typeof(gate_snapshot)='object'),
  created_at timestamptz not null default now(),

  foreign key (organisation_id,outlet_id,review_id)
    references review(organisation_id,outlet_id,id),

  foreign key (organisation_id,outlet_id,pack_version_id)
    references pack_version(organisation_id,outlet_id,id),

  foreign key (organisation_id,outlet_id,calc_run_id)
    references calc_run(organisation_id,outlet_id,id),

  unique (organisation_id,outlet_id,id),

  check (reviewer_role='reviewer'),
  check (
    decision <> 'signed'
    or coalesce((gate_snapshot->>'passed')::boolean,false)
  )
);

create unique index signoff_one_signed_per_pack_idx
  on signoff(pack_version_id)
  where decision='signed';

create index signoff_pack_time_idx
  on signoff(pack_version_id,created_at,id);


-- Existing pack guard learns the one new editable disclosure field. Pack
-- identity, calc snapshot and signed history remain immutable.
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

  if (
    to_jsonb(new) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'renderer_version','template_version',
      'reconciliation_disclosure',
      'updated_at'
    ]
  ) <> (
    to_jsonb(old) - array[
      'status',
      'artifact_bucket','artifact_path','artifact_sha256',
      'renderer_version','template_version',
      'reconciliation_disclosure',
      'updated_at'
    ]
  ) then
    raise exception 'pack version identity and calc snapshot are immutable'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;


create or replace function guard_review_comment_mutation()
returns trigger
language plpgsql
as $$
begin
  if tg_op='DELETE' then
    raise exception 'review comments are retained; delete is not permitted'
      using errcode='restrict_violation';
  end if;

  if (
    to_jsonb(new) - array[
      'resolution_status','resolution_note','resolved_by','resolved_at'
    ]
  ) <> (
    to_jsonb(old) - array[
      'resolution_status','resolution_note','resolved_by','resolved_at'
    ]
  ) then
    raise exception 'comment body and provenance are immutable'
      using errcode='restrict_violation';
  end if;

  if old.resolution_status='resolved'
     and (
       new.resolution_status is distinct from old.resolution_status
       or new.resolution_note is distinct from old.resolution_note
       or new.resolved_by is distinct from old.resolved_by
       or new.resolved_at is distinct from old.resolved_at
     ) then
    raise exception 'resolved review comment is immutable'
      using errcode='restrict_violation';
  end if;

  return new;
end
$$;

create trigger review_comment_mutation_guard
  before update or delete on review_comment
  for each row execute function guard_review_comment_mutation();

create trigger signoff_immutable
  before update or delete on signoff
  for each row execute function forbid_mutation();


alter table review_comment enable row level security;
alter table signoff enable row level security;

create policy review_comment_read on review_comment
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

create policy signoff_read on signoff
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on review_comment,signoff to restaurant_app;


create or replace function current_review_role(
  p_organisation_id uuid
)
returns app_role
language sql
security definer
stable
set search_path=''
as $$
  select m.role
  from public.membership m
  where m.organisation_id=p_organisation_id
    and m.user_id=public.current_app_user_id()
    and m.active
    and m.role in (
      'admin'::public.app_role,
      'editor'::public.app_role,
      'reviewer'::public.app_role
    )
  order by case m.role
    when 'reviewer'::public.app_role then 1
    when 'admin'::public.app_role then 2
    else 3
  end
  limit 1
$$;


create or replace function create_review_comment(
  p_review_id uuid,
  p_parent_comment_id uuid,
  p_body text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  comment_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_role public.app_role;
  v_comment_id uuid;
  v_existing jsonb;
  v_operation text := 'review.comment.create:'||p_review_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if nullif(btrim(p_body),'') is null then
    raise exception 'review comment body is required'
      using errcode='check_violation';
  end if;

  select * into v_review
  from public.review
  where id=p_review_id;

  if v_review.id is null
     or not public.has_outlet_access(v_review.organisation_id,v_review.outlet_id) then
    raise exception 'review is not available in the current context'
      using errcode='insufficient_privilege';
  end if;

  v_role := public.current_review_role(v_review.organisation_id);
  if v_role is null then
    raise exception 'review comment requires admin, editor or reviewer role'
      using errcode='insufficient_privilege';
  end if;

  if p_parent_comment_id is not null
     and not exists (
       select 1
       from public.review_comment c
       where c.id=p_parent_comment_id
         and c.review_id=v_review.id
         and c.organisation_id=v_review.organisation_id
         and c.outlet_id=v_review.outlet_id
     ) then
    raise exception 'parent comment must belong to this review'
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

  if coalesce(v_existing ? 'comment_id',false) then
    return query select (v_existing->>'comment_id')::uuid,true;
    return;
  end if;

  insert into public.review_comment(
    organisation_id,outlet_id,review_id,parent_comment_id,
    body,author_user_id,author_role
  )
  values(
    v_review.organisation_id,v_review.outlet_id,v_review.id,p_parent_comment_id,
    btrim(p_body),v_user_id,v_role
  )
  returning id into v_comment_id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'REVIEW_COMMENT_CREATED','review_comment',v_comment_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('comment_id',v_comment_id)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_comment_id,false;
end
$$;


create or replace function resolve_review_comment(
  p_comment_id uuid,
  p_resolution_note text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  comment_id uuid,
  resolution_status text,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_comment public.review_comment%rowtype;
  v_existing jsonb;
  v_operation text := 'review.comment.resolve:'||p_comment_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if nullif(btrim(p_resolution_note),'') is null then
    raise exception 'comment resolution note is required'
      using errcode='check_violation';
  end if;

  select * into v_comment
  from public.review_comment
  where id=p_comment_id
  for update;

  if v_comment.id is null
     or not public.has_org_role(
       v_comment.organisation_id,
       array['reviewer']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_comment.organisation_id,v_comment.outlet_id
     ) then
    raise exception 'review comment is not resolvable in the current context'
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

  if coalesce(v_existing ? 'comment_id',false) then
    return query select
      (v_existing->>'comment_id')::uuid,
      v_existing->>'resolution_status',
      true;
    return;
  end if;

  if v_comment.resolution_status='resolved' then
    update public.request_idempotency
    set response_json=jsonb_build_object(
      'comment_id',v_comment.id,
      'resolution_status','resolved'
    )
    where user_id=v_user_id
      and operation=v_operation
      and idempotency_key=p_idempotency_key;

    return query select v_comment.id,'resolved'::text,true;
    return;
  end if;

  update public.review_comment
  set resolution_status='resolved',
      resolution_note=btrim(p_resolution_note),
      resolved_by=v_user_id,
      resolved_at=now()
  where id=v_comment.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_comment.organisation_id,v_comment.outlet_id,
    'REVIEW_COMMENT_RESOLVED','review_comment',v_comment.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'comment_id',v_comment.id,
    'resolution_status','resolved'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_comment.id,'resolved'::text,false;
end
$$;


create or replace function submit_pack_for_review(
  p_pack_version_id uuid,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  pack_version_id uuid,
  pack_status pack_status,
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
  v_operation text := 'pack.submit:'||p_pack_version_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
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
    raise exception 'pack is not submittable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if v_pack.status not in ('draft','changes_requested') then
    raise exception 'only draft or changes-requested pack can be submitted'
      using errcode='check_violation';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
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
      (v_existing->>'status')::public.pack_status,
      true;
    return;
  end if;

  update public.pack_version
  set status='in_review',updated_at=now()
  where id=v_pack.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_pack.organisation_id,v_pack.outlet_id,
    'PACK_SUBMITTED_FOR_REVIEW','pack_version',v_pack.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'pack_version_id',v_pack.id,
    'status','in_review'
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_pack.id,'in_review'::public.pack_status,false;
end
$$;


create or replace function set_pack_reconciliation_disclosure(
  p_pack_version_id uuid,
  p_reason text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  pack_version_id uuid,
  reconciliation_disclosure text,
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
  v_operation text := 'pack.reconciliation.disclosure:'||p_pack_version_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if nullif(btrim(p_reason),'') is null then
    raise exception 'Not Reconciled disclosure requires a reason'
      using errcode='check_violation';
  end if;

  select * into v_pack
  from public.pack_version
  where id=p_pack_version_id
  for update;

  if v_pack.id is null
     or v_pack.status='signed'
     or not public.has_org_role(
       v_pack.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_pack.organisation_id,v_pack.outlet_id) then
    raise exception 'pack disclosure is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
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
      v_existing->>'reconciliation_disclosure',
      true;
    return;
  end if;

  update public.pack_version
  set reconciliation_disclosure=btrim(p_reason),updated_at=now()
  where id=v_pack.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_pack.organisation_id,v_pack.outlet_id,
    'PACK_NOT_RECONCILED_DISCLOSED','pack_version',v_pack.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'pack_version_id',v_pack.id,
    'reconciliation_disclosure',btrim(p_reason)
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_pack.id,btrim(p_reason),false;
end
$$;


-- The acceptance function now records the exact automated check snapshot. The
-- three manual checks are reviewer attestations when a claim is accepted.
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
  v_review_snapshot jsonb;
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

  v_review_snapshot := v_check || jsonb_build_object(
    'status_echo',
      case when v_status='accepted' then 'confirmed_by_reviewer' else 'not_applicable' end,
    'direction',
      case when v_status='accepted' then 'confirmed_by_reviewer' else 'not_applicable' end,
    'scope',
      case when v_status='accepted' then 'confirmed_by_reviewer' else 'not_applicable' end
  );

  update public.claim
  set claim_status=v_status,
      reviewed_by=v_user_id,
      reviewed_at=now(),
      review_check_snapshot=v_review_snapshot
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
    'check_result',v_review_snapshot
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_claim.id,v_status,v_review_snapshot,false;
end
$$;


-- Server-only final state transition. Deliberately not granted to
-- restaurant_app: callers that bypass the API cannot supply a forged RG result.
create or replace function record_pack_signoff(
  p_pack_version_id uuid,
  p_decision text,
  p_caveat text,
  p_scope_reviewed text[],
  p_scope_not_reviewed text[],
  p_gate_snapshot jsonb,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  signoff_id uuid,
  pack_status pack_status,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_pack public.pack_version%rowtype;
  v_signoff_id uuid;
  v_existing jsonb;
  v_operation text := 'pack.signoff:'||p_pack_version_id::text||':'||p_decision;
  v_new_status public.pack_status;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_decision not in ('signed','changes_requested') then
    raise exception 'signoff decision must be signed or changes_requested'
      using errcode='invalid_parameter_value';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key))<8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  select * into v_pack
  from public.pack_version
  where id=p_pack_version_id
  for update;

  if v_pack.id is null
     or v_pack.status <> 'in_review'
     or not public.has_org_role(
       v_pack.organisation_id,
       array['reviewer']::public.app_role[]
     )
     or not public.has_outlet_access(v_pack.organisation_id,v_pack.outlet_id) then
    raise exception 'pack is not signable in the current context'
      using errcode='insufficient_privilege';
  end if;

  if p_decision='signed' then
    if p_gate_snapshot is null
       or jsonb_typeof(p_gate_snapshot)<>'object'
       or not coalesce((p_gate_snapshot->>'passed')::boolean,false) then
      raise exception 'review gate must pass before signing'
        using errcode='check_violation';
    end if;

    if exists (
      select 1 from public.review_comment c
      where c.review_id=v_pack.review_id
        and c.resolution_status='open'
    ) then
      raise exception 'unresolved reviewer comments block sign-off'
        using errcode='check_violation';
    end if;

    if exists (
      select 1 from public.claim c
      where c.pack_version_id=v_pack.id
        and c.claim_status not in ('accepted','rejected')
    ) then
      raise exception 'every pack claim must be accepted or rejected before sign-off'
        using errcode='check_violation';
    end if;

    if exists (
      select 1
      from public.review_issue ri
      join public.decision d on d.id=ri.active_decision_id
      where ri.review_id=v_pack.review_id
        and ri.issue_status<>'removed'
        and d.decided_by=v_user_id
    ) then
      raise exception 'reviewer who made a management decision cannot sign the pack'
        using errcode='insufficient_privilege';
    end if;

    v_new_status := 'signed'::public.pack_status;
  else
    v_new_status := 'changes_requested'::public.pack_status;
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

  if coalesce(v_existing ? 'signoff_id',false) then
    return query select
      (v_existing->>'signoff_id')::uuid,
      (v_existing->>'status')::public.pack_status,
      true;
    return;
  end if;

  insert into public.signoff(
    organisation_id,outlet_id,review_id,pack_version_id,calc_run_id,
    reviewer_user_id,reviewer_role,decision,caveat,
    scope_reviewed,scope_not_reviewed,gate_snapshot
  )
  values(
    v_pack.organisation_id,v_pack.outlet_id,v_pack.review_id,
    v_pack.id,v_pack.calc_run_id,
    v_user_id,'reviewer',p_decision::public.pack_signoff_decision,
    nullif(btrim(p_caveat),''),
    coalesce(p_scope_reviewed,array[]::text[]),
    coalesce(p_scope_not_reviewed,array[]::text[]),
    coalesce(p_gate_snapshot,'{}'::jsonb)
  )
  returning id into v_signoff_id;

  update public.pack_version
  set status=v_new_status,updated_at=now()
  where id=v_pack.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,v_pack.organisation_id,v_pack.outlet_id,
    case when p_decision='signed'
      then 'PACK_SIGNED'
      else 'PACK_CHANGES_REQUESTED'
    end,
    'signoff',v_signoff_id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'signoff_id',v_signoff_id,
    'status',v_new_status::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_signoff_id,v_new_status,false;
end
$$;


revoke all on function current_review_role(uuid) from public;
revoke all on function create_review_comment(uuid,uuid,text,text,text) from public;
revoke all on function resolve_review_comment(uuid,text,text,text) from public;
revoke all on function submit_pack_for_review(uuid,text,text) from public;
revoke all on function set_pack_reconciliation_disclosure(uuid,text,text,text) from public;
revoke all on function record_pack_signoff(
  uuid,text,text,text[],text[],jsonb,text,text
) from public;

grant execute on function current_review_role(uuid) to restaurant_app;
grant execute on function create_review_comment(uuid,uuid,text,text,text) to restaurant_app;
grant execute on function resolve_review_comment(uuid,text,text,text) to restaurant_app;
grant execute on function submit_pack_for_review(uuid,text,text) to restaurant_app;
grant execute on function set_pack_reconciliation_disclosure(uuid,text,text,text)
  to restaurant_app;

-- record_pack_signoff is intentionally server-only. The API database role may
-- execute it; restaurant_app cannot. This keeps the pure RG evaluation as the
-- only route to a signed pack while preserving database-level immutability.
