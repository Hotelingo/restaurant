"use client";

import Link from "next/link";
import { useRef, useState } from "react";
import { useIssueDecisions } from "@/components/review/useIssueDecisions";
import { useReviewLines, type ReviewLine } from "@/components/review/useReviewLines";
import { Button, Card, Chip, ErrorPanel, Field, Skeleton } from "@/components/ui";
import { apiMutate, idempotencyKey } from "@/lib/api";
import type {
  PackMutationResponse, ReviewIssueListResponse, ReviewIssueMutationResponse, ReviewPackHistoryResponse, ReviewRead,
  ShortlistGuidance,
} from "@/lib/contracts";
import { formatAmount, formatDateTime, humanise } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import {
  DISPOSITIONS, EVIDENCE_LABEL, PACK_STATUS_LABEL, REVIEW_STATUS_LABEL, comparatorWord, evidenceTone, isNegative,
} from "@/lib/review";
import type { EvidenceStatus } from "@/lib/contracts";
import { useApi, useMutation } from "@/lib/use-api";

const GUIDANCE: Record<ShortlistGuidance, { tone: "ok" | "info" | "warn"; text: string }> = {
  below_expected: { tone: "info", text: "Most months need three to five movements explained. Add more if they matter." },
  expected_range: { tone: "ok", text: "Three to five movements: the expected range." },
  six_with_reason: { tone: "info", text: "Six movements, each with a reason for being here." },
  above_expected_warning: { tone: "warn", text: "More than six movements. Consider whether each really needs a decision this month." },
};

export default function ReviewWorkspace({ reviewId }: { reviewId: string }) {
  const { href, can } = useOutlet();
  const review = useApi<ReviewRead>(`/reviews/${reviewId}`);
  const issues = useApi<ReviewIssueListResponse>(`/reviews/${reviewId}/issues`);
  const history = useApi<ReviewPackHistoryResponse>(`/reviews/${reviewId}/history`);
  const { lines, loading: linesLoading, error: linesError } = useReviewLines(review.data);
  const issueList = issues.data?.issues ?? [];
  const { decisions } = useIssueDecisions(issueList.map((i) => i.id));
  const shortlist = useMutation();
  const createPack = useMutation();
  const packKey = useRef(idempotencyKey()).current;
  const [reason, setReason] = useState("");
  const canLead = can("admin", "editor");

  if (review.loading) {
    return <main className="shell"><div className="panel wide"><Skeleton width="45%" /><Skeleton width="70%" /></div></main>;
  }
  if (review.error || !review.data) {
    return (
      <main className="shell"><div className="panel wide">
        <ErrorPanel message={review.error?.status === 404 ? "This review is not available." : review.error?.message ?? "Unable to load this review."}
          correlationId={review.error?.correlationId} action={<Link className="btn" href={href("/reviews")}>Back to reviews</Link>} />
      </div></main>
    );
  }

  const r = review.data;
  const framed = r.status !== "draft";
  const shortlistedResultIds = new Set(issueList.map((i) => i.source_calc_result_id));
  const needsReason = issueList.length >= 5;
  const decidedCount = issueList.filter((i) => decisions[i.id]).length;
  const allDecided = issueList.length > 0 && decidedCount === issueList.length;
  const pack = history.data?.versions.at(-1) ?? null;
  const guidance = issues.data ? GUIDANCE[issues.data.shortlist_guidance] : null;
  // The review record has no release step yet; a signed pack is what "signed" means to the user.
  const shownStatus = pack?.status === "signed" ? "signed" : r.status;

  const steps = [
    { label: "Frame", done: framed },
    { label: "Shortlist", done: issueList.length > 0 },
    { label: "Decide", done: allDecided },
    { label: "Owner Pack", done: pack !== null && pack.status !== "draft" },
    { label: "Sign-off", done: pack?.status === "signed" },
  ];
  const current = steps.findIndex((s) => !s.done);

  async function addToShortlist(line: ReviewLine) {
    if (!line.variance) return;
    const res = await shortlist.run(() => apiMutate<ReviewIssueMutationResponse>(`/reviews/${reviewId}/issues`, {
      source_calc_result_id: line.variance!.id,
      title: `${line.label} vs ${comparatorWord(r.comparator_scenario)}`,
      selection_reason: needsReason ? reason.trim() || null : null,
    }));
    if (res) { setReason(""); issues.reload(); }
  }

  async function startPack() {
    const res = await createPack.run(() => apiMutate<PackMutationResponse>(`/reviews/${reviewId}/packs`, undefined, { key: packKey }));
    if (res) history.reload();
  }

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <div className="row sb">
            <h1>Review</h1>
            <Chip tone={shownStatus === "signed" || shownStatus === "closed" ? "ok" : "info"}>{REVIEW_STATUS_LABEL[shownStatus] ?? shownStatus}</Chip>
          </div>
          <p>Against <strong>{comparatorWord(r.comparator_scenario)}</strong>{r.frame_confirmed_at ? <>, framed {formatDateTime(r.frame_confirmed_at)}</> : null}. Every figure below comes from the calculation pinned at FRAME.</p>
        </div>

        <ol className="steps" aria-label="Review progress">
          {steps.map((s, i) => (
            <li key={s.label} className={s.done ? "done" : i === current ? "cur" : ""} aria-current={i === current ? "step" : undefined}>{s.label}</li>
          ))}
        </ol>

        {!framed ? (
          <div className="banner warn">This review is not framed yet. <Link href={href("/reviews")}>Frame it first.</Link></div>
        ) : (
          <div className="stack">
            <Card title="Shortlist the movements that matter">
              <div className="stack">
                <p className="muted" style={{ margin: 0 }}>
                  Pick the lines whose movement needs an explanation and a decision this month. The server records whether each
                  meets the materiality rules; you can still shortlist a line for a management reason.
                </p>
                {guidance && issueList.length > 0 ? <div className={`banner ${guidance.tone}`}>{guidance.text}</div> : null}
                {needsReason && canLead ? (
                  <Field id="shortlist-reason" label="Reason for adding another movement" value={reason} maxLength={200}
                    onChange={(e) => setReason(e.target.value)} hint="Required from the sixth movement onwards. One line." />
                ) : null}
                {shortlist.error ? <ErrorPanel message={shortlist.error.message} correlationId={shortlist.error.correlationId} /> : null}
                {linesError ? <ErrorPanel message={linesError.message} correlationId={linesError.correlationId} /> : null}
                {linesLoading ? <Skeleton width="80%" /> : (
                  <div className="tw">
                    <table className="tbl">
                      <caption className="sr-only">Management P&amp;L lines from the pinned calculation</caption>
                      <thead>
                        <tr>
                          <th scope="col">Line</th>
                          <th scope="col" className="n">Actual</th>
                          <th scope="col" className="n">{comparatorWord(r.comparator_scenario)}</th>
                          <th scope="col" className="n">Profit effect</th>
                          <th scope="col"><span className="sr-only">Shortlist</span></th>
                        </tr>
                      </thead>
                      <tbody>
                        {lines.map((line) => {
                          const effect = line.variance?.value_numeric ?? null;
                          const calculated = line.variance?.calculation_status === "CALCULATED";
                          const already = line.variance ? shortlistedResultIds.has(line.variance.id) : false;
                          return (
                            <tr key={line.code}>
                              <th scope="row" style={{ fontWeight: line.kind === "cost" || line.kind === "revenue" ? 500 : 700 }}>{line.label}</th>
                              <td className="n mono">{formatAmount(line.actual?.value_numeric)}</td>
                              <td className="n mono">{formatAmount(line.comparator?.value_numeric)}</td>
                              <td className={`n mono ${effect === null ? "" : isNegative(effect) ? "adverse" : "favourable"}`}>
                                {calculated ? formatAmount(effect) : <Chip tone="warn">Not calculated</Chip>}
                              </td>
                              <td style={{ textAlign: "right" }}>
                                {already ? <Chip tone="ok">Shortlisted</Chip> : canLead ? (
                                  <Button type="button" disabled={!calculated || shortlist.busy || (needsReason && !reason.trim())}
                                    onClick={() => void addToShortlist(line)} aria-label={`Shortlist ${line.label}`}>Shortlist</Button>
                                ) : null}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                )}
              </div>
            </Card>

            <Card title={`Shortlisted movements (${issueList.length})`}>
              {issueList.length === 0 ? (
                <p className="muted" style={{ margin: 0 }}>Nothing shortlisted yet.</p>
              ) : (
                <ul className="list-plain">
                  {issueList.map((issue) => {
                    const decision = decisions[issue.id];
                    return (
                      <li key={issue.id} className="row sb">
                        <div>
                          <strong>{issue.shortlist_order}. {issue.title}</strong>
                          <div className="muted">
                            Profit effect <span className={`mono ${isNegative(issue.movement_amount) ? "adverse" : "favourable"}`}>{formatAmount(issue.movement_amount)}</span>
                            {" · "}{issue.materiality_rules.map(humanise).join(", ")}
                          </div>
                        </div>
                        <div className="row">
                          <Chip tone={evidenceTone(issue.evidence_status)}>{EVIDENCE_LABEL[issue.evidence_status as EvidenceStatus] ?? humanise(issue.evidence_status)}</Chip>
                          {decision ? <Chip tone="ok">{DISPOSITIONS[decision.disposition].label}</Chip> : <Chip tone="mute">No decision</Chip>}
                          <Link className={`btn${decision ? "" : " p"}`} href={href(`/reviews/${reviewId}/issues/${issue.id}`)}>
                            {decision ? "Open" : "Diagnose & decide"}
                          </Link>
                        </div>
                      </li>
                    );
                  })}
                </ul>
              )}
            </Card>

            <Card title="Owner Pack">
              <div className="stack">
                {pack ? (
                  <div className="row sb">
                    <div>
                      <strong>Version {pack.version_no}</strong>
                      <div className="muted">Created {formatDateTime(pack.created_at)}</div>
                    </div>
                    <div className="row">
                      <Chip tone={pack.status === "signed" ? "ok" : pack.status === "changes_requested" ? "warn" : "info"}>{PACK_STATUS_LABEL[pack.status] ?? pack.status}</Chip>
                      <Link className="btn p" href={href(`/reviews/${reviewId}/pack`)}>Open Owner Pack</Link>
                    </div>
                  </div>
                ) : (
                  <>
                    <p className="muted" style={{ margin: 0 }}>
                      The Owner Pack states what happened and what was decided, citing the pinned calculation. Build it once every
                      shortlisted movement has a decision.
                    </p>
                    {createPack.error ? <ErrorPanel message={createPack.error.message} correlationId={createPack.error.correlationId} /> : null}
                    <div className="actions-bar">
                      <Button variant={allDecided ? "primary" : "default"} loading={createPack.busy} disabled={!canLead || issueList.length === 0}
                        onClick={() => void startPack()}>Create Owner Pack</Button>
                      {!allDecided && issueList.length > 0 ? <span className="muted">{issueList.length - decidedCount} movement(s) still without a decision.</span> : null}
                    </div>
                  </>
                )}
              </div>
            </Card>
          </div>
        )}
      </div>
    </main>
  );
}
