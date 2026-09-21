"use client";

import { useEffect, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { AuthContextResponse } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";

export default function FoundationHomePage() {
  const [context, setContext] = useState<AuthContextResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    apiFetch<AuthContextResponse>("/auth/context")
      .then(setContext)
      .catch((cause) => setError(cause instanceof ApiError ? cause : new ApiError("Unable to load access context.", 500, null)));
  }, []);

  return (
    <main className="shell">
      <div className="panel">
        <div className="page-head">
          <h1>Restaurant Performance Review</h1>
          <p>Foundation environment — authorised organisation and outlet context.</p>
        </div>
        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {!context && !error ? <><Skeleton /><Skeleton width="64%" /></> : null}
        {context?.organisations.length === 0 ? <EmptyState title="No organisation yet" /> : null}
        <div className="stack">
          {context?.organisations.map((org) => (
            <Card key={org.id} title={org.name}>
              <div className="row">
                {org.roles.map((role) => <Chip key={role} tone="info">{role}</Chip>)}
              </div>
              <div className="stack mt8">
                {org.outlets.map((outlet) => (
                  <div key={outlet.id} className="row sb">
                    <span>{outlet.name}{outlet.code ? ` · ${outlet.code}` : ""}</span>
                    <span className="muted">{outlet.currency_code} · {outlet.timezone}</span>
                  </div>
                ))}
              </div>
            </Card>
          ))}
        </div>
      </div>
    </main>
  );
}
