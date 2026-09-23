"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { SetupSummaryResponse } from "@/lib/contracts";
import { Card, Chip, ErrorPanel, Skeleton } from "@/components/ui";

export default function SetupCompleteClient({
  outletId,
}: {
  outletId: string | null;
}) {
  const [summary, setSummary] = useState<SetupSummaryResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    if (!outletId) return;
    apiFetch<SetupSummaryResponse>(`/outlets/${outletId}/setup-summary`)
      .then(setSummary)
      .catch((cause) => setError(cause instanceof ApiError ? cause : new ApiError("Setup summary could not be loaded.", 500, null)));
  }, [outletId]);

  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="done">1 Organisation</li><li className="done">2 Outlet</li><li className="done">3 Context</li><li className="done">4 Period</li>
        </ol>
        <div className="page-head">
          <h1>Setup complete</h1>
          <p>Your structural setup is ready. No financial values have been fabricated or entered.</p>
        </div>

        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {!summary && !error ? <><Skeleton /><Skeleton width="68%" /></> : null}

        {summary ? (
          <Card title="Setup summary">
            <div className="stack">
              <div className="row sb"><span>Organisation</span><strong>{summary.organisation_name}</strong></div>
              <div className="row sb"><span>Outlet</span><strong>{summary.outlet_name}</strong></div>
              <div className="row sb"><span>Reporting currency</span><span>{summary.currency_code}</span></div>
              <div className="row sb"><span>Restaurant context</span><Chip tone={summary.latest_context_version ? "ok" : "warn"}>{summary.latest_context_version ? `Version ${summary.latest_context_version}` : "Missing"}</Chip></div>
              <div className="row sb"><span>Reporting periods</span><span>{summary.periods.length}</span></div>
            </div>
          </Card>
        ) : null}

        <div className="row sb mt8">
          <Link className="btn" href={outletId ? `/app/outlets/${outletId}` : "/app"}>Go to outlet Home</Link>
          <Link className="btn p" href={outletId ? `/app/outlets/${outletId}/data` : "/app"}>Upload P&amp;L and budget</Link>
        </div>
      </div>
    </main>
  );
}
