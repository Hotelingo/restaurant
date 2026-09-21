# Calculation engine

Pure Python calculation functions.

Non-negotiable properties:
- Decimal-based money arithmetic;
- stable calc IDs;
- no database access;
- no HTTP/network access;
- no browser dependency;
- no clock or randomness;
- all settings supplied explicitly;
- missing is never silently converted to zero.

This package must run its unit tests with no database and no network available.

## Management P&L (PL)

calculate_pl_ladder(...) implements the eleven frozen Management P&L calc IDs from the Calculation Engine Specification. It accepts canonical, non-calculated ladder inputs and returns results in the stable ladder order. Missing source values return NOT_CALCULATED; dependent subtotals propagate that state rather than manufacturing zeroes.

calculate_pl_variances(...) emits PL.VAR.<LADDER_CODE> results. Every calculated variance stores both raw_delta = actual - comparator and profit_effect; cost-line profit effects reverse the raw sign so favourable is positive. A wholly missing comparator returns NOT_CALCULATED / COMPARATOR_NOT_COMMITTED.

No formula rounds. quantize_money_for_presentation(...) is an explicit presentation-boundary helper using ROUND_HALF_UP and a caller-supplied currency minor unit.

The Amberside engine parity tests aggregate fixture rows through explicit account-code mappings, not through source amounts, then prove all eleven ladder values plus the frozen Budget Operating Profit and Operating Profit variance.
