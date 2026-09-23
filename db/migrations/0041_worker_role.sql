-- Least-privilege database role for the calculation worker (readiness finding B3).
--
-- Until now the queue functions were granted to no role, so the worker had to
-- connect as the database owner: full DDL rights and RLS bypass for a process
-- that only reads committed facts and writes calculation snapshots.
--
-- restaurant_worker holds exactly what workers/pl_worker.py uses:
-- - EXECUTE on the four SECURITY DEFINER queue functions (claim, heartbeat,
--   complete, fail); no direct access to calculation_request_queue;
-- - SELECT on the reference, context and canonical fact tables it reads;
-- - INSERT on the four calculation snapshot tables, UPDATE on calc_run only;
-- - RLS policies scoped to this role alone. The worker is a trusted
--   cross-tenant service, but that trust is explicit, per table, and visible
--   in pg_policies rather than an ambient BYPASSRLS.
--
-- The role is created NOLOGIN so no credential lives in the repository. Enable
-- it per environment, outside migrations, with a secret from the host:
--     alter role restaurant_worker login password '<from the secret store>';
-- On Neon, do this in SQL rather than creating the role in the console, which
-- would also make it a member of neon_superuser.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'restaurant_worker') then
    create role restaurant_worker nologin;
  end if;
end
$$;

grant usage on schema public to restaurant_worker;

grant execute on function claim_calculation_request(text, integer, integer) to restaurant_worker;
grant execute on function heartbeat_calculation_request(uuid, text, integer) to restaurant_worker;
grant execute on function complete_calculation_request(uuid, text, uuid) to restaurant_worker;
grant execute on function fail_calculation_request(uuid, text, text, boolean, integer, integer) to restaurant_worker;

do $$
declare
  read_tables constant text[] := array[
    'outlet', 'reporting_period', 'import_batch', 'data_readiness', 'ladder_line',
    'setting', 'materiality_setting', 'value_mapping',
    'financial_fact', 'item', 'item_sales_fact', 'item_cost_snapshot', 'stock_fact',
    'revenue_activity_fact', 'channel_source_fact', 'labour_fact',
    'calc_run', 'calc_run_input', 'calc_result', 'calc_dependency'
  ];
  write_tables constant text[] := array['calc_run', 'calc_run_input', 'calc_result', 'calc_dependency'];
  t text;
  rls boolean;
begin
  foreach t in array read_tables loop
    execute format('grant select on public.%I to restaurant_worker', t);
    select c.relrowsecurity into rls from pg_class c where c.oid = format('public.%I', t)::regclass;
    if rls then
      execute format('drop policy if exists worker_read on public.%I', t);
      execute format('create policy worker_read on public.%I for select to restaurant_worker using (true)', t);
    end if;
  end loop;

  foreach t in array write_tables loop
    execute format('grant insert on public.%I to restaurant_worker', t);
    execute format('drop policy if exists worker_insert on public.%I', t);
    execute format('create policy worker_insert on public.%I for insert to restaurant_worker with check (true)', t);
  end loop;

  grant update on public.calc_run to restaurant_worker;
  drop policy if exists worker_update on public.calc_run;
  create policy worker_update on public.calc_run for update to restaurant_worker using (true) with check (true);
end
$$;
