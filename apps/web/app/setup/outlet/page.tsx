"use client";

import { useEffect, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { BootstrapResponse } from "@/lib/contracts";
import { Button, ErrorPanel, Field } from "@/components/ui";
import { useSetupDraft } from "../SetupDraftContext";

export default function OutletSetupPage() {
  const router = useRouter();
  const { organisation } = useSetupDraft();
  const idempotencyKey = useRef(crypto.randomUUID());
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  useEffect(() => {
    if (!organisation) router.replace("/setup/organisation");
  }, [organisation, router]);

  if (!organisation) return null;

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setError(null);
    const form = new FormData(event.currentTarget);

    try {
      const result = await apiFetch<BootstrapResponse>("/setup/bootstrap", {
        method: "POST",
        headers: { "Idempotency-Key": idempotencyKey.current },
        body: JSON.stringify({
          organisation_name: organisation.name,
          organisation_slug: organisation.slug,
          outlet_name: String(form.get("outlet_name") ?? ""),
          outlet_code: String(form.get("outlet_code") ?? "") || null,
          currency_code: String(form.get("currency_code") ?? ""),
          timezone: String(form.get("timezone") ?? ""),
          fiscal_year_start_month: Number(form.get("fiscal_year_start_month")),
        }),
      });
      router.push(`/setup/context?organisation=${result.organisation_id}&outlet=${result.outlet_id}`);
    } catch (cause) {
      setError(cause instanceof ApiError ? cause : new ApiError("Setup could not be completed.", 500, null));
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="done">1 Organisation</li><li className="cur">2 Outlet</li><li>3 Context</li><li>4 Period</li>
        </ol>
        <div className="page-head">
          <h1>Create first outlet</h1>
          <p>One reporting currency is configured per outlet in R1.</p>
        </div>
        <form onSubmit={submit} className="stack">
          <Field label="Outlet name" name="outlet_name" required />
          <Field label="Outlet code" name="outlet_code" hint="Optional internal short code." />
          <div className="g2">
            <Field label="Reporting currency" name="currency_code" defaultValue="USD" minLength={3} maxLength={3} required />
            <Field label="Timezone" name="timezone" defaultValue="UTC" required />
          </div>
          <Field label="Fiscal year start month" name="fiscal_year_start_month" type="number" min={1} max={12} defaultValue={1} required />
          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
          <div className="row sb">
            <Button type="button" onClick={() => router.back()}>Back</Button>
            <Button type="submit" variant="primary" loading={pending}>Create organisation & outlet</Button>
          </div>
        </form>
      </div>
    </main>
  );
}
