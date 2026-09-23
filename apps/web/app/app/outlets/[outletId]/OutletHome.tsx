"use client";

import Link from "next/link";
import { Card, Chip, Skeleton } from "@/components/ui";
import type { ImportBatchListResponse, PLAnalysisResponse, ReviewListResponse } from "@/lib/contracts";
import { formatAmount } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { useApi } from "@/lib/use-api";

type Step = { key: string; title: string; detail: string; done: boolean; href: string; cta: string };

export default function OutletHome() {
  const { outletId, summary, periodId, href } = useOutlet();
  const period = summary.periods.find((p) => p.id === periodId) ?? null;

  const imports = useApi<ImportBatchListResponse>(periodId ? `/outlets/${outletId}/imports?period_id=${periodId}` : null);
  const pnl = useApi<PLAnalysisResponse>(periodId ? `/outlets/${outletId}/analysis/pnl?period_id=${periodId}` : null);
  const reviews = useApi<ReviewListResponse>(periodId ? `/reviews?outlet_id=${outletId}&period_id=${periodId}` : null);

  if (!period) {
    return (
      <main className="shell">
        <div className="panel wide">
          <div className="page-head">
            <h1>{summary.outlet_name}</h1>
            <p>Add a reporting period to start. A period is the month you upload and review.</p>
          </div>
          <Link className="btn p" href={`/setup/period?outlet=${outletId}`}>Add a reporting period</Link>
        </div>
      </main>
    );
  }

  const loading = imports.loading || pnl.loading || reviews.loading;
  const batches = imports.data?.batches ?? [];
  const committed = (code: string) => batches.some((b) => b.template_code === code && b.status === "committed");
  const calculated = pnl.data !== null;
  const review = reviews.data?.reviews[0] ?? null;

  const steps: Step[] = [
    { key: "actual", title: "Upload the month's P&L", detail: "Your actual results by account, mapped once to the management ladder.",
      done: committed("T1"), href: href("/data", { template: "T1" }), cta: "Upload P&L" },
    { key: "budget", title: "Upload the budget", detail: "The comparator the month is measured against.",
      done: committed("T6"), href: href("/data", { template: "T6" }), cta: "Upload budget" },
    { key: "calc", title: "Calculate the Management P&L", detail: "Server-side, immutable, traceable to each source file.",
      done: calculated, href: calculated ? href("/analysis/pnl") : href("/data"), cta: calculated ? "Open P&L" : "Calculate" },
    { key: "review", title: "Run the review", detail: "Frame it, shortlist the material movements, decide and assign actions.",
      done: review !== null && review.status !== "draft", href: href("/reviews"), cta: review ? "Continue review" : "Start review" },
    { key: "pack", title: "Sign the Owner Pack", detail: "Reviewer sign-off on one locked calculation.",
      done: review?.status === "signed" || review?.status === "released" || review?.status === "closed",
      href: href("/reports"), cta: "Owner Packs" },
  ];
  const next = steps.find((s) => !s.done);
  const net = pnl.data?.lines.find((l) => l.line_code === "NET_SALES");
  const op = pnl.data?.lines.find((l) => l.line_code === "OPERATING_PROFIT");

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>{summary.outlet_name} · {period.label}</h1>
          <p>{next ? <>Next: <strong>{next.title.toLowerCase()}</strong>.</> : "This period's review is complete."}</p>
        </div>

        {loading ? (
          <div className="stack"><Skeleton width="60%" /><Skeleton width="80%" /><Skeleton width="50%" /></div>
        ) : (
          <div className="stack">
            <ol className="list-plain" aria-label="Review progress for this period">
              {steps.map((step, i) => (
                <li key={step.key} className="row sb">
                  <div>
                    <div className="row">
                      <span className="mono muted">{i + 1}</span>
                      <strong>{step.title}</strong>
                      {step.done ? <Chip tone="ok">Done</Chip> : step === next ? <Chip tone="info">Next</Chip> : <Chip tone="mute">Not yet</Chip>}
                    </div>
                    <div className="muted" style={{ marginLeft: 22 }}>{step.detail}</div>
                  </div>
                  <Link className={`btn${step === next ? " p" : ""}`} href={step.href}>{step.cta}</Link>
                </li>
              ))}
            </ol>

            {pnl.data ? (
              <Card title="This period at a glance">
                <dl className="kv">
                  <dt>Net Sales</dt><dd className="mono">{formatAmount(net?.actual?.value_numeric)} {pnl.data.currency_code}</dd>
                  <dt>Operating Profit</dt><dd className="mono">{formatAmount(op?.actual?.value_numeric)} {pnl.data.currency_code}</dd>
                  <dt>Operating Profit vs {pnl.data.run.comparator_scenario ?? "comparator"}</dt>
                  <dd className="mono">{formatAmount(op?.variance?.profit_effect)}</dd>
                  <dt>First material movement</dt>
                  <dd>{pnl.data.first_material_movement?.value_text?.replace(/_/g, " ").toLowerCase() ?? "—"}</dd>
                </dl>
              </Card>
            ) : null}
          </div>
        )}
      </div>
    </main>
  );
}
