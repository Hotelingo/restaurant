\set ON_ERROR_STOP on

create or replace function r1_assert_rejects(stmt text, label text)
returns void language plpgsql as $$
begin
  begin
    execute stmt;
  exception when others then
    raise notice 'PASS % (%)',label,sqlerrm;
    return;
  end;
  raise exception 'FAIL % accepted unexpectedly',label;
end $$;

do $$
declare
  v_run uuid;
  v_pack uuid;
  v_review uuid;
  v_actual_profile uuid;
begin
  select q.completed_run_id into v_run
  from calculation_request_queue q
  where q.source_batch_id='29000000-0000-0000-0000-000000000201'
    and q.status='completed'
  order by q.created_at desc
  limit 1;

  select r.id into v_review
  from review r
  join outlet o on o.id=r.outlet_id
  where o.code='R1ACC'
  order by r.created_at desc
  limit 1;

  select p.id into v_pack
  from pack_version p
  where p.review_id=v_review
  order by p.version_no desc
  limit 1;

  select profile_version_id into v_actual_profile
  from import_batch
  where id='29000000-0000-0000-0000-000000000201';

  -- Step 12 · reviewer change request and final sign are both preserved.
  if (select status::text from pack_version where id=v_pack) <> 'signed' then
    raise exception 'FAIL R1 final Owner Pack is not signed';
  end if;

  if not exists (
    select 1
    from pack_version
    where id=v_pack
      and artifact_bucket='uploads'
      and artifact_path like '%/owner-pack-v1-%.html'
      and artifact_sha256 ~ '^[0-9a-f]{64}
  if (select count(*) from signoff where pack_version_id=v_pack) <> 2 then
    raise exception 'FAIL R1 expected request-changes + signed history';
  end if;

  if (select count(*) from signoff
      where pack_version_id=v_pack and decision='changes_requested') <> 1
     or
     (select count(*) from signoff
      where pack_version_id=v_pack and decision='signed') <> 1 then
    raise exception 'FAIL R1 sign-off history does not preserve both reviewer decisions';
  end if;

  if not exists (
    select 1 from signoff
    where pack_version_id=v_pack
      and decision='signed'
      and calc_run_id=v_run
      and reviewer_user_id='29000000-0000-0000-0000-000000000002'
      and reviewer_name='R1 Reviewer'
      and reviewer_role='reviewer'
      and coalesce((gate_snapshot->>'passed')::boolean,false)
      and jsonb_array_length(gate_snapshot->'outcomes')=11
  ) then
    raise exception 'FAIL R1 signed history does not pin reviewer + 11-condition RG snapshot';
  end if;

  -- Step 13 · source → mapping → canonical facts → calc run → claim → pack →
  -- sign-off remains traversable with no detached links.
  if (select count(*) from calc_run_input where run_id=v_run) <> 2 then
    raise exception 'FAIL R1 calc run lost one of its two committed input snapshots';
  end if;

  if exists (
    select 1
    from calc_run_input cri
    join import_batch b on b.id=cri.batch_id
    join source_file sf on sf.id=b.source_file_id
    where cri.run_id=v_run
      and (
        b.status <> 'committed'
        or b.canonical_commit_hash is null
        or b.canonical_commit_hash <> cri.canonical_commit_hash
        or sf.sha256 is null
        or length(sf.sha256) <> 64
      )
  ) then
    raise exception 'FAIL R1 calc input/source-file commit lineage is incomplete';
  end if;

  if (
    select count(*)
    from financial_fact ff
    join staging_row sr
      on sr.id=ff.staging_row_id
     and sr.batch_id=ff.batch_id
    join import_batch b on b.id=ff.batch_id
    join source_file sf on sf.id=b.source_file_id
    where ff.batch_id in (
      '29000000-0000-0000-0000-000000000201',
      '29000000-0000-0000-0000-000000000202'
    )
  ) <> 14 then
    raise exception 'FAIL R1 canonical facts do not all trace to staging rows and source files';
  end if;

  if not exists (
    select 1
    from profile_version pv
    join account_mapping am on am.profile_version_id=pv.id
    join ladder_line ll on ll.id=am.ladder_line_id
    where pv.id=v_actual_profile
      and pv.version_no=2
      and pv.supersedes_profile_version_id is not null
      and am.source_account_code='8000'
      and ll.code='OWNER_STRUCTURAL_COST'
  ) then
    raise exception 'FAIL R1 mapping lineage lost the reused profile/new-account resolution';
  end if;

  if exists (
    select 1
    from calc_result cr
    cross join lateral jsonb_array_elements_text(cr.input_refs) ref
    left join financial_fact ff
      on ff.id=replace(ref.value,'financial_fact:','')::uuid
    where cr.run_id=v_run
      and cr.grain_type='management_pl'
      and cr.grain_key->>'scenario' in ('actual','budget')
      and cr.calc_id in (
        'PL.NET_SALES',
        'PL.PRODUCT_COST',
        'PL.CHANNEL_COST',
        'PL.DIRECT_LABOUR',
        'PL.OTHER_DIRECT_OPERATING',
        'PL.SHARED_RESTAURANT_COST',
        'PL.OWNER_STRUCTURAL_COST'
      )
      and ff.id is null
  ) then
    raise exception 'FAIL R1 source calc_result input_refs contain detached financial facts';
  end if;

  if not exists (
    select 1
    from claim c
    join claim_citation cc on cc.claim_id=c.id
    join calc_result cr
      on cr.id=cc.calc_result_id
     and cr.run_id=cc.calc_run_id
    join pack_version p on p.id=c.pack_version_id
    where p.id=v_pack
      and p.calc_run_id=v_run
      and cc.calc_run_id=v_run
      and cr.calc_id='PL.VAR.NET_SALES'
      and c.claim_status='accepted'
  ) then
    raise exception 'FAIL R1 pack claim does not trace to the pinned calc result';
  end if;

  if not exists (
    select 1
    from review_issue ri
    join decision d on d.id=ri.active_decision_id
    join action a on a.decision_id=d.id
    where ri.review_id=v_review
      and ri.source_calc_run_id=v_run
      and ri.ladder_code='NET_SALES'
      and d.disposition='ACT'
  ) then
    raise exception 'FAIL R1 issue → decision → action lineage is incomplete';
  end if;

  if not exists (
    select 1
    from evidence_request er
    join review_issue ri on ri.id=er.review_issue_id
    where ri.review_id=v_review
      and er.status='fulfilled'
      and er.fulfilled_batch_id='29000000-0000-0000-0000-000000000202'
  ) then
    raise exception 'FAIL R1 evidence request lineage to committed source material is incomplete';
  end if;

  raise notice 'PASS R1 twelve-step acceptance and complete source/mapping/calc/pack lineage';
end
$$;

select r1_assert_rejects(
  $q$
    update calc_run
    set engine_version='rewrite'
    where id=(
      select completed_run_id
      from calculation_request_queue
      where source_batch_id='29000000-0000-0000-0000-000000000201'
        and status='completed'
      order by created_at desc
      limit 1
    )
  $q$,
  'completed R1 calc run is immutable'
);

select r1_assert_rejects(
  $q$
    update signoff
    set caveat='rewrite reviewer history'
    where pack_version_id=(
      select p.id
      from pack_version p
      join review r on r.id=p.review_id
      join outlet o on o.id=r.outlet_id
      where o.code='R1ACC'
      order by p.version_no desc
      limit 1
    )
      and decision='signed'
  $q$,
  'R1 signed reviewer history is immutable'
);

select r1_assert_rejects(
  $q$
    update financial_fact
    set amount=0
    where batch_id='29000000-0000-0000-0000-000000000201'
  $q$,
  'R1 committed canonical facts are immutable'
);

drop function r1_assert_rejects(text,text);

      and artifact_source_sha256 ~ '^[0-9a-f]{64}
  if (select count(*) from signoff where pack_version_id=v_pack) <> 2 then
    raise exception 'FAIL R1 expected request-changes + signed history';
  end if;

  if (select count(*) from signoff
      where pack_version_id=v_pack and decision='changes_requested') <> 1
     or
     (select count(*) from signoff
      where pack_version_id=v_pack and decision='signed') <> 1 then
    raise exception 'FAIL R1 sign-off history does not preserve both reviewer decisions';
  end if;

  if not exists (
    select 1 from signoff
    where pack_version_id=v_pack
      and decision='signed'
      and calc_run_id=v_run
      and reviewer_user_id='29000000-0000-0000-0000-000000000002'
      and reviewer_name='R1 Reviewer'
      and reviewer_role='reviewer'
      and coalesce((gate_snapshot->>'passed')::boolean,false)
      and jsonb_array_length(gate_snapshot->'outcomes')=11
  ) then
    raise exception 'FAIL R1 signed history does not pin reviewer + 11-condition RG snapshot';
  end if;

  -- Step 13 · source → mapping → canonical facts → calc run → claim → pack →
  -- sign-off remains traversable with no detached links.
  if (select count(*) from calc_run_input where run_id=v_run) <> 2 then
    raise exception 'FAIL R1 calc run lost one of its two committed input snapshots';
  end if;

  if exists (
    select 1
    from calc_run_input cri
    join import_batch b on b.id=cri.batch_id
    join source_file sf on sf.id=b.source_file_id
    where cri.run_id=v_run
      and (
        b.status <> 'committed'
        or b.canonical_commit_hash is null
        or b.canonical_commit_hash <> cri.canonical_commit_hash
        or sf.sha256 is null
        or length(sf.sha256) <> 64
      )
  ) then
    raise exception 'FAIL R1 calc input/source-file commit lineage is incomplete';
  end if;

  if (
    select count(*)
    from financial_fact ff
    join staging_row sr
      on sr.id=ff.staging_row_id
     and sr.batch_id=ff.batch_id
    join import_batch b on b.id=ff.batch_id
    join source_file sf on sf.id=b.source_file_id
    where ff.batch_id in (
      '29000000-0000-0000-0000-000000000201',
      '29000000-0000-0000-0000-000000000202'
    )
  ) <> 14 then
    raise exception 'FAIL R1 canonical facts do not all trace to staging rows and source files';
  end if;

  if not exists (
    select 1
    from profile_version pv
    join account_mapping am on am.profile_version_id=pv.id
    join ladder_line ll on ll.id=am.ladder_line_id
    where pv.id=v_actual_profile
      and pv.version_no=2
      and pv.supersedes_profile_version_id is not null
      and am.source_account_code='8000'
      and ll.code='OWNER_STRUCTURAL_COST'
  ) then
    raise exception 'FAIL R1 mapping lineage lost the reused profile/new-account resolution';
  end if;

  if exists (
    select 1
    from calc_result cr
    cross join lateral jsonb_array_elements_text(cr.input_refs) ref
    left join financial_fact ff
      on ff.id=replace(ref.value,'financial_fact:','')::uuid
    where cr.run_id=v_run
      and cr.grain_type='management_pl'
      and cr.grain_key->>'scenario' in ('actual','budget')
      and cr.calc_id in (
        'PL.NET_SALES',
        'PL.PRODUCT_COST',
        'PL.CHANNEL_COST',
        'PL.DIRECT_LABOUR',
        'PL.OTHER_DIRECT_OPERATING',
        'PL.SHARED_RESTAURANT_COST',
        'PL.OWNER_STRUCTURAL_COST'
      )
      and ff.id is null
  ) then
    raise exception 'FAIL R1 source calc_result input_refs contain detached financial facts';
  end if;

  if not exists (
    select 1
    from claim c
    join claim_citation cc on cc.claim_id=c.id
    join calc_result cr
      on cr.id=cc.calc_result_id
     and cr.run_id=cc.calc_run_id
    join pack_version p on p.id=c.pack_version_id
    where p.id=v_pack
      and p.calc_run_id=v_run
      and cc.calc_run_id=v_run
      and cr.calc_id='PL.VAR.NET_SALES'
      and c.claim_status='accepted'
  ) then
    raise exception 'FAIL R1 pack claim does not trace to the pinned calc result';
  end if;

  if not exists (
    select 1
    from review_issue ri
    join decision d on d.id=ri.active_decision_id
    join action a on a.decision_id=d.id
    where ri.review_id=v_review
      and ri.source_calc_run_id=v_run
      and ri.ladder_code='NET_SALES'
      and d.disposition='ACT'
  ) then
    raise exception 'FAIL R1 issue → decision → action lineage is incomplete';
  end if;

  if not exists (
    select 1
    from evidence_request er
    join review_issue ri on ri.id=er.review_issue_id
    where ri.review_id=v_review
      and er.status='fulfilled'
      and er.fulfilled_batch_id='29000000-0000-0000-0000-000000000202'
  ) then
    raise exception 'FAIL R1 evidence request lineage to committed source material is incomplete';
  end if;

  raise notice 'PASS R1 twelve-step acceptance and complete source/mapping/calc/pack lineage';
end
$$;

select r1_assert_rejects(
  $q$
    update calc_run
    set engine_version='rewrite'
    where id=(
      select completed_run_id
      from calculation_request_queue
      where source_batch_id='29000000-0000-0000-0000-000000000201'
        and status='completed'
      order by created_at desc
      limit 1
    )
  $q$,
  'completed R1 calc run is immutable'
);

select r1_assert_rejects(
  $q$
    update signoff
    set caveat='rewrite reviewer history'
    where pack_version_id=(
      select p.id
      from pack_version p
      join review r on r.id=p.review_id
      join outlet o on o.id=r.outlet_id
      where o.code='R1ACC'
      order by p.version_no desc
      limit 1
    )
      and decision='signed'
  $q$,
  'R1 signed reviewer history is immutable'
);

select r1_assert_rejects(
  $q$
    update financial_fact
    set amount=0
    where batch_id='29000000-0000-0000-0000-000000000201'
  $q$,
  'R1 committed canonical facts are immutable'
);

drop function r1_assert_rejects(text,text);

      and renderer_version='server-html-v1'
      and template_version='owner-pack-v1'
  ) then
    raise exception 'FAIL R1 signed Owner Pack is missing deterministic rendered artefact provenance';
  end if;

  if (select count(*) from signoff where pack_version_id=v_pack) <> 2 then
    raise exception 'FAIL R1 expected request-changes + signed history';
  end if;

  if (select count(*) from signoff
      where pack_version_id=v_pack and decision='changes_requested') <> 1
     or
     (select count(*) from signoff
      where pack_version_id=v_pack and decision='signed') <> 1 then
    raise exception 'FAIL R1 sign-off history does not preserve both reviewer decisions';
  end if;

  if not exists (
    select 1 from signoff
    where pack_version_id=v_pack
      and decision='signed'
      and calc_run_id=v_run
      and reviewer_user_id='29000000-0000-0000-0000-000000000002'
      and reviewer_name='R1 Reviewer'
      and reviewer_role='reviewer'
      and coalesce((gate_snapshot->>'passed')::boolean,false)
      and jsonb_array_length(gate_snapshot->'outcomes')=11
  ) then
    raise exception 'FAIL R1 signed history does not pin reviewer + 11-condition RG snapshot';
  end if;

  -- Step 13 · source → mapping → canonical facts → calc run → claim → pack →
  -- sign-off remains traversable with no detached links.
  if (select count(*) from calc_run_input where run_id=v_run) <> 2 then
    raise exception 'FAIL R1 calc run lost one of its two committed input snapshots';
  end if;

  if exists (
    select 1
    from calc_run_input cri
    join import_batch b on b.id=cri.batch_id
    join source_file sf on sf.id=b.source_file_id
    where cri.run_id=v_run
      and (
        b.status <> 'committed'
        or b.canonical_commit_hash is null
        or b.canonical_commit_hash <> cri.canonical_commit_hash
        or sf.sha256 is null
        or length(sf.sha256) <> 64
      )
  ) then
    raise exception 'FAIL R1 calc input/source-file commit lineage is incomplete';
  end if;

  if (
    select count(*)
    from financial_fact ff
    join staging_row sr
      on sr.id=ff.staging_row_id
     and sr.batch_id=ff.batch_id
    join import_batch b on b.id=ff.batch_id
    join source_file sf on sf.id=b.source_file_id
    where ff.batch_id in (
      '29000000-0000-0000-0000-000000000201',
      '29000000-0000-0000-0000-000000000202'
    )
  ) <> 14 then
    raise exception 'FAIL R1 canonical facts do not all trace to staging rows and source files';
  end if;

  if not exists (
    select 1
    from profile_version pv
    join account_mapping am on am.profile_version_id=pv.id
    join ladder_line ll on ll.id=am.ladder_line_id
    where pv.id=v_actual_profile
      and pv.version_no=2
      and pv.supersedes_profile_version_id is not null
      and am.source_account_code='8000'
      and ll.code='OWNER_STRUCTURAL_COST'
  ) then
    raise exception 'FAIL R1 mapping lineage lost the reused profile/new-account resolution';
  end if;

  if exists (
    select 1
    from calc_result cr
    cross join lateral jsonb_array_elements_text(cr.input_refs) ref
    left join financial_fact ff
      on ff.id=replace(ref.value,'financial_fact:','')::uuid
    where cr.run_id=v_run
      and cr.grain_type='management_pl'
      and cr.grain_key->>'scenario' in ('actual','budget')
      and cr.calc_id in (
        'PL.NET_SALES',
        'PL.PRODUCT_COST',
        'PL.CHANNEL_COST',
        'PL.DIRECT_LABOUR',
        'PL.OTHER_DIRECT_OPERATING',
        'PL.SHARED_RESTAURANT_COST',
        'PL.OWNER_STRUCTURAL_COST'
      )
      and ff.id is null
  ) then
    raise exception 'FAIL R1 source calc_result input_refs contain detached financial facts';
  end if;

  if not exists (
    select 1
    from claim c
    join claim_citation cc on cc.claim_id=c.id
    join calc_result cr
      on cr.id=cc.calc_result_id
     and cr.run_id=cc.calc_run_id
    join pack_version p on p.id=c.pack_version_id
    where p.id=v_pack
      and p.calc_run_id=v_run
      and cc.calc_run_id=v_run
      and cr.calc_id='PL.VAR.NET_SALES'
      and c.claim_status='accepted'
  ) then
    raise exception 'FAIL R1 pack claim does not trace to the pinned calc result';
  end if;

  if not exists (
    select 1
    from review_issue ri
    join decision d on d.id=ri.active_decision_id
    join action a on a.decision_id=d.id
    where ri.review_id=v_review
      and ri.source_calc_run_id=v_run
      and ri.ladder_code='NET_SALES'
      and d.disposition='ACT'
  ) then
    raise exception 'FAIL R1 issue → decision → action lineage is incomplete';
  end if;

  if not exists (
    select 1
    from evidence_request er
    join review_issue ri on ri.id=er.review_issue_id
    where ri.review_id=v_review
      and er.status='fulfilled'
      and er.fulfilled_batch_id='29000000-0000-0000-0000-000000000202'
  ) then
    raise exception 'FAIL R1 evidence request lineage to committed source material is incomplete';
  end if;

  raise notice 'PASS R1 twelve-step acceptance and complete source/mapping/calc/pack lineage';
end
$$;

select r1_assert_rejects(
  $q$
    update calc_run
    set engine_version='rewrite'
    where id=(
      select completed_run_id
      from calculation_request_queue
      where source_batch_id='29000000-0000-0000-0000-000000000201'
        and status='completed'
      order by created_at desc
      limit 1
    )
  $q$,
  'completed R1 calc run is immutable'
);

select r1_assert_rejects(
  $q$
    update signoff
    set caveat='rewrite reviewer history'
    where pack_version_id=(
      select p.id
      from pack_version p
      join review r on r.id=p.review_id
      join outlet o on o.id=r.outlet_id
      where o.code='R1ACC'
      order by p.version_no desc
      limit 1
    )
      and decision='signed'
  $q$,
  'R1 signed reviewer history is immutable'
);

select r1_assert_rejects(
  $q$
    update financial_fact
    set amount=0
    where batch_id='29000000-0000-0000-0000-000000000201'
  $q$,
  'R1 committed canonical facts are immutable'
);

drop function r1_assert_rejects(text,text);
