"use client";

import { useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { ReportingPeriodResponse } from "@/lib/contracts";
import { Button, ErrorPanel, Field } from "@/components/ui";

export default function PeriodSetupPage() {
  const router = useRouter();
  const search = useSearchParams();
  const outletId = search.get("outlet");
  const organisationId = search.get("organisation");
  const contextVersion = search.get("contextVersion");
  const key = useRef(crypto.randomUUID());
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!outletId || !organisationId) {
      router.replace("/auth/continue");
      return;
    }

    const form = new FormData(event.currentTarget);
    setPending(true);
    setError(null);

    try {
      const result = await apiFetch<ReportingPeriodResponse>(`/outlets/${outletId}/periods`, {
        method: "POST",
        headers: { "Idempotency-Key": key.current },
        body: JSON.stringify({
          period_start: String(form.get("period_start") ?? ""),
          period_end: String(form.get("period_end") ?? ""),
          label: String(form.get("label") ?? ""),
        }),
      });

      router.push(
        `/setup/complete?outlet=${outletId}&period=${result.period_id}&contextVersion=${contextVersion ?? ""}`,
      );
    } catch (cause) {
      setError(cause instanceof ApiError ? cause : new ApiError("Reporting period could not be created.", 500, null));
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="done">1 Organisation</li><li className="done">2 Outlet</li><li className="done">3 Context</li><li className="cur">4 Period</li>
        </ol>
        <div className="page-head">
          <h1>First reporting period</h1>
          <p>Only period metadata belongs here. Financial values enter through the Data Centre.</p>
        </div>

        <form onSubmit={submit} className="stack">
          <Field label="Period label" name="label" placeholder="September 2026" required />
          <div className="g2">
            <Field label="Start date" name="period_start" type="date" required />
            <Field label="End date" name="period_end" type="date" required />
          </div>
          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
          <div className="row sb">
            <Button type="button" onClick={() => router.back()}>Back</Button>
            <Button type="submit" variant="primary" loading={pending}>Create period</Button>
          </div>
        </form>
      </div>
    </main>
  );
}
