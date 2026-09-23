"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { apiFetch, ApiError } from "@/lib/api";
import type { OutletControlsResponse } from "@/lib/contracts";
import {
  Button,
  Card,
  Chip,
  DataTable,
  ErrorPanel,
  Field,
  Select,
  Skeleton,
} from "@/components/ui";

type FormState = {
  primaryComparator: string;
  taxBasis: string;
  signConvention: string;
  popularityFactor: string;
  posToPlPct: string;
  purchasesToPlPct: string;
  posItemToLedgerPct: string;
  foodBenchmarkPct: string;
  beverageBenchmarkPct: string;
  gapBenchmark: string;
  reportingCalendar: string;
};

const blank: FormState = {
  primaryComparator: "",
  taxBasis: "",
  signConvention: "",
  popularityFactor: "",
  posToPlPct: "",
  purchasesToPlPct: "",
  posItemToLedgerPct: "",
  foodBenchmarkPct: "",
  beverageBenchmarkPct: "",
  gapBenchmark: "",
  reportingCalendar: "",
};

function textValue(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function pctForForm(value: unknown): string {
  if (value === null || value === undefined || value === "") return "";
  const number = Number(value);
  return Number.isFinite(number) ? String(number * 100) : "";
}

function pctForApi(value: string): string {
  return String(Number(value) / 100);
}

export default function SettingsClient({ outletId }: { outletId: string }) {
  const [controls, setControls] = useState<OutletControlsResponse | null>(null);
  const [form, setForm] = useState<FormState>(blank);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(false);
  const [materialitySaving, setMaterialitySaving] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<ApiError | null>(null);
  const settingsKey = useRef(crypto.randomUUID());
  const materialityKey = useRef(crypto.randomUUID());

  async function reload() {
    setLoading(true);
    setError(null);
    try {
      const data = await apiFetch<OutletControlsResponse>(`/outlets/${outletId}/controls`);
      setControls(data);
      setForm({
        primaryComparator: textValue(data.settings.primary_comparator),
        taxBasis: textValue(data.settings.tax_basis),
        signConvention: textValue(data.settings.sign_convention),
        popularityFactor: textValue(data.settings.popularity_factor),
        posToPlPct: pctForForm(data.settings.reconciliation_pos_to_pl_pct),
        purchasesToPlPct: pctForForm(data.settings.reconciliation_purchases_to_pl_pct),
        posItemToLedgerPct: pctForForm(data.settings.reconciliation_pos_item_to_ledger_pct),
        foodBenchmarkPct: pctForForm(data.settings.food_benchmark_pct),
        beverageBenchmarkPct: pctForForm(data.settings.beverage_benchmark_pct),
        gapBenchmark: textValue(data.settings.gap_benchmark),
        reportingCalendar: textValue(data.settings.reporting_calendar),
      });
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Outlet controls could not be loaded.", 500, null),
      );
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void reload();
  }, [outletId]);

  function patch<K extends keyof FormState>(key: K, value: FormState[K]) {
    setForm((current) => ({ ...current, [key]: value }));
  }

  async function saveSettings(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setError(null);
    setMessage(null);

    const settings: { key: string; value: unknown }[] = [];
    if (form.primaryComparator) settings.push({ key: "primary_comparator", value: form.primaryComparator });
    if (form.taxBasis) settings.push({ key: "tax_basis", value: form.taxBasis });
    if (form.signConvention) settings.push({ key: "sign_convention", value: form.signConvention });
    if (form.popularityFactor) settings.push({ key: "popularity_factor", value: form.popularityFactor });
    if (form.posToPlPct) settings.push({ key: "reconciliation_pos_to_pl_pct", value: pctForApi(form.posToPlPct) });
    if (form.purchasesToPlPct) settings.push({ key: "reconciliation_purchases_to_pl_pct", value: pctForApi(form.purchasesToPlPct) });
    if (form.posItemToLedgerPct) settings.push({ key: "reconciliation_pos_item_to_ledger_pct", value: pctForApi(form.posItemToLedgerPct) });
    if (form.foodBenchmarkPct) settings.push({ key: "food_benchmark_pct", value: pctForApi(form.foodBenchmarkPct) });
    if (form.beverageBenchmarkPct) settings.push({ key: "beverage_benchmark_pct", value: pctForApi(form.beverageBenchmarkPct) });
    if (form.gapBenchmark) settings.push({ key: "gap_benchmark", value: form.gapBenchmark });
    if (form.reportingCalendar) settings.push({ key: "reporting_calendar", value: form.reportingCalendar });

    if (settings.length === 0) {
      setMessage("Nothing to save.");
      setSaving(false);
      return;
    }

    try {
      await apiFetch(`/outlets/${outletId}/settings/batch`, {
        method: "PUT",
        headers: { "Idempotency-Key": settingsKey.current },
        body: JSON.stringify({ settings }),
      });
      settingsKey.current = crypto.randomUUID();
      setMessage("Outlet settings saved.");
      await reload();
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Outlet settings could not be saved.", 500, null),
      );
    } finally {
      setSaving(false);
    }
  }

  async function saveMateriality(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setMaterialitySaving(true);
    setError(null);
    setMessage(null);
    const data = new FormData(event.currentTarget);
    const amount = String(data.get("absolute_threshold") ?? "").trim();
    const pct = String(data.get("percent_threshold") ?? "").trim();
    const recurrence = String(data.get("recurrence_rule") ?? "").trim();

    try {
      await apiFetch(`/outlets/${outletId}/materiality`, {
        method: "POST",
        headers: { "Idempotency-Key": materialityKey.current },
        body: JSON.stringify({
          scope_type: String(data.get("scope_type") ?? "general"),
          absolute_threshold: amount ? amount : null,
          percent_threshold: pct ? pctForApi(pct) : null,
          recurrence_rule: recurrence ? { rule: recurrence } : {},
          risk_override_enabled: data.get("risk_override_enabled") === "on",
          proposal_basis: { basis: "explicit confirmation in Settings" },
          effective_from: String(data.get("effective_from") ?? ""),
        }),
      });
      materialityKey.current = crypto.randomUUID();
      event.currentTarget.reset();
      setMessage("New materiality version created. Earlier approved values were preserved.");
      await reload();
    } catch (cause) {
      setError(
        cause instanceof ApiError
          ? cause
          : new ApiError("Materiality could not be saved.", 500, null),
      );
    } finally {
      setMaterialitySaving(false);
    }
  }

  const materialityRows = useMemo(() => controls?.materiality ?? [], [controls]);

  return (
    <main className="shell">
      <div className="panel" style={{ width: "min(100%, 980px)" }}>
        <div className="page-head">
          <h1>Settings and controls</h1>
          <p>
            {controls
              ? `${controls.outlet_name} · ${controls.currency_code} · ${controls.timezone}`
              : "Loading authorised outlet configuration."}
          </p>
        </div>

        {error ? <ErrorPanel message={error.message} correlationId={error.correlationId} /> : null}
        {message ? <div className="banner info" role="status">{message}</div> : null}
        {loading && !controls ? <><Skeleton /><Skeleton width="62%" /></> : null}

        {controls ? (
          <div className="stack">
            <Card title="Review defaults">
              <form onSubmit={saveSettings} className="stack">
                <div className="g2">
                  <Select
                    label="Primary comparator"
                    name="primary_comparator"
                    value={form.primaryComparator}
                    onChange={(event) => patch("primaryComparator", event.target.value)}
                    hint="Budget or Prior Year. Latest Forecast remains a separate R2 view."
                  >
                    <option value="">Not set</option>
                    <option value="budget">Budget</option>
                    <option value="prior_year">Prior year</option>
                  </Select>
                  <Select
                    label="Tax basis"
                    name="tax_basis"
                    value={form.taxBasis}
                    onChange={(event) => patch("taxBasis", event.target.value)}
                  >
                    <option value="">Not set</option>
                    <option value="tax_exclusive">Tax exclusive</option>
                    <option value="tax_inclusive">Tax inclusive</option>
                  </Select>
                  <Select
                    label="Sign convention"
                    name="sign_convention"
                    value={form.signConvention}
                    onChange={(event) => patch("signConvention", event.target.value)}
                  >
                    <option value="">Not set</option>
                    <option value="income_positive_costs_positive">Income positive, costs positive</option>
                    <option value="income_positive_costs_negative">Income positive, costs negative</option>
                  </Select>
                  <Field
                    label="Menu popularity factor"
                    name="popularity_factor"
                    type="number"
                    step="0.01"
                    min="0.01"
                    value={form.popularityFactor}
                    onChange={(event) => patch("popularityFactor", event.target.value)}
                    hint="Stored as an outlet setting; no value is assumed when blank."
                  />
                  <Select
                    label="Food-cost gap benchmark"
                    name="gap_benchmark"
                    value={form.gapBenchmark}
                    onChange={(event) => patch("gapBenchmark", event.target.value)}
                  >
                    <option value="">Not set</option>
                    <option value="budget_pct">Budget %</option>
                    <option value="prior_period_pct">Prior period %</option>
                    <option value="expected_usage">Expected usage</option>
                  </Select>
                  <Select
                    label="Reporting calendar"
                    name="reporting_calendar"
                    value={form.reportingCalendar}
                    onChange={(event) => patch("reportingCalendar", event.target.value)}
                  >
                    <option value="">Not set</option>
                    <option value="calendar_month">Calendar month</option>
                    <option value="4-4-5_weeks">4-4-5 weeks</option>
                    <option value="4_or_5_week_periods">4 or 5 week periods</option>
                  </Select>
                  <Field
                    label="Food benchmark (%)"
                    name="food_benchmark_pct"
                    type="number"
                    min="0.01"
                    max="100"
                    step="0.01"
                    value={form.foodBenchmarkPct}
                    onChange={(event) => patch("foodBenchmarkPct", event.target.value)}
                  />
                  <Field
                    label="Beverage benchmark (%)"
                    name="beverage_benchmark_pct"
                    type="number"
                    min="0.01"
                    max="100"
                    step="0.01"
                    value={form.beverageBenchmarkPct}
                    onChange={(event) => patch("beverageBenchmarkPct", event.target.value)}
                  />
                </div>

                <h3 style={{ marginBottom: 0 }}>Cross-file reconciliation tolerances</h3>
                <div className="g2">
                  <Field
                    label="POS/category sales ↔ P&L (%)"
                    name="pos_to_pl_pct"
                    type="number"
                    min="0.0001"
                    max="100"
                    step="0.01"
                    value={form.posToPlPct}
                    onChange={(event) => patch("posToPlPct", event.target.value)}
                    hint="R1 reference from the import specification: 0.5%. It is not persisted until you confirm it."
                  />
                  <Field
                    label="Purchases ↔ mapped P&L purchases (%)"
                    name="purchases_to_pl_pct"
                    type="number"
                    min="0.0001"
                    max="100"
                    step="0.01"
                    value={form.purchasesToPlPct}
                    onChange={(event) => patch("purchasesToPlPct", event.target.value)}
                    hint="R1 reference: 2%."
                  />
                  <Field
                    label="POS item revenue ↔ ledger net sales (%)"
                    name="pos_item_to_ledger_pct"
                    type="number"
                    min="0.0001"
                    max="100"
                    step="0.01"
                    value={form.posItemToLedgerPct}
                    onChange={(event) => patch("posItemToLedgerPct", event.target.value)}
                    hint="Wireframe R2 reference: 2%."
                  />
                </div>
                <div className="banner info">
                  Calculation parity tolerance is an engine/test control and is intentionally not editable here.
                </div>
                <Button type="submit" variant="primary" loading={saving}>Save outlet settings</Button>
              </form>
            </Card>

            <Card title="Materiality">
              <div className="banner info">
                A new outlet does not receive a hidden absolute threshold. Once comparator Net Sales is available,
                the product may propose approximately 0.5% of monthly comparator Net Sales. The percentage starting
                reference is 10% of the individual comparator line. A user must confirm the values before formal review use.
              </div>
              <form onSubmit={saveMateriality} className="stack">
                <div className="g2">
                  <Select label="Scope" name="scope_type" defaultValue="general">
                    <option value="general">General</option>
                    <option value="food">Food</option>
                    <option value="beverage">Beverage</option>
                    <option value="labour">Labour</option>
                    <option value="other_cost">Other cost</option>
                    <option value="menu">Menu</option>
                  </Select>
                  <Field label={`Absolute threshold (${controls.currency_code})`} name="absolute_threshold" type="number" min="0.01" step="0.01" />
                  <Field label="Percentage threshold (%)" name="percent_threshold" type="number" min="0.01" max="100" step="0.01" placeholder="10" />
                  <Field label="Effective from" name="effective_from" type="date" required />
                  <Field
                    label="Recurrence trigger"
                    name="recurrence_rule"
                    placeholder="e.g. same cause in consecutive reviews"
                  />
                </div>
                <label className="row">
                  <input type="checkbox" name="risk_override_enabled" />
                  <span>Enable separate risk/control override for safety, control, legal or serious guest impact.</span>
                </label>
                <Button type="submit" variant="primary" loading={materialitySaving}>Create materiality version</Button>
              </form>

              {materialityRows.length ? (
                <div className="mt8">
                  <DataTable
                    caption="Materiality history"
                    rows={materialityRows}
                    rowKey={(row) => row.id}
                    columns={[
                      { key: "scope", header: "Scope", render: (row) => row.scope_type },
                      { key: "amount", header: "Amount", align: "right", render: (row) => row.absolute_threshold ?? "—" },
                      { key: "pct", header: "%", align: "right", render: (row) => row.percent_threshold ? String(Number(row.percent_threshold) * 100) : "—" },
                      { key: "effective", header: "Effective", render: (row) => row.effective_to ? `${row.effective_from} to ${row.effective_to}` : `${row.effective_from} onward` },
                      { key: "source", header: "Status", render: (row) => <Chip tone={row.effective_to ? "mute" : "ok"}>{row.source_kind}</Chip> },
                    ]}
                  />
                </div>
              ) : (
                <div className="empty mt8">No materiality version has been confirmed for this outlet.</div>
              )}
            </Card>
          </div>
        ) : null}
      </div>
    </main>
  );
}
