"use client";

import Link from "next/link";
import { Button, Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";
import { apiFetch } from "@/lib/api";
import type { PackArtifactUrlResponse, ReviewListResponse, ReviewPackHistoryResponse, ReviewRead } from "@/lib/contracts";
import { formatDateTime, humanise } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { PACK_STATUS_LABEL, REVIEW_STATUS_LABEL, comparatorWord } from "@/lib/review";
import { useApi, useMutation } from "@/lib/use-api";

/** Owner Pack history across every review of this outlet: versions, sign-offs and the signed file. */
export default function OwnerPacks() {
  const { outletId, summary } = useOutlet();
  const reviews = useApi<ReviewListResponse>(`/reviews?outlet_id=${outletId}`);
  const list = [...(reviews.data?.reviews ?? [])].sort((a, b) => {
    const pa = summary.periods.find((p) => p.id === a.period_id)?.period_start ?? "";
    const pb = summary.periods.find((p) => p.id === b.period_id)?.period_start ?? "";
    return pb.localeCompare(pa);
  });

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>Owner Packs</h1>
          <p>Every version is kept. A signed pack is never edited; a correction is a new version that supersedes it.</p>
        </div>
        {reviews.error ? <ErrorPanel message={reviews.error.message} correlationId={reviews.error.correlationId} /> : null}
        {reviews.loading ? <Skeleton width="60%" /> : list.length === 0 ? (
          <EmptyState title="No reviews yet">Owner Packs appear here once a review creates one.</EmptyState>
        ) : (
          <div className="stack">
            {list.map((r) => (
              <ReviewPacks key={r.id} review={r} periodLabel={summary.periods.find((p) => p.id === r.period_id)?.label ?? "—"} />
            ))}
          </div>
        )}
      </div>
    </main>
  );
}

function ReviewPacks({ review, periodLabel }: { review: ReviewRead; periodLabel: string }) {
  const { href } = useOutlet();
  const history = useApi<ReviewPackHistoryResponse>(`/reviews/${review.id}/history`);
  const download = useMutation();
  const versions = [...(history.data?.versions ?? [])].reverse();

  async function open(packId: string) {
    const r = await download.run(() => apiFetch<PackArtifactUrlResponse>(`/packs/${packId}/artifact-url`));
    if (r) window.open(r.url, "_blank", "noopener");
  }

  return (
    <Card title={`${periodLabel} · vs ${comparatorWord(review.comparator_scenario)}`}>
      <div className="stack">
        <div className="row sb">
          <Chip tone={review.status === "signed" || review.status === "closed" ? "ok" : "info"}>{REVIEW_STATUS_LABEL[review.status] ?? review.status}</Chip>
          <Link className="btn" href={href(`/reviews/${review.id}`, { period: review.period_id })}>Open review</Link>
        </div>
        {history.loading ? <Skeleton width="40%" /> : versions.length === 0 ? (
          <p className="muted" style={{ margin: 0 }}>No Owner Pack yet.</p>
        ) : (
          <ul className="list-plain">
            {versions.map((v) => (
              <li key={v.id} className="row sb">
                <div>
                  <strong>Version {v.version_no}</strong> <span className="muted">· created {formatDateTime(v.created_at)}</span>
                  {(v.signoffs ?? []).map((s) => (
                    <div key={s.id} className="muted">
                      {s.decision === "signed" ? "Signed" : "Changes requested"} by {s.reviewer_name} ({humanise(s.reviewer_role)}) · {formatDateTime(s.created_at)}
                      {s.caveat ? ` · caveat: ${s.caveat}` : ""}
                    </div>
                  ))}
                </div>
                <div className="row">
                  <Chip tone={v.status === "signed" ? "ok" : v.status === "superseded" ? "mute" : "info"}>{PACK_STATUS_LABEL[v.status] ?? v.status}</Chip>
                  {v.artifact_sha256 ? <Button type="button" loading={download.busy} onClick={() => void open(v.id)}>Download</Button> : null}
                  <Link className="btn" href={href(`/reviews/${review.id}/pack`, { period: review.period_id })}>View</Link>
                </div>
              </li>
            ))}
          </ul>
        )}
        {download.error ? <ErrorPanel message={download.error.message} correlationId={download.error.correlationId} /> : null}
      </div>
    </Card>
  );
}
