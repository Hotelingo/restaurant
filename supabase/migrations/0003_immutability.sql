-- 0003 · Immutability enforcement
--
-- PROPOSED. Not accepted.
--
-- G-05. The architecture document states as invariants that committed facts
-- never mutate, calc results are immutable after run completion, and a signed
-- pack never changes. The draft schema enforced none of them -- no triggers, no
-- revoked privileges, no CHECKs.
--
-- Documented invariants that the database does not enforce are not invariants.
-- They are hopes. Under a service role, an application bug will silently
-- rewrite history, which destroys the product's entire value proposition: if a
-- signed pack can change after signature, the signature means nothing.
--
-- These triggers are deliberately blunt. They raise rather than ignore, and
-- they apply to the service role too. A legitimate correction is a SUPERSEDING
-- record, never an UPDATE.

-- Blocks every UPDATE and DELETE unconditionally.
create or replace function forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception
    'record is immutable: % on %.% is not permitted; create a superseding record instead',
    tg_op, tg_table_schema, tg_table_name
    using errcode = 'restrict_violation';
end $$;

-- Blocks mutation only once a row has reached a terminal state. The row is
-- editable while it is being built, frozen the moment it is committed,
-- completed or signed.
--
-- Expects two trigger arguments: the state column name, and a comma-separated
-- list of terminal values.
create or replace function forbid_mutation_when_final() returns trigger
language plpgsql as $$
declare
  state_col  text := tg_argv[0];
  final_vals text[] := string_to_array(tg_argv[1], ',');
  old_state  text;
begin
  execute format('select ($1).%I::text', state_col) into old_state using old;

  if old_state = any (final_vals) then
    raise exception
      'record is immutable: %.% is %, so % is not permitted; create a superseding record instead',
      tg_table_schema, tg_table_name, old_state, tg_op
      using errcode = 'restrict_violation';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

-- ---------------------------------------------------------------- slice 1

-- Versioned context: a new version is a new row, never an edit of an old one.
create trigger restaurant_context_immutable
  before update or delete on restaurant_context
  for each row execute function forbid_mutation();

-- Materiality settings are approved and frozen into calc runs. Once approved,
-- they cannot change, or a run's settings snapshot becomes a lie.
create or replace function forbid_mutation_when_approved() returns trigger
language plpgsql as $$
begin
  if old.approved_at is not null then
    raise exception
      'record is immutable: %.% was approved at %, so % is not permitted',
      tg_table_schema, tg_table_name, old.approved_at, tg_op
      using errcode = 'restrict_violation';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end $$;

create trigger materiality_setting_immutable
  before update or delete on materiality_setting
  for each row execute function forbid_mutation_when_approved();

-- The audit log is append-only. An audit trail that can be edited is not one.
create trigger audit_log_append_only
  before update or delete on audit_log
  for each row execute function forbid_mutation();

-- ---------------------------------------------------------------- later slices
--
-- Applied in the migration that creates each table:
--
--   import_batch     forbid_mutation_when_final('status', 'committed,superseded')
--   financial_fact   forbid_mutation()            -- facts are insert-only
--   stock_fact       forbid_mutation()
--   meal_period_fact forbid_mutation()
--   labour_fact      forbid_mutation()
--   staging_row      forbid_mutation_when_final('row_status', 'parsed,rejected')
--   profile_version  forbid_mutation_when_approved()
--   calc_run         forbid_mutation_when_final('status', 'completed,failed')
--   calc_result      forbid_mutation()            -- results are insert-only
--   pack_version     forbid_mutation_when_final('status', 'signed,released')
--   signoff          forbid_mutation()
--
-- Each needs a test that attempts the mutation AS THE SERVICE ROLE and expects
-- rejection. A test that only proves a normal client cannot do it proves
-- nothing -- the service role is precisely where the risk lives.
