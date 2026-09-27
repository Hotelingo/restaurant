"use client";

import type { CalcResultRead, PLLineRead, PLTrendSeriesRead } from "@/lib/contracts";
import { formatAmount, formatPercent } from "@/lib/format";

function valueOf(result: CalcResultRead | null | undefined, field: "value_numeric" | "raw_delta" | "profit_effect" = "value_numeric"): number | null {
  if (!result || result.calculation_status !== "CALCULATED") return null;
  const raw = result[field];
  if (raw === null) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

function signed(value: number, currency = false): string {
  const body = currency ? formatAmount(Math.abs(value)) : String(Math.abs(value));
  return `${value > 0 ? "+" : value < 0 ? "−" : ""}${body}`;
}

function toneFromVariance(result: CalcResultRead | null | undefined): "good" | "bad" | "neutral" {
  const effect = valueOf(result, "profit_effect");
  if (effect === null || effect === 0) return "neutral";
  return effect > 0 ? "good" : "bad";
}

export function AnalyticsKpi({
  label,
  actual,
  comparator,
  variance,
  unit = "currency",
  comparatorLabel = "Comparator",
}: {
  label: string;
  actual: CalcResultRead | null | undefined;
  comparator: CalcResultRead | null | undefined;
  variance: CalcResultRead | null | undefined;
  unit?: "currency" | "ratio";
  comparatorLabel?: string;
}) {
  const actualValue = valueOf(actual);
  const comparatorValue = valueOf(comparator);
  const raw = valueOf(variance, "raw_delta");
  const tone = toneFromVariance(variance);
  const display = (v: number | null) => v === null ? "—" : unit === "ratio" ? formatPercent(v) : formatAmount(v);
  const delta = raw === null ? "Not calculated" : unit === "ratio"
    ? `${raw > 0 ? "+" : raw < 0 ? "−" : ""}${Math.abs(raw * 100).toFixed(1)} pp`
    : signed(raw, true);

  return (
    <div className="analytics-kpi">
      <div className="analytics-kpi-label">{label}</div>
      <div className="analytics-kpi-value">{display(actualValue)}</div>
      <div className="analytics-kpi-comp">{comparatorLabel} {display(comparatorValue)}</div>
      <div className={`analytics-kpi-delta ${tone}`}>{delta}</div>
    </div>
  );
}

export type BridgeLeg = {
  label: string;
  result: CalcResultRead | null | undefined;
};

export function ProfitBridge({
  startLabel,
  start,
  endLabel,
  end,
  legs,
}: {
  startLabel: string;
  start: CalcResultRead | null | undefined;
  endLabel: string;
  end: CalcResultRead | null | undefined;
  legs: BridgeLeg[];
}) {
  const startValue = valueOf(start);
  const endValue = valueOf(end);
  const usableLegs = legs
    .map((leg) => ({ ...leg, value: valueOf(leg.result, "profit_effect") }))
    .filter((leg): leg is BridgeLeg & { value: number } => leg.value !== null);

  if (startValue === null || endValue === null || usableLegs.length === 0) {
    return <div className="analytics-empty">Bridge not calculated for this period.</div>;
  }

  let running = startValue;
  const states: { from: number; to: number; label: string; value: number }[] = [];
  for (const leg of usableLegs) {
    const next = running + leg.value;
    states.push({ from: running, to: next, label: leg.label, value: leg.value });
    running = next;
  }
  const values = [startValue, endValue, ...states.flatMap((x) => [x.from, x.to]), 0];
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const width = 900;
  const height = 250;
  const padTop = 22;
  const padBottom = 48;
  const plotH = height - padTop - padBottom;
  const y = (v: number) => padTop + ((max - v) / span) * plotH;
  const columns = states.length + 2;
  const step = (width - 70) / columns;
  const barW = Math.min(72, step * 0.58);
  const xAt = (i: number) => 35 + i * step + (step - barW) / 2;

  const baseline = y(0);
  return (
    <div className="analytics-chart-scroll">
      <svg className="waterfall-svg" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Operating profit waterfall">
        <line x1="28" x2={width - 20} y1={baseline} y2={baseline} className="wf-axis" />
        <rect x={xAt(0)} y={Math.min(y(startValue), baseline)} width={barW} height={Math.max(2, Math.abs(baseline - y(startValue)))} className="wf-total start" />
        <text x={xAt(0) + barW / 2} y={Math.min(y(startValue), baseline) - 6} textAnchor="middle" className="wf-value">{formatAmount(startValue)}</text>
        <text x={xAt(0) + barW / 2} y={height - 18} textAnchor="middle" className="wf-label">{startLabel}</text>
        {states.map((leg, index) => {
          const x = xAt(index + 1);
          const top = Math.min(y(leg.from), y(leg.to));
          const h = Math.max(2, Math.abs(y(leg.from) - y(leg.to)));
          const cls = leg.value >= 0 ? "wf-change good" : "wf-change bad";
          return (
            <g key={leg.label}>
              <line x1={x - (step - barW) / 2} x2={x} y1={y(leg.from)} y2={y(leg.from)} className="wf-connector" />
              <rect x={x} y={top} width={barW} height={h} className={cls} />
              <text x={x + barW / 2} y={top - 6} textAnchor="middle" className="wf-value">{signed(leg.value, true)}</text>
              <text x={x + barW / 2} y={height - 18} textAnchor="middle" className="wf-label">{leg.label}</text>
            </g>
          );
        })}
        <rect x={xAt(columns - 1)} y={Math.min(y(endValue), baseline)} width={barW} height={Math.max(2, Math.abs(baseline - y(endValue)))} className="wf-total end" />
        <text x={xAt(columns - 1) + barW / 2} y={Math.min(y(endValue), baseline) - 6} textAnchor="middle" className="wf-value">{formatAmount(endValue)}</text>
        <text x={xAt(columns - 1) + barW / 2} y={height - 18} textAnchor="middle" className="wf-label">{endLabel}</text>
      </svg>
    </div>
  );
}

export function VarianceRanking({
  lines,
  limit = 6,
}: {
  lines: PLLineRead[];
  limit?: number;
}) {
  const rows = lines
    .filter((line) => !line.is_calculated)
    .map((line) => ({ line, value: valueOf(line.variance, "profit_effect") }))
    .filter((row): row is { line: PLLineRead; value: number } => row.value !== null)
    .sort((a, b) => Math.abs(b.value) - Math.abs(a.value))
    .slice(0, limit);
  const max = Math.max(1, ...rows.map((row) => Math.abs(row.value)));

  if (!rows.length) return <div className="analytics-empty">No calculated movements.</div>;

  return (
    <div className="variance-ranking">
      {rows.map(({ line, value }) => (
        <div className="variance-rank-row" key={line.line_code}>
          <span className="variance-rank-label">{line.label}</span>
          <div className="variance-rank-track" aria-hidden="true">
            <div className={`variance-rank-fill ${value >= 0 ? "good" : "bad"}`} style={{ width: `${Math.max(4, Math.abs(value) / max * 100)}%` }} />
          </div>
          <strong className={value > 0 ? "favourable" : value < 0 ? "adverse" : ""}>{signed(value, true)}</strong>
        </div>
      ))}
    </div>
  );
}

export function TrendChart({ series }: { series: PLTrendSeriesRead | null | undefined }) {
  const points = series?.points ?? [];
  const actual = points.map((p) => valueOf(p.actual));
  const comparator = points.map((p) => valueOf(p.comparator));
  const values = [...actual, ...comparator].filter((v): v is number => v !== null);
  if (!series || points.length < 2 || values.length < 2) {
    return <div className="analytics-empty">Add more reporting periods to unlock the trend view.</div>;
  }
  const width = 620;
  const height = 210;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const pad = Math.max((max - min) * 0.15, series.unit === "ratio" ? 0.01 : 1);
  const low = min - pad;
  const high = max + pad;
  const span = high - low || 1;
  const x = (i: number) => 28 + (i * (width - 56)) / Math.max(1, points.length - 1);
  const y = (v: number) => 18 + ((high - v) / span) * (height - 54);
  const path = (valuesIn: (number | null)[]) => valuesIn.map((v, i) => v === null ? null : `${x(i)},${y(v)}`).filter(Boolean).join(" ");

  return (
    <div>
      <svg className="trend-svg" viewBox={`0 0 ${width} ${height}`} role="img" aria-label={`${series.label} trend`}>
        <line x1="28" x2={width - 28} y1={height - 36} y2={height - 36} className="trend-axis" />
        <polyline points={path(comparator)} className="trend-line comparator" fill="none" />
        <polyline points={path(actual)} className="trend-line actual" fill="none" />
        {actual.map((v, i) => v === null ? null : <circle key={`a-${i}`} cx={x(i)} cy={y(v)} r="4" className="trend-dot actual" />)}
        {points.map((point, i) => <text key={point.period.id} x={x(i)} y={height - 14} textAnchor="middle" className="trend-label">{point.period.label}</text>)}
      </svg>
      <div className="analytics-legend"><span><i className="legend-dot actual" />Actual</span><span><i className="legend-dot comparator" />Comparator</span></div>
    </div>
  );
}
