"use client";

import { useState } from "react";
import { Button, Chip, ErrorPanel, Skeleton, TextArea } from "@/components/ui";
import { apiMutate } from "@/lib/api";
import type { ReviewComment } from "@/lib/contracts";
import { formatDateTime, humanise } from "@/lib/format";
import { useApi, useMutation, useSubmitKey } from "@/lib/use-api";

/** Review-level comment thread. Open comments block sign-off until a reviewer resolves them. */
export function ReviewComments({ reviewId, canComment, canResolve, onChange }: {
  reviewId: string; canComment: boolean; canResolve: boolean; onChange?: () => void;
}) {
  const comments = useApi<ReviewComment[]>(`/reviews/${reviewId}/comments`);
  const [body, setBody] = useState("");
  const add = useMutation();
  const key = useSubmitKey();
  const list = comments.data ?? [];
  const open = list.filter((c) => c.resolution_status === "open").length;
  const changed = () => { comments.reload(); onChange?.(); };

  async function submit() {
    const r = await add.run(() => apiMutate(`/reviews/${reviewId}/comments`, { body: body.trim() }, { key: key.current() }));
    if (r) { key.rotate(); setBody(""); changed(); }
  }

  return (
    <div className="stack">
      {comments.loading && !comments.data ? <Skeleton width="50%" /> : comments.error ? (
        <ErrorPanel message={comments.error.message} correlationId={comments.error.correlationId} />
      ) : list.length === 0 ? (
        <p className="muted" style={{ margin: 0 }}>No comments.</p>
      ) : (
        <>
          {open > 0 ? <div className="banner warn">{open} open comment(s) block sign-off until resolved.</div> : null}
          <ul className="list-plain">
            {list.map((c) => <CommentRow key={c.id} reviewId={reviewId} comment={c} canResolve={canResolve} onResolved={changed} />)}
          </ul>
        </>
      )}
      {canComment ? (
        <form className="stack" onSubmit={(e) => { e.preventDefault(); if (body.trim()) void submit(); }}>
          <TextArea id="comment-body" label="Add a comment" value={body} onChange={(e) => setBody(e.target.value)} rows={2} />
          {add.error ? <ErrorPanel message={add.error.message} correlationId={add.error.correlationId} /> : null}
          <div className="actions-bar"><Button type="submit" loading={add.busy} disabled={!body.trim()}>Post comment</Button></div>
        </form>
      ) : null}
    </div>
  );
}

function CommentRow({ reviewId, comment, canResolve, onResolved }: {
  reviewId: string; comment: ReviewComment; canResolve: boolean; onResolved: () => void;
}) {
  const [note, setNote] = useState("");
  const [resolving, setResolving] = useState(false);
  const resolve = useMutation();
  const key = useSubmitKey();

  async function submit() {
    const r = await resolve.run(() => apiMutate(`/reviews/${reviewId}/comments/${comment.id}/resolve`, { resolution_note: note.trim() }, { key: key.current() }));
    if (r) { key.rotate(); setResolving(false); onResolved(); }
  }

  return (
    <li className="stack" style={{ alignItems: "stretch" }}>
      <div className="row sb">
        <span className="muted">{humanise(comment.author_role)} · {formatDateTime(comment.created_at)}</span>
        <Chip tone={comment.resolution_status === "open" ? "warn" : "ok"}>{comment.resolution_status === "open" ? "Open" : "Resolved"}</Chip>
      </div>
      <p style={{ margin: 0 }}>{comment.body}</p>
      {comment.resolution_note ? <p className="muted" style={{ margin: 0 }}>Resolution: {comment.resolution_note}</p> : null}
      {canResolve && comment.resolution_status === "open" ? (
        resolving ? (
          <div className="stack">
            <TextArea id={`resolve-${comment.id}`} label="Resolution note" value={note} onChange={(e) => setNote(e.target.value)} rows={2} />
            {resolve.error ? <ErrorPanel message={resolve.error.message} correlationId={resolve.error.correlationId} /> : null}
            <div className="actions-bar">
              <Button type="button" variant="primary" loading={resolve.busy} disabled={!note.trim()} onClick={() => void submit()}>Resolve</Button>
              <Button type="button" onClick={() => setResolving(false)}>Cancel</Button>
            </div>
          </div>
        ) : <div className="actions-bar"><Button type="button" onClick={() => setResolving(true)}>Resolve…</Button></div>
      ) : null}
    </li>
  );
}
