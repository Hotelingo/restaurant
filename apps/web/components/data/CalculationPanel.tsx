"use client";

import Link from "next/link";
import { useEffect, useRef } from "react";
import { Button, Chip, ErrorPanel } from "@/components/ui";
import { apiFetch } from "@/lib/api";
import type { CalculationModule, CalculationRequestResponse, CalculationStatus, CalculationStatusResponse } from "@/lib/contracts";
import { MODULE_LABEL } from "@/lib/domain";
import { formatDateTime } from "@/lib/format";
import { useApi, useMutation } from "@/lib/use-api";

function belongsTo(module: CalculationModule, reason: string): boolean {
  if (module === "pl") return reason.startsWith("pl") || reason === "financial_import_committed";
  if (module === "labour_other") return reason.startsWith("labour");
  return reason.startsWith(module);
}

export function CalculationPanel({
  periodId,
  module = "pl",
  ready,
  resultHref,
  onCompleted,
}: {
  periodId: string;
  module?: CalculationModule;
  /** Whether the source data this module needs has been committed. */
  ready: boolean;
  resultHref: string;
  onCompleted?: () => void;
}) {
  const status = useApi<CalculationStatusResponse>(`/periods/${periodId}/calculations`);
  const request = useMutation();
  const latest: CalculationStatus | undefined = status.data?.requests.find((r) => belongsTo(module, r.reason));
  const active = latest?.status === "pending" || latest?.status === "running";

  // Poll while a request is outstanding; stop as soon as it settles.
  useEffect(() => {
    if (!active) return;
    const timer = setInterval(status.reload, 2500);
    return () => clearInterval(timer);
  }, [active, status.reload]);

  // Tell the parent only when a request it watched moves from queued/running to
  // completed. Firing on mount for an already-finished request made the parent
  // reload, remount this panel, and fire again, forever.
  const watching = useRef<string | null>(null);
  useEffect(() => {
    if (!latest) return;
    if (latest.status === "pending" || latest.status === "running") {
      watching.current = latest.request_id;
    } else if (latest.status === "completed" && watching.current === latest.request_id) {
      watching.current = null;
      onCompleted?.();
    }
  }, [latest, onCompleted]);

  async function calculate() {
    const ok = await request.run(() =>
      apiFetch<CalculationRequestResponse>(`/periods/${periodId}/calculations`, {
        method: "POST",
        body: JSON.stringify({ module }),
      }),
    );
    if (ok) status.reload();
  }

  const label = MODULE_LABEL[module];
  return (
    <div className="stack">
      <div className="row sb">
        <div>
          <strong>{label}</strong>
          <div className="muted">
            {!ready
              ? "Commit the required files for this period first."
              : !latest
                ? "Not calculated yet for this period."
                : latest.status === "pending"
                  ? "Queued — waiting for the calculation service to pick it up."
                  : latest.status === "running"
                    ? "Calculating…"
                    : latest.status === "completed"
                      ? `Calculated ${formatDateTime(latest.completed_at)}.`
                      : "The last calculation did not complete."}
          </div>
        </div>
        <div className="row">
          {latest ? (
            <Chip tone={latest.status === "completed" ? "ok" : latest.status === "failed" ? "bad" : "info"}>
              {latest.status === "completed" ? "Calculated" : latest.status === "failed" ? "Failed" : latest.status === "running" ? "Running" : "Queued"}
            </Chip>
          ) : null}
          {latest?.status === "completed" ? <Link className="btn" href={resultHref}>Open {label}</Link> : null}
          <Button type="button" variant={latest?.status === "completed" ? "default" : "primary"} disabled={!ready || active}
            loading={request.busy} onClick={() => void calculate()}>
            {latest?.status === "completed" ? "Recalculate" : "Calculate"}
          </Button>
        </div>
      </div>
      {latest?.status === "failed" && latest.last_error ? (
        <ErrorPanel title="Calculation failed" message={latest.last_error} />
      ) : null}
      {request.error ? <ErrorPanel message={request.error.message} correlationId={request.error.correlationId} /> : null}
    </div>
  );
}
