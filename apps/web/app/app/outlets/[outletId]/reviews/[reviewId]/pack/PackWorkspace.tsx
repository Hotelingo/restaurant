"use client";

import Link from "next/link";
import { useState } from "react";
import { ReviewComments } from "@/components/review/ReviewComments";
import { useIssueDecisions } from "@/components/review/useIssueDecisions";
import { useReviewLines } from "@/components/review/useReviewLines";
import { Button, Card, Chip, ErrorPanel, Skeleton, TextArea } from "@/components/ui";
import { apiFetch, apiMutate } from "@/lib/api";
import type {
  EvidenceStatus, PackArtifactUrlResponse, PackClaimRead, PackReadResponse, PackSignoffResponse, ReconciliationResponse,
  ReviewGateResponse, ReviewIssueListResponse, ReviewPackHistoryResponse, ReviewRead,
} from "@/lib/contracts";
import { formatDateTime, humanise } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { EVIDENCE_LABEL, PACK_STATUS_LABEL, draftLineClaim, evidenceTone } from "@/lib/review";
import { useApi, useMutation, useSubmitKey } from "@/lib/use-api";

const SCOPE = ["Management P&L", "Shortlisted movements", "Decisions and actions", "Reconciliation", "Owner Pack wording"];

export default function PackWorkspace({ reviewId }: { reviewId: string }) {
  const { href, can, userId } = useOutlet();
  const review = useApi<ReviewRead>(`/reviews/${reviewId}`);
  const history = useApi<ReviewPackHistoryResponse>(`/reviews/${reviewId}/history`);
  const packId = history.data?.versions.at(-1)?.id ?? null;
  const pack = useApi<PackReadResponse>(packId ? `/packs/${packId}` : null);
  const gates = useApi<ReviewGateResponse>(packId ? `/reviews/${reviewId}/gates` : null);
  const issues = useApi<ReviewIssueListResponse>(`/reviews/${reviewId}/issues`);
  const recon = useApi<ReconciliationResponse>(review.data ? `/periods/${review.data.period_id}/reconciliation` : null);
  const { lines } = useReviewLines(review.data);
  const issueList = issues.data?.issues ?? [];
  const { decisions } = useIssueDecisions(issueList.map((i) => i.id));
  const canPrepare = can("admin", "editor");
  const isReviewer = can("reviewer");

  if (review.loading || history.loading || (packId && pack.loading && !pack.data)) {
    return <main className="shell"><div className="panel wide"><Skeleton width="45%" /><Skeleton width="70%" /></div></main>;
  }
  if (!packId || !pack.data) {
    return (
      <main className="shell"><div className="panel wide">
        <ErrorPanel message={pack.error?.message ?? "There is no Owner Pack for this review yet."} correlationId={pack.error?.correlationId}
          action={<Link className="btn" href={href(`/reviews/${reviewId}`)}>Back to the review</Link>} />
      </div></main>
    );
  }

  const p = pack.data.pack;
  const claims = pack.data.claims;
  const editable = p.status === "draft" || p.status === "changes_requested";
  const inReview = p.status === "in_review";
  const reload = () => { pack.reload(); gates.reload(); history.reload(); review.reload(); };
  const allSettled = claims.length > 0 && claims.every((c) => c.claim_status === "accepted" || c.claim_status === "rejected");
  const citedVariance = new Set(claims.flatMap((c) => (c.citations ?? []).map((x) => x.calc_result_id)));
  const madeDecision = Object.values(decisions).some((d) => d && d.decided_by === userId);
  const reconFailed = recon.data?.status === "not_reconciled"
    || gates.data?.failures.some((f) => f.code === "RECONCILIATION_DISCLOSURE") === true;

  const drafts = issueList
    .map((issue) => {
      const line = lines.find((l) => l.variance?.id === issue.source_calc_result_id);
      if (!line || !line.actual || !line.comparator || !line.variance || citedVariance.has(line.variance.id)) return null;
      const text = draftLineClaim(line.label, line.actual, line.comparator, line.variance, review.data?.comparator_scenario ?? null);
      return text ? { issue, line, text } : null;
    })
    .filter((d): d is NonNullable<typeof d> => d !== null);

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <p className="muted" style={{ margin: 0 }}><Link href={href(`/reviews/${reviewId}`)}>← Review</Link></p>
          <div className="row sb">
            <h1>Owner Pack · version {p.version_no}</h1>
            <Chip tone={p.status === "signed" ? "ok" : p.status === "changes_requested" ? "warn" : "info"}>{PACK_STATUS_LABEL[p.status] ?? p.status}</Chip>
          </div>
          <p>
            Every statement cites the pinned calculation. The server checks each one: numbers must match what is cited, and
            accusations or absolute wording are refused.
          </p>
        </div>

        <div className="stack">
          {p.status === "changes_requested" ? (
            <div className="banner warn"><strong>The reviewer asked for changes.</strong> Read the comments below, edit the claims, then submit again.</div>
          ) : null}

          {editable && canPrepare && drafts.length > 0 ? (
            <Card title="Draft statements from the shortlist">
              <div className="stack">
                <p className="muted" style={{ margin: 0 }}>
                  Suggested wording uses the exact cited figures. Edit it freely; keep every number as shown or the check will fail.
                </p>
                {drafts.map((d) => (
                  <DraftClaim key={d.issue.id} packId={p.id} text={d.text}
                    citationIds={[d.line.actual!.id, d.line.comparator!.id, d.line.variance!.id]}
                    evidenceStatus={(d.line.variance!.evidence_status as EvidenceStatus) ?? "supported"} onSaved={reload} />
                ))}
              </div>
            </Card>
          ) : null}

          <Card title={`Statements (${claims.length})`}>
            {claims.length === 0 ? <p className="muted" style={{ margin: 0 }}>No statements yet.</p> : (
              <div className="stack">
                {claims.map((c) => (
                  <ClaimRow key={c.id} packId={p.id} claim={c} canEdit={editable && canPrepare} canReview={inReview && isReviewer} onSaved={reload} />
                ))}
              </div>
            )}
          </Card>

          {reconFailed || p.reconciliation_disclosure ? (
            <Card title="Reconciliation">
              <DisclosurePanel packId={p.id} disclosure={p.reconciliation_disclosure} canEdit={editable && canPrepare} onSaved={reload}
                reconHref={href("/analysis/reconciliation")} />
            </Card>
          ) : null}

          <Card title="Owner Pack file">
            <ArtifactPanel packId={p.id} rendered={Boolean(p.artifact_sha256)} signed={p.status === "signed"} allSettled={allSettled}
              canRender={(canPrepare || isReviewer) && allSettled && p.status !== "signed" && p.status !== "superseded"}
              renderedAt={p.artifact_sha256 ? p.updated_at : null} onSaved={reload} />
          </Card>

          {editable && canPrepare ? (
            <Card title="Send to the reviewer">
              <SubmitPanel packId={p.id} claimCount={claims.length} onSaved={reload} />
            </Card>
          ) : null}

          <Card title="Sign-off gate">
            {gates.loading && !gates.data ? <Skeleton width="60%" /> : gates.error ? (
              <ErrorPanel message={gates.error.message} correlationId={gates.error.correlationId} />
            ) : gates.data ? (
              <div className="stack">
                <div className={`banner ${gates.data.passed ? "ok" : "warn"}`}>
                  {gates.data.passed ? "Every sign-off check passes." : `${gates.data.failures.length} check(s) still block sign-off.`}
                </div>
                <ul className="gate-list">
                  {gates.data.outcomes.map((o) => (
                    <li key={o.code}>
                      <Chip tone={o.passed ? "ok" : "bad"}>{o.passed ? "Pass" : "Blocked"}</Chip>
                      <div>
                        <div>{o.message}</div>
                        {!o.passed ? <div className="muted">{o.remediation}</div> : null}
                      </div>
                    </li>
                  ))}
                </ul>
              </div>
            ) : null}
          </Card>

          {isReviewer && inReview ? (
            <Card title="Sign off">
              <SignoffPanel packId={p.id} gatePassed={gates.data?.passed === true} madeDecision={madeDecision} onSaved={reload} />
            </Card>
          ) : null}

          <Card title="Reviewer comments">
            <ReviewComments reviewId={reviewId} canComment={can("admin", "editor", "reviewer")} canResolve={isReviewer} onChange={gates.reload} />
          </Card>
        </div>
      </div>
    </main>
  );
}

function DraftClaim({ packId, text, citationIds, evidenceStatus, onSaved }: {
  packId: string; text: string; citationIds: string[]; evidenceStatus: EvidenceStatus; onSaved: () => void;
}) {
  const [value, setValue] = useState(text);
  const save = useMutation();
  const key = useSubmitKey();
  const id = `draft-${citationIds[2]}`;

  async function submit() {
    const r = await save.run(() => apiMutate(`/packs/${packId}/claims`, {
      section_code: "movements", claim_text: value.trim(), evidence_status: evidenceStatus, calc_result_ids: citationIds,
    }, { key: key.current() }));
    if (r) { key.rotate(); onSaved(); }
  }

  return (
    <div className="claim stack">
      <TextArea id={id} label="Statement" value={value} onChange={(e) => setValue(e.target.value)} rows={2} />
      {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
      <div className="actions-bar">
        <Button type="button" variant="primary" loading={save.busy} disabled={!value.trim()} onClick={() => void submit()}>Add statement</Button>
        <span className="muted">Evidence: {EVIDENCE_LABEL[evidenceStatus] ?? evidenceStatus}</span>
      </div>
    </div>
  );
}

function ClaimRow({ packId, claim, canEdit, canReview, onSaved }: {
  packId: string; claim: PackClaimRead; canEdit: boolean; canReview: boolean; onSaved: () => void;
}) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(claim.claim_text);
  const act = useMutation();
  const key = useSubmitKey();
  const check = claim.check ?? null;
  const settled = claim.claim_status === "accepted" || claim.claim_status === "rejected";

  async function run(path: string, body?: unknown) {
    const r = await act.run(() => apiMutate(`/packs/${packId}/claims/${claim.id}/${path}`, body, { key: key.current() }));
    if (r) { key.rotate(); setEditing(false); onSaved(); }
  }

  return (
    <div className="claim stack">
      <div className="row sb">
        <div className="row">
          <Chip tone={claim.claim_status === "accepted" ? "ok" : claim.claim_status === "rejected" ? "bad" : "info"}>{humanise(claim.claim_status)}</Chip>
          <Chip tone={evidenceTone(claim.evidence_status)}>{EVIDENCE_LABEL[claim.evidence_status]}</Chip>
          {check ? <Chip tone={check.passed ? "ok" : "bad"}>{check.passed ? "Check passed" : "Check failed"}</Chip> : null}
        </div>
        <span className="muted">{humanise(claim.section_code)}</span>
      </div>
      {editing ? (
        <TextArea id={`edit-${claim.id}`} label="Edit statement" value={text} onChange={(e) => setText(e.target.value)} rows={2} />
      ) : (
        <p style={{ margin: 0 }}><q>{claim.claim_text}</q></p>
      )}
      {check && !check.passed ? (
        <div className="banner bad">
          {!check.number_match ? <div>Numbers not found in the cited results: {check.unmatched_numbers.map(String).join(", ")}.</div> : null}
          {check.banned_wording ? <div>Refused wording: {check.banned_terms.join(", ")}.</div> : null}
          {!check.citation_present ? <div>No citation.</div> : null}
        </div>
      ) : null}
      {claim.citations?.length ? (
        <div className="muted" style={{ fontSize: 12 }}>
          Cites {claim.citations.map((c) => `${c.calc_id}${c.value_numeric !== null ? ` = ${c.value_numeric}` : ""}`).join(" · ")}
        </div>
      ) : null}
      {act.error ? <ErrorPanel message={act.error.message} correlationId={act.error.correlationId} /> : null}
      <div className="actions-bar">
        {canEdit && !settled ? (
          editing ? (
            <>
              <Button type="button" variant="primary" loading={act.busy} disabled={!text.trim()} onClick={() => void run("edit", { claim_text: text.trim() })}>Save</Button>
              <Button type="button" onClick={() => { setEditing(false); setText(claim.claim_text); }}>Cancel</Button>
            </>
          ) : <Button type="button" onClick={() => setEditing(true)}>Edit</Button>
        ) : null}
        {canReview && !settled ? (
          <>
            <Button type="button" variant="primary" loading={act.busy} disabled={check?.passed === false} onClick={() => void run("accept")}
              aria-label={`Accept statement: ${claim.claim_text}`}>Accept</Button>
            <Button type="button" loading={act.busy} onClick={() => void run("reject")} aria-label={`Reject statement: ${claim.claim_text}`}>Reject</Button>
          </>
        ) : null}
      </div>
    </div>
  );
}

function DisclosurePanel({ packId, disclosure, canEdit, onSaved, reconHref }: {
  packId: string; disclosure: string | null; canEdit: boolean; onSaved: () => void; reconHref: string;
}) {
  const [reason, setReason] = useState("");
  const save = useMutation();
  const key = useSubmitKey();
  if (disclosure) return <div className="banner warn"><strong>Stamped Not Reconciled.</strong> {disclosure}</div>;
  return (
    <div className="stack">
      <div className="banner warn">
        The management figures do not tie to the accounting P&amp;L for this calculation. Resolve it in{" "}
        <Link href={reconHref}>Reconciliation</Link>, or stamp the pack Not Reconciled with the reason.
      </div>
      {canEdit ? (
        <>
          <TextArea id="disclosure-reason" label="Reason for Not Reconciled" value={reason} onChange={(e) => setReason(e.target.value)} />
          {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}
          <div className="actions-bar">
            <Button type="button" loading={save.busy} disabled={!reason.trim()} onClick={async () => {
              const r = await save.run(() => apiMutate(`/packs/${packId}/reconciliation-disclosure`, { reason: reason.trim() }, { key: key.current() }));
              if (r) { key.rotate(); onSaved(); }
            }}>Stamp Not Reconciled</Button>
          </div>
        </>
      ) : null}
    </div>
  );
}

function ArtifactPanel({ packId, rendered, signed, allSettled, canRender, renderedAt, onSaved }: {
  packId: string; rendered: boolean; signed: boolean; allSettled: boolean; canRender: boolean; renderedAt: string | null; onSaved: () => void;
}) {
  const render = useMutation();
  const download = useMutation();
  const key = useSubmitKey();
  return (
    <div className="stack">
      <p className="muted" style={{ margin: 0 }}>
        {rendered
          ? signed
            ? `Signed file generated ${formatDateTime(renderedAt)}. Its fingerprint is recorded with the sign-off.`
            : `A file was generated ${formatDateTime(renderedAt)}. It can be downloaded once the pack is signed.`
          : allSettled
            ? "Generate the file the owner receives."
            : "The file the owner receives is generated once the reviewer has accepted or rejected every statement."}
      </p>
      {render.error ? <ErrorPanel message={render.error.message} correlationId={render.error.correlationId} /> : null}
      {download.error ? <ErrorPanel message={download.error.message} correlationId={download.error.correlationId} /> : null}
      <div className="actions-bar">
        {canRender ? (
          <Button type="button" loading={render.busy} onClick={async () => {
            const r = await render.run(() => apiMutate(`/packs/${packId}/render`, undefined, { key: key.current() }));
            if (r) { key.rotate(); onSaved(); }
          }}>{rendered ? "Regenerate file" : "Generate file"}</Button>
        ) : null}
        {rendered && signed ? (
          <Button type="button" loading={download.busy} onClick={async () => {
            const r = await download.run(() => apiFetch<PackArtifactUrlResponse>(`/packs/${packId}/artifact-url`));
            if (r) window.open(r.url, "_blank", "noopener");
          }}>Download</Button>
        ) : null}
      </div>
    </div>
  );
}

function SubmitPanel({ packId, claimCount, onSaved }: { packId: string; claimCount: number; onSaved: () => void }) {
  const submit = useMutation();
  const key = useSubmitKey();
  return (
    <div className="stack">
      <p className="muted" style={{ margin: 0 }}>
        The reviewer accepts or rejects each statement and signs off. Statements cannot be changed while the pack is with them.
      </p>
      {submit.error ? <ErrorPanel message={submit.error.message} correlationId={submit.error.correlationId} /> : null}
      <div className="actions-bar">
        <Button type="button" variant="primary" loading={submit.busy} disabled={claimCount === 0} onClick={async () => {
          const r = await submit.run(() => apiMutate(`/packs/${packId}/submit`, undefined, { key: key.current() }));
          if (r) { key.rotate(); onSaved(); }
        }}>Submit for review</Button>
        {claimCount === 0 ? <span className="muted">Add at least one statement first.</span> : null}
      </div>
    </div>
  );
}

function SignoffPanel({ packId, gatePassed, madeDecision, onSaved }: {
  packId: string; gatePassed: boolean; madeDecision: boolean; onSaved: () => void;
}) {
  const [decision, setDecision] = useState<"signed" | "changes_requested">("signed");
  const [caveat, setCaveat] = useState("");
  const [reviewed, setReviewed] = useState<string[]>(SCOPE);
  const sign = useMutation();
  const key = useSubmitKey();
  const blocked = decision === "signed" && (!gatePassed || madeDecision);

  async function submit() {
    const r = await sign.run(() => apiMutate<PackSignoffResponse>(`/packs/${packId}/signoff`, {
      decision, caveat: caveat.trim() || null,
      scope_reviewed: reviewed, scope_not_reviewed: SCOPE.filter((s) => !reviewed.includes(s)),
    }, { key: key.current() }));
    if (r) { key.rotate(); onSaved(); }
  }

  return (
    <form className="stack" onSubmit={(e) => { e.preventDefault(); if (!blocked) void submit(); }}>
      {madeDecision ? (
        <div className="banner warn">You recorded a decision in this review, so you cannot sign it. Ask an independent reviewer.</div>
      ) : null}
      <fieldset className="choice">
        <legend>Outcome</legend>
        <label className={decision === "signed" ? "on" : ""}>
          <input type="radio" name="signoff" checked={decision === "signed"} onChange={() => setDecision("signed")} />
          <span>Sign<small>The pack is fair and supported by the pinned calculation.</small></span>
        </label>
        <label className={decision === "changes_requested" ? "on" : ""}>
          <input type="radio" name="signoff" checked={decision === "changes_requested"} onChange={() => setDecision("changes_requested")} />
          <span>Request changes<small>Send it back with comments.</small></span>
        </label>
      </fieldset>
      <fieldset className="choice">
        <legend>What you reviewed</legend>
        {SCOPE.map((s) => (
          <label key={s} className={reviewed.includes(s) ? "on" : ""}>
            <input type="checkbox" checked={reviewed.includes(s)}
              onChange={(e) => setReviewed((v) => e.target.checked ? [...v, s] : v.filter((x) => x !== s))} />
            <span>{s}</span>
          </label>
        ))}
      </fieldset>
      <TextArea id="signoff-caveat" label="Caveat (optional)" value={caveat} onChange={(e) => setCaveat(e.target.value)}
        hint="Anything the owner should know about the limits of this review." />
      {sign.error ? <ErrorPanel message={sign.error.message} correlationId={sign.error.correlationId} /> : null}
      <div className="actions-bar">
        <Button type="submit" variant="primary" loading={sign.busy} disabled={blocked}>
          {decision === "signed" ? "Sign the Owner Pack" : "Request changes"}
        </Button>
        {decision === "signed" && !gatePassed ? <span className="muted">The sign-off gate must pass first.</span> : null}
      </div>
    </form>
  );
}
