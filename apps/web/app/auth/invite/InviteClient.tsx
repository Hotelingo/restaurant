"use client";

import Link from "next/link";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { authClient } from "@/lib/auth/client";
import { apiFetch, ApiError, publicApiFetch } from "@/lib/api";
import type { InvitationPreviewResponse } from "@/lib/contracts";
import { Button, Card, Chip, ErrorPanel, Skeleton } from "@/components/ui";

export default function InviteClient({ token }: { token: string }) {
  const router = useRouter();
  const [preview, setPreview] = useState<InvitationPreviewResponse | null>(null);
  const [signedIn, setSignedIn] = useState(false);
  const [loading, setLoading] = useState(true);
  const [pending, setPending] = useState<"accept" | "decline" | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  const returnTo = useMemo(
    () => `/auth/invite?token=${encodeURIComponent(token)}`,
    [token],
  );

  useEffect(() => {
    let cancelled = false;

    async function load() {
      if (!token) {
        setError(new ApiError("Invitation is not available.", 404, null));
        setLoading(false);
        return;
      }

      try {
        const [invitation, session] = await Promise.all([
          publicApiFetch<InvitationPreviewResponse>(
            `/invitations/${encodeURIComponent(token)}/preview`,
          ),
          authClient.getSession(),
        ]);
        if (cancelled) return;
        setPreview(invitation);
        setSignedIn(Boolean(session.data?.session));
      } catch (cause) {
        if (cancelled) return;
        setError(
          cause instanceof ApiError
            ? cause
            : new ApiError("Invitation is not available.", 404, null),
        );
      } finally {
        if (!cancelled) setLoading(false);
      }
    }

    void load();
    return () => { cancelled = true; };
  }, [token]);

  async function decide(action: "accept" | "decline") {
    setPending(action);
    setError(null);

    try {
      const result = await apiFetch<{
        organisation_id?: string | null;
        membership_id?: string | null;
        invitation_id?: string | null;
      }>(`/invitations/${encodeURIComponent(token)}/${action}`, {
        method: "POST",
      });

      if (action === "accept" && result.organisation_id) {
        router.replace("/auth/continue");
      } else {
        router.replace("/auth/sign-in");
      }
    } catch (cause) {
      const apiError = cause instanceof ApiError
        ? cause
        : new ApiError("Invitation could not be processed.", 500, null);
      if (apiError.status === 401) setSignedIn(false);
      setError(apiError);
    } finally {
      setPending(null);
    }
  }

  const pendingStatus = preview?.status === "pending";

  return (
    <main className="shell">
      <div className="panel">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          <div><b>Restaurant Performance Review</b><span>Membership invitation</span></div>
        </div>

        {loading ? <><Skeleton /><Skeleton width="68%" /></> : null}
        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}

        {preview ? (
          <div className="stack">
            <div className="page-head">
              <h1>Organisation invitation</h1>
              <p>Review the signed invitation before accepting it.</p>
            </div>

            <Card title={preview.organisation_name}>
              <div className="stack">
                <div className="row sb"><span>Role</span><Chip tone="info">{preview.role}</Chip></div>
                <div className="row sb">
                  <span>Outlet scope</span>
                  <strong>
                    {preview.scope_mode === "all_outlets"
                      ? "All outlets"
                      : preview.outlet_names.join(", ") || "Selected outlets"}
                  </strong>
                </div>
                {preview.inviter_name ? (
                  <div className="row sb"><span>Invited by</span><span>{preview.inviter_name}</span></div>
                ) : null}
                <div className="row sb">
                  <span>Expires</span>
                  <span>{new Date(preview.expires_at).toLocaleString()}</span>
                </div>
                <div className="row sb">
                  <span>Status</span>
                  <Chip tone={pendingStatus ? "ok" : "warn"}>{preview.status}</Chip>
                </div>
              </div>
            </Card>

            {!pendingStatus ? (
              <div className="banner info">This invitation is no longer pending. Ask an administrator for a new invitation if access is still required.</div>
            ) : signedIn ? (
              <div className="row sb">
                <Button
                  type="button"
                  onClick={() => void decide("decline")}
                  loading={pending === "decline"}
                  disabled={pending !== null}
                >
                  Decline
                </Button>
                <Button
                  type="button"
                  variant="primary"
                  onClick={() => void decide("accept")}
                  loading={pending === "accept"}
                  disabled={pending !== null}
                >
                  Accept invitation
                </Button>
              </div>
            ) : (
              <div className="stack">
                <div className="banner info">
                  Sign in with the invited email address, or create an account using that address, to accept this invitation.
                </div>
                <div className="row">
                  <Link className="btn p" href={`/auth/sign-in?returnTo=${encodeURIComponent(returnTo)}`}>Sign in</Link>
                  <Link className="btn" href={`/auth/register?returnTo=${encodeURIComponent(returnTo)}`}>Create account</Link>
                </div>
              </div>
            )}
          </div>
        ) : null}
      </div>
    </main>
  );
}
