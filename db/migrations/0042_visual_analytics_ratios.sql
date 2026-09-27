-- 0042 · Visual analytics authoritative P&L ratios
--
-- AX-1 / AX-2. Registers the stable persisted ratio metrics used by the
-- Analysis Home and Management P&L visual layer. These metrics are produced by
-- the calculation worker; the browser remains presentation-only.

insert into calc_definition(
  calc_id,definition_version,module,name,unit,formula_key,active
)
values
  ('PL.RATIO.PRODUCT_COST_PCT','v1','PL','Product Cost %','ratio','PRODUCT_COST/NET_SALES',true),
  ('PL.RATIO.PRODUCT_MARGIN_PCT','v1','PL','Product Margin %','ratio','PRODUCT_MARGIN/NET_SALES',true),
  ('PL.RATIO.LABOUR_PCT','v1','PL','Labour %','ratio','DIRECT_LABOUR/NET_SALES',true),
  ('PL.RATIO.CONTRIBUTION_PCT','v1','PL','Contribution %','ratio','CONTRIBUTION/NET_SALES',true),
  ('PL.RATIO.OPERATING_PROFIT_PCT','v1','PL','Operating Profit %','ratio','OPERATING_PROFIT/NET_SALES',true),
  ('PL.RATIO.VAR.PRODUCT_COST_PCT','v1','PL','Product Cost % variance','ratio','ratio_variance:PRODUCT_COST_PCT',true),
  ('PL.RATIO.VAR.PRODUCT_MARGIN_PCT','v1','PL','Product Margin % variance','ratio','ratio_variance:PRODUCT_MARGIN_PCT',true),
  ('PL.RATIO.VAR.LABOUR_PCT','v1','PL','Labour % variance','ratio','ratio_variance:LABOUR_PCT',true),
  ('PL.RATIO.VAR.CONTRIBUTION_PCT','v1','PL','Contribution % variance','ratio','ratio_variance:CONTRIBUTION_PCT',true),
  ('PL.RATIO.VAR.OPERATING_PROFIT_PCT','v1','PL','Operating Profit % variance','ratio','ratio_variance:OPERATING_PROFIT_PCT',true)
on conflict (calc_id,definition_version) do nothing;

-- Additive only. Historical immutable runs are not rewritten; the next PL run
-- for a period will carry the ratio snapshot alongside the existing ladder.
