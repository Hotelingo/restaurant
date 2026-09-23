"use client";

import { useMemo } from "react";
import type { CalcResultRead, CalcResultsResponse, ReviewRead } from "@/lib/contracts";
import { LADDER } from "@/lib/domain";
import { useApi } from "@/lib/use-api";

export type ReviewLine = {
  code: string;
  label: string;
  kind: string;
  actual: CalcResultRead | null;
  comparator: CalcResultRead | null;
  variance: CalcResultRead | null;
};

/**
 * Management P&L lines from the review's pinned calculation run, never the
 * latest one: a shortlist or claim must cite the snapshot the review framed.
 */
export function useReviewLines(review: ReviewRead | null) {
  const runId = review?.active_calc_run_id ?? null;
  const results = useApi<CalcResultsResponse>(runId ? `/calc-runs/${runId}/results` : null);

  const lines = useMemo<ReviewLine[]>(() => {
    const all = results.data?.results ?? [];
    const comparator = review?.comparator_scenario ?? null;
    const find = (grain: string, code: string, scenario?: string | null) =>
      all.find((r) => r.grain_type === grain && r.grain_key.ladder_code === code
        && (scenario === undefined || r.grain_key.scenario === scenario)) ?? null;
    return LADDER.map((l) => ({
      code: l.code,
      label: l.label,
      kind: l.kind,
      actual: find("management_pl", l.code, "actual"),
      comparator: comparator ? find("management_pl", l.code, comparator) : null,
      variance: find("management_pl_variance", l.code),
    }));
  }, [results.data, review?.comparator_scenario]);

  return { lines, loading: results.loading, error: results.error, currency: results.data?.results[0]?.currency_code ?? null };
}
