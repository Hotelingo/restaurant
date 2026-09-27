"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { LabourOtherAnalysisResponse, OtherCostRead, PLAnalysisResponse } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { AnalyticsKpi } from "@/components/analytics/AnalyticsCharts";
import { calcNumber, EffectBars, EvidenceChip, ReadinessStrip, resultText } from "@/components/analytics/ModuleAnalytics";
import { formatAmount } from "@/lib/format";

function plLine(data: PLAnalysisResponse | null, code: string) {
  return data?.lines.find((line) => line.line_code === code) ?? null;
}
function labelize(value: string): string {
  return value.toLowerCase().split("_").map((part) => part ? part[0].toUpperCase() + part.slice(1) : "").join(" ");
}
function strongest(rows: OtherCostRead[], field: "total_variance" | "quantity_effect" | "rate_effect") {
  return rows
    .map((row) => ({ row, value: calcNumber(row[field], "profit_effect") }))
    .filter((item): item is { row: OtherCostRead; value: number } => item.value !== null)
    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))[0] ?? null;
}

export default function OtherCostsClient({ outletId, periodId }: { outletId: string; periodId?: string }) {
  const [data, setData] = useState<LabourOtherAnalysisResponse | null>(null);
  const [pnl, setPnl] = useState<PLAnalysisResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;
    const query = periodId ? `?period_id=${encodeURIComponent(periodId)}` : "";
    Promise.all([
      apiFetch<LabourOtherAnalysisResponse>(`/outlets/${outletId}/analysis/labour-other${query}`),
      apiFetch<PLAnalysisResponse>(`/outlets/${outletId}/analysis/pnl${query}`).catch(() => null),
    ])
      .then(([other, pl]) => {
        if (!cancelled) {
          setData(other);
          setPnl(pl);
          setError(null);
        }
      })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load Other Cost analysis.", 500, null));
      });
    return () => { cancelled = true; };
  }, [outletId, periodId]);

  const rows = useMemo(() => [...(data?.other_costs ?? [])].sort((a, b) => {
    const av = calcNumber(a.total_variance, "profit_effect") ?? 0;
    const bv = calcNumber(b.total_variance, "profit_effect") ?? 0;
    return Math.abs(bv) - Math.abs(av);
  }), [data]);

  if (!data) {
    return <main className="shell"><div className="panel wide"><div className="page-head"><h1>Other Operating Costs</h1></div>{error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /></>}</div></main>;
  }

  const otherDirect = plLine(pnl, "OTHER_DIRECT_OPERATING");
  const shared = plLine(pnl, "SHARED_RESTAURANT_COST");
  const totalLeader = strongest(rows, "total_variance");
  const quantityLeader = strongest(rows, "quantity_effect");
  const rateLeader = strongest(rows, "rate_effect");

  return (
    <main className="shell">
      <div className="panel wide analytics-page">
        <div className="row sb">
          <div className="page-head">
            <h1>Other Operating Costs</h1>
            <p>Prioritise material cost movements and show quantity/rate decomposition only where the evidence supports it.</p>
          </div>
          <div className="row"><Chip tone="mute">{data.period.label}</Chip>{data.run ? <Chip tone="ok">Calculated</Chip> : <Chip tone="warn">Not calculated</Chip>}</div>
        </div>

        <ReadinessStrip status={data.readiness.status} missingInputs={data.readiness.missing_inputs} explanation={data.readiness.explanation_code} />
        <div className="banner info"><strong>Evidence guardrail:</strong> the application shows a total accounting variance even when quantity/rate evidence is unavailable; it does not estimate missing driver decomposition.</div>

        {!data.run ? (
          <EmptyState title="Other Cost driver analysis is not ready">
            Complete the inputs required by the Labour/Other Cost calculation run. Existing P&amp;L accounting movements remain visible in Management P&amp;L.
          </EmptyState>
        ) : (
          <>
            <div className="analytics-kpi-grid">
              <AnalyticsKpi label="Other Direct Operating" actual={otherDirect?.actual} comparator={otherDirect?.comparator} variance={otherDirect?.variance} comparatorLabel="Comparator" />
              <AnalyticsKpi label="Shared Restaurant Cost" actual={shared?.actual} comparator={shared?.comparator} variance={shared?.variance} comparatorLabel="Comparator" />
              <div className="analytics-kpi"><div className="analytics-kpi-label">Cost lines analysed</div><div className="analytics-kpi-value">{rows.length}</div><div className="analytics-kpi-comp">Quantity/rate decomposition depends on explicit evidence</div></div>
            </div>

            <div className="analytics-primary-grid">
              <Card title="Cost variance Pareto · profit impact">
                <EffectBars rows={rows.map((row) => ({ label: labelize(row.line_code), value: calcNumber(row.total_variance, "profit_effect") }))} />
              </Card>
              <Card title="Quantity effect where supported">
                <EffectBars rows={rows.map((row) => ({ label: labelize(row.line_code), value: calcNumber(row.quantity_effect, "profit_effect") }))} emptyMessage="No supported quantity decomposition in this run." />
              </Card>
            </div>

            <div className="analytics-secondary-grid">
              <Card title="Rate effect where supported">
                <EffectBars rows={rows.map((row) => ({ label: labelize(row.line_code), value: calcNumber(row.rate_effect, "profit_effect") }))} emptyMessage="No supported rate decomposition in this run." />
              </Card>
              <Card title="Management observations">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Largest total movement</strong><span>{totalLeader ? `${labelize(totalLeader.row.line_code)}: ${formatAmount(Math.abs(totalLeader.value))} ${totalLeader.value < 0 ? "adverse" : "favourable"} profit impact.` : "No supported cost variance."}</span></div>
                  <div className="analytics-observation"><strong>Largest quantity component</strong><span>{quantityLeader ? `${labelize(quantityLeader.row.line_code)}: ${formatAmount(Math.abs(quantityLeader.value))} ${quantityLeader.value < 0 ? "adverse" : "favourable"}.` : "Quantity evidence is not available."}</span></div>
                  <div className="analytics-observation"><strong>Largest rate component</strong><span>{rateLeader ? `${labelize(rateLeader.row.line_code)}: ${formatAmount(Math.abs(rateLeader.value))} ${rateLeader.value < 0 ? "adverse" : "favourable"}.` : "Rate evidence is not available."}</span></div>
                </div>
              </Card>
            </div>

            <Card title="Material operating-cost driver table">
              <div className="tw"><table className="tbl analysis-table">
                <thead><tr><th>Cost line</th><th>Comparator</th><th className="n">Quantity profit impact</th><th className="n">Rate profit impact</th><th className="n">Total profit impact</th><th>Evidence status</th></tr></thead>
                <tbody>{rows.map((row) => (
                  <tr key={`${row.line_code}:${row.comparator_scenario ?? ""}`}>
                    <th scope="row">{labelize(row.line_code)}</th><td>{row.comparator_scenario?.replaceAll("_", " ") ?? "—"}</td>
                    <td className={`n ${(calcNumber(row.quantity_effect, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.quantity_effect, "currency", "profit_effect")}</td>
                    <td className={`n ${(calcNumber(row.rate_effect, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.rate_effect, "currency", "profit_effect")}</td>
                    <td className={`n ${(calcNumber(row.total_variance, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.total_variance, "currency", "profit_effect")}</td>
                    <td><EvidenceChip status={row.evidence_status} /></td>
                  </tr>
                ))}</tbody>
              </table></div>
            </Card>
          </>
        )}

        <div className="row mt8"><Link className="btn" href={`/app/outlets/${outletId}/analysis?period=${data.period.id}`}>Back to Analysis Home</Link><Link className="btn p" href={`/app/outlets/${outletId}/reviews?period=${data.period.id}`}>Continue to review</Link></div>
      </div>
    </main>
  );
}
