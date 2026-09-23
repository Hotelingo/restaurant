"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { CalcResultRead, PLAnalysisResponse, PLLineRead } from "@/lib/contracts";
import { Card, Chip, Disclosure, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";

function formatAmount(value: string | null): string {
  if (value === null) return "";
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return value;
  return new Intl.NumberFormat(undefined, {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(parsed);
}

function comparatorLabel(value: string | null): string {
  if (value === "budget") return "Budget";
  if (value === "forecast") return "Latest Forecast";
  if (value === "prior_year") return "Prior Year";
  return "Comparator";
}

function ResultAmount({
  result,
  field = "value_numeric",
}: {
  result: CalcResultRead | null;
  field?: "value_numeric" | "raw_delta" | "profit_effect";
}) {
  if (!result || result.calculation_status !== "CALCULATED") {
    const code = result?.explanation_code ?? "NOT_AVAILABLE";
    return <Chip tone="warn">Not calculated · {code}</Chip>;
  }
  const value = result[field];
  if (value === null) return <Chip tone="warn">Not calculated</Chip>;
  // Only profit effect carries favourable/adverse meaning. Actuals, comparators
  // and raw deltas stay neutral: a cost line's positive raw delta is an adverse
  // overspend, so colouring by sign would show it as favourable.
  if (field !== "profit_effect") return <span>{formatAmount(value)}</span>;
  return <span className={Number(value) < 0 ? "amount-negative" : Number(value) > 0 ? "amount-positive" : ""}>{formatAmount(value)}</span>;
}

function kpiLine(lines: PLLineRead[], code: string): PLLineRead | null {
  return lines.find((line) => line.line_code === code) ?? null;
}

export default function PnlClient({
  outletId,
  periodId,
}: {
  outletId: string;
  periodId?: string;
}) {
  const [data, setData] = useState<PLAnalysisResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    const query = periodId ? `?period_id=${encodeURIComponent(periodId)}` : "";
    apiFetch<PLAnalysisResponse>(`/outlets/${outletId}/analysis/pnl${query}`)
      .then((value) => {
        setData(value);
        setError(null);
      })
      .catch((cause) => {
        setError(cause instanceof ApiError ? cause : new ApiError("Unable to load Management P&L.", 500, null));
      });
  }, [outletId, periodId]);

  const kpis = useMemo(() => {
    if (!data) return [];
    return [
      kpiLine(data.lines, "NET_SALES"),
      kpiLine(data.lines, "PRODUCT_MARGIN"),
      kpiLine(data.lines, "CONTRIBUTION"),
      kpiLine(data.lines, "OPERATING_PROFIT"),
    ].filter((line): line is PLLineRead => line !== null);
  }, [data]);

  if (error?.status === 404) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head">
            <h1>Management P&amp;L</h1>
            <p>No completed calculation snapshot is available yet.</p>
          </div>
          <EmptyState title="Management P&L is not ready">
            Commit the actual P&amp;L and budget in Data Centre, then press Calculate.
          </EmptyState>
          <div className="row mt8">
            <Link className="btn p" href={`/app/outlets/${outletId}/data`}>Open Data Centre</Link>
          </div>
        </div>
      </main>
    );
  }

  if (!data) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head"><h1>Management P&amp;L</h1></div>
          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /><Skeleton /></>}
        </div>
      </main>
    );
  }

  const comparator = comparatorLabel(data.run.comparator_scenario);
  const sequence = data.first_material_movement;
  const sequenceLine = sequence?.value_text && sequence.value_text !== "NO_MATERIAL_MOVEMENT"
    ? data.lines.find((line) => line.line_code === sequence.value_text)
    : null;
  const sequenceImpact = typeof sequence?.result_metadata?.impact === "string"
    ? sequence.result_metadata.impact
    : null;
  const sequenceReason = typeof sequence?.result_metadata?.materiality_reason === "string"
    ? sequence.result_metadata.materiality_reason
    : null;

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="row sb">
          <div className="page-head">
            <h1>Management P&amp;L</h1>
            <p>Which level moved first, and by how much?</p>
          </div>
          <div className="row">
            <Chip tone="mute">{data.period.label}</Chip>
            <Chip tone="info">vs {comparator}</Chip>
            <Chip tone="mute">{data.currency_code}</Chip>
          </div>
        </div>

        <div className="banner info">
          <strong>One comparator, one sign convention.</strong> Variance profit effects are favourable when positive and adverse when negative. Raw delta is shown separately so cost-line sign reversal stays explicit.
        </div>

        {sequence?.calculation_status === "CALCULATED" ? (
          sequence.value_text === "NO_MATERIAL_MOVEMENT" ? (
            <div className="banner info"><strong>SEQUENCE:</strong> No material movement was identified under the frozen run thresholds.</div>
          ) : (
            <div className="banner">
              <strong>First material movement:</strong> {sequenceLine?.label ?? sequence.value_text}
              {sequenceImpact ? <> · profit effect {formatAmount(sequenceImpact)}</> : null}
              {sequenceReason ? <> · rule <span className="mono">{sequenceReason}</span></> : null}.
              This locates the first economic movement; it does not state an operating cause.
            </div>
          )
        ) : (
          <div className="banner info">
            <strong>SEQUENCE not calculated.</strong> {sequence?.explanation_code ?? "Materiality/comparator evidence is incomplete."}
            {sequence?.explanation_code === "MATERIALITY_UNSET" ? (
              <> Set materiality thresholds in{" "}
                <Link href={`/app/outlets/${outletId}/settings`}>Settings</Link>, then recalculate in{" "}
                <Link href={`/app/outlets/${outletId}/data?period=${data.period.id}`}>Data Centre</Link>.</>
            ) : null}
          </div>
        )}

        <div className="metric-grid">
          {kpis.map((line) => (
            <div className="metric-card" key={line.line_code}>
              <div className="metric-label">{line.label}</div>
              <div className="metric-value"><ResultAmount result={line.actual} /></div>
              <div className="metric-sub">Profit effect: <ResultAmount result={line.variance} field="profit_effect" /></div>
            </div>
          ))}
        </div>

        <Card title="Management P&L · all eleven lines">
          <div className="tw">
            <table className="tbl analysis-table">
              <caption>Actual, comparator, raw movement and profit effect from immutable calculation run {data.run.id}</caption>
              <thead>
                <tr>
                  <th scope="col">Line</th>
                  <th scope="col" className="n">Actual</th>
                  <th scope="col" className="n">{comparator}</th>
                  <th scope="col" className="n">Raw delta</th>
                  <th scope="col" className="n">Profit effect</th>
                  <th scope="col">Calculation state</th>
                </tr>
              </thead>
              <tbody>
                {data.lines.map((line) => (
                  <tr key={line.line_code} className={line.is_calculated ? "derived-row" : undefined}>
                    <th scope="row">{line.label}</th>
                    <td className="n"><ResultAmount result={line.actual} /></td>
                    <td className="n"><ResultAmount result={line.comparator} /></td>
                    <td className="n"><ResultAmount result={line.variance} field="raw_delta" /></td>
                    <td className="n"><ResultAmount result={line.variance} field="profit_effect" /></td>
                    <td>
                      {line.variance?.calculation_status === "CALCULATED"
                        ? <Chip tone="ok">Calculated</Chip>
                        : <Chip tone="warn">Not calculated · {line.variance?.explanation_code ?? "NO_RESULT"}</Chip>}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>

        <Card title="Traceability">
          <p className="muted">Every displayed figure belongs to one immutable calculation snapshot and traces back to the committed source batches below.</p>
          <Disclosure summary="Calculation run and source lineage">
            <div className="trace-grid">
              <span>Run</span><code>{data.run.id}</code>
              <span>Engine</span><code>{data.run.engine_version}</code>
              <span>Result hash</span><code>{data.run.result_hash ?? "—"}</code>
              {data.run.inputs.map((input) => (
                <div className="trace-item" key={input.batch_id}>
                  <strong>{input.input_role}</strong> · {input.scenario} · {input.original_filename}
                  <div className="mono">batch {input.batch_id}</div>
                  <div className="mono">source SHA-256 {input.source_sha256}</div>
                  <div className="mono">canonical commit {input.canonical_commit_hash}</div>
                </div>
              ))}
            </div>
          </Disclosure>
        </Card>

        <div className="row mt8">
          <Link className="btn p" href={`/app/outlets/${outletId}/reviews?period=${data.period.id}`}>
            Review this period
          </Link>
          <Link className="btn" href={`/app/outlets/${outletId}/analysis/reconciliation?period=${data.period.id}`}>
            Open reconciliation
          </Link>
        </div>
      </div>
    </main>
  );
}
