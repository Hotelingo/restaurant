"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { Button, Card, Chip, EmptyState, ErrorPanel, Select, Skeleton, TextArea } from "@/components/ui";
import { apiFetch, apiMutate, ApiError } from "@/lib/api";
import type { ActionListResponse, ActionMutationResponse, ActionRead, ActionStatus, ReviewListResponse } from "@/lib/contracts";
import { formatDate } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { ACTION_STATUS_LABEL } from "@/lib/review";
import { useApi, useMutation, useSubmitKey } from "@/lib/use-api";

const STATUSES: ActionStatus[] = ["OPEN_ON_TRACK", "OVERDUE_NOT_COMPLETED", "REPEATED_ISSUE", "REOPENED", "CLOSED"];

/** Every action raised in any review of this outlet, newest review first. */
export default function ActionRegister() {
  const { outletId, summary, href, can } = useOutlet();
  const reviews = useApi<ReviewListResponse>(`/reviews?outlet_id=${outletId}`);
  const [actions, setActions] = useState<ActionRead[] | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const [version, setVersion] = useState(0);
  const [filter, setFilter] = useState<"open" | "all">("open");
  const reviewIds = (reviews.data?.reviews ?? []).map((r) => r.id).join(",");

  useEffect(() => {
    if (!reviews.data) return;
    let cancelled = false;
    const ids = reviewIds ? reviewIds.split(",") : [];
    Promise.all(ids.map((id) => apiFetch<ActionListResponse>(`/reviews/${id}/actions`)))
      .then((lists) => { if (!cancelled) { setActions(lists.flatMap((l) => l.actions)); setError(null); } })
      .catch((cause) => { if (!cancelled) setError(cause instanceof ApiError ? cause : new ApiError("Unable to load actions.", 500, null)); });
    return () => { cancelled = true; };
    // `version` forces a refresh after a status change.
  }, [reviewIds, version]);

  const periodOf = (reviewId: string) => {
    const review = reviews.data?.reviews.find((r) => r.id === reviewId);
    return summary.periods.find((p) => p.id === review?.period_id)?.label ?? "—";
  };
  const shown = (actions ?? []).filter((a) => filter === "all" || a.status !== "CLOSED");

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>Action register</h1>
          <p>What was decided, who owns it, and whether it happened. Each action is checked again in the next period's review.</p>
        </div>
        {reviews.error || error ? <ErrorPanel message={(reviews.error ?? error)!.message} correlationId={(reviews.error ?? error)!.correlationId} /> : null}
        {reviews.loading || (reviews.data && actions === null && !error) ? <><Skeleton width="60%" /><Skeleton width="45%" /></> : actions && actions.length === 0 ? (
          <EmptyState title="No actions yet" action={<Link className="btn p" href={href("/reviews")}>Open reviews</Link>}>
            Actions are created from decisions in a review.
          </EmptyState>
        ) : actions ? (
          <div className="stack">
            <div className="row">
              <Select label="Show" id="action-filter" value={filter} onChange={(e) => setFilter(e.target.value as "open" | "all")}>
                <option value="open">Open actions</option>
                <option value="all">All actions</option>
              </Select>
            </div>
            {shown.length === 0 ? <p className="muted">Nothing open.</p> : shown.map((a) => (
              <ActionCard key={a.id} action={a} period={periodOf(a.review_id)} canEdit={can("admin", "editor")}
                issueHref={href(`/reviews/${a.review_id}/issues/${a.review_issue_id}`)} onSaved={() => setVersion((v) => v + 1)} />
            ))}
          </div>
        ) : null}
      </div>
    </main>
  );
}

function ActionCard({ action, period, canEdit, issueHref, onSaved }: {
  action: ActionRead; period: string; canEdit: boolean; issueHref: string; onSaved: () => void;
}) {
  const [status, setStatus] = useState<ActionStatus>(action.status);
  const [note, setNote] = useState("");
  const [evidence, setEvidence] = useState("");
  const save = useMutation();
  const key = useSubmitKey();
  const changed = status !== action.status;
  const closing = status === "CLOSED";
  const valid = changed && (!closing || evidence.trim().length > 0);

  async function submit() {
    const r = await save.run(() => apiMutate<ActionMutationResponse>(`/actions/${action.id}/status`, {
      status, note: note.trim() || null, closure_evidence: closing ? evidence.trim() : null,
    }, { key: key.current() }));
    if (r) { key.rotate(); setNote(""); setEvidence(""); onSaved(); }
  }

  return (
    <Card>
      <div className="stack">
        <div className="row sb">
          <div>
            <strong>{action.owner}</strong>{action.lever ? <> · {action.lever}</> : null}
            <div className="muted">
              {period}{action.due_date ? ` · due ${formatDate(action.due_date)}` : ""}{action.cadence ? ` · ${action.cadence}` : ""}
              {action.metric ? ` · measured by ${action.metric}` : ""}
            </div>
          </div>
          <div className="row">
            <Chip tone={action.status === "CLOSED" ? "ok" : action.status === "OPEN_ON_TRACK" ? "info" : "warn"}>{ACTION_STATUS_LABEL[action.status]}</Chip>
            <Link className="btn" href={issueHref}>Decision</Link>
          </div>
        </div>
        {action.guardrail ? <div className="muted">Guardrail: {action.guardrail}</div> : null}
        {action.closure_evidence ? <div className="muted">Closed with: {action.closure_evidence}</div> : null}
        {canEdit && action.status !== "CLOSED" ? (
          <form className="stack" onSubmit={(e) => { e.preventDefault(); if (valid) void submit(); }}>
            <div className="g2">
              <Select label="Status" id={`status-${action.id}`} value={status} onChange={(e) => setStatus(e.target.value as ActionStatus)}>
                {STATUSES.map((s) => <option key={s} value={s}>{ACTION_STATUS_LABEL[s]}</option>)}
              </Select>
              <div />
            </div>
            {changed ? (
              <>
                {closing ? <TextArea id={`closure-${action.id}`} label="Closure evidence" value={evidence} onChange={(e) => setEvidence(e.target.value)} required
                  hint="What shows it is done, e.g. the new rota in use from 4 August." /> : null}
                <TextArea id={`note-${action.id}`} label="Note (optional)" value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
                {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
                <div className="actions-bar"><Button type="submit" variant="primary" loading={save.busy} disabled={!valid}>Update status</Button></div>
              </>
            ) : null}
          </form>
        ) : null}
      </div>
    </Card>
  );
}
