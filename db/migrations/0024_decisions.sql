-- 0024 · Decision discipline and disposition-keyed database invariants
-- Slice 4 / SC12. One active disposition per shortlisted issue is represented
-- by review_issue.active_decision_id. Revisions append immutable decision rows;
-- the active pointer moves, so prior management reasoning is never rewritten.

create type decision_disposition as enum (
  'ACT',
  'MONITOR',
  'INVESTIGATE',
  'ESCALATE',
  'CLOSE'
);

alter table evidence_request
  add constraint evidence_request_issue_id_unique
  unique (organisation_id, outlet_id, review_issue_id, id);

create table decision (
  id uuid primary key default gen_random_uuid(),
  organisation_id uuid not null,
  outlet_id uuid not null,
  review_issue_id uuid not null,
  version_no integer not null check (version_no > 0),
  disposition decision_disposition not null,
  diagnosis_id uuid,
  decision_text text not null
    check (length(btrim(decision_text)) > 0),

  owner text,
  lever text,
  guardrail text,
  verification_metric text,
  target_trigger text,
  due_date date,
  cadence text,
  evidence_request_id uuid,
  decision_required text,
  consequence_of_waiting text,
  forecast_treatment text,
  closure_evidence text,

  supersedes_decision_id uuid,
  decided_by uuid not null references neon_auth."user"(id),
  decided_at timestamptz not null default now(),

  foreign key (organisation_id, outlet_id, review_issue_id)
    references review_issue(organisation_id, outlet_id, id),

  foreign key (
    organisation_id, outlet_id, review_issue_id, diagnosis_id
  )
    references diagnosis(
      organisation_id, outlet_id, review_issue_id, id
    ),

  foreign key (
    organisation_id, outlet_id, review_issue_id, evidence_request_id
  )
    references evidence_request(
      organisation_id, outlet_id, review_issue_id, id
    ),

  unique (organisation_id, outlet_id, review_issue_id, id),
  unique (review_issue_id, version_no),

  constraint decision_requirements_check check (
    case disposition
      when 'ACT' then
        nullif(btrim(owner),'') is not null
        and nullif(btrim(lever),'') is not null
        and nullif(btrim(guardrail),'') is not null
        and nullif(btrim(verification_metric),'') is not null
        and (
          due_date is not null
          or nullif(btrim(cadence),'') is not null
        )

      when 'INVESTIGATE' then
        evidence_request_id is not null
        and nullif(btrim(owner),'') is not null
        and due_date is not null

      when 'MONITOR' then
        nullif(btrim(target_trigger),'') is not null
        and nullif(btrim(cadence),'') is not null

      when 'ESCALATE' then
        nullif(btrim(decision_required),'') is not null
        and nullif(btrim(consequence_of_waiting),'') is not null
        and nullif(btrim(owner),'') is not null
        and due_date is not null

      when 'CLOSE' then
        nullif(btrim(forecast_treatment),'') is not null
        and nullif(btrim(closure_evidence),'') is not null
    end
  )
);

alter table decision
  add constraint decision_supersedes_same_issue_fk
  foreign key (
    organisation_id, outlet_id, review_issue_id, supersedes_decision_id
  )
  references decision(
    organisation_id, outlet_id, review_issue_id, id
  );

create index decision_issue_version_idx
  on decision(review_issue_id, version_no desc);

alter table review_issue
  add column active_decision_id uuid;

alter table review_issue
  add constraint review_issue_active_decision_same_issue_fk
  foreign key (
    organisation_id, outlet_id, id, active_decision_id
  )
  references decision(
    organisation_id, outlet_id, review_issue_id, id
  );

create unique index review_issue_one_active_decision_idx
  on review_issue(active_decision_id)
  where active_decision_id is not null;


create or replace function guard_decision_insert()
returns trigger
language plpgsql
as $$
declare
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_latest_diagnosis public.diagnosis%rowtype;
begin
  select ri.* into v_issue
  from public.review_issue ri
  where ri.id = new.review_issue_id;

  if v_issue.id is null
     or v_issue.organisation_id <> new.organisation_id
     or v_issue.outlet_id <> new.outlet_id then
    raise exception 'decision must belong to the same review issue tenant'
      using errcode='check_violation';
  end if;

  select rv.* into v_review
  from public.review rv
  where rv.id = v_issue.review_id;

  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status = 'removed' then
    raise exception 'decision requires an active in-review shortlisted issue'
      using errcode='check_violation';
  end if;

  select d.* into v_latest_diagnosis
  from public.diagnosis d
  where d.review_issue_id = v_issue.id
  order by d.version_no desc
  limit 1;

  -- Evidence-required issues may still be INVESTIGATEd to obtain evidence or
  -- ESCALATEd when the required decision sits above local authority. They may
  -- not be acted on, treated as understood-monitoring, or closed.
  if v_issue.evidence_status = 'evidence_required'
     and new.disposition in ('ACT','MONITOR','CLOSE') then
    raise exception
      'evidence-required issue may only be INVESTIGATE or ESCALATE'
      using errcode='check_violation';
  end if;

  -- SC12 explicitly requires a supported driver before ACT.
  if new.disposition = 'ACT' then
    if v_latest_diagnosis.id is null
       or new.diagnosis_id is distinct from v_latest_diagnosis.id
       or v_latest_diagnosis.diagnosis_state <> 'supported'
       or v_latest_diagnosis.evidence_status not in ('supported','validated')
       or v_latest_diagnosis.diagnostic_status <> 'ready_for_decision' then
      raise exception
        'ACT requires the latest supported/validated diagnosis to be decision-ready'
        using errcode='check_violation';
    end if;
  end if;

  if new.disposition = 'INVESTIGATE' then
    if not exists (
      select 1
      from public.evidence_request er
      where er.id = new.evidence_request_id
        and er.organisation_id = new.organisation_id
        and er.outlet_id = new.outlet_id
        and er.review_issue_id = new.review_issue_id
        and er.status = 'open'
    ) then
      raise exception
        'INVESTIGATE requires an open evidence request for the same issue'
        using errcode='check_violation';
    end if;
  end if;

  return new;
end
$$;

create trigger decision_insert_guard
  before insert on decision
  for each row execute function guard_decision_insert();

create trigger decision_immutable
  before update or delete on decision
  for each row execute function forbid_mutation();


alter table decision enable row level security;

create policy decision_read on decision
  for select to restaurant_app
  using (
    (has_org_access(organisation_id) and has_outlet_access(organisation_id,outlet_id))
    or has_staff_outlet_access(organisation_id,outlet_id)
  );

grant select on decision to restaurant_app;


create or replace function record_issue_decision(
  p_issue_id uuid,
  p_disposition text,
  p_decision_text text,
  p_owner text,
  p_lever text,
  p_guardrail text,
  p_verification_metric text,
  p_target_trigger text,
  p_due_date date,
  p_cadence text,
  p_evidence_request_id uuid,
  p_decision_required text,
  p_consequence_of_waiting text,
  p_forecast_treatment text,
  p_closure_evidence text,
  p_idempotency_key text,
  p_correlation_id text default null
)
returns table (
  decision_id uuid,
  version_no integer,
  disposition decision_disposition,
  reused boolean
)
language plpgsql
security definer
set search_path=''
as $$
declare
  v_user_id uuid := public.current_app_user_id();
  v_issue public.review_issue%rowtype;
  v_review public.review%rowtype;
  v_latest_diagnosis_id uuid;
  v_previous_decision_id uuid;
  v_version integer;
  v_decision_id uuid;
  v_disposition public.decision_disposition;
  v_existing jsonb;
  v_operation text := 'issue.decision.record:' || p_issue_id::text;
begin
  if v_user_id is null then
    raise exception 'authenticated user context is required'
      using errcode='insufficient_privilege';
  end if;

  if p_idempotency_key is null or length(btrim(p_idempotency_key)) < 8 then
    raise exception 'a valid idempotency key is required'
      using errcode='invalid_parameter_value';
  end if;

  if p_disposition not in ('ACT','MONITOR','INVESTIGATE','ESCALATE','CLOSE') then
    raise exception 'unsupported disposition'
      using errcode='invalid_parameter_value';
  end if;

  v_disposition := p_disposition::public.decision_disposition;

  select ri.* into v_issue
  from public.review_issue ri
  where ri.id=p_issue_id
  for update;

  if v_issue.id is null then
    raise exception 'review issue not found'
      using errcode='no_data_found';
  end if;

  select rv.* into v_review
  from public.review rv
  where rv.id=v_issue.review_id;

  if v_review.id is null
     or v_review.status <> 'in_review'
     or v_issue.issue_status='removed'
     or not public.has_org_role(
       v_issue.organisation_id,
       array['admin','editor']::public.app_role[]
     )
     or not public.has_outlet_access(
       v_issue.organisation_id,
       v_issue.outlet_id
     ) then
    raise exception 'review issue is not editable in the current context'
      using errcode='insufficient_privilege';
  end if;

  insert into public.request_idempotency(
    user_id,operation,idempotency_key
  )
  values(v_user_id,v_operation,p_idempotency_key)
  on conflict(user_id,operation,idempotency_key) do nothing;

  select response_json into v_existing
  from public.request_idempotency
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key
  for update;

  if coalesce(v_existing ? 'decision_id',false) then
    return query select
      (v_existing->>'decision_id')::uuid,
      (v_existing->>'version_no')::integer,
      (v_existing->>'disposition')::public.decision_disposition,
      true;
    return;
  end if;

  select d.id
    into v_latest_diagnosis_id
  from public.diagnosis d
  where d.review_issue_id=v_issue.id
  order by d.version_no desc
  limit 1;

  select d.id,d.version_no
    into v_previous_decision_id,v_version
  from public.decision d
  where d.review_issue_id=v_issue.id
  order by d.version_no desc
  limit 1;

  v_version := coalesce(v_version,0)+1;

  insert into public.decision(
    organisation_id,outlet_id,review_issue_id,version_no,
    disposition,diagnosis_id,decision_text,
    owner,lever,guardrail,verification_metric,target_trigger,
    due_date,cadence,evidence_request_id,
    decision_required,consequence_of_waiting,
    forecast_treatment,closure_evidence,
    supersedes_decision_id,decided_by
  )
  values(
    v_issue.organisation_id,
    v_issue.outlet_id,
    v_issue.id,
    v_version,
    v_disposition,
    v_latest_diagnosis_id,
    btrim(p_decision_text),
    nullif(btrim(p_owner),''),
    nullif(btrim(p_lever),''),
    nullif(btrim(p_guardrail),''),
    nullif(btrim(p_verification_metric),''),
    nullif(btrim(p_target_trigger),''),
    p_due_date,
    nullif(btrim(p_cadence),''),
    p_evidence_request_id,
    nullif(btrim(p_decision_required),''),
    nullif(btrim(p_consequence_of_waiting),''),
    nullif(btrim(p_forecast_treatment),''),
    nullif(btrim(p_closure_evidence),''),
    v_previous_decision_id,
    v_user_id
  )
  returning id into v_decision_id;

  update public.review_issue
  set active_decision_id=v_decision_id,
      updated_at=now()
  where id=v_issue.id;

  insert into public.audit_log(
    actor_user_id,organisation_id,outlet_id,
    action_code,object_type,object_id,correlation_id
  )
  values(
    v_user_id,
    v_issue.organisation_id,
    v_issue.outlet_id,
    'ISSUE_DECISION_RECORDED',
    'decision',
    v_decision_id::text,
    p_correlation_id
  );

  update public.request_idempotency
  set response_json=jsonb_build_object(
    'decision_id',v_decision_id,
    'version_no',v_version,
    'disposition',v_disposition::text
  )
  where user_id=v_user_id
    and operation=v_operation
    and idempotency_key=p_idempotency_key;

  return query
    select v_decision_id,v_version,v_disposition,false;
end
$$;

revoke all on function record_issue_decision(
  uuid,text,text,text,text,text,text,text,date,text,uuid,text,text,text,text,text,text
) from public;

grant execute on function record_issue_decision(
  uuid,text,text,text,text,text,text,text,date,text,uuid,text,text,text,text,text,text
) to restaurant_app;

-- Decision revisions are append-only. Exactly one revision is active through
-- review_issue.active_decision_id; later actions pin the specific decision
-- revision they implement.
