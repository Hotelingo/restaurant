"use client";

import { useRef, useState } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { apiFetch, ApiError } from "@/lib/api";
import type { ContextVersionResponse } from "@/lib/contracts";
import { Button, ErrorPanel, Field } from "@/components/ui";

function list(value: FormDataEntryValue | null) {
  return String(value ?? "").split(",").map((item) => item.trim()).filter(Boolean);
}

export default function ContextSetupClient() {
  const router = useRouter();
  const search = useSearchParams();
  const outletId = search.get("outlet");
  const organisationId = search.get("organisation");
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
      const result = await apiFetch<ContextVersionResponse>(`/outlets/${outletId}/context`, {
        method: "POST",
        headers: { "Idempotency-Key": key.current },
        body: JSON.stringify({
          service_style: String(form.get("service_style") ?? "") || null,
          seats: form.get("seats") ? Number(form.get("seats")) : null,
          meal_periods: list(form.get("meal_periods")),
          business_formats: list(form.get("business_formats")),
          customer_sources: list(form.get("customer_sources")),
          recipe_costing_status: String(form.get("recipe_costing_status") ?? "") || null,
          labour_recording_basis: String(form.get("labour_recording_basis") ?? "") || null,
          source_tracking_quality: String(form.get("source_tracking_quality") ?? "") || null,
          evidence_maturity: String(form.get("evidence_maturity") ?? "") || null,
          effective_from: String(form.get("effective_from") ?? ""),
        }),
      });

      router.push(
        `/setup/period?organisation=${organisationId}&outlet=${outletId}&contextVersion=${result.version_no}`,
      );
    } catch (cause) {
      setError(cause instanceof ApiError ? cause : new ApiError("Restaurant context could not be saved.", 500, null));
    } finally {
      setPending(false);
    }
  }

  return (
    <main className="shell">
      <div className="panel">
        <ol className="stepper" aria-label="Setup progress">
          <li className="done">1 Organisation</li><li className="done">2 Outlet</li><li className="cur">3 Context</li><li>4 Period</li>
        </ol>
        <div className="page-head">
          <h1>Restaurant context</h1>
          <p>Create context version 1. Optional information stays missing when you leave it blank.</p>
        </div>

        <form onSubmit={submit} className="stack">
          <div className="g2">
            <Field label="Service style" name="service_style" placeholder="e.g. casual dining" />
            <Field label="Seats / capacity" name="seats" type="number" min={0} />
          </div>
          <Field label="Meal periods" name="meal_periods" placeholder="Breakfast, Lunch, Dinner" hint="Comma-separated." />
          <Field label="Business formats" name="business_formats" placeholder="Dine-in, Delivery" hint="Comma-separated." />
          <Field label="Important customer sources" name="customer_sources" placeholder="Walk-in, Online, Corporate" hint="Comma-separated." />
          <div className="g2">
            <Field label="Recipe-costing status" name="recipe_costing_status" placeholder="Complete / Partial / Missing" />
            <Field label="Labour recording basis" name="labour_recording_basis" placeholder="Clocked hours / Roster / Payroll only" />
            <Field label="Source-tracking quality" name="source_tracking_quality" placeholder="Strong / Moderate / Limited" />
            <Field label="Evidence maturity" name="evidence_maturity" placeholder="Mature / Developing / Early" />
          </div>
          <Field label="Effective from" name="effective_from" type="date" required />

          {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
          <div className="row sb">
            <Button type="button" onClick={() => router.back()}>Back</Button>
            <Button type="submit" variant="primary" loading={pending}>Save context & continue</Button>
          </div>
        </form>
      </div>
    </main>
  );
}
