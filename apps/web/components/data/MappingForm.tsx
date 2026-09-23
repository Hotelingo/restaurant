"use client";

import { useMemo, useState } from "react";
import { Button, ErrorPanel, Field } from "@/components/ui";
import type { ImportExceptionItem, MappingConfirmRequest } from "@/lib/contracts";
import { MAPPABLE_LINES, suggestLadderCode } from "@/lib/domain";

const KIND_TITLE: Record<string, { title: string; help: string }> = {
  account: { title: "Accounts", help: "Choose the management P&L line each account belongs to. You do this once; later uploads with the same accounts reuse it." },
  management_line: { title: "Budget lines", help: "Match each line in your budget file to a management P&L line." },
  product_group: { title: "Product groups", help: "Tell us whether each stock group is food or beverage." },
  item: { title: "Menu items", help: "Give each item a stable key. Keep the POS code unless two codes are really the same item." },
  labour_activity_basis: { title: "Labour workload basis", help: "Say what each role group's workload number counts, e.g. \"covers\" or \"orders\". Only groups with the same basis are ever added together." },
};

function label(item: ImportExceptionItem): { primary: string; secondary: string | null } {
  if (item.kind === "account" || item.kind === "item") {
    const code = item.source_account_code;
    const name = item.source_account_name;
    return { primary: name ?? code ?? item.identity, secondary: code && name ? code : null };
  }
  return { primary: item.source_value ?? item.identity, secondary: null };
}

function initialValue(item: ImportExceptionItem): string {
  switch (item.kind) {
    case "account":
      return suggestLadderCode(item.suggested_management_line);
    case "management_line":
      return suggestLadderCode(item.source_value);
    case "product_group": {
      const v = (item.source_value ?? "").toLowerCase();
      return v.startsWith("food") ? "food" : v.startsWith("bev") || v.includes("drink") ? "beverage" : "";
    }
    case "item":
      return (item.source_account_code ?? item.source_account_name ?? "").trim();
    default:
      return "";
  }
}

export function MappingForm({
  exceptions,
  defaultSourceLabel,
  busy,
  error,
  onConfirm,
}: {
  exceptions: ImportExceptionItem[];
  /** Pre-filled name for a new layout; the API requires one for a first mapping. */
  defaultSourceLabel: string;
  busy: boolean;
  error: string | null;
  onConfirm: (request: MappingConfirmRequest) => void;
}) {
  const [values, setValues] = useState<Record<string, string>>(() =>
    Object.fromEntries(exceptions.map((e) => [e.identity, initialValue(e)])),
  );
  const [sourceLabel, setSourceLabel] = useState(defaultSourceLabel);
  const groups = useMemo(() => {
    const byKind = new Map<string, ImportExceptionItem[]>();
    for (const e of exceptions) byKind.set(e.kind, [...(byKind.get(e.kind) ?? []), e]);
    return [...byKind.entries()];
  }, [exceptions]);

  const missing = exceptions.filter((e) => !values[e.identity]?.trim()).length + (sourceLabel.trim() ? 0 : 1);
  const suggested = exceptions.filter((e) => initialValue(e) !== "").length;

  function submit() {
    const v = (e: ImportExceptionItem) => values[e.identity].trim();
    const of = (kind: string) => exceptions.filter((e) => e.kind === kind);
    onConfirm({
      source_label: sourceLabel.trim() || null,
      account_mappings: of("account").map((e) => ({
        source_account_code: e.source_account_code ?? null,
        source_account_name: e.source_account_name ?? e.source_account_code ?? e.identity,
        ladder_line_code: v(e),
      })),
      management_line_mappings: of("management_line").map((e) => ({ source_value: e.source_value ?? e.identity, ladder_line_code: v(e) })),
      product_group_mappings: of("product_group").map((e) => ({
        source_value: e.source_value ?? e.identity, canonical_value: v(e) as "food" | "beverage",
      })),
      item_mappings: of("item").map((e) => ({
        source_item_code: e.source_account_code ?? null, source_item_name: e.source_account_name ?? null, canonical_item_key: v(e),
      })),
      labour_activity_basis_mappings: of("labour_activity_basis").map((e) => ({ source_role_group: e.source_value ?? e.identity, activity_basis: v(e) })),
    });
  }

  return (
    <form className="stack" onSubmit={(ev) => { ev.preventDefault(); if (missing === 0) submit(); }}>
      <div className="banner info">
        <strong>{exceptions.length} {exceptions.length === 1 ? "row needs" : "rows need"} mapping.</strong>{" "}
        {suggested > 0 ? `${suggested} ${suggested === 1 ? "has" : "have"} a suggestion filled in — check each one. ` : ""}
        Nothing is saved until you confirm, and amounts are never used to guess a mapping.
      </div>

      {groups.map(([kind, items]) => {
        const meta = KIND_TITLE[kind] ?? { title: kind, help: "" };
        return (
          <fieldset key={kind} className="card" style={{ border: "1px solid var(--line)" }}>
            <legend className="card-h" style={{ padding: "0 4px" }}><h2>{meta.title}</h2></legend>
            {meta.help ? <p className="muted" style={{ margin: "0 0 8px" }}>{meta.help}</p> : null}
            <div>
              {items.map((item) => {
                const { primary, secondary } = label(item);
                const id = `map-${item.identity.replace(/[^a-z0-9]+/gi, "-")}`;
                const rows = item.source_row_numbers.length;
                return (
                  <div key={item.identity} className="map-row">
                    <label className="map-src" htmlFor={id}>
                      {primary}
                      <small>
                        {secondary ? <>Code {secondary} · </> : null}
                        {rows} {rows === 1 ? "row" : "rows"}
                        {item.suggested_management_line ? <> · file suggests “{item.suggested_management_line}”</> : null}
                      </small>
                    </label>
                    {kind === "account" || kind === "management_line" ? (
                      <select id={id} value={values[item.identity]} required
                        onChange={(e) => setValues((s) => ({ ...s, [item.identity]: e.target.value }))}>
                        <option value="">Choose a P&amp;L line…</option>
                        {MAPPABLE_LINES.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
                      </select>
                    ) : kind === "product_group" ? (
                      <select id={id} value={values[item.identity]} required
                        onChange={(e) => setValues((s) => ({ ...s, [item.identity]: e.target.value }))}>
                        <option value="">Choose…</option>
                        <option value="food">Food</option>
                        <option value="beverage">Beverage</option>
                      </select>
                    ) : (
                      <input id={id} className="textarea" style={{ minHeight: 0 }} value={values[item.identity]} required
                        list={kind === "labour_activity_basis" ? "activity-basis-options" : undefined}
                        onChange={(e) => setValues((s) => ({ ...s, [item.identity]: e.target.value }))} />
                    )}
                  </div>
                );
              })}
            </div>
          </fieldset>
        );
      })}
      <datalist id="activity-basis-options">
        <option value="covers" /><option value="orders" /><option value="outlet covers" /><option value="guests" />
      </datalist>

      <Field id="mapping-source-label" label="Name this source" required
        hint="How you will recognise this layout next time, e.g. “Xero P&L export”."
        value={sourceLabel} onChange={(e) => setSourceLabel(e.target.value)} maxLength={120} />

      {error ? <ErrorPanel message={error} /> : null}
      <div className="actions-bar">
        <Button type="submit" variant="primary" loading={busy} disabled={missing > 0}>Confirm mapping</Button>
        {missing > 0 ? <span className="muted">{missing} still to choose.</span> : null}
      </div>
    </form>
  );
}
