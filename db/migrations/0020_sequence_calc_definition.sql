-- 0020 · SEQUENCE calculation registry entry
-- No schema mutation: register the accepted first-material-movement output so
-- persisted worker results remain traceable to a versioned calculation definition.

insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values (
  'SEQ.FIRST_MATERIAL_MOVEMENT',
  'v1',
  'SEQ',
  'First Material Movement',
  'ladder_code',
  'first_material:ordered_pl_variances',
  true
)
on conflict (calc_id,definition_version) do nothing;

-- Additive seed only; no rollback is required after calculation history exists.
