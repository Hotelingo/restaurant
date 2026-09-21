"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import { authClient } from "@/lib/auth/client";
import type { AuthContextResponse } from "@/lib/contracts";
import { Card, Chip, EmptyState, ErrorPanel, Skeleton } from "@/components/ui";

export default function FoundationHomePage() {
  const router = useRouter();
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
        <div className="row sb">
          <div className="page-head">
            <h1>Restaurant Performance Review</h1>
            <p>Foundation environment — authorised organisation and outlet context.</p>
          </div>
          <button
            type="button"
            className="btn"
            onClick={async () => {
              await authClient.signOut();
              router.replace("/auth/sign-in");
              router.refresh();
            }}
          >
            Sign out
          </button>
        </div>
        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {!context && !error ? <><Skeleton /><Skeleton width="64%" /></> : null}
        {context?.organisations.length === 0 ? (
          <EmptyState
            title="Start your first restaurant review workspace"
            action={<Link className="btn p" href="/setup/organisation">Start guided setup</Link>}
          >
            <div className="stack">
              <span>Create the organisation and first outlet.</span>
              <span>Add the restaurant operating context and first reporting period.</span>
              <span>Then continue to Data Centre to upload the first P&amp;L when ingestion is enabled.</span>
            </div>
          </EmptyState>
        ) : null}
        <div className="stack">
          {context?.organisations.map((org) => (
            <Card key={org.id} title={org.name}>
              <div className="row sb">
                <div className="row">
                  {org.roles.map((role) => <Chip key={role} tone="info">{role}</Chip>)}
                </div>
                {org.roles.includes("admin") ? (
                  <div className="row">
                    <Link className="btn" href={`/app/organisations/${org.id}/outlets/new`}>Add outlet</Link>
                    <Link className="btn" href={`/app/organisations/${org.id}/members`}>Users & roles</Link>
                    <Link className="btn" href={`/app/organisations/${org.id}/audit`}>Audit log</Link>
                  </div>
                ) : null}
              </div>
              <div className="stack mt8">
                {org.outlets.map((outlet) => (
                  <div key={outlet.id} className="row sb">
                    <span>{outlet.name}{outlet.code ? ` · ${outlet.code}` : ""}</span>
                    <div className="row">
                      <span className="muted">{outlet.currency_code} · {outlet.timezone}</span>
                      {outlet.roles.includes("admin") ? (
                        <Link className="btn" href={`/app/outlets/${outlet.id}/settings`}>Settings</Link>
                      ) : null}
                    </div>
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
