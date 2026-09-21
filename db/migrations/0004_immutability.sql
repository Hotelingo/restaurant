-- 0004 · Immutability enforcement
create or replace function forbid_mutation() returns trigger
language plpgsql as $$
begin
  raise exception
    'record is immutable: % on %.% is not permitted; create a superseding record instead',
    tg_op, tg_table_schema, tg_table_name
    using errcode = 'restrict_violation';
end $$;

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

create trigger restaurant_context_immutable
  before update or delete on restaurant_context
  for each row execute function forbid_mutation();

create trigger materiality_setting_immutable
  before update or delete on materiality_setting
  for each row execute function forbid_mutation_when_approved();

create trigger audit_log_append_only
  before update or delete on audit_log
  for each row execute function forbid_mutation();
