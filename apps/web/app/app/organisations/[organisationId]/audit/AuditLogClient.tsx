"use client";

import { useEffect, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { AuditLogResponse } from "@/lib/contracts";
import { DataTable, ErrorPanel, Skeleton } from "@/components/ui";

export default function AuditLogClient({ organisationId }: { organisationId: string }) {
  const [data, setData] = useState<AuditLogResponse | null>(null);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    apiFetch<AuditLogResponse>(`/organisations/${organisationId}/audit-log?limit=100`)
      .then(setData)
      .catch((cause) => setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Audit log could not be loaded.", 500, null),
      ));
  }, [organisationId]);

  return (
    <main className="shell">
      <div className="panel" style={{ width: "min(100%, 980px)" }}>
        <div className="page-head">
          <h1>Audit log</h1>
          <p>Recent organisation activity. Financial audit records are append-only.</p>
        </div>
        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {!data && !error ? <><Skeleton /><Skeleton width="72%" /></> : null}
        {data ? (
          <DataTable
            caption="Recent audit events"
            rows={data.events}
            rowKey={(row) => String(row.id)}
            columns={[
              { key: "when", header: "When", render: (row) => new Date(row.occurred_at).toLocaleString() },
              { key: "who", header: "Who", render: (row) => row.actor_name || row.actor_email || "System" },
              { key: "action", header: "Action", render: (row) => row.action_code },
              { key: "object", header: "Object", render: (row) => `${row.object_type}${row.object_id ? ` · ${row.object_id}` : ""}` },
              { key: "correlation", header: "Correlation", render: (row) => row.correlation_id || "—" },
            ]}
          />
        ) : null}
      </div>
    </main>
  );
}
