"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useRef, useState } from "react";
import { Button, Card, Chip, EmptyState, ErrorPanel, Select, Skeleton } from "@/components/ui";
import { apiMutate, idempotencyKey } from "@/lib/api";
import type {
  ContextVersionListResponse, PLAnalysisResponse, ReviewListResponse, ReviewMutationResponse, ReviewRead,
} from "@/lib/contracts";
import { formatDate, formatDateTime } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { REVIEW_STATUS_LABEL, comparatorWord } from "@/lib/review";
import { useApi, useMutation } from "@/lib/use-api";

const COMPARATORS = ["budget", "forecast", "prior_year"] as const;

export default function ReviewsHome() {
  const router = useRouter();
  const { outletId, summary, periodId, href, can } = useOutlet();
  const period = summary.periods.find((p) => p.id === periodId) ?? null;
  const reviews = useApi<ReviewListResponse>(periodId ? `/reviews?outlet_id=${outletId}&period_id=${periodId}` : null);
  const pnl = useApi<PLAnalysisResponse>(periodId ? `/outlets/${outletId}/analysis/pnl?period_id=${periodId}` : null);
  const contexts = useApi<ContextVersionListResponse>(periodId ? `/outlets/${outletId}/context-versions?period_id=${periodId}` : null);
  const start = useMutation();
  const frame = useMutation();
  const startKey = useRef(idempotencyKey()).current;
  const frameKey = useRef(idempotencyKey()).current;
  const [comparator, setComparator] = useState<string>("");
  const [contextId, setContextId] = useState<string>("");
  const canLead = can("admin", "editor");

  if (!period) {
    return (
      <main className="shell"><div className="panel wide">
        <div className="page-head"><h1>Reviews</h1></div>
        <EmptyState title="Add a reporting period first"
          action={<Link className="btn p" href={`/setup/period?outlet=${outletId}`}>Add a reporting period</Link>}>
          A review covers one period.
        </EmptyState>
      </div></main>
    );
  }

  if (reviews.loading || pnl.loading || contexts.loading) {
    return <main className="shell"><div className="panel wide"><Skeleton width="40%" /><Skeleton width="70%" /></div></main>;
  }

  const review: ReviewRead | null = reviews.data?.reviews[0] ?? null;
  const applicable = (contexts.data?.versions ?? []).filter((v) => v.applies_to_period);
  const chosenContext = contextId || applicable[0]?.id || "";
  const run = pnl.data?.run ?? null;
  const chosenComparator = comparator || run?.comparator_scenario || "budget";

  async function startReview() {
    const r = await start.run(() => apiMutate<ReviewMutationResponse>("/reviews", { outlet_id: outletId, period_id: periodId }, { key: startKey }));
    if (r) reviews.reload();
  }

  async function confirmFrame(reviewId: string) {
    if (!run) return;
    const r = await frame.run(() => apiMutate<ReviewMutationResponse>(`/reviews/${reviewId}/frame`, {
      context_version_id: chosenContext, active_calc_run_id: run.id, comparator_scenario: chosenComparator,
    }, { key: frameKey }));
    if (r) router.push(href(`/reviews/${reviewId}`));
  }

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>Review · {period.label}</h1>
          <p>Frame the month, shortlist the movements that matter, decide what to do about each, and send the Owner Pack for sign-off.</p>
        </div>

        {reviews.error ? <ErrorPanel message={reviews.error.message} correlationId={reviews.error.correlationId} /> : null}

        {!review ? (
          pnl.data ? (
            <Card title="Start the review">
              <div className="stack">
                <p className="muted" style={{ margin: 0 }}>
                  One review per period. You will pin the calculation it is based on, so later uploads cannot change what was reviewed.
                </p>
                {start.error ? <ErrorPanel message={start.error.message} correlationId={start.error.correlationId} /> : null}
                <div className="actions-bar">
                  <Button variant="primary" loading={start.busy} disabled={!canLead} onClick={() => void startReview()}>Start review</Button>
                  {!canLead ? <span className="muted">An admin or editor starts the review.</span> : null}
                </div>
              </div>
            </Card>
          ) : (
            <EmptyState title="Calculate the Management P&L first"
              action={<Link className="btn p" href={href("/data")}>Open Data Centre</Link>}>
              A review is always based on a completed calculation.
            </EmptyState>
          )
        ) : review.status === "draft" ? (
          <Card title="Frame the review">
            <div className="stack">
              <p className="muted" style={{ margin: 0 }}>
                FRAME fixes what this review compares, against which restaurant context, on which calculation. It cannot be changed afterwards.
              </p>
              {!run ? (
                <div className="banner warn">No completed calculation for this period. <Link href={href("/data")}>Calculate it in Data Centre.</Link></div>
              ) : (
                <dl className="kv">
                  <dt>Calculation</dt>
                  <dd>Completed {formatDateTime(run.completed_at)} · <span className="mono">{run.result_hash?.slice(0, 12) ?? run.id.slice(0, 8)}</span></dd>
                  <dt>Inputs</dt>
                  <dd>{run.inputs.map((i) => i.original_filename).join(", ") || "—"}</dd>
                </dl>
              )}
              <div className="g2">
                <Select label="Compare against" id="frame-comparator" value={chosenComparator} onChange={(e) => setComparator(e.target.value)}
                  hint={run?.comparator_scenario ? `The calculation holds ${comparatorWord(run.comparator_scenario)} figures.` : undefined}>
                  {COMPARATORS.map((c) => <option key={c} value={c}>{comparatorWord(c)}</option>)}
                </Select>
                <Select label="Restaurant context" id="frame-context" value={chosenContext} onChange={(e) => setContextId(e.target.value)}
                  hint={applicable.length === 0 ? "No context version covers this period." : undefined}>
                  {applicable.length === 0 ? <option value="">None available</option> : null}
                  {applicable.map((v) => (
                    <option key={v.id} value={v.id}>Version {v.version_no} · from {formatDate(v.effective_from)}{v.service_style ? ` · ${v.service_style}` : ""}</option>
                  ))}
                </Select>
              </div>
              {applicable.length === 0 ? (
                <div className="banner warn">Add a context version that covers {period.label} in <Link href={href("/settings")}>Settings</Link>.</div>
              ) : null}
              {frame.error ? <ErrorPanel message={frame.error.message} correlationId={frame.error.correlationId} /> : null}
              <div className="actions-bar">
                <Button variant="primary" loading={frame.busy} disabled={!canLead || !run || !chosenContext}
                  onClick={() => void confirmFrame(review.id)}>Confirm FRAME</Button>
              </div>
            </div>
          </Card>
        ) : (
          <Card title="This period's review">
            <div className="row sb">
              <div>
                <strong>{REVIEW_STATUS_LABEL[review.status] ?? review.status}</strong>
                <div className="muted">
                  Against {comparatorWord(review.comparator_scenario)} · framed {formatDateTime(review.frame_confirmed_at)}
                </div>
              </div>
              <div className="row">
                <Chip tone={review.status === "signed" || review.status === "closed" ? "ok" : "info"}>{REVIEW_STATUS_LABEL[review.status] ?? review.status}</Chip>
                <Link className="btn p" href={href(`/reviews/${review.id}`)}>Open review</Link>
              </div>
            </div>
          </Card>
        )}
      </div>
    </main>
  );
}
