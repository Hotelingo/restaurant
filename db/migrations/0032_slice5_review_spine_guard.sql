-- 0032 · Slice 5 review-spine guard
-- Summary Food Cost is an analysis module. It must not become a parallel
-- review/decision/pack system. The core review FRAME remains anchored to the
-- completed Management P&L snapshot; later modules may contribute evidence
-- through explicit contracts without replacing that immutable anchor.

create or replace function guard_review_core_calc_run()
returns trigger
language plpgsql
as $$
declare
  v_run public.calc_run%rowtype;
begin
  if new.active_calc_run_id is null then
    return new;
  end if;

  select * into v_run
  from public.calc_run
  where id=new.active_calc_run_id
    and organisation_id=new.organisation_id
    and outlet_id=new.outlet_id
    and period_id=new.period_id;

  if v_run.id is null then
    raise exception 'review active calculation run is outside the review context'
      using errcode='check_violation';
  end if;

  if v_run.status<>'completed'
     or v_run.result_hash is null then
    raise exception 'review FRAME requires a completed immutable calculation snapshot'
      using errcode='check_violation';
  end if;

  if v_run.engine_version not like 'pl-%' then
    raise exception
      'core review FRAME must pin a Management P&L calculation run; module runs remain supporting analysis'
      using errcode='check_violation';
  end if;

  if new.comparator_scenario is null
     or v_run.comparator_scenario is distinct from new.comparator_scenario then
    raise exception 'review comparator must match the pinned Management P&L run'
      using errcode='check_violation';
  end if;

  return new;
end
$$;

create trigger review_core_calc_run_guard
  before insert or update of active_calc_run_id,status,comparator_scenario
  on review
  for each row execute function guard_review_core_calc_run();

-- Forward hardening: the public FRAME function already selects a matching
-- comparator and completed run. The trigger above independently enforces the
-- module boundary even for privileged/server code.
