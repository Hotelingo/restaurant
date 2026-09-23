-- 0020 · First material movement calculation definition
-- The pure engine and worker already use the existing calc_result text-value
-- contract. This migration registers the stable sequence calculation id.

insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values (
  'SEQ.FIRST_MATERIAL_MOVEMENT',
  'v1',
  'SEQ',
  'First Material Movement',
  'ladder_code',
  'first_material_movement:pl_ladder',
  true
)
on conflict (calc_id,definition_version) do nothing;

-- Additive migration. Historical calc runs retain their original result set;
-- future runs add the sequence result under the stable v1 calc id.
