-- 0022 · Review shortlist foundation
-- SC11: management chooses issues from immutable calculation results.
-- Authoritative movement values/materiality evidence are copied server-side;
-- client input never supplies financial amounts or rates.

create table review_issue (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_id uuid not null,
  source_calc_result_id uuid not null,
  title text not null,
  movement_amount numeric(20,4) not null,
  movement_rate numeric(18,8),
  ladder_code text not null,
  module text not null,
  materiality_reason text not null,
  materiality_rules jsonb not null default '[]'::jsonb
    check (jsonb_typeof(materiality_rules) = 'array'),
  shortlist_order integer not null check (shortlist_order > 0),
  selection_reason text,
  evidence_status text not null,
  issue_status text not null default 'open'
    check (issue_status in ('open','resolved','removed')),
  created_by uuid not null references neon_auth."user"(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, review_id)
    references review(organisation_id, outlet_id, id),

  foreign key (organisation_id, outlet_id, review_id, source_calc_result_id)
    references calc_result(organisation_id, outlet_id, run_id, id),

  foreign key (ladder_code)
    references ladder_line(code),

  unique (organisation_id, outlet_id, id),
  unique (review_id, source_calc_result_id)
);

create unique index review_issue_active_order_unique_idx
  on review_issue(review_id, shortlist_order)
  where issue_status <> 'removed';

create index review_issue_review_order_idx
  on review_issue(review_id, shortlist_order, created_at);

create index review_issue_source_idx
  on review_issue(source_calc_result_id);


-- The composite FK above intentionally uses review_id in the calc-result run slot.
-- Replace it with the actual pinned calc run through an insert guard; PostgreSQL
-- cannot express review.active_calc_run_id in a declarative FK.
alter table review_issue
  drop constraint review_issue_organisation_id_outlet_id_review_id_source_calc_result_id_fkey;

alter table review_issue
  add constraint review_issue_source_same_tenant_fk
  foreign key (organisation_id, outlet_id, source_calc_result_id)
  references calc_result(organisation_id, outlet_id, id)
  deferrable initially immediate;


create or replace function guard_review_issue_origin()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'review issue history is retained; remove through workflow state instead'
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'UPDATE' then
    if new.source_calc_result_id is distinct from old.source_calc_result_id
       or new.movement_amount is distinct from old.movement_amount
       or new.movement_rate is distinct from old.movement_rate
       or new.ladder_code is distinct from old.ladder_code
       or new.module is distinct from old.module
       or new.materiality_reason is distinct from old.materiality_reason
       or new.materiality_rules is distinct from old.materiality_rules
       or new.created_by is distinct from old.created_by
       or new.created_at is distinct from old.created_at
       or new.organisation_id is distinct from old.organisation_id
       or new.outlet_id is distinct from old.outlet_id
       or new.review_id is distinct from old.review_id then
      raise exception 'review issue analytic origin is immutable'
        using errcode = 'restrict_violation';
    end if;
  end if;

  return new;
end
$$;

create trigger review_issue_origin_guard
  before update or delete on review_issue
  for each row execute function guard_review_issue_origin();


alter table review_issue enable row level security;

create policy review_issue_read on review_issue
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on review_issue to restaurant_app;


create or replace function add_review_issue(
  p_review_id uuid,
  p_source_calc_result_id uuid,
  p_title text,
  p_selection_reason text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  created_issue_id uuid,
  shortlist_count integer,
  shortlist_guidance text,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_source public.calc_result%rowtype;
  v_comparator public.calc_result%rowtype;
  v_sequence public.calc_result%rowtype;
  v_issue_id uuid;
  v_existing jsonb;
  v_operation text := 'review.issue.add:' || p_review_id::text || ':' || p_source_calc_result_id::text;
  v_count integer;
  v_order integer;
  v_rate numeric(18,8);
  v_title text;
  v_reason text;
  v_rules jsonb := '[]'::jsonb;
  v_abs_threshold numeric;
  v_pct_threshold numeric;
  v_magnitude numeric;
  v_matched text[] := array[]::text[];
  v_sequence_rules text[];
  v_guidance text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  select rv.* into v_review
  from public.review rv
  where rv.id=p_review_id
  for update;

  if v_review.id is null
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_review.organisation_id,v_review.outlet_id) then
    raise exception 'review is not available to this user'
      using errcode = 'insufficient_privilege';
  end if;

  if v_review.status <> 'in_review'
     or v_review.active_calc_run_id is null
     or v_review.frame_confirmed_at is null then
    raise exception 'shortlist requires a confirmed in-review FRAME'
      using errcode = 'check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values (v_user_id,v_operation,p_idempotency_key)
  on conflict (user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'issue_id',false) then
    return query
      select
        (v_existing->>'issue_id')::uuid,
        (v_existing->>'shortlist_count')::integer,
        v_existing->>'shortlist_guidance',
        true;
    return;
  end if;

  select cr.* into v_source
  from public.calc_result cr
  where cr.id=p_source_calc_result_id
    and cr.organisation_id=v_review.organisation_id
    and cr.outlet_id=v_review.outlet_id
    and cr.run_id=v_review.active_calc_run_id;

  if v_source.id is null then
    raise exception 'source calculation result does not belong to the review calc snapshot'
      using errcode = 'check_violation';
  end if;

  if v_source.grain_type <> 'management_pl_variance'
     or v_source.calculation_status <> 'CALCULATED'
     or v_source.raw_delta is null
     or v_source.profit_effect is null then
    raise exception 'shortlist source must be a calculated Management P&L variance result'
      using errcode = 'check_violation';
  end if;

  if nullif(btrim(v_source.grain_key->>'ladder_code'),'') is null then
    raise exception 'variance result is missing ladder_code grain'
      using errcode = 'check_violation';
  end if;

  select cr.* into v_comparator
  from public.calc_result cr
  where cr.run_id=v_review.active_calc_run_id
    and cr.organisation_id=v_review.organisation_id
    and cr.outlet_id=v_review.outlet_id
    and cr.grain_type='management_pl'
    and cr.calculation_status='CALCULATED'
    and cr.grain_key->>'ladder_code'=v_source.grain_key->>'ladder_code'
    and cr.grain_key->>'scenario'=v_review.comparator_scenario::text
  order by cr.id
  limit 1;

  if v_comparator.id is not null
     and v_comparator.value_numeric is not null
     and abs(v_comparator.value_numeric) <> 0 then
    v_rate := (
      abs(v_source.raw_delta) / abs(v_comparator.value_numeric)
    )::numeric(18,8);
  else
    v_rate := null;
  end if;

  begin
    v_abs_threshold := nullif(
      v_review.materiality_snapshot->'general'->>'absolute_threshold',''
    )::numeric;
  exception when invalid_text_representation then
    raise exception 'review materiality absolute threshold is invalid'
      using errcode = 'check_violation';
  end;

  begin
    v_pct_threshold := nullif(
      v_review.materiality_snapshot->'general'->>'percent_threshold',''
    )::numeric;
  exception when invalid_text_representation then
    raise exception 'review materiality percent threshold is invalid'
      using errcode = 'check_violation';
  end;

  v_magnitude := abs(v_source.raw_delta);

  if v_abs_threshold is not null and v_magnitude >= v_abs_threshold then
    v_matched := array_append(v_matched,'amount_test');
  end if;

  if v_pct_threshold is not null
     and v_rate is not null
     and v_rate >= v_pct_threshold then
    v_matched := array_append(v_matched,'percentage_test');
  end if;

  select cr.* into v_sequence
  from public.calc_result cr
  where cr.run_id=v_review.active_calc_run_id
    and cr.calc_id='SEQ.FIRST_MATERIAL_MOVEMENT'
    and cr.calculation_status='CALCULATED'
    and cr.value_text=v_source.grain_key->>'ladder_code'
  order by cr.id
  limit 1;

  if v_sequence.id is not null
     and nullif(v_sequence.result_metadata->>'matched_rules','') is not null then
    v_sequence_rules := string_to_array(
      v_sequence.result_metadata->>'matched_rules','|'
    );
    select array_agg(distinct rule order by rule)
      into v_matched
    from unnest(v_matched || coalesce(v_sequence_rules,array[]::text[])) rule;
  end if;

  if coalesce(array_length(v_matched,1),0) > 0 then
    v_rules := to_jsonb(v_matched);
    v_reason := v_matched[1];
  else
    v_rules := '["management_selection"]'::jsonb;
    v_reason := 'management_selection';
  end if;

  select count(*)::integer into v_count
  from public.review_issue ri
  where ri.review_id=v_review.id
    and ri.issue_status <> 'removed';

  v_order := v_count + 1;

  if v_order = 6 and nullif(btrim(p_selection_reason),'') is null then
    raise exception 'a sixth shortlist item requires a one-line reason'
      using errcode = 'check_violation';
  end if;

  select coalesce(nullif(btrim(p_title),''),ll.name)
    into v_title
  from public.ladder_line ll
  where ll.code=v_source.grain_key->>'ladder_code';

  if v_title is null then
    raise exception 'source ladder line is not registered'
      using errcode = 'check_violation';
  end if;

  insert into public.review_issue(
    organisation_id,outlet_id,review_id,source_calc_result_id,
    title,movement_amount,movement_rate,ladder_code,module,
    materiality_reason,materiality_rules,shortlist_order,
    selection_reason,evidence_status,created_by
  )
  values (
    v_review.organisation_id,
    v_review.outlet_id,
    v_review.id,
    v_source.id,
    v_title,
    v_source.profit_effect,
    v_rate,
    v_source.grain_key->>'ladder_code',
    split_part(v_source.calc_id,'.',1),
    v_reason,
    v_rules,
    v_order,
    nullif(btrim(p_selection_reason),''),
    v_source.evidence_status,
    v_user_id
  )
  on conflict (review_id,source_calc_result_id) do nothing
  returning id into v_issue_id;

  if v_issue_id is null then
    select ri.id into v_issue_id
    from public.review_issue ri
    where ri.review_id=v_review.id
      and ri.source_calc_result_id=v_source.id;

    select count(*)::integer into v_count
    from public.review_issue ri
    where ri.review_id=v_review.id
      and ri.issue_status <> 'removed';
  else
    v_count := v_order;

    insert into public.audit_log(
      actor_user_id,organisation_id,outlet_id,
      action_code,object_type,object_id,correlation_id
    )
    values (
      v_user_id,v_review.organisation_id,v_review.outlet_id,
      'REVIEW_ISSUE_SHORTLISTED','review_issue',v_issue_id::text,p_correlation_id
    );
  end if;

  v_guidance := case
    when v_count < 3 then 'below_expected'
    when v_count <= 5 then 'expected_range'
    when v_count = 6 then 'six_with_reason'
    else 'above_expected_warning'
  end;

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'issue_id',v_issue_id,
    'shortlist_count',v_count,
    'shortlist_guidance',v_guidance
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_issue_id,v_count,v_guidance,false;
end
$$;


create or replace function reorder_review_issues(
  p_review_id uuid,
  p_issue_ids uuid[],
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  reordered_count integer,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_review public.review%rowtype;
  v_count integer;
  v_distinct integer;
  v_existing jsonb;
  v_operation text := 'review.issue.reorder:' || p_review_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode = 'insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode = 'invalid_parameter_value';
  end if;

  select rv.* into v_review
  from public.review rv
  where rv.id=p_review_id
  for update;

  if v_review.id is null
     or not public.has_org_role(
       v_review.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(v_review.organisation_id,v_review.outlet_id) then
    raise exception 'review is not available to this user'
      using errcode = 'insufficient_privilege';
  end if;

  if v_review.status <> 'in_review' then
    raise exception 'only an in-review shortlist can be reordered'
      using errcode = 'check_violation';
  end if;

  insert into public.request_idempotency(user_id,operation,idempotency_key)
  values (v_user_id,v_operation,p_idempotency_key)
  on conflict (user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'reordered_count',false) then
    return query
      select (v_existing->>'reordered_count')::integer,true;
    return;
  end if;

  select count(*)::integer into v_count
  from public.review_issue ri
  where ri.review_id=v_review.id
    and ri.issue_status <> 'removed';

  select count(distinct id)::integer into v_distinct
  from unnest(coalesce(p_issue_ids,array[]::uuid[])) id;

  if coalesce(array_length(p_issue_ids,1),0) <> v_count
     or v_distinct <> v_count
     or exists (
       select 1
       from unnest(coalesce(p_issue_ids,array[]::uuid[])) id
       where not exists (
         select 1
         from public.review_issue ri
         where ri.id=id
           and ri.review_id=v_review.id
           and ri.issue_status <> 'removed'
       )
     ) then
    raise exception 'reorder payload must contain each active shortlist issue exactly once'
      using errcode = 'check_violation';
  end if;

  -- Move orders out of the constrained range first, then assign the requested
  -- deterministic order.
  update public.review_issue
  set shortlist_order=shortlist_order+1000000,
      updated_at=now()
  where review_id=v_review.id
    and issue_status <> 'removed';

  update public.review_issue ri
  set shortlist_order=ordered.ordinality::integer,
      updated_at=now()
  from unnest(p_issue_ids) with ordinality ordered(issue_id,ordinality)
  where ri.id=ordered.issue_id
    and ri.review_id=v_review.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values (
    v_user_id,v_review.organisation_id,v_review.outlet_id,
    'REVIEW_SHORTLIST_REORDERED','review',v_review.id::text,p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object('reordered_count',v_count)
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query select v_count,false;
end
$$;


revoke all on function add_review_issue(uuid,uuid,text,text,text,text) from public;
revoke all on function reorder_review_issues(uuid,uuid[],text,text) from public;

grant execute on function add_review_issue(uuid,uuid,text,text,text,text)
  to restaurant_app;
grant execute on function reorder_review_issues(uuid,uuid[],text,text)
  to restaurant_app;

-- Soft shortlist policy:
-- 3–5 expected; 6 requires an explicit one-line reason; >6 remains possible
-- but is returned as an application warning rather than blocked.
