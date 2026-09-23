"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { PLAnalysisResponse, ReconciliationResponse } from "@/lib/contracts";
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

async function resolvePeriod(outletId: string, periodId?: string): Promise<string> {
  if (periodId) return periodId;
  const pnl = await apiFetch<PLAnalysisResponse>(`/outlets/${outletId}/analysis/pnl`);
  return pnl.period.id;
}

export default function ReconciliationClient({
  outletId,
  periodId,
}: {
  outletId: string;
  periodId?: string;
}) {
  const [data, setData] = useState<ReconciliationResponse | null>(null);
  const [resolvedPeriod, setResolvedPeriod] = useState<string | null>(periodId ?? null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;

    resolvePeriod(outletId, periodId)
      .then(async (period) => {
        if (cancelled) return;
        setResolvedPeriod(period);
        const response = await apiFetch<ReconciliationResponse>(`/periods/${period}/reconciliation`);
        if (!cancelled) {
          setData(response);
          setError(null);
        }
      })
      .catch((cause) => {
        if (!cancelled) {
          setError(cause instanceof ApiError ? cause : new ApiError("Unable to load reconciliation.", 500, null));
        }
      });

    return () => {
      cancelled = true;
    };
  }, [outletId, periodId]);

  if (error?.status === 404) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head">
            <h1>Reconciliation</h1>
            <p>No completed calculation snapshot is available for reconciliation yet.</p>
          </div>
          <EmptyState title="Reconciliation is not ready">
            Commit and calculate the Management P&amp;L first.
          </EmptyState>
          <div className="row mt8">
            <Link className="btn" href={`/app/outlets/${outletId}/analysis/pnl`}>Back to Management P&amp;L</Link>
          </div>
        </div>
      </main>
    );
  }

  if (!data) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head"><h1>Reconciliation</h1></div>
          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : <><Skeleton /><Skeleton /><Skeleton /></>}
        </div>
      </main>
    );
  }

  const reconciled = data.status === "reconciled";

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="row sb">
          <div className="page-head">
            <h1>Reconciliation</h1>
            <p>Does the Management P&amp;L tie to the committed accounting statement?</p>
          </div>
          <div className="row">
            <Chip tone="mute">{data.period.label}</Chip>
            <Chip tone={reconciled ? "ok" : "bad"}>{reconciled ? "Reconciled" : "Not reconciled"}</Chip>
          </div>
        </div>

        <div className={`banner ${reconciled ? "ok" : "bad"}`}>
          <strong>{reconciled ? "Reconciled." : "Not reconciled."}</strong>{" "}
          {reconciled
            ? "Every committed source ladder line agrees with the immutable Management P&L result for this run."
            : "At least one committed source ladder line does not tie. The pack must not describe this period as reconciled."}
        </div>

        <Card title="Line-by-line tie-out">
          <div className="tw">
            <table className="tbl analysis-table">
              <caption>Committed accounting P&amp;L batch compared with Management P&amp;L source-line results</caption>
              <thead>
                <tr>
                  <th scope="col">Ladder line</th>
                  <th scope="col">Statement accounts</th>
                  <th scope="col" className="n">Management view</th>
                  <th scope="col" className="n">Accounting statement</th>
                  <th scope="col" className="n">Difference</th>
                  <th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {data.lines.map((line) => (
                  <tr key={line.line_code}>
                    <th scope="row">{line.label}</th>
                    <td className="mono">{line.statement_accounts.join(", ") || "—"}</td>
                    <td className="n">
                      {line.management_amount !== null
                        ? formatAmount(line.management_amount)
                        : <Chip tone="warn">Not calculated · {line.explanation_code ?? "NO_RESULT"}</Chip>}
                    </td>
                    <td className="n">{formatAmount(line.accounting_amount)}</td>
                    <td className={`n ${line.difference !== null && Number(line.difference) !== 0 ? "amount-negative" : ""}`}>
                      {line.difference !== null ? formatAmount(line.difference) : "—"}
                    </td>
                    <td><Chip tone={line.status === "ties" ? "ok" : "bad"}>{line.status === "ties" ? "Ties" : "Not reconciled"}</Chip></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Card>

        <Card title="Cross-module reconciliation">
          <div className="row">
            <Chip tone="mute">Not tested yet</Chip>
            <span>{data.cross_module_note}</span>
          </div>
        </Card>

        <Card title="Traceability">
          <Disclosure summary="Source file, batch and calculation snapshot">
            <div className="trace-grid">
              <span>Calculation run</span><code>{data.run_id}</code>
              <span>Source batch</span><code>{data.source_batch_id}</code>
              <span>Source file</span><code>{data.original_filename}</code>
              <span>Source SHA-256</span><code>{data.source_sha256}</code>
              <span>Scope</span><code>{data.scope}</code>
            </div>
          </Disclosure>
          <Disclosure summary="Canonical fact lineage">
            <div className="stack">
              {data.lines.map((line) => (
                <div key={line.line_code}>
                  <strong>{line.label}</strong>
                  <div className="mono">calc_result {line.calc_result_id ?? "not calculated"}</div>
                  <div className="mono">financial_fact {line.financial_fact_ids.join(", ")}</div>
                </div>
              ))}
            </div>
          </Disclosure>
        </Card>

        <div className="row mt8">
          <Link className="btn p" href={`/app/outlets/${outletId}/analysis/pnl?period=${resolvedPeriod ?? data.period.id}`}>
            Back to Management P&amp;L
          </Link>
          <Link className="btn" href={`/app/outlets/${outletId}/analysis/pnl`}>Back to Management P&amp;L</Link>
        </div>
      </div>
    </main>
  );
}
