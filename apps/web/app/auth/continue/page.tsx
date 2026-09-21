"use client";

import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { AuthContextResponse } from "@/lib/contracts";
import { ErrorPanel, Skeleton } from "@/components/ui";

export default function ContinuePage() {
  const router = useRouter();
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    let cancelled = false;

    apiFetch<AuthContextResponse>("/auth/context")
      .then((context) => {
        if (cancelled) return;
        if (context.organisations.length === 0) {
          router.replace("/setup/organisation");
        } else {
          router.replace("/app");
        }
      })
      .catch((cause) => {
        if (!cancelled) setError(
          cause instanceof ApiError ? cause : new ApiError("Unable to resolve your access.", 500, null),
        );
      });

    return () => { cancelled = true; };
  }, [router]);

  return (
    <main className="shell">
      <div className="panel">
        <div className="page-head">
          <h1>Resolving access</h1>
          <p>Checking your authorised organisations and outlets.</p>
        </div>
        {error ? (
          <ErrorPanel
            message={error.message}
            correlationId={error.correlationId}
            action={<button className="btn" onClick={() => location.reload()}>Retry</button>}
          />
        ) : (
          <><Skeleton width="72%" /><Skeleton width="48%" /></>
        )}
      </div>
    </main>
  );
}
