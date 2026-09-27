"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { LabourOtherAnalysisResponse, LabourRoleGroupRead, PLAnalysisResponse } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { AnalyticsKpi } from "@/components/analytics/AnalyticsCharts";
import { calcNumber, EffectBars, EvidenceChip, ReadinessStrip, resultText } from "@/components/analytics/ModuleAnalytics";
import { formatAmount } from "@/lib/format";

function plLine(data: PLAnalysisResponse | null, code: string) {
  return data?.lines.find((line) => line.line_code === code) ?? null;
}
function plRatio(data: PLAnalysisResponse | null, code: string) {
  return data?.ratios.find((ratio) => ratio.metric_code === code) ?? null;
}
function strongest(rows: LabourRoleGroupRead[], field: "total_variance" | "hours_effect_raw" | "rate_effect_raw") {
  return rows
    .map((row) => ({ row, value: calcNumber(row[field], "profit_effect") }))
    .filter((item): item is { row: LabourRoleGroupRead; value: number } => item.value !== null)
    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))[0] ?? null;
}

export default function LabourClient({ outletId, periodId }: { outletId: string; periodId?: string }) {
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
      .then(([labour, pl]) => {
        if (!cancelled) {
          setData(labour);
          setPnl(pl);
          setError(null);
        }
      })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load Labour analysis.", 500, null));
      });
    return () => { cancelled = true; };
  }, [outletId, periodId]);

  const rows = useMemo(() => [...(data?.labour ?? [])].sort((a, b) => {
    const av = calcNumber(a.total_variance, "profit_effect") ?? 0;
    const bv = calcNumber(b.total_variance, "profit_effect") ?? 0;
    return Math.abs(bv) - Math.abs(av);
  }), [data]);

  if (!data) {
    return <main className="shell"><div className="panel wide"><div className="page-head"><h1>Labour &amp; Productivity</h1></div>{error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /></>}</div></main>;
  }

  const labourLine = plLine(pnl, "DIRECT_LABOUR");
  const labourPct = plRatio(pnl, "LABOUR_PCT");
  const totalLeader = strongest(rows, "total_variance");
  const hoursLeader = strongest(rows, "hours_effect_raw");
  const rateLeader = strongest(rows, "rate_effect_raw");

  return (
    <main className="shell">
      <div className="panel wide analytics-page">
        <div className="row sb">
          <div className="page-head">
            <h1>Labour &amp; Productivity</h1>
            <p>Separate hours, pay-rate, overtime and productivity signals without automatically inferring overstaffing.</p>
          </div>
          <div className="row"><Chip tone="mute">{data.period.label}</Chip>{data.run ? <Chip tone="ok">Calculated</Chip> : <Chip tone="warn">Not calculated</Chip>}</div>
        </div>

        <ReadinessStrip status={data.readiness.status} missingInputs={data.readiness.missing_inputs} explanation={data.readiness.explanation_code} />
        <div className="banner info"><strong>Interpretation guardrail:</strong> an adverse Labour % or hours effect identifies a movement; it does not prove the outlet is overstaffed. Operational context is still required.</div>

        {!data.run ? (
          <EmptyState title="Labour analysis is not ready">
            Import and commit T5 labour detail and ensure the Direct Labour comparator is available. No staffing conclusion is generated while the evidence is incomplete.
          </EmptyState>
        ) : (
          <>
            <div className="analytics-kpi-grid">
              <AnalyticsKpi label="Direct Labour" actual={labourLine?.actual} comparator={labourLine?.comparator} variance={labourLine?.variance} comparatorLabel="Comparator" />
              <AnalyticsKpi label="Labour %" actual={labourPct?.actual} comparator={labourPct?.comparator} variance={labourPct?.variance} unit="ratio" comparatorLabel="Comparator" />
              <div className="analytics-kpi"><div className="analytics-kpi-label">Role groups analysed</div><div className="analytics-kpi-value">{rows.length}</div><div className="analytics-kpi-comp">Each role group keeps its own activity basis</div></div>
            </div>

            <div className="analytics-primary-grid">
              <Card title="Hours effect by role group">
                <p className="muted analytics-card-intro">Favourable-positive profit impact of the hours component.</p>
                <EffectBars rows={rows.map((row) => ({ label: row.role_group, value: calcNumber(row.hours_effect_raw, "profit_effect") }))} />
              </Card>
              <Card title="Rate effect by role group">
                <p className="muted analytics-card-intro">Separates pay-rate movement from worked-hour movement.</p>
                <EffectBars rows={rows.map((row) => ({ label: row.role_group, value: calcNumber(row.rate_effect_raw, "profit_effect") }))} />
              </Card>
            </div>

            <div className="analytics-secondary-grid">
              <Card title="Role-group total variance">
                <EffectBars rows={rows.map((row) => ({ label: row.role_group, value: calcNumber(row.total_variance, "profit_effect") }))} />
              </Card>
              <Card title="Management observations">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Largest total movement</strong><span>{totalLeader ? `${totalLeader.row.role_group}: ${formatAmount(Math.abs(totalLeader.value))} ${totalLeader.value < 0 ? "adverse" : "favourable"} profit impact.` : "No supported total variance."}</span></div>
                  <div className="analytics-observation"><strong>Largest hours component</strong><span>{hoursLeader ? `${hoursLeader.row.role_group}: ${formatAmount(Math.abs(hoursLeader.value))} ${hoursLeader.value < 0 ? "adverse" : "favourable"} hours effect.` : "Hours effect not calculated."}</span></div>
                  <div className="analytics-observation"><strong>Largest rate component</strong><span>{rateLeader ? `${rateLeader.row.role_group}: ${formatAmount(Math.abs(rateLeader.value))} ${rateLeader.value < 0 ? "adverse" : "favourable"} rate effect.` : "Rate effect not calculated."}</span></div>
                </div>
              </Card>
            </div>

            <Card title="Role-group productivity and labour bridge">
              <div className="tw"><table className="tbl analysis-table">
                <thead><tr><th>Role group</th><th>Activity basis</th><th className="n">Actual rate</th><th className="n">Comparator rate</th><th className="n">Hours effect</th><th className="n">Rate effect</th><th className="n">Total profit impact</th><th className="n">Hours / activity</th><th className="n">Cost / activity</th><th className="n">OT hours</th><th className="n">OT rate effect</th><th>Evidence</th></tr></thead>
                <tbody>{rows.map((row) => (
                  <tr key={`${row.role_group}:${row.activity_basis ?? ""}`}>
                    <th scope="row">{row.role_group}</th><td>{row.activity_basis ?? "—"}</td>
                    <td className="n">{resultText(row.actual_rate)}</td><td className="n">{resultText(row.comparator_rate)}</td>
                    <td className={`n ${(calcNumber(row.hours_effect_raw, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.hours_effect_raw, "currency", "profit_effect")}</td>
                    <td className={`n ${(calcNumber(row.rate_effect_raw, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.rate_effect_raw, "currency", "profit_effect")}</td>
                    <td className={`n ${(calcNumber(row.total_variance, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(row.total_variance, "currency", "profit_effect")}</td>
                    <td className="n">{resultText(row.hours_per_activity, "plain")}</td><td className="n">{resultText(row.cost_per_activity)}</td>
                    <td className="n">{resultText(row.overtime_hours, "plain")}</td><td className="n">{resultText(row.overtime_rate_effect, "currency", "profit_effect")}</td>
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
