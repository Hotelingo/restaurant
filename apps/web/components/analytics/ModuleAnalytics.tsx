"use client";

import type { CalcResultRead } from "@/lib/contracts";
import { Chip } from "@/components/ui";
import { formatAmount, formatPercent } from "@/lib/format";

export function calcNumber(result: CalcResultRead | null | undefined, field: "value_numeric" | "raw_delta" | "profit_effect" = "value_numeric"): number | null {
  if (!result || result.calculation_status !== "CALCULATED") return null;
  const raw = result[field];
  if (raw === null) return null;
  const n = Number(raw);
  return Number.isFinite(n) ? n : null;
}

export function resultText(
  result: CalcResultRead | null | undefined,
  unit: "currency" | "ratio" | "plain" = "currency",
  field: "value_numeric" | "raw_delta" | "profit_effect" = "value_numeric",
): string {
  const n = calcNumber(result, field);
  if (n === null) return "—";
  if (unit === "ratio") return formatPercent(n);
  if (unit === "plain") return String(n);
  return formatAmount(n);
}

export function EvidenceChip({ status }: { status: string | null | undefined }) {
  const normalized = (status ?? "evidence_required").toLowerCase();
  if (normalized.includes("validated")) return <Chip tone="ok">Validated</Chip>;
  if (normalized.includes("supported")) return <Chip tone="info">{normalized.includes("total_only") ? "Total only" : "Supported"}</Chip>;
  if (normalized.includes("not_reconciled")) return <Chip tone="bad">Not reconciled</Chip>;
  return <Chip tone="warn">Evidence required</Chip>;
}

export function ReadinessStrip({
  status,
  missingInputs,
  explanation,
}: {
  status: string;
  missingInputs: string[];
  explanation: string | null;
}) {
  const normalized = status.toLowerCase();
  const tone = normalized === "ready" ? "ok" : normalized === "blocked" || normalized === "not_reconciled" ? "bad" : "warn";
  return (
    <div className="module-readiness-strip">
      <Chip tone={tone}>Readiness: {status.replaceAll("_", " ")}</Chip>
      {missingInputs.length ? <span>Missing: {missingInputs.join(", ")}</span> : <span>Inputs available.</span>}
      {explanation ? <span className="muted">{explanation.replaceAll("_", " ")}</span> : null}
    </div>
  );
}

export type EffectBar = {
  label: string;
  value: number | null;
};

export function EffectBars({
  rows,
  currency = true,
  emptyMessage = "No calculated driver effects.",
}: {
  rows: EffectBar[];
  currency?: boolean;
  emptyMessage?: string;
}) {
  const usable = rows.filter((row): row is { label: string; value: number } => row.value !== null);
  if (!usable.length) return <div className="analytics-empty">{emptyMessage}</div>;
  const max = Math.max(1, ...usable.map((row) => Math.abs(row.value)));
  return (
    <div className="module-effect-bars">
      {usable.map((row) => (
        <div className="module-effect-row" key={row.label}>
          <span>{row.label}</span>
          <div className="module-effect-track">
            <div
              className={`module-effect-fill ${row.value >= 0 ? "good" : "bad"}`}
              style={{ width: `${Math.max(4, Math.abs(row.value) / max * 100)}%` }}
            />
          </div>
          <strong className={row.value > 0 ? "favourable" : row.value < 0 ? "adverse" : ""}>
            {row.value > 0 ? "+" : row.value < 0 ? "−" : ""}
            {currency ? formatAmount(Math.abs(row.value)) : Math.abs(row.value).toFixed(1)}
          </strong>
        </div>
      ))}
    </div>
  );
}

export function FoodCostBridge({
  budget,
  menuMix,
  expected,
  operatingGap,
  actual,
}: {
  budget: CalcResultRead | null;
  menuMix: CalcResultRead | null;
  expected: CalcResultRead | null;
  operatingGap: CalcResultRead | null;
  actual: CalcResultRead | null;
}) {
  const budgetValue = calcNumber(budget);
  const menuMixValue = calcNumber(menuMix);
  const expectedValue = calcNumber(expected);
  const operatingGapValue = calcNumber(operatingGap);
  const actualValue = calcNumber(actual);

  if ([budgetValue, menuMixValue, expectedValue, operatingGapValue, actualValue].some((v) => v === null)) {
    return <div className="analytics-empty">The full Food Cost bridge is not calculated for this product group.</div>;
  }

  const vals = [budgetValue!, expectedValue!, actualValue!, 0];
  const max = Math.max(...vals);
  const min = Math.min(...vals);
  const span = max - min || 1;
  const height = 230;
  const width = 760;
  const padTop = 22;
  const padBottom = 48;
  const plotH = height - padTop - padBottom;
  const y = (v: number) => padTop + ((max - v) / span) * plotH;
  const base = y(0);
  const xs = [55, 200, 345, 490, 635];
  const bw = 72;

  const changeRect = (from: number, to: number, x: number, cls: string, label: string, value: number) => {
    const top = Math.min(y(from), y(to));
    const h = Math.max(2, Math.abs(y(from) - y(to)));
    return (
      <g key={label}>
        <rect x={x} y={top} width={bw} height={h} className={cls} />
        <text x={x + bw / 2} y={top - 6} textAnchor="middle" className="wf-value">{value >= 0 ? "+" : "−"}{formatAmount(Math.abs(value))}</text>
        <text x={x + bw / 2} y={height - 18} textAnchor="middle" className="wf-label">{label}</text>
      </g>
    );
  };

  return (
    <div className="analytics-chart-scroll">
      <svg className="waterfall-svg" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Food Cost budget to expected to actual bridge">
        <line x1="30" x2={width - 25} y1={base} y2={base} className="wf-axis" />
        <rect x={xs[0]} y={Math.min(y(budgetValue!), base)} width={bw} height={Math.max(2, Math.abs(base - y(budgetValue!)))} className="wf-total start" />
        <text x={xs[0] + bw / 2} y={Math.min(y(budgetValue!), base) - 6} textAnchor="middle" className="wf-value">{formatAmount(budgetValue!)}</text>
        <text x={xs[0] + bw / 2} y={height - 18} textAnchor="middle" className="wf-label">Budget</text>
        {changeRect(budgetValue!, expectedValue!, xs[1], menuMixValue! >= 0 ? "wf-change bad" : "wf-change good", "Menu mix", menuMixValue!)}
        <rect x={xs[2]} y={Math.min(y(expectedValue!), base)} width={bw} height={Math.max(2, Math.abs(base - y(expectedValue!)))} className="wf-total end" />
        <text x={xs[2] + bw / 2} y={Math.min(y(expectedValue!), base) - 6} textAnchor="middle" className="wf-value">{formatAmount(expectedValue!)}</text>
        <text x={xs[2] + bw / 2} y={height - 18} textAnchor="middle" className="wf-label">Expected</text>
        {changeRect(expectedValue!, actualValue!, xs[3], operatingGapValue! >= 0 ? "wf-change bad" : "wf-change good", "Operating gap", operatingGapValue!)}
        <rect x={xs[4]} y={Math.min(y(actualValue!), base)} width={bw} height={Math.max(2, Math.abs(base - y(actualValue!)))} className="wf-total end" />
        <text x={xs[4] + bw / 2} y={Math.min(y(actualValue!), base) - 6} textAnchor="middle" className="wf-value">{formatAmount(actualValue!)}</text>
        <text x={xs[4] + bw / 2} y={height - 18} textAnchor="middle" className="wf-label">Actual</text>
      </svg>
    </div>
  );
}
