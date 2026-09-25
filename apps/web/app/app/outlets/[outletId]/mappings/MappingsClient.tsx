"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useMemo, useState } from "react";
import { Button, Card, Chip, DataTable, Disclosure, EmptyState, ErrorPanel, Select, Skeleton } from "@/components/ui";
import { apiMutate } from "@/lib/api";
import type {
  MappingProfileDetailResponse, MappingProfileListResponse, MappingRevisionRequest,
  MappingRevisionResponse, MappingValueField,
} from "@/lib/contracts";
import { LADDER, MAPPABLE_LINES, templateInfo } from "@/lib/domain";
import { formatDateTime } from "@/lib/format";
import { useOutlet } from "@/lib/outlet-context";
import { useApi, useMutation, useSubmitKey } from "@/lib/use-api";

type Account = MappingProfileDetailResponse["accounts"][number];
type Value = MappingProfileDetailResponse["values"][number];

const VALUE_FIELD: Record<MappingValueField, { title: string; source: string; help: string }> = {
  management_line: {
    title: "Budget lines", source: "Line in your file",
    help: "Which management P&L line each line of your budget, forecast or prior-year file belongs to.",
  },
  product_group: {
    title: "Stock groups", source: "Group in your file",
    help: "Whether each purchases/stock group counts as food or beverage.",
  },
  labour_activity_basis: {
    title: "Labour workload basis", source: "Role group",
    help: "What each role group's workload number counts, e.g. covers or orders.",
  },
};

const isValueField = (field: string): field is MappingValueField => field in VALUE_FIELD;
const ladderLabel = (code: string) => LADDER.find((l) => l.code === code)?.label ?? code;
const valueKey = (v: Value) => `${v.field_name}\u0000${v.source_value}`;

export default function MappingsClient() {
  const router = useRouter();
  const search = useSearchParams();
  const { outletId, href, can } = useOutlet();
  const list = useApi<MappingProfileListResponse>(`/outlets/${outletId}/mapping-profiles`);
  const profiles = useMemo(() => list.data?.profiles ?? [], [list.data]);

  const selectedId = search.get("profile") ?? profiles[0]?.source_profile_id ?? null;
  const versionId = search.get("version");
  const detailPath = selectedId
    ? `/mapping-profiles/${selectedId}${versionId ? `?version_id=${versionId}` : ""}`
    : null;
  const detail = useApi<MappingProfileDetailResponse>(detailPath);
  // Lives here, not in ProfileDetail: that remounts when the saved version loads.
  const [notice, setNotice] = useState<string | null>(null);

  function open(profile: string, version?: string) {
    setNotice(null);
    router.push(href("/mappings", { profile, ...(version ? { version } : {}) }));
  }

  return (
    <main className="shell">
      <div className="panel wide">
        <div className="page-head">
          <h1>Mappings</h1>
          <p>
            How the rows in each file you upload are classified. Change a mapping here and every file read from now on
            uses the new version; months already committed keep the mapping they were read with.
          </p>
        </div>

        {list.loading ? <><Skeleton width="60%" /><Skeleton width="40%" /></> : list.error ? (
          <ErrorPanel message={list.error.message} correlationId={list.error.correlationId} />
        ) : profiles.length === 0 ? (
          <EmptyState title="No saved mappings yet"
            action={<Link className="btn p" href={href("/data")}>Go to Data Centre</Link>}>
            A mapping is saved the first time you upload and map a file. It then appears here.
          </EmptyState>
        ) : (
          <div className="stack">
            <Card title="Saved layouts">
              <ul className="list-plain">
                {profiles.map((p) => {
                  const selected = p.source_profile_id === selectedId;
                  return (
                    <li key={p.source_profile_id} className="row sb">
                      <div>
                        <strong>{p.source_label}</strong>
                        <div className="muted">
                          {templateInfo(p.template_code)?.label ?? p.template_code}
                          {" · "}
                          {[
                            p.account_count ? `${p.account_count} accounts` : null,
                            p.value_count ? `${p.value_count} values` : null,
                            p.item_count ? `${p.item_count} items` : null,
                          ].filter(Boolean).join(", ") || "layout only"}
                        </div>
                      </div>
                      <div className="row">
                        {p.active_version_no !== null ? <Chip tone="mute">Version {p.active_version_no}</Chip> : null}
                        {selected ? <Chip tone="info">Showing</Chip> : (
                          <button type="button" className="btn" onClick={() => open(p.source_profile_id)}>
                            View<span className="sr-only"> {p.source_label}</span>
                          </button>
                        )}
                      </div>
                    </li>
                  );
                })}
              </ul>
            </Card>

            {detail.loading ? <Skeleton width="70%" /> : detail.error ? (
              <ErrorPanel message={detail.error.message} correlationId={detail.error.correlationId} />
            ) : detail.data ? (
              <ProfileDetail
                key={detail.data.version_id}
                detail={detail.data}
                canEdit={detail.data.can_edit && can("admin", "editor", "setup_analyst")}
                notice={notice}
                onVersion={(v) => open(detail.data!.source_profile_id, v)}
                onSaved={(message) => {
                  list.reload();
                  // Drop any ?version= so the new active version loads.
                  if (versionId) open(detail.data!.source_profile_id);
                  else detail.reload();
                  setNotice(message);
                }}
              />
            ) : null}
          </div>
        )}
      </div>
    </main>
  );
}

function ProfileDetail({
  detail, canEdit, notice, onVersion, onSaved,
}: {
  detail: MappingProfileDetailResponse;
  canEdit: boolean;
  notice: string | null;
  onVersion: (versionId: string) => void;
  onSaved: (message: string) => void;
}) {
  const editable = canEdit && detail.is_active;
  const [accountDraft, setAccountDraft] = useState<Record<string, string>>({});
  const [valueDraft, setValueDraft] = useState<Record<string, string>>({});
  const save = useMutation();
  const key = useSubmitKey();

  const accountChanges = detail.accounts.filter(
    (a) => accountDraft[a.source_identity_key] !== undefined && accountDraft[a.source_identity_key] !== a.ladder_line_code,
  );
  const valueChanges = detail.values.filter(
    (v) => valueDraft[valueKey(v)] !== undefined && valueDraft[valueKey(v)].trim() !== v.canonical_value
      && valueDraft[valueKey(v)].trim() !== "",
  );
  const blankValues = detail.values.filter((v) => valueDraft[valueKey(v)] !== undefined && valueDraft[valueKey(v)].trim() === "");
  const changeCount = accountChanges.length + valueChanges.length;

  const valueGroups = useMemo(() => {
    const byField = new Map<MappingValueField, Value[]>();
    for (const v of detail.values) {
      if (!isValueField(v.field_name)) continue;
      byField.set(v.field_name, [...(byField.get(v.field_name) ?? []), v]);
    }
    return [...byField.entries()];
  }, [detail.values]);

  async function submit() {
    if (changeCount === 0 || blankValues.length > 0) return;
    const request: MappingRevisionRequest = {
      account_changes: accountChanges.map((a) => ({
        source_identity_key: a.source_identity_key, ladder_line_code: accountDraft[a.source_identity_key],
      })),
      value_changes: valueChanges.map((v) => ({
        field_name: v.field_name as MappingValueField, source_value: v.source_value,
        canonical_value: valueDraft[valueKey(v)].trim(),
      })),
    };
    const r = await save.run(() => apiMutate<MappingRevisionResponse>(
      `/mapping-profiles/versions/${detail.version_id}/revisions`, request, { key: key.current() },
    ));
    if (r) {
      key.rotate();
      onSaved(`Saved as version ${r.version_no}. Files read from now on use it.`);
    }
  }

  const template = templateInfo(detail.template_code);

  return (
    <Card title={detail.source_label}>
      <div className="stack">
        <p className="muted" style={{ margin: 0 }}>
          {template?.label ?? detail.template_code}
          {detail.approved_at ? <> · version {detail.version_no} approved {formatDateTime(detail.approved_at)}</> : null}
        </p>

        {detail.versions.length > 1 ? (
          <Select label="Version" id="mapping-version" value={detail.version_id} onChange={(e) => onVersion(e.target.value)}
            hint="Earlier versions are kept because committed months were read with them.">
            {detail.versions.map((v) => (
              <option key={v.id} value={v.id}>
                Version {v.version_no}{v.is_active ? " (current)" : ""}
              </option>
            ))}
          </Select>
        ) : null}

        {!detail.is_active ? (
          <div className="banner info">
            You are viewing an earlier version. It is kept for the months that were read with it and cannot be changed.
            {detail.active_version_id ? <> <button type="button" className="btn" onClick={() => onVersion(detail.active_version_id!)}>Show the current version</button></> : null}
          </div>
        ) : !canEdit ? (
          <div className="banner info">You can view mappings. Changing them needs the admin, editor or setup analyst role.</div>
        ) : null}

        {notice ? <div className="banner ok" role="status">{notice}</div> : null}
        {save.error ? <ErrorPanel message={save.error.message} correlationId={save.error.correlationId} /> : null}

        {detail.accounts.length > 0 ? (
          <section className="stack">
            <h3 style={{ margin: 0 }}>Accounts</h3>
            <p className="muted" style={{ margin: 0 }}>The management P&amp;L line each account in your file belongs to.</p>
            <DataTable<Account>
              caption={`Accounts in ${detail.source_label}, version ${detail.version_no}`}
              rows={detail.accounts}
              rowKey={(a) => a.source_identity_key}
              columns={[
                { key: "code", header: "Code", render: (a) => <span className="mono">{a.source_account_code ?? "—"}</span> },
                { key: "name", header: "Account", render: (a) => a.source_account_name },
                {
                  key: "line", header: "P&L line", render: (a) => {
                    const id = `acct-${a.source_identity_key.replace(/[^a-z0-9]+/gi, "-")}`;
                    const value = accountDraft[a.source_identity_key] ?? a.ladder_line_code;
                    if (!editable) return ladderLabel(a.ladder_line_code);
                    return (
                      <>
                        <label className="sr-only" htmlFor={id}>P&amp;L line for {a.source_account_name}</label>
                        <select id={id} value={value}
                          onChange={(e) => setAccountDraft((d) => ({ ...d, [a.source_identity_key]: e.target.value }))}>
                          {MAPPABLE_LINES.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
                        </select>
                        {value !== a.ladder_line_code ? <> <Chip tone="warn">Changed from {ladderLabel(a.ladder_line_code)}</Chip></> : null}
                      </>
                    );
                  },
                },
              ]}
            />
          </section>
        ) : null}

        {valueGroups.map(([field, rows]) => {
          const meta = VALUE_FIELD[field];
          return (
            <section key={field} className="stack">
              <h3 style={{ margin: 0 }}>{meta.title}</h3>
              <p className="muted" style={{ margin: 0 }}>{meta.help}</p>
              <DataTable<Value>
                caption={`${meta.title} in ${detail.source_label}, version ${detail.version_no}`}
                rows={rows}
                rowKey={valueKey}
                columns={[
                  { key: "source", header: meta.source, render: (v) => v.source_value },
                  {
                    key: "target", header: "Maps to", render: (v) => {
                      const id = `val-${field}-${v.source_value.replace(/[^a-z0-9]+/gi, "-")}`;
                      const value = valueDraft[valueKey(v)] ?? v.canonical_value;
                      const shown = field === "management_line" ? ladderLabel(v.canonical_value) : v.canonical_value;
                      if (!editable) return shown;
                      const set = (next: string) => setValueDraft((d) => ({ ...d, [valueKey(v)]: next }));
                      const label = <label className="sr-only" htmlFor={id}>{meta.title}: {v.source_value}</label>;
                      const changed = value.trim() !== v.canonical_value;
                      return (
                        <>
                          {label}
                          {field === "management_line" ? (
                            <select id={id} value={value} onChange={(e) => set(e.target.value)}>
                              {MAPPABLE_LINES.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
                            </select>
                          ) : field === "product_group" ? (
                            <select id={id} value={value} onChange={(e) => set(e.target.value)}>
                              <option value="food">Food</option>
                              <option value="beverage">Beverage</option>
                            </select>
                          ) : (
                            <input id={id} className="textarea" style={{ minHeight: 0 }} value={value} maxLength={120}
                              list="mapping-activity-basis" onChange={(e) => set(e.target.value)} />
                          )}
                          {changed ? <> <Chip tone={value.trim() ? "warn" : "bad"}>{value.trim() ? `Changed from ${shown}` : "Required"}</Chip></> : null}
                        </>
                      );
                    },
                  },
                ]}
              />
            </section>
          );
        })}
        <datalist id="mapping-activity-basis">
          <option value="covers" /><option value="orders" /><option value="outlet covers" /><option value="guests" />
        </datalist>

        {detail.items.length > 0 ? (
          <Disclosure summary={`Menu items (${detail.items.length}, view only)`}>
            <DataTable<MappingProfileDetailResponse["items"][number]>
              caption={`Menu items in ${detail.source_label}, version ${detail.version_no}`}
              rows={detail.items}
              rowKey={(i) => `${i.source_item_code ?? ""}\u0000${i.source_item_name}`}
              columns={[
                { key: "code", header: "Code", render: (i) => <span className="mono">{i.source_item_code ?? "—"}</span> },
                { key: "name", header: "Item in your file", render: (i) => i.source_item_name },
                { key: "key", header: "Stable item key", render: (i) => <span className="mono">{i.canonical_item_key}</span> },
              ]}
            />
          </Disclosure>
        ) : null}

        {detail.columns.length > 0 ? (
          <Disclosure summary={`File columns (${detail.columns.length})`}>
            <DataTable<MappingProfileDetailResponse["columns"][number]>
              caption={`Columns recognised in ${detail.source_label}`}
              rows={detail.columns}
              rowKey={(c) => c.source_column}
              columns={[
                { key: "col", header: "Column in your file", render: (c) => c.source_column },
                { key: "field", header: "Read as", render: (c) => <span className="mono">{c.canonical_field}</span> },
              ]}
            />
          </Disclosure>
        ) : null}

        {editable && (detail.accounts.length > 0 || valueGroups.length > 0) ? (
          <div className="actions-bar">
            <Button variant="primary" loading={save.busy} disabled={changeCount === 0 || blankValues.length > 0}
              onClick={() => void submit()}>
              Save as version {Math.max(...detail.versions.map((v) => v.version_no)) + 1}
            </Button>
            <Button disabled={changeCount === 0 && blankValues.length === 0 || save.busy}
              onClick={() => { setAccountDraft({}); setValueDraft({}); save.clearError(); }}>
              Discard changes
            </Button>
            <span className="muted">
              {blankValues.length > 0 ? "Fill in every value before saving."
                : changeCount === 0 ? "No changes yet."
                : `${changeCount} ${changeCount === 1 ? "change" : "changes"} · applies to files read after you save.`}
            </span>
          </div>
        ) : null}
      </div>
    </Card>
  );
}
