"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { AdditionalOutletResponse } from "@/lib/contracts";
import { Button, ErrorPanel, Field } from "@/components/ui";

export default function NewOutletClient({ organisationId }: { organisationId: string }) {
  const router = useRouter();
  const key = useRef(crypto.randomUUID());
  const [pending, setPending] = useState(false);
  const [error, setError] = useState<ApiError | null>(null);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const form = new FormData(event.currentTarget);
    setPending(true);
    setError(null);

    try {
      const result = await apiFetch<AdditionalOutletResponse>(
        `/organisations/${organisationId}/outlets`,
        {
          method: "POST",
          headers: { "Idempotency-Key": key.current },
          body: JSON.stringify({
            name: String(form.get("name") ?? ""),
            code: String(form.get("code") ?? "") || null,
            currency_code: String(form.get("currency_code") ?? ""),
            timezone: String(form.get("timezone") ?? ""),
            fiscal_year_start_month: Number(form.get("fiscal_year_start_month")),
          }),
        },
      );
      router.push(`/app/outlets/${result.outlet_id}/settings`);
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Outlet could not be created.", 500, null),
      );
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="shell">
      <div className="panel">
        <div className="page-head">
          <h1>Add outlet</h1>
          <p>R1 supports multiple outlets inside one organisation. Cross-outlet roll-up is not part of R1.</p>
        </div>
        <form onSubmit={submit} className="stack">
          <Field label="Outlet name" name="name" required />
          <Field label="Outlet code" name="code" />
          <div className="g2">
            <Field label="Reporting currency" name="currency_code" defaultValue="USD" minLength={3} maxLength={3} required />
            <Field label="Timezone" name="timezone" defaultValue="UTC" required />
          </div>
          <Field label="Fiscal year start month" name="fiscal_year_start_month" type="number" min={1} max={12} defaultValue={1} required />
          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
          <div className="row sb">
            <Button type="button" onClick={() => router.back()}>Cancel</Button>
            <Button type="submit" variant="primary" loading={pending}>Create outlet</Button>
          </div>
        </form>
      </div>
    </main>
  );
}
