"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { PLAnalysisResponse, RevenueAnalysisResponse, RevenueGrainRead } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { AnalyticsKpi } from "@/components/analytics/AnalyticsCharts";
import { calcNumber, EffectBars, EvidenceChip, ReadinessStrip, resultText } from "@/components/analytics/ModuleAnalytics";
import { formatAmount, formatPercent } from "@/lib/format";

function line(data: PLAnalysisResponse | null, code: string) {
  return data?.lines.find((item) => item.line_code === code) ?? null;
}

function strongest(grains: RevenueGrainRead[], field: "total_variance" | "volume_effect" | "spend_effect", adverseOnly = false) {
  return grains
    .map((grain) => ({ grain, value: calcNumber(grain[field], "profit_effect") }))
    .filter((row): row is { grain: RevenueGrainRead; value: number } => row.value !== null && (!adverseOnly || row.value < 0))
    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))[0] ?? null;
}

export default function RevenueClient({ outletId, periodId }: { outletId: string; periodId?: string }) {
  const [data, setData] = useState<RevenueAnalysisResponse | null>(null);
  const [pnl, setPnl] = useState<PLAnalysisResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;
    const query = periodId ? `?period_id=${encodeURIComponent(periodId)}` : "";
    Promise.all([
      apiFetch<RevenueAnalysisResponse>(`/outlets/${outletId}/analysis/revenue${query}`),
      apiFetch<PLAnalysisResponse>(`/outlets/${outletId}/analysis/pnl${query}`).catch(() => null),
    ])
      .then(([revenue, pl]) => {
        if (!cancelled) {
          setData(revenue);
          setPnl(pl);
          setError(null);
        }
      })
      .catch((cause) => {
        if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load Revenue analysis.", 500, null));
      });
    return () => { cancelled = true; };
  }, [outletId, periodId]);

  const sorted = useMemo(() => {
    return [...(data?.grains ?? [])].sort((a, b) => {
      const av = calcNumber(a.total_variance, "profit_effect") ?? 0;
      const bv = calcNumber(b.total_variance, "profit_effect") ?? 0;
      return Math.abs(bv) - Math.abs(av);
    });
  }, [data]);

  if (!data) {
    return <main className="shell"><div className="panel wide"><div className="page-head"><h1>Revenue &amp; Contribution</h1></div>{error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /></>}</div></main>;
  }

  const netSales = line(pnl, "NET_SALES");
  const contribution = data.contribution;
  const largest = strongest(data.grains, "total_variance");
  const volume = strongest(data.grains, "volume_effect", true);
  const spend = strongest(data.grains, "spend_effect", true);

  return (
    <main className="shell">
      <div className="panel wide analytics-page">
        <div className="row sb">
          <div className="page-head">
            <h1>Revenue &amp; Contribution</h1>
            <p>Separate activity-volume and average-spend movements before deciding why revenue changed.</p>
          </div>
          <div className="row"><Chip tone="mute">{data.period.label}</Chip>{data.run ? <Chip tone="ok">Calculated</Chip> : <Chip tone="warn">Not calculated</Chip>}</div>
        </div>

        <ReadinessStrip status={data.readiness.status} missingInputs={data.readiness.missing_inputs} explanation={data.readiness.explanation_code} />

        {!data.run ? (
          <EmptyState title="Revenue analysis is not ready">
            Complete the missing inputs shown above and run Revenue calculation. The application will not estimate missing drivers.
          </EmptyState>
        ) : (
          <>
            <div className="analytics-kpi-grid">
              <AnalyticsKpi label="Net Sales" actual={netSales?.actual} comparator={netSales?.comparator} variance={netSales?.variance} comparatorLabel="Comparator" />
              <div className="analytics-kpi"><div className="analytics-kpi-label">Contribution</div><div className="analytics-kpi-value">{resultText(contribution?.contribution)}</div><div className="analytics-kpi-comp">Directly attributable contribution</div><EvidenceChip status={contribution?.evidence_status} /></div>
              <div className="analytics-kpi"><div className="analytics-kpi-label">Contribution Margin</div><div className="analytics-kpi-value">{resultText(contribution?.contribution_margin_pct, "ratio")}</div><div className="analytics-kpi-comp">No shared overhead allocation</div></div>
              <div className="analytics-kpi"><div className="analytics-kpi-label">Contribution / Activity</div><div className="analytics-kpi-value">{resultText(contribution?.contribution_per_activity_unit)}</div><div className="analytics-kpi-comp">Only where activity denominator is supported</div></div>
            </div>

            <div className="analytics-primary-grid">
              <Card title="Volume effect by business view">
                <p className="muted analytics-card-intro">Favourable-positive revenue effect. Each bar is a persisted calculation result.</p>
                <EffectBars rows={sorted.map((g) => ({ label: g.business_view_key, value: calcNumber(g.volume_effect, "profit_effect") }))} />
              </Card>
              <Card title="Spend effect by business view">
                <p className="muted analytics-card-intro">Shows whether average-spend movement offset or compounded the activity movement.</p>
                <EffectBars rows={sorted.map((g) => ({ label: g.business_view_key, value: calcNumber(g.spend_effect, "profit_effect") }))} />
              </Card>
            </div>

            <div className="analytics-secondary-grid">
              <Card title="Management observations">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Largest revenue movement</strong><span>{largest ? `${largest.grain.business_view_key}: ${formatAmount(Math.abs(largest.value))} ${largest.value < 0 ? "adverse" : "favourable"}.` : "No supported variance."}</span></div>
                  <div className="analytics-observation"><strong>Largest adverse volume signal</strong><span>{volume ? `${volume.grain.business_view_key}: ${formatAmount(Math.abs(volume.value))} adverse volume effect.` : "No adverse supported volume effect."}</span></div>
                  <div className="analytics-observation"><strong>Largest adverse spend signal</strong><span>{spend ? `${spend.grain.business_view_key}: ${formatAmount(Math.abs(spend.value))} adverse spend effect.` : "No adverse supported spend effect."}</span></div>
                  <div className="analytics-observation"><strong>Interpretation guardrail</strong><span>Volume and spend locate the numerical movement. They do not establish its operational cause.</span></div>
                </div>
              </Card>
              <Card title="Contribution integrity">
                <div className="analytics-observations">
                  <div className="analytics-observation"><strong>Evidence</strong><span><EvidenceChip status={contribution?.evidence_status} /></span></div>
                  <div className="analytics-observation"><strong>Scope</strong><span>Net Sales less direct channel, product, direct labour and other direct operating costs.</span></div>
                  <div className="analytics-observation"><strong>Shared overhead</strong><span>Not allocated merely to manufacture contribution.</span></div>
                </div>
              </Card>
            </div>

            <Card title="Meal-period / business-view driver table">
              <div className="tw">
                <table className="tbl analysis-table">
                  <thead><tr><th>Business view</th><th>Activity basis</th><th className="n">Units</th><th className="n">Avg spend</th><th className="n">Revenue</th><th className="n">Volume effect</th><th className="n">Spend effect</th><th className="n">Total variance</th><th>Evidence</th></tr></thead>
                  <tbody>{sorted.map((grain) => (
                    <tr key={`${grain.business_view_type}:${grain.business_view_key}`}>
                      <th scope="row">{grain.business_view_key}<div className="muted">{grain.business_view_type.replaceAll("_", " ")}</div></th>
                      <td>{grain.activity_unit_type}</td>
                      <td className="n">{resultText(grain.activity_units, "plain")}</td>
                      <td className="n">{resultText(grain.avg_spend)}</td>
                      <td className="n">{resultText(grain.revenue)}</td>
                      <td className={`n ${(calcNumber(grain.volume_effect, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(grain.volume_effect, "currency", "profit_effect")}</td>
                      <td className={`n ${(calcNumber(grain.spend_effect, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(grain.spend_effect, "currency", "profit_effect")}</td>
                      <td className={`n ${(calcNumber(grain.total_variance, "profit_effect") ?? 0) < 0 ? "adverse" : "favourable"}`}>{resultText(grain.total_variance, "currency", "profit_effect")}</td>
                      <td><EvidenceChip status={grain.evidence_status} /></td>
                    </tr>
                  ))}</tbody>
                </table>
              </div>
            </Card>

            <Card title="Customer / source economics">
              {data.source_channels.length ? (
                <div className="tw"><table className="tbl analysis-table"><thead><tr><th>Source channel</th><th className="n">Activity</th><th className="n">Attributed revenue</th><th className="n">Direct channel cost</th><th className="n">Commission</th><th className="n">Promotion cost</th><th>Evidence</th></tr></thead>
                <tbody>{data.source_channels.map((row) => (
                  <tr key={row.fact_id}><th scope="row">{row.source_channel}</th><td className="n">{row.activity_units ?? "—"}</td><td className="n">{row.attributed_revenue ? formatAmount(row.attributed_revenue) : "—"}</td><td className="n">{row.direct_channel_cost ? formatAmount(row.direct_channel_cost) : "—"}</td><td className="n">{row.commission ? formatAmount(row.commission) : "—"}</td><td className="n">{row.promotion_cost ? formatAmount(row.promotion_cost) : "—"}</td><td><EvidenceChip status={row.source_evidence_status} /></td></tr>
                ))}</tbody></table></div>
              ) : <div className="analytics-empty">No customer/source facts are pinned to this run.</div>}
            </Card>
          </>
        )}

        <div className="row mt8"><Link className="btn" href={`/app/outlets/${outletId}/analysis?period=${data.period.id}`}>Back to Analysis Home</Link><Link className="btn p" href={`/app/outlets/${outletId}/reviews?period=${data.period.id}`}>Continue to review</Link></div>
      </div>
    </main>
  );
}
