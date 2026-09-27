"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { PLAnalysisResponse, PLLineRead, PLRatioRead, PLTrendResponse } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { formatAmount } from "@/lib/format";
import { AnalyticsKpi, ProfitBridge, TrendChart, VarianceRanking } from "@/components/analytics/AnalyticsCharts";

function lineByCode(lines: PLLineRead[], code: string): PLLineRead | null {
  return lines.find((line) => line.line_code === code) ?? null;
}

function ratioByCode(ratios: PLRatioRead[], code: string): PLRatioRead | null {
  return ratios.find((ratio) => ratio.metric_code === code) ?? null;
}

function comparatorLabel(value: string | null): string {
  if (value === "budget") return "Budget";
  if (value === "forecast") return "Latest Forecast";
  if (value === "prior_year") return "Prior Year";
  return "Comparator";
}

function effect(line: PLLineRead | null): number | null {
  if (!line?.variance || line.variance.calculation_status !== "CALCULATED" || line.variance.profit_effect === null) return null;
  const value = Number(line.variance.profit_effect);
  return Number.isFinite(value) ? value : null;
}

const OP_SOURCE_CODES = [
  "NET_SALES",
  "PRODUCT_COST",
  "CHANNEL_COST",
  "DIRECT_LABOUR",
  "OTHER_DIRECT_OPERATING",
  "SHARED_RESTAURANT_COST",
];

export default function AnalyticsHomeClient({ outletId, periodId }: { outletId: string; periodId?: string }) {
  const [data, setData] = useState<PLAnalysisResponse | null>(null);
  const [trends, setTrends] = useState<PLTrendResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;
    const query = periodId ? `?period_id=${encodeURIComponent(periodId)}` : "";
    Promise.all([
      apiFetch<PLAnalysisResponse>(`/outlets/${outletId}/analysis/pnl${query}`),
      apiFetch<PLTrendResponse>(`/outlets/${outletId}/analysis/trends?periods=6`).catch(() => null),
    ])
      .then(([pnl, trend]) => {
        if (cancelled) return;
        setData(pnl);
        setTrends(trend);
        setError(null);
      })
      .catch((cause) => {
        if (!cancelled) {
          setError(cause instanceof ApiError ? cause : new ApiError("Unable to load analysis.", 500, null));
        }
      });
    return () => { cancelled = true; };
  }, [outletId, periodId]);

  const supporting = useMemo(() => {
    if (!data) return [];
    return data.lines.filter((line) => OP_SOURCE_CODES.includes(line.line_code));
  }, [data]);

  if (error?.status === 404) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head"><h1>Analysis Home</h1><p>Visual decision support begins after the Management P&amp;L is calculated.</p></div>
          <EmptyState title="Analysis is not ready">
            Commit actual and comparator data, then run the Management P&amp;L calculation.
          </EmptyState>
          <div className="row mt8"><Link className="btn p" href={`/app/outlets/${outletId}/data`}>Open Data Centre</Link></div>
        </div>
      </main>
    );
  }

  if (!data) {
    return (
      <main className="shell"><div className="panel wide">
        <div className="page-head"><h1>Analysis Home</h1></div>
        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /><Skeleton /></>}
      </div></main>
    );
  }

  const comparator = comparatorLabel(data.run.comparator_scenario);
  const netSales = lineByCode(data.lines, "NET_SALES");
  const contribution = lineByCode(data.lines, "CONTRIBUTION");
  const op = lineByCode(data.lines, "OPERATING_PROFIT");
  const ratios = data.ratios ?? [];
  const productCostPct = ratioByCode(ratios, "PRODUCT_COST_PCT");
  const labourPct = ratioByCode(ratios, "LABOUR_PCT");
  const opPct = ratioByCode(ratios, "OPERATING_PROFIT_PCT");
  const opTrend = trends?.series.find((series) => series.metric_code === "OPERATING_PROFIT_PCT") ?? null;
  const first = data.first_material_movement;
  const firstLine = first?.value_text && first.value_text !== "NO_MATERIAL_MOVEMENT"
    ? lineByCode(data.lines, first.value_text)
    : null;

  const ranked = [...supporting]
    .map((line) => ({ line, impact: effect(line) }))
    .filter((row): row is { line: PLLineRead; impact: number } => row.impact !== null)
    .sort((a, b) => Math.abs(b.impact) - Math.abs(a.impact));
  const largest = ranked[0] ?? null;
  const opImpact = effect(op);

  return (
    <main className="shell">
      <div className="panel wide analytics-page">
        <div className="row sb">
          <div className="page-head">
            <h1>Analysis Home</h1>
            <p>Understand performance, locate the major movements and open the supporting evidence before deciding what to do.</p>
          </div>
          <div className="row">
            <Chip tone="mute">{data.period.label}</Chip>
            <Chip tone="info">vs {comparator}</Chip>
            <Chip tone="ok">Calculated</Chip>
          </div>
        </div>

        <div className="analytics-kpi-grid">
          <AnalyticsKpi label="Net Sales" actual={netSales?.actual} comparator={netSales?.comparator} variance={netSales?.variance} comparatorLabel={comparator} />
          <AnalyticsKpi label="Product Cost %" actual={productCostPct?.actual} comparator={productCostPct?.comparator} variance={productCostPct?.variance} unit="ratio" comparatorLabel={comparator} />
          <AnalyticsKpi label="Labour %" actual={labourPct?.actual} comparator={labourPct?.comparator} variance={labourPct?.variance} unit="ratio" comparatorLabel={comparator} />
          <AnalyticsKpi label="Contribution" actual={contribution?.actual} comparator={contribution?.comparator} variance={contribution?.variance} comparatorLabel={comparator} />
          <AnalyticsKpi label="Operating Profit" actual={op?.actual} comparator={op?.comparator} variance={op?.variance} comparatorLabel={comparator} />
          <AnalyticsKpi label="Operating Profit %" actual={opPct?.actual} comparator={opPct?.comparator} variance={opPct?.variance} unit="ratio" comparatorLabel={comparator} />
        </div>

        {ratios.length === 0 || ratios.every((ratio) => ratio.actual === null) ? (
          <div className="banner info">
            <strong>Ratio metrics need one recalculation.</strong> This period was calculated before the visual-analytics ratio contract existed. Recalculate the P&amp;L after the AX-1 migration/worker deployment; historical monetary results remain unchanged.
          </div>
        ) : null}

        <div className="analytics-primary-grid">
          <Card title="Operating Profit bridge · comparator to actual">
            <p className="muted analytics-card-intro">Only direct Operating Profit drivers are included, avoiding double counting of derived subtotals.</p>
            <ProfitBridge
              startLabel={comparator}
              start={op?.comparator}
              endLabel="Actual"
              end={op?.actual}
              legs={supporting.map((line) => ({ label: line.label, result: line.variance }))}
            />
          </Card>
          <Card title="Top movements by profit impact">
            <p className="muted analytics-card-intro">Source P&amp;L lines ranked by the immutable favourable/adverse profit-effect result.</p>
            <VarianceRanking lines={supporting} />
          </Card>
        </div>

        <div className="analytics-secondary-grid">
          <Card title="Performance trend · Operating Profit %">
            <TrendChart series={opTrend} />
          </Card>
          <Card title="Automated observations">
            <div className="analytics-observations">
              <div className="analytics-observation">
                <strong>Operating Profit</strong>
                <span>{opImpact === null ? "Not calculated." : `${formatAmount(Math.abs(opImpact))} ${opImpact < 0 ? "adverse" : opImpact > 0 ? "favourable" : "on comparator"} versus ${comparator}.`}</span>
              </div>
              <div className="analytics-observation">
                <strong>Largest source-line movement</strong>
                <span>{largest ? `${largest.line.label}: ${formatAmount(Math.abs(largest.impact))} ${largest.impact < 0 ? "adverse" : "favourable"} profit impact.` : "No calculated source-line movement."}</span>
              </div>
              <div className="analytics-observation">
                <strong>SEQUENCE</strong>
                <span>{firstLine ? `${firstLine.label} is the first material movement under the frozen review thresholds. This locates the movement; it does not infer a cause.` : first?.value_text === "NO_MATERIAL_MOVEMENT" ? "No material movement under the frozen thresholds." : first?.explanation_code ?? "Materiality not calculated."}</span>
              </div>
            </div>
          </Card>
        </div>

        <div className="analytics-module-grid">
          <Link className="analytics-module-card" href={`/app/outlets/${outletId}/analysis/pnl?period=${data.period.id}`}>
            <span>Revenue &amp; Contribution</span><strong>{netSales?.variance?.profit_effect ? formatAmount(netSales.variance.profit_effect) : "—"}</strong><small>Net Sales profit effect · detailed driver page follows AX-3</small>
          </Link>
          <Link className="analytics-module-card" href={`/app/outlets/${outletId}/analysis/pnl?period=${data.period.id}`}>
            <span>Food &amp; Beverage Cost</span><strong>{lineByCode(data.lines, "PRODUCT_COST")?.variance?.profit_effect ? formatAmount(lineByCode(data.lines, "PRODUCT_COST")!.variance!.profit_effect) : "—"}</strong><small>P&amp;L Product Cost effect · detailed food-cost bridge follows AX-3</small>
          </Link>
          <Link className="analytics-module-card" href={`/app/outlets/${outletId}/analysis/pnl?period=${data.period.id}`}>
            <span>Labour &amp; Productivity</span><strong>{lineByCode(data.lines, "DIRECT_LABOUR")?.variance?.profit_effect ? formatAmount(lineByCode(data.lines, "DIRECT_LABOUR")!.variance!.profit_effect) : "—"}</strong><small>P&amp;L Direct Labour effect · role-group bridge follows AX-3</small>
          </Link>
          <Link className="analytics-module-card" href={`/app/outlets/${outletId}/analysis/reconciliation?period=${data.period.id}`}>
            <span>Reconciliation</span><strong>Control view</strong><small>Confirm the management view ties to committed accounting evidence.</small>
          </Link>
        </div>

        <Card title="Material P&L movements">
          <div className="tw">
            <table className="tbl analysis-table analytics-movement-table">
              <thead><tr><th>Line</th><th className="n">Actual</th><th className="n">{comparator}</th><th className="n">Raw delta</th><th className="n">Profit impact</th><th>Review signal</th></tr></thead>
              <tbody>
                {supporting.map((line) => {
                  const isFirst = firstLine?.line_code === line.line_code;
                  return (
                    <tr key={line.line_code}>
                      <th scope="row">{line.label}</th>
                      <td className="n">{line.actual?.value_numeric ? formatAmount(line.actual.value_numeric) : "—"}</td>
                      <td className="n">{line.comparator?.value_numeric ? formatAmount(line.comparator.value_numeric) : "—"}</td>
                      <td className="n">{line.variance?.raw_delta ? formatAmount(line.variance.raw_delta) : "—"}</td>
                      <td className={`n ${Number(line.variance?.profit_effect ?? 0) < 0 ? "adverse" : Number(line.variance?.profit_effect ?? 0) > 0 ? "favourable" : ""}`}>{line.variance?.profit_effect ? formatAmount(line.variance.profit_effect) : "—"}</td>
                      <td>{isFirst ? <Chip tone="warn">First material movement</Chip> : <Chip tone="mute">Available for review</Chip>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </Card>

        <div className="row mt8">
          <Link className="btn p" href={`/app/outlets/${outletId}/analysis/pnl?period=${data.period.id}`}>Open Management P&amp;L</Link>
          <Link className="btn" href={`/app/outlets/${outletId}/reviews?period=${data.period.id}`}>Continue to review</Link>
        </div>
      </div>
    </main>
  );
}
